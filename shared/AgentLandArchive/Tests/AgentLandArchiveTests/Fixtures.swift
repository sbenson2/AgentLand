import Foundation
import XCTest
import AgentLandCore
@testable import AgentLandArchive

/// Change feed items and pages as the host sends them.
enum Fixture {
    static func chat(_ id: String, project: String = "p1", provider: String = "claude", title: String = "Fix login",
                     created: String = "2026-09-23T12:00:00.000Z", updated: String = "2026-09-23T12:05:00.000Z",
                     model: String? = "claude/opus", parent: String? = nil) -> ArchiveChangeItem {
        .chat(ArchiveChatRecord(id: id, projectID: project, provider: provider, title: title, model: model,
                                parentID: parent, relation: parent == nil ? nil : "continue", createdAt: created, updatedAt: updated))
    }

    static func message(_ id: String, chat: String, role: MessageRole = .user, ord: Int64, text: String,
                        created: String = "2026-09-23T12:00:00.000Z", hidden: Bool = false, status: ConversationMessageStatus = .complete,
                        extraParts: [ConversationPart] = [], provider: String = "claude", model: String? = nil) -> ArchiveChangeItem {
        var parts = extraParts
        if !text.isEmpty { parts.append(ConversationPart(id: id + "-text", kind: .text, ord: Int64(parts.count), text: text)) }
        return .message(ArchiveMessageRecord(message: ConversationMessage(id: id, chatID: chat, turnID: role == .user ? id : "", role: role,
                                                                         status: status, ord: ord, createdAt: created, provider: provider,
                                                                         model: model, parts: parts), hidden: hidden))
    }

    static func log(_ id: String, project: String = "p1", title: String = "Build", status: String = "exited", bytes: Int64 = 100,
                    gap: Int64 = 0, started: String = "2026-09-23T11:00:00.000Z") -> ArchiveChangeItem {
        .terminalLog(ArchiveTerminalLogRecord(id: id, projectID: project, title: title, program: "shell", startedAt: started,
                                              endedAt: status == "running" ? nil : "2026-09-23T11:05:00.000Z", status: status,
                                              exitCode: status == "running" ? nil : 0, bytes: bytes, gapBytes: gap))
    }

    static func page(_ items: [ArchiveChangeItem], cursor: String, epoch: String = "e1", resync: Bool = false, hasMore: Bool = false,
                     firstSeq: Int64 = 1) -> ArchiveChangesPage {
        ArchiveChangesPage(epoch: epoch, resync: resync,
                           changes: items.enumerated().map { ArchiveChange(seq: firstSeq + Int64($0.offset), item: $0.element) },
                           cursor: cursor, hasMore: hasMore)
    }

    /// Two chats with a few messages and one terminal log.
    static let starter = page([
        chat("ses_1", title: "Fix the login loop"),
        message("u1", chat: "ses_1", ord: 1, text: "Why does the login page loop after a passkey sign-in?"),
        message("a1", chat: "ses_1", role: .assistant, ord: 2, text: "The session cookie is set for the wrong domain, so every redirect starts over.",
                created: "2026-09-23T12:01:00.000Z", model: "claude/opus"),
        chat("ses_2", provider: "codex", title: "Add CSV export", updated: "2026-09-22T09:00:00.000Z", model: "codex/gpt"),
        message("u2", chat: "ses_2", ord: 1, text: "Add a CSV export to the reports screen", created: "2026-09-22T08:50:00.000Z", provider: "codex"),
        log("t1")
    ], cursor: "e1.6")
}

/// A folder removed when the test ends.
final class TemporaryFolder {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "AgentLandArchiveTests-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func location(_ name: String = "host", key: String = "https://mac.example|device-1") -> ArchiveLocation {
        ArchiveLocation(hostKey: key, directory: url.appending(path: name, directoryHint: .isDirectory))
    }
}

extension XCTestCase {
    /// Waits for a condition checked on the main actor.
    @MainActor
    func eventually(_ what: String, within seconds: Double = 3, _ condition: () async -> Bool,
                    file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !(await condition()), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        let met = await condition()
        XCTAssertTrue(met, "Timed out waiting for \(what)", file: file, line: line)
    }
}
