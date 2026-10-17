import Foundation

// The rules both remote-access bridges follow (docs/HOST-API.md "Remote access (iroh)", "The two
// apps"): the Mac's, which copies each iroh stream to a connection to the host's tunnel socket, and
// the phone's, which copies each of `APIClient`'s loopback connections to an iroh stream. The Mac's is
// AgentLandDesktopCore's `MacTunnelBridge`, the phone's AgentLandRemoteAccess's `TunnelBridge`; these
// types hold the parts of their rules that are easy to get wrong, so both follow the same ones.

extension RemoteAccessTunnel {
    /// The phone bridge's limits ("The phone's bridge").
    public enum Bridge {
        /// Streams open at once, half the host's 16 tunnel connections per device.
        public static let maximumStreams = 8
        /// Streams opened in any minute, half the host's 60.
        public static let maximumStreamsPerMinute = 30
        /// Connections that wait for a request head at once (`WaitingRoom`).
        public static let maximumWaiting = 16
        /// The longest request head.
        public static let maximumHeadBytes = 4096
        /// How long a connection has for each head: the first after it opens, the second after the
        /// 407. URLSession writes each within a millisecond over loopback (about 0.1 ms and 0.3 ms
        /// on macOS 26), so this only bounds connections that send nothing.
        public static let headTimeout: Duration = .milliseconds(250)

        /// The connections that have not shown the bridge's credential yet.
        ///
        /// Any app on the phone can open connections to the bridge's port, so a full room must not
        /// keep `APIClient`'s out: a connection that arrives while `capacity` wait takes the place of
        /// the one that has waited longest, which the bridge closes. A connection leaves the room when
        /// it shows the credential (it is never closed for room after that), and when it is closed for
        /// any other reason (a refused or late head, its peer closing). `APIClient`'s connections wait
        /// well under a millisecond, so an app that only holds connections open cannot push them out;
        /// one that keeps opening connections faster than that can, while it runs, but none of its
        /// connections reaches the Mac.
        public struct WaitingRoom<Connection: Hashable & Sendable>: Sendable {
            public let capacity: Int
            /// Oldest first.
            public private(set) var waiting: [Connection] = []

            public init(capacity: Int = Bridge.maximumWaiting) {
                precondition(capacity >= 1, "a waiting room holds at least one connection")
                self.capacity = capacity
            }

            /// A connection arrived. Returns the connection to close to make room for it (the one that
            /// has waited longest) when the room was full; the new one always gets in.
            public mutating func arrive(_ connection: Connection) -> Connection? {
                guard !waiting.contains(connection) else { return nil }
                var evicted: Connection?
                if waiting.count >= capacity { evicted = waiting.removeFirst() }
                waiting.append(connection)
                return evicted
            }

            /// The connection showed the credential or was closed: it no longer waits.
            public mutating func leave(_ connection: Connection) {
                waiting.removeAll { $0 == connection }
            }
        }
    }

    /// How a bridge ends one stream and the socket it carries ("Ending a stream").
    ///
    /// A stream carries two directions, and each ends on its own:
    /// - Sending, from the socket's reads into the stream's sending side: the socket's end of file
    ///   finishes the stream, and a failed read resets it with code 1. When the peer stops the
    ///   stream's sending side, the bridge reads and drops what the socket still sends until its end,
    ///   so it never closes a socket with unread input (on TCP that sends a reset, which can make the
    ///   other side drop bytes it has received but not read).
    /// - Receiving, from the stream's receiving side into the socket's writes: the stream's end shuts
    ///   down the socket's sending side, a failed write stops the stream's receiving side with code 1,
    ///   and a reset from the peer aborts the socket.
    ///
    /// A failure in one direction never resets the other: a sending side that has finished stays
    /// finished, so QUIC retransmits what it sent (the host's last bytes before it closed its socket)
    /// until the peer has it, even when a write in the other direction then fails. Only a failed read
    /// or an abort ends both, because the socket is gone. The Mac's bridge reports `hostRefused` in
    /// place of the socket's end when the host sent nothing (code 2).
    public struct StreamEnds: Sendable, Equatable {
        public enum Sending: Sendable, Equatable {
            case open
            /// The peer stopped it; the socket's input is read and dropped until its end.
            case dropping
            case finished
            case aborted
        }

        public enum Receiving: Sendable, Equatable {
            case open
            case finished
            case aborted
        }

        public enum Event: Sendable, Equatable {
            /// The socket read its end of file.
            case socketEnded
            /// A read from the socket failed (`ECONNRESET`, …).
            case socketReadFailed
            /// A write to the socket failed (`EPIPE`, …).
            case socketWriteFailed
            /// The Mac's tunnel socket ended before the host sent a byte, or could not be reached.
            case hostRefused
            /// The stream's receiving side reached its end (the peer finished).
            case streamEnded
            /// The peer reset the stream's receiving side.
            case streamReset(code: UInt64)
            /// The peer stopped the stream's sending side.
            case streamStopped(code: UInt64)
        }

        public enum Action: Sendable, Equatable {
            /// `SendStream.finish()`.
            case finishStream
            /// `SendStream.reset(errorCode:)`.
            case resetStream(StreamCode)
            /// `RecvStream.stop(errorCode:)`.
            case stopStream(StreamCode)
            /// Keep reading the socket and forward nothing, until its end.
            case dropSocketInput
            /// `shutdown(SHUT_WR)`: on the phone a TCP FIN.
            case shutdownSocketOutput
            /// On the phone a TCP reset (`SO_LINGER` 0, then `close()`), on the Mac `close()`.
            case abortSocket
            /// Both directions have ended: let go of the stream (a finished sending side keeps
            /// delivering what it sent; never reset it) and close the socket.
            case close
        }

        public private(set) var sending: Sending = .open
        public private(set) var receiving: Receiving = .open
        /// The host refused this connection (a reset with code 2) while `APIClient` still used it: the
        /// phone's bridge tells its route logic.
        public private(set) var refusedByHost = false
        public private(set) var closed = false

        public init() {}

        /// What the bridge does now.
        public mutating func handle(_ event: Event) -> [Action] {
            guard !closed else { return [] }
            var actions: [Action] = []
            switch event {
            case .socketEnded:
                if sending == .open {
                    actions.append(.finishStream)
                    sending = .finished
                } else if sending == .dropping {
                    sending = .aborted
                }
            case .socketReadFailed:
                abortSending(&actions, code: .aborted)
                stopReceiving(&actions, code: .aborted)
            case .socketWriteFailed:
                stopReceiving(&actions, code: .aborted)
            case .hostRefused:
                abortSending(&actions, code: .refused)
                stopReceiving(&actions, code: .refused)
            case .streamEnded:
                if receiving == .open {
                    actions.append(.shutdownSocketOutput)
                    receiving = .finished
                }
            case .streamReset(let code):
                guard receiving == .open else { break }
                // The Mac resets and stops with code 2; its stop may arrive first (then the socket's input
                // is being dropped). Only a finished sending side means `APIClient` had ended the
                // connection.
                if code == StreamCode.refused.rawValue, sending == .open || sending == .dropping { refusedByHost = true }
                receiving = .aborted
                abortSending(&actions, code: .aborted)
                actions.append(.abortSocket)
            case .streamStopped:
                if sending == .open {
                    actions.append(.dropSocketInput)
                    sending = .dropping
                }
            }
            if (sending == .finished || sending == .aborted), receiving != .open {
                closed = true
                actions.append(.close)
            }
            return actions
        }

        /// The socket can send nothing more: an open sending side is reset, a dropping one ends, and a
        /// finished one stays finished.
        private mutating func abortSending(_ actions: inout [Action], code: StreamCode) {
            switch sending {
            case .open:
                actions.append(.resetStream(code))
                sending = .aborted
            case .dropping:
                sending = .aborted
            case .finished, .aborted:
                break
            }
        }

        private mutating func stopReceiving(_ actions: inout [Action], code: StreamCode) {
            guard receiving == .open else { return }
            actions.append(.stopStream(code))
            receiving = .aborted
        }
    }
}
