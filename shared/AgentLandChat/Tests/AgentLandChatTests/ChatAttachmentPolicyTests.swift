import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import AgentLandCore
@testable import AgentLandChat

final class ChatAttachmentPolicyTests: XCTestCase {
    func testPhotosAreReencodedWithoutLocationAndScaledDown() throws {
        let photo = try encodedImage(width: 4032, height: 3024, type: .jpeg, gps: true)
        XCTAssertNotNil(properties(photo)[kCGImagePropertyGPSDictionary as String], "Fixture must carry GPS metadata")
        let prepared = try ChatAttachmentPolicy.prepare(name: "IMG_0001.HEIC", data: photo, type: .heic)
        XCTAssertEqual(prepared.mime, "image/jpeg")
        XCTAssertEqual(prepared.name, "IMG_0001.jpg")
        let result = properties(prepared.data)
        XCTAssertNil(result[kCGImagePropertyGPSDictionary as String], "Location must not leave the device")
        XCTAssertEqual(result[kCGImagePropertyPixelWidth as String] as? Int, 2048)
        XCTAssertEqual(result[kCGImagePropertyPixelHeight as String] as? Int, 1536)
    }

    func testScreenshotsStayPNGAndSmallImagesKeepTheirSize() throws {
        let screenshot = try encodedImage(width: 300, height: 200, type: .png, gps: false)
        let prepared = try ChatAttachmentPolicy.prepare(name: "Screen Shot.png", data: screenshot, type: .png)
        XCTAssertEqual(prepared.mime, "image/png")
        XCTAssertEqual(prepared.name, "Screen Shot.png")
        XCTAssertEqual(properties(prepared.data)[kCGImagePropertyPixelWidth as String] as? Int, 300)
    }

    func testGIFPDFAndTextTypes() throws {
        let gif = try encodedImage(width: 10, height: 10, type: .gif, gps: false)
        XCTAssertEqual(try ChatAttachmentPolicy.prepare(name: "a.gif", data: gif, type: .gif).data, gif, "Animated GIFs are sent unchanged")
        XCTAssertEqual(try ChatAttachmentPolicy.prepare(name: "spec.pdf", data: Data("%PDF-1.7".utf8), type: .pdf).mime, "application/pdf")
        XCTAssertEqual(try ChatAttachmentPolicy.prepare(name: "main.swift", data: Data("let x = 1".utf8), type: nil).mime, "text/plain")
        XCTAssertEqual(try ChatAttachmentPolicy.prepare(name: "NOTES.md", data: Data("# Notes".utf8), type: nil).mime, "text/markdown")
        XCTAssertEqual(try ChatAttachmentPolicy.prepare(name: "data.json", data: Data("{}".utf8), type: nil).mime, "application/json")
        XCTAssertEqual(try ChatAttachmentPolicy.prepare(name: "rows.csv", data: Data("a,b".utf8), type: nil).mime, "text/csv")
        XCTAssertEqual(try ChatAttachmentPolicy.prepare(name: "Makefile", data: Data("all:\n\tmake".utf8), type: nil).mime, "text/plain")
    }

    func testBinaryInvalidTextAndOversizedFilesAreRefused() {
        XCTAssertThrowsError(try ChatAttachmentPolicy.prepare(name: "archive.zip", data: Data([0x50, 0x4B]), type: .zip)) {
            XCTAssertEqual($0 as? ChatAttachmentPolicy.Problem, .unsupported("archive.zip"))
        }
        XCTAssertThrowsError(try ChatAttachmentPolicy.prepare(name: "notes.txt", data: Data([0xFF, 0xFE, 0x00, 0xD8]), type: .plainText)) {
            XCTAssertEqual($0 as? ChatAttachmentPolicy.Problem, .unsupported("notes.txt"))
        }
        let large = Data(repeating: 0x61, count: ChatAttachmentPolicy.maxTextBytes + 1)
        XCTAssertThrowsError(try ChatAttachmentPolicy.prepare(name: "big.log", data: large, type: .plainText)) {
            XCTAssertEqual($0 as? ChatAttachmentPolicy.Problem, .tooLarge("big.log"))
        }
        XCTAssertThrowsError(try ChatAttachmentPolicy.prepare(name: "empty.txt", data: Data(), type: .plainText)) {
            XCTAssertEqual($0 as? ChatAttachmentPolicy.Problem, .unreadable("empty.txt"))
        }
    }

    func testNamesAreSanitizedAndBounded() {
        XCTAssertEqual(ChatAttachmentPolicy.sanitizedName("../etc/passwd"), ".._etc_passwd")
        XCTAssertEqual(ChatAttachmentPolicy.sanitizedName("a\u{0}b\nc.txt"), "a_b_c.txt")
        XCTAssertEqual(ChatAttachmentPolicy.sanitizedName("   "), "Attachment")
        XCTAssertLessThanOrEqual(ChatAttachmentPolicy.sanitizedName(String(repeating: "é", count: 200)).utf8.count, 120)
    }

    @MainActor
    func testTrayTracksUploadsFailuresRemovalAndLimit() async throws {
        let tray = ChatAttachmentTray()
        let text = try ChatAttachmentPolicy.prepare(name: "a.txt", data: Data("a".utf8), type: .plainText)
        tray.add(text) { UploadedAttachment(id: "att_" + $0.name, name: $0.name, mime: $0.mime, size: Int64($0.data.count)) }
        XCTAssertNil(tray.uploadedIDs, "A message waits until every file has uploaded")
        try await waitUntil { tray.uploadedIDs != nil }
        XCTAssertEqual(tray.uploadedIDs, ["att_a.txt"])

        tray.add(text) { _ in throw URLError(.timedOut) }
        try await waitUntil { if case .failed = tray.items.last?.upload { return true } else { return false } }
        XCTAssertNil(tray.uploadedIDs)
        tray.remove(tray.items[1].id)
        XCTAssertEqual(tray.uploadedIDs, ["att_a.txt"])

        for _ in 0..<10 { tray.add(text) { UploadedAttachment(id: "x", name: $0.name, mime: $0.mime, size: 1) } }
        XCTAssertEqual(tray.items.count, ChatAttachmentPolicy.maxCount)
        XCTAssertNotNil(tray.problem)
    }

    @MainActor private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition not met")
    }

    private func encodedImage(width: Int, height: Int, type: UTType, gps: Bool) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        var metadata: [CFString: Any] = [:]
        if gps { metadata[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N"] }
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func properties(_ data: Data) -> [String: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
    }
}

final class ChatPresentationTests: XCTestCase {
    func testReasoningDurations() {
        XCTAssertEqual(ChatDurations.finished(0.4), "< 1 s")
        XCTAssertEqual(ChatDurations.finished(12.2), "12 s")
        XCTAssertEqual(ChatDurations.finished(184), "3 min 4 s")
        XCTAssertEqual(ChatDurations.elapsed(7.9), "0:07")
        XCTAssertEqual(ChatDurations.seconds(start: "2026-09-24T09:00:00.000Z", end: "2026-09-24T09:00:12.500Z", legacyMilliseconds: nil), 12.5)
        XCTAssertEqual(ChatDurations.seconds(start: nil, end: nil, legacyMilliseconds: 1500), 1.5)
        XCTAssertNil(ChatDurations.seconds(start: nil, end: nil, legacyMilliseconds: nil))
    }

    func testToolRowsAreHumanizedAcrossProviders() {
        XCTAssertEqual(ChatToolSummary(ConversationTool(name: "read", status: .completed, input: #"{"filePath":"/p/Sources/LoginView.swift"}"#)).phrase,
                       "Read `LoginView.swift`")
        XCTAssertEqual(ChatToolSummary(ConversationTool(name: "Bash", status: .running, input: #"{"command":"npm test"}"#)).phrase,
                       "Running `npm test`…")
        XCTAssertEqual(ChatToolSummary(ConversationTool(name: "Command", status: .completed, title: "npm test", input: "npm test")).phrase,
                       "Ran `npm test`", "Codex sends the command itself as input")
        XCTAssertEqual(ChatToolSummary(ConversationTool(name: "grep", status: .completed, input: #"{"pattern":"redirect"}"#)).phrase,
                       "Searched for “redirect”")
        XCTAssertEqual(ChatToolSummary(ConversationTool(name: "mcp__linear__create_issue", status: .completed)).phrase,
                       "Used `mcp__linear__create_issue`")
        XCTAssertEqual(ChatToolSummary(ConversationTool(name: "bash", status: .running), interrupted: true).state, .interrupted)
        XCTAssertEqual(ChatToolSummary(ConversationTool(name: "bash", status: .error, error: "The user rejected permission")).state, .denied)
        XCTAssertEqual(ChatToolSummary(ConversationTool(name: "edit", status: .error, error: "No such file")).state, .failed)
        XCTAssertEqual(ChatToolKind(toolName: "TodoWrite"), .plan)
        XCTAssertEqual(ChatToolKind(toolName: "Task"), .subagent)
        XCTAssertEqual(ChatToolKind(toolName: "WebSearch"), .web)
        let group = [
            ChatToolSummary(ConversationTool(name: "read", status: .completed)), ChatToolSummary(ConversationTool(name: "read", status: .completed)),
            ChatToolSummary(ConversationTool(name: "edit", status: .completed)), ChatToolSummary(ConversationTool(name: "bash", status: .error, error: "exit 1"))
        ]
        XCTAssertEqual(ChatToolSummary.groupSummary(group), "Read 2 files · Edited 1 · Ran 1 command · 1 failed")
    }

    func testOnlyWebAndMailLinksStayTappable() throws {
        XCTAssertTrue(ChatInline.allowsLink(try XCTUnwrap(URL(string: "https://example.com"))))
        XCTAssertTrue(ChatInline.allowsLink(try XCTUnwrap(URL(string: "mailto:a@example.com"))))
        XCTAssertFalse(ChatInline.allowsLink(try XCTUnwrap(URL(string: "javascript:alert(1)"))))
        XCTAssertFalse(ChatInline.allowsLink(try XCTUnwrap(URL(string: "agentland://pair?code=1"))))
        let attributed = ChatInline.attributed("[open](javascript:alert(1)) and [site](https://example.com)", role: .reply)
        XCTAssertEqual(attributed.runs.compactMap { $0.link }, [URL(string: "https://example.com")!])
    }

    func testUserTextKeepsLogsAndShowsOnlyFencesAsCode() {
        XCTAssertEqual(ChatUserText.segments("**not bold**\n# not a heading\n```swift\nlet x = 1\n```\nafter"), [
            .text("**not bold**\n# not a heading"), .code(language: "swift", code: "let x = 1"), .text("after")
        ])
    }

    func testErrorCardsAndApprovalTitles() {
        XCTAssertEqual(ChatErrorCopy.category(ConversationError(code: "provider_auth", message: "401"), provider: .claude).title,
                       "Claude Code Isn’t Signed In")
        // Chat names its agents Claude Code and Codex, as Terminal does (2026-10-12 ~20:50): the terminal step says "it".
        let signIn = ChatErrorCopy.category(ConversationError(code: AgentErrorCode.authRequired, message: "Sign in"), provider: .codex)
        XCTAssertEqual([signIn.title, signIn.guidance, signIn.announcement],
                       ["Sign In to Codex", "Open it in a terminal and follow its sign-in, then choose Run Again.", "Reply failed: Codex needs you to sign in"])
        XCTAssertEqual(ChatSignInNotice.title(provider: .claude), "Sign in to Claude Code: open it in a terminal and follow its sign-in")
        XCTAssertEqual(ChatInteractionCopy.pill(ChatInteraction(id: "q", kind: .question, questions: [ChatQuestion(id: "0", text: "Which?")]),
                                                provider: .claude).0, "Claude Code asked a question")
        XCTAssertEqual(ChatErrorCopy.category(ConversationError(code: "provider_error", message: "Rate limit exceeded (429)"), provider: .opencode).title,
                       "Rate Limited")
        XCTAssertEqual(ChatErrorCopy.category(ConversationError(code: "agent_error", message: "Boom"), provider: .codex).title, "Reply Failed")
        XCTAssertEqual(ChatInteractionCopy.approvalTitle(ChatPermission(tool: "bash", title: "ls"), provider: .opencode),
                       "Allow OpenCode to run this command?")
        XCTAssertEqual(ChatInteractionCopy.approvalTitle(ChatPermission(tool: "Edit", title: "Sources/Auth.swift"), provider: .codex),
                       "Allow Codex to edit `Auth.swift`?")
        XCTAssertEqual(ChatInteractionCopy.approvalTitle(ChatPermission(tool: "webfetch"), provider: .opencode), "Allow OpenCode to use `webfetch`?")
        XCTAssertEqual(ChatInteractionCopy.approvalTarget(ChatPermission(tool: "bash", title: "echo *", input: #"{"command":"echo approved"}"#)),
                       "echo approved")
    }

    func testAlwaysButtonSaysWhatTheHostGrants() {
        let worded = ChatInteraction(id: "p", kind: .permission, choices: ["once", "always", "reject"],
                                     alwaysLabel: "Allow Bash(npm test *) in this project",
                                     alwaysDetail: "Saved in this project's .claude/settings.local.json.")
        XCTAssertEqual(ChatInteractionCopy.alwaysTitle(worded), "Allow Bash(npm test *) in this project")
        XCTAssertEqual(ChatInteractionCopy.alwaysTitle(ChatInteraction(id: "p", kind: .permission, choices: ["once", "always", "reject"])),
                       "Always Allow", "Hosts that do not word it keep today's title")
        XCTAssertEqual(ChatInteractionCopy.alwaysTitle(ChatInteraction(id: "p", kind: .permission, alwaysLabel: "  ")), "Always Allow")
    }
}
