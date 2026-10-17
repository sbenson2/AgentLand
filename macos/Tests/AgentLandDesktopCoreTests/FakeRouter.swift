import Darwin
import Foundation
@testable import AgentLandDesktopCore

/// A PCP and NAT-PMP server on 127.0.0.1 with an ephemeral port, standing in for the router in
/// the port mapping tests: no request ever leaves loopback. It records every request it reads and
/// keeps a mapping table that `restart()` loses, as a router that restarts does. Like a PCP router
/// (RFC 6887 §11.3), it refuses a MAP or delete with another nonce than the mapping's while that
/// mapping lasts (NOT_AUTHORIZED, with the time it has left).
final class FakeRouter: @unchecked Sendable {
    /// `pcpOnly` answers NAT-PMP requests with PCP's UNSUPP_VERSION, as a router without NAT-PMP does.
    enum Mode { case pcp, natPMPOnly, pcpOnly, silent }

    struct Request: Equatable {
        let method: PortMapper.Method
        /// PCP: 0 ANNOUNCE, 1 MAP. NAT-PMP: 0 address, 1 UDP, 2 TCP.
        let opcode: UInt8
        let transport: MappedTransport?
        let internalPort: UInt16
        let suggestedPort: UInt16
        let lifetime: UInt32
        let nonce: [UInt8]?
        /// PCP's client address field, as sent.
        let clientAddress: [UInt8]?
        let length: Int
        let receivedAt: TimeInterval
    }

    private struct Key: Hashable { let transport: MappedTransport; let internalPort: UInt16 }
    private struct Entry { let external: UInt16; let nonce: [UInt8]?; let expiresAt: TimeInterval }

    let port: UInt16
    private let descriptor: Int32
    private let lock = NSLock()
    private var thread: Thread?
    private var stopped = false
    private var recorded: [Request] = []
    private var table: [Key: Entry] = [:]
    private var epochStart = PortMapper.now() - 1000
    private var modeValue: Mode
    private var lifetimeValue: UInt32?
    private var portOffset: UInt16 = 0
    private var refusals: [MappedTransport: UInt16] = [:]
    private var strays = 0
    private var datagrams = 0
    private var drops = 0
    private var lostAnswers = 0
    private var answeredAddress: [UInt8] = FakeRouter.externalAddress

    init(mode: Mode = .pcp) throws {
        modeValue = mode
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw PortMappingError.socket("fake router socket") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Int32 in
                guard bind(fd, pointer, length) == 0 else { return -1 }
                return getsockname(fd, pointer, &length)
            }
        }
        guard bound == 0 else { close(fd); throw PortMappingError.socket("fake router bind") }
        descriptor = fd
        port = UInt16(bigEndian: address.sin_port)
        var timeout = timeval(tv_sec: 0, tv_usec: 50_000)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let thread = Thread { [weak self] in self?.serve() }
        thread.name = "FakeRouter"
        self.thread = thread
        thread.start()
    }

    deinit { stop() }

    func stop() {
        let wasRunning = lock.withLock { () -> Bool in
            defer { stopped = true }
            return !stopped
        }
        guard wasRunning else { return }
        // The serving loop wakes within its receive timeout and closes the socket.
        Thread.sleep(forTimeInterval: 0.1)
    }

    var mode: Mode {
        get { lock.withLock { modeValue } }
        set { lock.withLock { modeValue = newValue } }
    }
    /// Grants this lifetime instead of the one asked for.
    var grantedLifetime: UInt32? {
        get { lock.withLock { lifetimeValue } }
        set { lock.withLock { lifetimeValue = newValue } }
    }
    /// Grants the suggested port plus this, like a router whose port is taken.
    var grantedPortOffset: UInt16 {
        get { lock.withLock { portOffset } }
        set { lock.withLock { portOffset = newValue } }
    }
    func refuse(_ transport: MappedTransport, code: UInt16) { lock.withLock { refusals[transport] = code } }
    /// Answers the next MAP request first with a datagram that is not its answer.
    func sendStrayAnswerFirst() { lock.withLock { strays += 1 } }
    /// Loses the next `count` mapping requests (not deletes): recorded, never applied or answered.
    func dropMapRequests(_ count: Int) { lock.withLock { drops = count } }
    /// Loses the answers to the next `count` mapping requests (not deletes): applied, never answered.
    func loseAnswers(_ count: Int) { lock.withLock { lostAnswers = count } }
    /// Seconds the router keeps this mapping from now, nil when it has none.
    func remainingLifetime(_ transport: MappedTransport, internalPort: UInt16) -> TimeInterval? {
        lock.withLock {
            guard let entry = table[Key(transport: transport, internalPort: internalPort)] else { return nil }
            let remaining = entry.expiresAt - PortMapper.now()
            return remaining > 0 ? remaining : nil
        }
    }

    var requests: [Request] { lock.withLock { recorded } }
    /// Every datagram read, answered or not.
    var datagramsReceived: Int { lock.withLock { datagrams } }
    var mapRequests: [Request] { requests.filter { $0.transport != nil } }
    var mappings: [MappedTransport: [UInt16: UInt16]] {
        lock.withLock {
            var result: [MappedTransport: [UInt16: UInt16]] = [:]
            let now = PortMapper.now()
            for (key, entry) in table where entry.expiresAt > now { result[key.transport, default: [:]][key.internalPort] = entry.external }
            return result
        }
    }

    /// Loses every mapping and starts the epoch at 0, as a router that restarts does.
    func restart() {
        lock.withLock {
            table.removeAll()
            epochStart = PortMapper.now()
        }
    }

    /// The default external address, a documentation one (not global unicast, so never reported).
    static let externalAddress: [UInt8] = [203, 0, 113, 7]

    /// The external address the router answers with (PCP's MAP, NAT-PMP's address query). Remote
    /// access tests set a global unicast one; it only travels inside answers on loopback.
    var externalAddressBytes: [UInt8] {
        get { lock.withLock { answeredAddress } }
        set { lock.withLock { answeredAddress = newValue } }
    }

    private func serve() {
        var buffer = [UInt8](repeating: 0, count: 1500)
        while !lock.withLock({ stopped }) {
            var source = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &source) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(descriptor, bytes.baseAddress, bytes.count, 0, $0, &sourceLength)
                    }
                }
            }
            guard count > 0 else { continue }
            for answer in answers(to: Array(buffer.prefix(count))) {
                _ = answer.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &source) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, sourceLength)
                        }
                    }
                }
            }
        }
        close(descriptor)
    }

    private func epoch() -> UInt32 { UInt32(max(0, PortMapper.now() - epochStart)) }

    private func answers(to data: [UInt8]) -> [[UInt8]] {
        lock.withLock {
            datagrams += 1
            guard modeValue != .silent, data.count >= 2 else { return [] }
            if data[0] == PCPWire.version { return pcpAnswers(to: data) }
            if data[0] == NATPMPWire.version { return natPMPAnswers(to: data) }
            return []
        }
    }

    private func pcpAnswers(to data: [UInt8]) -> [[UInt8]] {
        let opcode = data[1] & 0x7f
        if modeValue == .natPMPOnly {
            // RFC 6886 §3.5: an unsupported version answer, in NAT-PMP's format.
            recorded.append(Request(method: .pcp, opcode: opcode, transport: nil, internalPort: 0, suggestedPort: 0,
                                    lifetime: 0, nonce: nil, clientAddress: nil, length: data.count, receivedAt: PortMapper.now()))
            return [[0, 128 | opcode] + bigEndian(UInt16(1)) + bigEndian(epoch())]
        }
        guard data.count >= 24 else { return [] }
        let lifetime = readUInt32(data, 4)
        let client = Array(data[8..<24])
        if opcode == PCPWire.announceOpcode {
            recorded.append(Request(method: .pcp, opcode: opcode, transport: nil, internalPort: 0, suggestedPort: 0,
                                    lifetime: lifetime, nonce: nil, clientAddress: client, length: data.count, receivedAt: PortMapper.now()))
            return [[2, 0x80, 0, 0] + bigEndian(UInt32(0)) + bigEndian(epoch()) + [UInt8](repeating: 0, count: 12)]
        }
        guard opcode == PCPWire.mapOpcode, data.count >= 60 else { return [] }
        let nonce = Array(data[24..<36])
        let transport: MappedTransport = data[36] == 17 ? .udp : .tcp
        let internalPort = readUInt16(data, 40)
        let suggested = readUInt16(data, 42)
        recorded.append(Request(method: .pcp, opcode: opcode, transport: transport, internalPort: internalPort,
                                suggestedPort: suggested, lifetime: lifetime, nonce: nonce, clientAddress: client,
                                length: data.count, receivedAt: PortMapper.now()))
        if lifetime > 0, drops > 0 {
            drops -= 1
            return []
        }
        func answer(result: UInt8, lifetime: UInt32, external: UInt16, nonce: [UInt8]) -> [UInt8] {
            [2, 0x81, 0, result] + bigEndian(lifetime) + bigEndian(epoch()) + [UInt8](repeating: 0, count: 12)
                + nonce + [data[36], 0, 0, 0] + bigEndian(internalPort) + bigEndian(external)
                + [UInt8](repeating: 0, count: 10) + [0xff, 0xff] + self.answeredAddress
        }
        var out: [[UInt8]] = []
        if strays > 0 {
            strays -= 1
            out.append(answer(result: 0, lifetime: 60, external: 1, nonce: [UInt8](repeating: 0xee, count: 12)))
        }
        if let code = refusals[transport] {
            out.append(answer(result: UInt8(code), lifetime: 30, external: 0, nonce: nonce))
            return out
        }
        let key = Key(transport: transport, internalPort: internalPort)
        let now = PortMapper.now()
        if let existing = table[key], existing.expiresAt <= now { table[key] = nil }
        if let existing = table[key], let owner = existing.nonce, owner != nonce {
            out.append(answer(result: 2, lifetime: UInt32(max(0, existing.expiresAt - now).rounded(.up)), external: 0, nonce: nonce))
            return out
        }
        if lifetime == 0 {
            table[key] = nil
            out.append(answer(result: 0, lifetime: 0, external: suggested, nonce: nonce))
            return out
        }
        let external = table[key]?.external ?? (suggested &+ portOffset)
        let granted = lifetimeValue ?? lifetime
        table[key] = Entry(external: external, nonce: nonce, expiresAt: now + TimeInterval(granted))
        if lostAnswers > 0 {
            lostAnswers -= 1
            return []
        }
        out.append(answer(result: 0, lifetime: granted, external: external, nonce: nonce))
        return out
    }

    private func natPMPAnswers(to data: [UInt8]) -> [[UInt8]] {
        let opcode = data[1]
        if modeValue == .pcpOnly {
            // RFC 6887 §9: a version it does not speak, answered in PCP's format with UNSUPP_VERSION.
            recorded.append(Request(method: .natPMP, opcode: opcode, transport: nil, internalPort: 0, suggestedPort: 0,
                                    lifetime: 0, nonce: nil, clientAddress: nil, length: data.count, receivedAt: PortMapper.now()))
            return [[PCPWire.version, 0x80 | opcode, 0, 1] + bigEndian(UInt32(0)) + bigEndian(epoch()) + [UInt8](repeating: 0, count: 12)]
        }
        if opcode == 0 {
            recorded.append(Request(method: .natPMP, opcode: 0, transport: nil, internalPort: 0, suggestedPort: 0,
                                    lifetime: 0, nonce: nil, clientAddress: nil, length: data.count, receivedAt: PortMapper.now()))
            return [[0, 128] + bigEndian(UInt16(0)) + bigEndian(epoch()) + answeredAddress]
        }
        guard opcode == 1 || opcode == 2, data.count >= 12 else { return [] }
        let transport: MappedTransport = opcode == 1 ? .udp : .tcp
        let internalPort = readUInt16(data, 4)
        let suggested = readUInt16(data, 6)
        let lifetime = readUInt32(data, 8)
        recorded.append(Request(method: .natPMP, opcode: opcode, transport: transport, internalPort: internalPort,
                                suggestedPort: suggested, lifetime: lifetime, nonce: nil, clientAddress: nil,
                                length: data.count, receivedAt: PortMapper.now()))
        func answer(result: UInt16, external: UInt16, lifetime: UInt32) -> [UInt8] {
            [0, 128 + opcode] + bigEndian(result) + bigEndian(epoch()) + bigEndian(internalPort) + bigEndian(external) + bigEndian(lifetime)
        }
        if lifetime > 0, drops > 0 {
            drops -= 1
            return []
        }
        if let code = refusals[transport] { return [answer(result: code, external: 0, lifetime: 0)] }
        let key = Key(transport: transport, internalPort: internalPort)
        if lifetime == 0 {
            table[key] = nil
            return [answer(result: 0, external: 0, lifetime: 0)]
        }
        let external = table[key]?.external ?? (suggested &+ portOffset)
        let granted = lifetimeValue ?? lifetime
        table[key] = Entry(external: external, nonce: nil, expiresAt: PortMapper.now() + TimeInterval(granted))
        return [answer(result: 0, external: external, lifetime: granted)]
    }
}
