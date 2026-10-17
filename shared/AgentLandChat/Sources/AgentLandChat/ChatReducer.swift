import Foundation
import AgentLandCore

/// Identifies one field of one part: a part's text, or a tool's output.
public struct ChatPartKey: Hashable, Sendable {
    public let messageID: String
    public let partID: String
    public let field: ConversationPartDelta.Field
    public init(messageID: String, partID: String, field: ConversationPartDelta.Field) {
        self.messageID = messageID; self.partID = partID; self.field = field
    }
}

/// An interaction the host resolved while this chat was open, kept for the
/// after-state line in the transcript. `afterPartID` is the part the reply
/// had reached when the request arrived, so the line keeps its place.
public struct ChatResolvedInteraction: Hashable, Sendable, Identifiable {
    public let interaction: ChatInteraction
    public let outcome: String
    public let turnID: String?
    public let afterPartID: String?
    public var id: String { interaction.id }
}

public struct ChatTurnOutcome: Hashable, Sendable {
    public let turnID: String
    public let outcome: String
}

/// What changed since the projection last synced. The reducer records it so
/// the projection touches only what moved: one delta redraws one part.
public struct ChatChanges: Equatable, Sendable {
    /// Everything was replaced (a snapshot or a legacy load).
    public var reset = false
    /// Messages were added, removed or reordered.
    public var structure = false
    /// Message header fields (status, times, usage, error).
    public var messages: Set<String> = []
    /// Messages whose part lists gained, lost or reordered parts.
    public var partLists: Set<String> = []
    /// Parts replaced in full.
    public var parts: Set<ChatPartKey> = []
    /// Text appended to a part field in this batch, in order.
    public var appended: [ChatPartKey: String] = [:]
    /// Chat info, status, interactions, queue or rewind point.
    public var meta = false
    public var newInteractions: [ChatInteraction] = []
    public var resolvedInteractions: [ChatResolvedInteraction] = []
    public var finishedTurns: [ChatTurnOutcome] = []

    public init() {}
    public var isEmpty: Bool { self == ChatChanges() }
}

/// The client's copy of one chat, fed by the event stream (or by the legacy
/// transcript on hosts that do not stream).
public struct ChatState: Equatable, Sendable {
    /// The last cursor the host gave (`ready`, `beat`, `end`). Opaque.
    public var cursor: String?
    /// The position of the last applied event. Anything at or before it is a repeat.
    public var seq: UInt64 = 0
    /// Set by `ready` without `resumed`: nothing applies until the snapshot.
    public var awaitingSnapshot = false
    private var readyCursor: String?
    /// A snapshot or legacy load has been applied at least once.
    public var hasContent = false
    public var chat: ChatInfo?
    /// Oldest first, by `ord`.
    public var messages: [ConversationMessage] = []
    public var hasMore = false
    public var status = ChatStatusInfo(state: .unknown)
    public var interactions: [ChatInteraction] = []
    public var resolved: [ChatResolvedInteraction] = []
    public var queue: [QueuedPrompt] = []
    public var rewind: RewindState?
    public var turnID: String?
    /// Where each pending interaction arrived: the last part of the reply at the time.
    public var interactionAnchors: [String: String] = [:]
    public var changes = ChatChanges()

    public init() {}

    public func messageIndex(_ id: String) -> Int? { messages.firstIndex { $0.id == id } }

    fileprivate mutating func takeReadyCursor() -> String? {
        defer { readyCursor = nil }
        return readyCursor
    }
    fileprivate mutating func setReadyCursor(_ cursor: String?) { readyCursor = cursor }
}

/// What applying one event asks the stream to do next.
public enum ChatReduction: Equatable, Sendable {
    case applied
    /// A repeat (seq at or before the cursor) or an event with nothing to change.
    case ignored
    /// The stream and the state disagree (a missing part, an offset mismatch):
    /// reconnect without a cursor so a fresh snapshot replaces the state.
    case resync(String)
    /// The stream's lifetime ended; reconnect with the cursor.
    case ended
    case stopping
    case unauthorized
}

/// Applies stream events to `ChatState`. Pure and idempotent: applying the
/// same events again (as after a resume from an older cursor) changes nothing.
public enum ChatReducer {
    public static func apply(_ envelope: ChatEventEnvelope, to state: inout ChatState) -> ChatReduction {
        switch envelope.event {
        case let .ready(cursor, resumed):
            if resumed {
                // The host resumes only within the cursor's epoch; replayed
                // events that follow are dropped by their seq.
                guard state.hasContent, !state.awaitingSnapshot else { return .resync("resumed without state") }
                state.cursor = cursor
                return .applied
            }
            // A new epoch (or no cursor): the snapshot that follows replaces everything.
            state.awaitingSnapshot = true
            state.setReadyCursor(cursor)
            return .applied
        case let .snapshot(snapshot):
            replace(&state, with: snapshot)
            state.seq = envelope.seq
            // Right after `ready` the snapshot is at the ready cursor. A
            // snapshot mid-stream (a rebuilt chat) has a new epoch the client
            // learns from the next beat; until then it resumes with no cursor.
            state.cursor = state.awaitingSnapshot ? state.takeReadyCursor() : nil
            state.awaitingSnapshot = false
            return .applied
        case let .beat(cursor), let .end(cursor):
            if let cursor { state.cursor = cursor }
            if case .end = envelope.event { return .ended }
            return .applied
        case .stopping:
            return .stopping
        case .unauthorized:
            return .unauthorized
        default:
            break
        }
        guard !state.awaitingSnapshot else { return .ignored }
        guard envelope.seq > state.seq else { return .ignored }
        let result = applyChange(envelope.event, to: &state)
        if case .resync = result { return result }
        state.seq = envelope.seq
        return result
    }

    /// Replaces the state with a legacy transcript (hosts without events).
    public static func replace(_ state: inout ChatState, with snapshot: ChatSnapshot) {
        state.chat = snapshot.chat
        state.messages = snapshot.messages.sorted(by: ordered)
        state.hasMore = snapshot.hasMore
        state.status = snapshot.status
        state.interactions = snapshot.interactions
        state.queue = snapshot.queue
        state.rewind = snapshot.rewind
        let pending = Set(snapshot.interactions.map(\.id))
        state.interactionAnchors = state.interactionAnchors.filter { pending.contains($0.key) }
        for interaction in snapshot.interactions where state.interactionAnchors[interaction.id] == nil {
            state.interactionAnchors[interaction.id] = lastPartID(state)
        }
        state.hasContent = true
        state.changes.reset = true
        state.changes.meta = true
    }

    /// Adds an older page (newest first, as the host pages them) in front of
    /// the loaded messages. Messages already loaded are kept as they are.
    public static func mergeOlder(_ page: ConversationPage, into state: inout ChatState) {
        let known = Set(state.messages.map(\.id))
        let older = page.messages.filter { !known.contains($0.id) }
        state.hasMore = page.hasMore
        state.changes.meta = true
        guard !older.isEmpty else { return }
        state.messages = (older + state.messages).sorted(by: ordered)
        state.changes.structure = true
    }

    static func ordered(_ left: ConversationMessage, _ right: ConversationMessage) -> Bool {
        left.ord == right.ord ? left.id < right.id : left.ord < right.ord
    }

    private static func lastPartID(_ state: ChatState) -> String? {
        state.messages.last(where: { $0.role == .assistant })?.parts.last?.id
    }

    private static func applyChange(_ event: ChatEvent, to state: inout ChatState) -> ChatReduction {
        switch event {
        case let .chatUpdated(update):
            var chat = state.chat ?? ChatInfo(id: "")
            if let title = update.title { chat.title = title }
            if let model = update.model { chat.model = model }
            if let mode = update.mode { chat.mode = mode }
            if let effort = update.effort { chat.effort = effort }
            // The source comes with every title change; without a basis beside it the title has none.
            if let source = update.titleSource {
                chat.titleSource = source
                chat.titleBasis = update.titleBasis
            } else if let basis = update.titleBasis {
                chat.titleBasis = basis
            }
            guard chat != state.chat else { return .ignored }
            state.chat = chat
            state.changes.meta = true
        case let .status(status):
            guard status != state.status else { return .ignored }
            state.status = status
            state.changes.meta = true
        case let .messageCreated(message):
            var message = message
            message.parts.sort { $0.ord == $1.ord ? $0.id < $1.id : $0.ord < $1.ord }
            if let index = state.messageIndex(message.id) {
                // A repeat of a message this client holds: take the host's copy.
                guard state.messages[index] != message else { return .ignored }
                let reordered = state.messages[index].ord != message.ord
                state.messages[index] = message
                if reordered {
                    state.messages.sort(by: ordered)
                    state.changes.structure = true
                }
                state.changes.messages.insert(message.id)
                state.changes.partLists.insert(message.id)
            } else {
                let position = state.messages.firstIndex { ordered(message, $0) } ?? state.messages.endIndex
                state.messages.insert(message, at: position)
                state.changes.structure = true
            }
        case let .messageUpdated(update):
            guard let index = state.messageIndex(update.messageID) else { return missing(state, "message \(update.messageID)") }
            var message = state.messages[index]
            if let status = update.status { message.status = status }
            if let completedAt = update.completedAt { message.completedAt = completedAt }
            if let usage = update.usage { message.usage = usage }
            if let error = update.error { message.error = error }
            guard message != state.messages[index] else { return .ignored }
            state.messages[index] = message
            state.changes.messages.insert(update.messageID)
        case let .messageRemoved(messageID):
            guard let index = state.messageIndex(messageID) else { return .ignored }
            state.messages.remove(at: index)
            state.changes.structure = true
        case let .partCreated(messageID, part), let .partUpdated(messageID, part):
            guard let index = state.messageIndex(messageID) else { return missing(state, "message \(messageID)") }
            if let partIndex = state.messages[index].parts.firstIndex(where: { $0.id == part.id }) {
                guard state.messages[index].parts[partIndex] != part else { return .ignored }
                let reordered = state.messages[index].parts[partIndex].ord != part.ord
                state.messages[index].parts[partIndex] = part
                if reordered {
                    state.messages[index].parts.sort { $0.ord == $1.ord ? $0.id < $1.id : $0.ord < $1.ord }
                    state.changes.partLists.insert(messageID)
                }
                for field in [ConversationPartDelta.Field.text, .output] {
                    let key = ChatPartKey(messageID: messageID, partID: part.id, field: field)
                    state.changes.parts.insert(key)
                    state.changes.appended[key] = nil
                }
            } else {
                let parts = state.messages[index].parts
                let position = parts.firstIndex { part.ord < $0.ord || (part.ord == $0.ord && part.id < $0.id) } ?? parts.endIndex
                state.messages[index].parts.insert(part, at: position)
                state.changes.partLists.insert(messageID)
            }
        case let .partDelta(delta):
            return appendDelta(delta, to: &state)
        case let .partRemoved(messageID, partID):
            guard let index = state.messageIndex(messageID),
                  let partIndex = state.messages[index].parts.firstIndex(where: { $0.id == partID }) else { return .ignored }
            state.messages[index].parts.remove(at: partIndex)
            state.changes.partLists.insert(messageID)
        case let .interactionRequested(interaction):
            if let index = state.interactions.firstIndex(where: { $0.id == interaction.id }) {
                guard state.interactions[index] != interaction else { return .ignored }
                state.interactions[index] = interaction
            } else {
                state.interactions.append(interaction)
                state.interactionAnchors[interaction.id] = lastPartID(state)
                state.changes.newInteractions.append(interaction)
            }
            state.changes.meta = true
        case let .interactionResolved(id, outcome):
            guard let index = state.interactions.firstIndex(where: { $0.id == id }) else { return .ignored }
            let interaction = state.interactions.remove(at: index)
            let resolved = ChatResolvedInteraction(interaction: interaction, outcome: outcome, turnID: state.turnID,
                                                   afterPartID: state.interactionAnchors.removeValue(forKey: id))
            state.resolved.removeAll { $0.id == id }
            state.resolved.append(resolved)
            if state.resolved.count > 64 { state.resolved.removeFirst(state.resolved.count - 64) }
            state.changes.resolvedInteractions.append(resolved)
            state.changes.meta = true
        case let .queueUpdated(items):
            guard items != state.queue else { return .ignored }
            state.queue = items
            state.changes.meta = true
        case let .turnStarted(turnID):
            state.turnID = turnID
            state.changes.meta = true
        case let .turnFinished(turnID, outcome, _):
            if state.turnID == turnID { state.turnID = nil }
            state.changes.finishedTurns.append(ChatTurnOutcome(turnID: turnID, outcome: outcome))
            state.changes.meta = true
        case .unknown:
            return .ignored
        case .ready, .snapshot, .beat, .end, .stopping, .unauthorized:
            return .ignored
        }
        return .applied
    }

    /// An event for a message this client does not hold. With older messages
    /// not loaded it may belong to one of them; with the whole chat loaded it
    /// is a gap in the stream.
    private static func missing(_ state: ChatState, _ what: String) -> ChatReduction {
        state.hasMore ? .ignored : .resync("unknown \(what)")
    }

    private static func appendDelta(_ delta: ConversationPartDelta, to state: inout ChatState) -> ChatReduction {
        guard let index = state.messageIndex(delta.messageID) else { return missing(state, "message \(delta.messageID)") }
        guard let partIndex = state.messages[index].parts.firstIndex(where: { $0.id == delta.partID }) else {
            return .resync("unknown part \(delta.partID)")
        }
        let key = ChatPartKey(messageID: delta.messageID, partID: delta.partID, field: delta.field)
        let current: Int
        switch delta.field {
        case .text: current = state.messages[index].parts[partIndex].text.utf8.count
        case .output: current = state.messages[index].parts[partIndex].tool?.output.utf8.count ?? 0
        }
        guard delta.offset == current else {
            // Text this client already holds (the same bytes at that offset) is a repeat.
            if delta.offset + delta.delta.utf8.count <= current, holds(delta, in: state.messages[index].parts[partIndex]) {
                return .ignored
            }
            return .resync("offset \(delta.offset) for a field of \(current) bytes")
        }
        guard !delta.delta.isEmpty else { return .ignored }
        switch delta.field {
        case .text:
            state.messages[index].parts[partIndex].text.append(delta.delta)
        case .output:
            if state.messages[index].parts[partIndex].tool == nil {
                state.messages[index].parts[partIndex].tool = ConversationTool(name: "tool", status: .running)
            }
            state.messages[index].parts[partIndex].tool?.output.append(delta.delta)
        }
        if !state.changes.parts.contains(key) {
            state.changes.appended[key, default: ""].append(delta.delta)
        }
        return .applied
    }

    private static func holds(_ delta: ConversationPartDelta, in part: ConversationPart) -> Bool {
        let field = delta.field == .text ? part.text : (part.tool?.output ?? "")
        let bytes = field.utf8
        guard let start = bytes.index(bytes.startIndex, offsetBy: delta.offset, limitedBy: bytes.endIndex),
              let end = bytes.index(start, offsetBy: delta.delta.utf8.count, limitedBy: bytes.endIndex) else { return false }
        return bytes[start..<end].elementsEqual(delta.delta.utf8)
    }
}
