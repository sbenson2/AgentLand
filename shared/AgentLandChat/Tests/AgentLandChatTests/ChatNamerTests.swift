import XCTest
import AgentLandCore
@testable import AgentLandChat

/// What a chat's name is made from, the checks a name passes, and how the on-device model's namer
/// handles an unavailable model and its errors.
final class ChatNamerTests: XCTestCase {
    private func message(_ id: String, _ role: MessageRole, ord: Int64, _ text: String, kind: ConversationPartKind = .text) -> ConversationMessage {
        ConversationMessage(id: id, role: role, ord: ord, parts: [ConversationPart(id: id + "p", kind: kind, text: text)])
    }

    // MARK: Input

    func testTheNewestPromptAndTheStartOfItsReply() throws {
        let long = String(repeating: "p", count: 1_500)
        let reply = String(repeating: "r", count: 700)
        let messages = [
            message("agentland-seed", .user, ord: 0, "An earlier chat", kind: .context),
            message("u1", .user, ord: 1, "First question"),
            message("a1", .assistant, ord: 2, "First answer"),
            message("u2", .user, ord: 3, "  \(long)  "),
            message("a2", .assistant, ord: 4, reply),
            message("a3", .assistant, ord: 5, "More"),
        ]
        let input = try XCTUnwrap(ChatNamingInput.latest(in: messages))
        XCTAssertEqual(input.prompt, String(long.prefix(1_200)))
        XCTAssertEqual(input.reply, String(reply.prefix(600)), "At most 600 characters of the reply")
        XCTAssertEqual(input.newestMessageID, "a3")
    }

    func testAPromptWithoutAReplyYetAndChatsWithoutPrompts() throws {
        let waiting = try XCTUnwrap(ChatNamingInput.latest(in: [message("a0", .assistant, ord: 1, "Hello"), message("u1", .user, ord: 2, "Fix the build")]))
        XCTAssertEqual(waiting.prompt, "Fix the build")
        XCTAssertEqual(waiting.reply, "")
        XCTAssertEqual(waiting.newestMessageID, "u1")
        XCTAssertNil(ChatNamingInput.latest(in: [message("agentland-seed", .user, ord: 0, "Seed", kind: .context)]),
                     "A continued chat's seed is not a prompt")
        XCTAssertNil(ChatNamingInput.latest(in: []))
    }

    // MARK: Checks

    func testNamesAreCheckedBeforeTheyAreSent() {
        let table: [(String, String?, UInt)] = [
            ("Fix the login redirect", "Fix the login redirect", #line),
            ("\"Fix the login redirect.\"", "Fix the login redirect", #line),
            ("“Tidy imports”", "Tidy imports", #line),
            ("'Add CSV export'!", "Add CSV export", #line),
            ("Fix login...", "Fix login", #line),
            ("Fix login…", "Fix login", #line),
            ("Fix login (iOS)", "Fix login (iOS)", #line),
            ("Rename the \"remember me\" box", "Rename the \"remember me\" box", #line),
            ("  \n  Refactor   the   parser  \nSecond line", "Refactor the parser", #line),
            ("OK", "OK", #line),
            ("X", nil, #line),
            ("...", nil, #line),
            ("", nil, #line),
            ("Chat", nil, #line),
            ("Conversation.", nil, #line),
            ("New chat", nil, #line),
            ("A chat about code", nil, #line),
            ("Coding help", nil, #line),
            ("Claude Code", nil, #line),
            (String(repeating: "a", count: 60), String(repeating: "a", count: 60), #line),
            (String(repeating: "a", count: 61), nil, #line),
        ]
        for (raw, expected, line) in table {
            XCTAssertEqual(ChatNameRules.clean(raw), expected, raw.debugDescription, line: line)
        }
    }

    // MARK: The on-device model

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var prompts: [String] = []
        func record(_ prompt: String) { lock.withLock { prompts.append(prompt) } }
        var all: [String] { lock.withLock { prompts } }
    }

    func testAnUnavailableModelIsNeverAsked() async {
        let calls = Calls()
        let namer = FoundationModelsChatNamer(isAvailable: { false }, generate: { _, prompt in calls.record(prompt); return "Name" })
        XCTAssertFalse(namer.isAvailable)
        let name = await namer.name(for: ChatNamingInput(prompt: "Fix it", reply: "", newestMessageID: "u1"))
        XCTAssertNil(name)
        XCTAssertEqual(calls.all, [])
    }

    /// Settings → Apple Intelligence turned off while the model answered: its answer is dropped.
    func testAnAnswerAfterAppleIntelligenceWentOffIsDropped() async {
        let on = Calls()
        on.record("on")
        let namer = FoundationModelsChatNamer(isAvailable: { !on.all.isEmpty && on.all.last == "on" },
                                              generate: { _, _ in on.record("off"); return "Fix the login redirect" })
        let name = await namer.name(for: ChatNamingInput(prompt: "Fix the login redirect", reply: "", newestMessageID: "u1"))
        XCTAssertNil(name)
    }

    func testRefusalsAndErrorsGiveNoName() async {
        let namer = FoundationModelsChatNamer(isAvailable: { true }, generate: { _, _ in throw CancellationError() })
        let name = await namer.name(for: ChatNamingInput(prompt: "Fix it", reply: "", newestMessageID: "u1"))
        XCTAssertNil(name)
    }

    func testTheModelIsAskedAboutThePromptAndTheReply() async {
        let calls = Calls()
        let namer = FoundationModelsChatNamer(isAvailable: { true }, generate: { _, prompt in calls.record(prompt); return "Fix the login redirect" })
        let name = await namer.name(for: ChatNamingInput(prompt: "Why does /login loop?", reply: "The cookie's domain is wrong.", newestMessageID: "a1"))
        XCTAssertEqual(name, "Fix the login redirect")
        let prompt = calls.all.first ?? ""
        XCTAssertTrue(prompt.contains("Why does /login loop?"))
        XCTAssertTrue(prompt.contains("The cookie's domain is wrong."))
        XCTAssertFalse(prompt.contains("a1"), "The message ID is not the model's business")
        XCTAssertFalse(FoundationModelsChatNamer.prompt(for: ChatNamingInput(prompt: "Hi", reply: "", newestMessageID: "u1")).contains("reply began"))
        let instructions = FoundationModelsChatNamer.instructions
        XCTAssertTrue(instructions.contains("two to six words"))
        XCTAssertTrue(instructions.contains("no quotation marks"))
        XCTAssertTrue(instructions.contains("\"chat\"") && instructions.contains("\"conversation\""))
    }

    /// A terminal is named under its own instructions, not a chat's, from the text its screen gave.
    func testATerminalIsAskedUnderItsOwnInstructions() async {
        let calls = Calls()
        let namer = FoundationModelsChatNamer(isAvailable: { true }, generate: { context, prompt in
            calls.record((context == .terminal ? "terminal\n" : "chat\n") + prompt); return "Fix the tab bar"
        })
        let input = ChatNamingInput(prompt: "Requests the person typed, oldest first:\n- fix the tab bar", reply: "",
                                    newestMessageID: "917", context: .terminal)
        let name = await namer.name(for: input)
        XCTAssertEqual(name, "Fix the tab bar")
        let asked = calls.all.first ?? ""
        XCTAssertTrue(asked.hasPrefix("terminal\n"), asked)
        XCTAssertTrue(asked.contains("- fix the tab bar"))
        XCTAssertFalse(asked.contains("917"), "The cursor is not the model's business")
        let instructions = FoundationModelsChatNamer.terminalInstructions
        XCTAssertNotEqual(instructions, FoundationModelsChatNamer.instructions)
        XCTAssertTrue(instructions.contains("two to six words") && instructions.contains("formats") && instructions.contains("unchanged"))
        XCTAssertFalse(instructions.contains("chat"))
    }
}
