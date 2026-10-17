import XCTest
import AgentLandCore
@testable import AgentLandChat

final class ChatReducerTests: XCTestCase {
    private func envelope(_ seq: UInt64, _ event: ChatEvent) -> ChatEventEnvelope { ChatEventEnvelope(seq: seq, event: event) }

    private func message(_ id: String, role: MessageRole = .assistant, ord: Int64, turn: String = "u1",
                         parts: [ConversationPart] = [], status: ConversationMessageStatus = .streaming) -> ConversationMessage {
        ConversationMessage(id: id, chatID: "c", turnID: turn, role: role, status: status, ord: ord, parts: parts)
    }

    private func loaded(_ messages: [ConversationMessage] = [], hasMore: Bool = false) -> ChatState {
        var state = ChatState()
        _ = ChatReducer.apply(envelope(0, .ready(cursor: "e1.0", resumed: false)), to: &state)
        _ = ChatReducer.apply(envelope(0, .snapshot(ChatSnapshot(chat: ChatInfo(id: "c"), messages: messages, hasMore: hasMore))), to: &state)
        state.changes = ChatChanges()
        return state
    }

    func testSnapshotAfterReadyTakesTheReadyCursorAndOrdersByOrd() {
        var state = ChatState()
        XCTAssertEqual(ChatReducer.apply(envelope(5, .ready(cursor: "e1.5", resumed: false)), to: &state), .applied)
        XCTAssertTrue(state.awaitingSnapshot)
        let snapshot = ChatSnapshot(chat: ChatInfo(id: "c", title: "T"),
                                    messages: [message("m2", ord: 20), message("u1", role: .user, ord: 10)])
        XCTAssertEqual(ChatReducer.apply(envelope(5, .snapshot(snapshot)), to: &state), .applied)
        XCTAssertEqual(state.messages.map(\.id), ["u1", "m2"])
        XCTAssertEqual(state.cursor, "e1.5")
        XCTAssertEqual(state.seq, 5)
        XCTAssertFalse(state.awaitingSnapshot)
        XCTAssertTrue(state.changes.reset)
    }

    func testMessagesAndPartsKeepTheirOrdEvenWhenTheyArriveOutOfOrder() {
        var state = loaded([message("u1", role: .user, ord: 10)])
        _ = ChatReducer.apply(envelope(1, .messageCreated(message("m3", ord: 30))), to: &state)
        _ = ChatReducer.apply(envelope(2, .messageCreated(message("m2", ord: 20))), to: &state)
        XCTAssertEqual(state.messages.map(\.id), ["u1", "m2", "m3"])
        _ = ChatReducer.apply(envelope(3, .partCreated(messageID: "m2", part: ConversationPart(id: "b", kind: .text, ord: 2))), to: &state)
        _ = ChatReducer.apply(envelope(4, .partCreated(messageID: "m2", part: ConversationPart(id: "a", kind: .reasoning, ord: 1))), to: &state)
        XCTAssertEqual(state.messages[1].parts.map(\.id), ["a", "b"])
        XCTAssertEqual(state.seq, 4)
    }

    func testReplayedEventsChangeNothing() {
        let events: [ChatEventEnvelope] = [
            envelope(1, .messageCreated(message("m1", ord: 10))),
            envelope(2, .partCreated(messageID: "m1", part: ConversationPart(id: "p", kind: .text, ord: 1))),
            envelope(3, .partDelta(ConversationPartDelta(messageID: "m1", partID: "p", field: .text, offset: 0, delta: "Hello "))),
            envelope(4, .partDelta(ConversationPartDelta(messageID: "m1", partID: "p", field: .text, offset: 6, delta: "world"))),
            envelope(5, .messageUpdated(ConversationMessageUpdate(messageID: "m1", status: .complete)))
        ]
        var state = loaded()
        for event in events { _ = ChatReducer.apply(event, to: &state) }
        state.changes = ChatChanges()
        let settled = state
        // A resume from an older cursor replays events the client already has.
        XCTAssertEqual(ChatReducer.apply(envelope(2, .ready(cursor: "e1.2", resumed: true)), to: &state), .applied)
        for event in events.dropFirst(2) { XCTAssertEqual(ChatReducer.apply(event, to: &state), .ignored) }
        state.cursor = settled.cursor
        XCTAssertEqual(state, settled)
        XCTAssertEqual(state.messages[0].parts[0].text, "Hello world")
        XCTAssertEqual(state.messages[0].status, .complete)
    }

    func testANewEpochReplacesEverything() {
        var state = loaded([message("old", ord: 1, parts: [ConversationPart(id: "p", kind: .text, text: "stale")])])
        _ = ChatReducer.apply(envelope(9, .messageCreated(message("older-epoch", ord: 2))), to: &state)
        XCTAssertEqual(state.seq, 9)
        // The host restarted: its ring starts again from 1 under a new epoch.
        XCTAssertEqual(ChatReducer.apply(envelope(1, .ready(cursor: "e2.1", resumed: false)), to: &state), .applied)
        XCTAssertEqual(ChatReducer.apply(envelope(3, .messageCreated(message("early", ord: 3))), to: &state), .ignored,
                       "Nothing applies between ready and the snapshot")
        let fresh = ChatSnapshot(chat: ChatInfo(id: "c"), messages: [message("new", ord: 5)])
        _ = ChatReducer.apply(envelope(1, .snapshot(fresh)), to: &state)
        XCTAssertEqual(state.messages.map(\.id), ["new"])
        XCTAssertEqual(state.seq, 1, "Sequence numbers restart with the epoch")
        XCTAssertEqual(state.cursor, "e2.1")
        XCTAssertEqual(ChatReducer.apply(envelope(2, .messageCreated(message("next", ord: 6))), to: &state), .applied)
        XCTAssertEqual(state.messages.map(\.id), ["new", "next"])
    }

    func testMidStreamSnapshotReplacesStateAndDropsTheStaleCursor() {
        var state = loaded([message("m1", ord: 1)])
        _ = ChatReducer.apply(envelope(40, .beat(cursor: "e1.40")), to: &state)
        XCTAssertEqual(state.cursor, "e1.40")
        let rebuilt = ChatSnapshot(chat: ChatInfo(id: "c"), messages: [], rewind: RewindState(messageID: "m1"))
        _ = ChatReducer.apply(envelope(3, .snapshot(rebuilt)), to: &state)
        XCTAssertEqual(state.messages, [])
        XCTAssertEqual(state.rewind, RewindState(messageID: "m1"))
        XCTAssertNil(state.cursor, "The rebuilt chat has a new epoch; resume without a cursor until a beat names it")
        XCTAssertEqual(state.seq, 3)
    }

    func testOffsetMismatchAndGapsAskForAFreshSnapshot() {
        var state = loaded([message("m1", ord: 1, parts: [ConversationPart(id: "p", kind: .text, text: "abc")])])
        XCTAssertEqual(ChatReducer.apply(envelope(1, .partDelta(ConversationPartDelta(messageID: "m1", partID: "p", field: .text, offset: 5, delta: "x"))), to: &state),
                       .resync("offset 5 for a field of 3 bytes"))
        XCTAssertEqual(state.seq, 0, "A rejected event does not advance the position")
        XCTAssertEqual(ChatReducer.apply(envelope(1, .partDelta(ConversationPartDelta(messageID: "m1", partID: "p", field: .text, offset: 1, delta: "bc"))), to: &state),
                       .ignored, "The same bytes at a known offset are a repeat")
        XCTAssertEqual(ChatReducer.apply(envelope(2, .partDelta(ConversationPartDelta(messageID: "m1", partID: "nope", field: .text, offset: 0, delta: "x"))), to: &state),
                       .resync("unknown part nope"))
        XCTAssertEqual(ChatReducer.apply(envelope(3, .messageUpdated(ConversationMessageUpdate(messageID: "ghost", status: .complete))), to: &state),
                       .resync("unknown message ghost"))
        var partial = loaded([message("m9", ord: 9)], hasMore: true)
        XCTAssertEqual(ChatReducer.apply(envelope(1, .messageUpdated(ConversationMessageUpdate(messageID: "older", status: .complete))), to: &partial),
                       .ignored, "With older messages not loaded, an unknown message may be one of them")
    }

    func testMultibyteOffsetsCountUTF8Bytes() {
        var state = loaded([message("m1", ord: 1, parts: [ConversationPart(id: "p", kind: .text, text: "é")])])
        XCTAssertEqual(ChatReducer.apply(envelope(1, .partDelta(ConversationPartDelta(messageID: "m1", partID: "p", field: .text, offset: 2, delta: "🎪"))), to: &state), .applied)
        XCTAssertEqual(state.messages[0].parts[0].text, "é🎪")
        XCTAssertEqual(state.changes.appended[ChatPartKey(messageID: "m1", partID: "p", field: .text)], "🎪")
    }

    func testToolOutputDeltasAndInteractions() {
        let tool = ConversationPart(id: "t", kind: .tool, ord: 1, tool: ConversationTool(name: "bash", status: .running))
        var state = loaded([message("m1", ord: 1, parts: [tool])])
        _ = ChatReducer.apply(envelope(1, .partDelta(ConversationPartDelta(messageID: "m1", partID: "t", field: .output, offset: 0, delta: "line 1\n"))), to: &state)
        XCTAssertEqual(state.messages[0].parts[0].tool?.output, "line 1\n")
        let permission = ChatInteraction(id: "per", kind: .permission, choices: ["once", "reject"], permission: ChatPermission(tool: "bash", title: "ls"))
        _ = ChatReducer.apply(envelope(2, .turnStarted(turnID: "u1")), to: &state)
        _ = ChatReducer.apply(envelope(3, .interactionRequested(permission)), to: &state)
        XCTAssertEqual(state.interactions, [permission])
        XCTAssertEqual(state.changes.newInteractions, [permission])
        XCTAssertEqual(state.interactionAnchors["per"], "t")
        XCTAssertEqual(ChatReducer.apply(envelope(3, .interactionRequested(permission)), to: &state), .ignored)
        _ = ChatReducer.apply(envelope(4, .interactionResolved(id: "per", outcome: "once")), to: &state)
        XCTAssertEqual(state.interactions, [])
        XCTAssertEqual(state.resolved.first?.outcome, "once")
        XCTAssertEqual(state.resolved.first?.turnID, "u1")
        XCTAssertEqual(state.resolved.first?.afterPartID, "t")
        _ = ChatReducer.apply(envelope(5, .turnFinished(turnID: "u1", outcome: "completed", usage: nil)), to: &state)
        XCTAssertNil(state.turnID)
        XCTAssertEqual(state.changes.finishedTurns, [ChatTurnOutcome(turnID: "u1", outcome: "completed")])
    }

    func testControlLines() {
        var state = loaded()
        XCTAssertEqual(ChatReducer.apply(envelope(0, .end(cursor: "e1.0")), to: &state), .ended)
        XCTAssertEqual(ChatReducer.apply(envelope(0, .stopping), to: &state), .stopping)
        XCTAssertEqual(ChatReducer.apply(envelope(0, .unauthorized), to: &state), .unauthorized)
        XCTAssertEqual(ChatReducer.apply(envelope(7, .unknown(type: "later")), to: &state), .ignored)
        var fresh = ChatState()
        XCTAssertEqual(ChatReducer.apply(envelope(3, .ready(cursor: "e.3", resumed: true)), to: &fresh), .resync("resumed without state"),
                       "A client with nothing cannot resume")
    }

    func testOlderPagesMergeInFront() {
        var state = loaded([message("m3", ord: 30)], hasMore: true)
        let page = ConversationPage(messages: [message("m2", ord: 20), message("m1", role: .user, ord: 10), message("m3", ord: 30)],
                                    hasMore: false, oldestID: "m1")
        ChatReducer.mergeOlder(page, into: &state)
        XCTAssertEqual(state.messages.map(\.id), ["m1", "m2", "m3"])
        XCTAssertFalse(state.hasMore)
        XCTAssertTrue(state.changes.structure)
    }
}
