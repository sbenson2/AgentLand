#if DEBUG
import Foundation
import SwiftUI
import AgentLandCore

/// A week of realistic archive for previews: chats with every part kind, a
/// continued chat, pins and terminal logs, and a host that answers model
/// options and terminal log ranges.
enum ArchivePreviewData {
    static let loginChatID = "ses_login"

    @MainActor static let store: ArchiveStore = {
        let store = try! ArchiveStore.inMemory(hostKey: "https://studio-mac.local:9841|preview")
        try! store.applyNow(page)
        try! store.setPinnedNow(true, chatID: loginChatID)
        return store
    }()

    static let workspaces = ["p_web": "web-app", "p_api": "billing-api"]

    static let capabilities = CapabilitiesResponse(
        interactions: true, terminal: true, chatProviders: ["opencode", "claude", "codex"],
        chatFeatures: ["events", "parts", "attachments", "continue", "continueThrough", "modes", "effort"],
        chatProviderInfo: ["opencode": ChatProviderInfo(transport: "sse", features: ["rewind"]),
                           "claude": ChatProviderInfo(transport: "stream-json", features: ["modes", "effort"]),
                           "codex": ChatProviderInfo(transport: "app-server", features: ["modes", "effort"])],
        archive: ArchiveCapabilities(features: ["sync", "search", "export", "terminalLogs", "continue", "continueThrough"]))

    static var client: APIClient {
        APIClient(address: try! ServerAddress(validating: "https://studio-mac.local:9841"), token: "preview", transport: PreviewHost())
    }

    static func environment(online: Bool = true, capabilities: CapabilitiesResponse? = capabilities) -> ArchiveEnvironment {
        var status = SyncEngine.Status()
        status.phase = .upToDate
        status.lastSyncedAt = Date().addingTimeInterval(-120)
        return ArchiveEnvironment(client: online ? client : nil, capabilities: capabilities, reachable: online, hostName: "Studio Mac",
                                  workspaces: workspaces, sync: status)
    }

    static let terminalCache: TerminalLogCache = {
        let folder = FileManager.default.temporaryDirectory.appending(path: "AgentLandArchivePreview", directoryHint: .isDirectory)
        return try! TerminalLogCache(location: ArchiveLocation(hostKey: "preview", directory: folder))
    }()

    static let buildLog = ArchivedTerminalLog(id: "log_build", projectID: "p_web", title: "npm run build", program: "shell",
                                              startedAt: Date().addingTimeInterval(-5_400), endedAt: Date().addingTimeInterval(-5_300),
                                              status: "exited", exitCode: 1, bytes: Int64(PreviewHost.buildOutput.count), gapBytes: 2_048)

    private static func at(_ interval: TimeInterval) -> String {
        Date().addingTimeInterval(interval).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    private static func chat(_ id: String, _ project: String, _ provider: String, _ title: String, model: String, ago: TimeInterval,
                             parent: String? = nil) -> ArchiveChangeItem {
        .chat(ArchiveChatRecord(id: id, projectID: project, provider: provider, title: title, model: model, parentID: parent,
                                relation: parent == nil ? nil : "continue", createdAt: at(-ago - 600), updatedAt: at(-ago)))
    }

    private static func message(_ id: String, _ chat: String, _ role: MessageRole, _ ord: Int64, ago: TimeInterval, provider: String,
                                model: String? = nil, status: ConversationMessageStatus = .complete, parts: [ConversationPart]) -> ArchiveChangeItem {
        .message(ArchiveMessageRecord(message: ConversationMessage(id: id, chatID: chat, turnID: role == .user ? id : "", role: role,
                                                                  status: status, ord: ord, createdAt: at(-ago), provider: provider,
                                                                  model: model, parts: parts)))
    }

    private static func text(_ id: String, _ text: String) -> ConversationPart { ConversationPart(id: id, kind: .text, text: text) }

    private static var page: ArchiveChangesPage {
        let login = loginChatID
        let items: [ArchiveChangeItem] = [
            chat(login, "p_web", "claude", "Fix the login loop after passkey sign-in", model: "claude/opus", ago: 1_200),
            message("l1", login, .user, 1, ago: 1_900, provider: "claude",
                    parts: [text("l1t", "Signing in with a passkey on Safari sends me back to /login forever. Can you find out why?"),
                            ConversationPart(id: "l1a", kind: .attachment, attachment: AttachmentRecord(name: "redirects.har", mime: "application/json"))]),
            message("l2", login, .assistant, 2, ago: 1_800, provider: "claude", model: "claude/opus", parts: [
                ConversationPart(id: "l2r", kind: .reasoning, text: "The redirect happens after the session cookie is set, so the cookie is probably not sent back.",
                                 start: at(-1_830), end: at(-1_818)),
                ConversationPart(id: "l2t1", kind: .tool, tool: ConversationTool(name: "Bash", callID: "c1", status: .completed, title: "npm test -- auth",
                                                                                 input: #"{"command":"npm test -- auth"}"#, output: "12 passing\n1 failing: session cookie domain")),
                ConversationPart(id: "l2p", kind: .patch, text: "src/auth/session.ts\nsrc/auth/session.test.ts"),
                text("l2x", """
                The session cookie was set for `auth.example.com`, so the browser never sent it to `example.com` and every page load started a new sign-in.

                I changed the cookie to the parent domain:

                ```ts
                res.cookie("session", token, { domain: ".example.com", sameSite: "lax", secure: true })
                ```

                The auth tests pass now.
                """)
            ]),
            message("l3", login, .user, 3, ago: 1_300, provider: "claude", parts: [text("l3t", "Does this break the staging subdomain?")]),
            message("l4", login, .assistant, 4, ago: 1_200, provider: "claude", model: "claude/opus", status: .aborted,
                    parts: [text("l4t", "Staging uses `staging.example.com`, which is still under the parent domain, so")]),
            chat("ses_csv", "p_web", "codex", "Add CSV export to the reports screen", model: "codex/gpt-5", ago: 9_000),
            message("c1", "ses_csv", .user, 1, ago: 9_600, provider: "codex", parts: [text("c1t", "Add a CSV export button to the reports screen.")]),
            message("c2", "ses_csv", .assistant, 2, ago: 9_000, provider: "codex", model: "codex/gpt-5",
                    parts: [text("c2t", "Added **Export CSV** to the toolbar. It streams rows so large reports don’t load into memory.")]),
            chat("ses_upload", "p_api", "opencode", "Why is the upload test flaky?", model: "anthropic/claude-sonnet", ago: 86_400 + 3_600),
            message("u1", "ses_upload", .user, 1, ago: 86_400 + 4_000, provider: "opencode", parts: [text("u1t", "The upload test fails about one run in five.")]),
            message("u2", "ses_upload", .assistant, 2, ago: 86_400 + 3_600, provider: "opencode", model: "anthropic/claude-sonnet",
                    parts: [text("u2t", "It waits a fixed 100 ms for the temp file. Waiting on the upload's completion instead fixes it.")]),
            chat("ses_keys", "p_web", "claude", "Rename the settings keys", model: "claude/sonnet", ago: 3 * 86_400),
            message("k1", "ses_keys", .user, 1, ago: 3 * 86_400, provider: "claude", parts: [text("k1t", "Rename the settings keys to the new scheme and migrate old values.")]),
            chat("ses_profile", "p_api", "codex", "Profile the image pipeline", model: "codex/gpt-5", ago: 15 * 86_400),
            message("p1", "ses_profile", .user, 1, ago: 15 * 86_400, provider: "codex", parts: [text("p1t", "Where does the image pipeline spend its time?")]),
            chat("ses_notes", "p_web", "opencode", "Draft release notes for 0.1", model: "openai/gpt-5", ago: 40 * 86_400),
            message("n1", "ses_notes", .user, 1, ago: 40 * 86_400, provider: "opencode", parts: [text("n1t", "Draft release notes from the merged changes.")]),
            chat("ses_login_codex", "p_web", "codex", "Fix the login loop after passkey sign-in (continued)", model: "codex/gpt-5", ago: 600, parent: login),
            message("agentland-seed", "ses_login_codex", .user, 0, ago: 650, provider: "codex",
                    parts: [ConversationPart(id: "seed", kind: .context, text: "Context from an earlier chat, \"Fix the login loop after passkey sign-in\" (claude, claude/opus), continued here with another model.")]),
            message("x1", "ses_login_codex", .user, 1, ago: 620, provider: "codex", parts: [text("x1t", "Check the staging subdomain too.")]),
            .terminalLog(ArchiveTerminalLogRecord(id: "log_dev", projectID: "p_web", title: "npm run dev", program: "shell",
                                                  startedAt: at(-3_000), status: "running", bytes: 48_213)),
            .terminalLog(ArchiveTerminalLogRecord(id: buildLog.id, projectID: "p_web", title: buildLog.title, program: "shell", startedAt: at(-5_400),
                                                  endedAt: at(-5_300), status: "exited", exitCode: 1, bytes: buildLog.bytes, gapBytes: buildLog.gapBytes)),
            .terminalLog(ArchiveTerminalLogRecord(id: "log_claude", projectID: "p_api", title: "Claude Code", program: "claude",
                                                  startedAt: at(-2 * 86_400), endedAt: at(-2 * 86_400 + 900), status: "exited", exitCode: 0, bytes: 512_000))
        ]
        return ArchiveChangesPage(epoch: "preview", changes: items.enumerated().map { ArchiveChange(seq: Int64($0.offset + 1), item: $0.element) },
                                  cursor: "preview.\(items.count)")
    }
}

/// Answers the few routes the previews use.
private final class PreviewHost: APITransport, @unchecked Sendable {
    static let buildOutput = Data("""
    \u{1B}[1m> web-app@0.1.0 build\u{1B}[0m
    \u{1B}[36mvite\u{1B}[0m v6.0.0 building for production...
    \u{1B}[32m✓\u{1B}[0m 412 modules transformed.
    \u{1B}[31merror\u{1B}[0m src/auth/session.ts(14,5): Type 'string | undefined' is not assignable to type 'string'.
    Build failed in 3.21s

    """.replacingOccurrences(of: "\n", with: "\r\n").utf8)

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body: String
        switch request.url?.path {
        case "/v1/chat/options":
            body = #"{"models":[{"id":"codex/gpt-5","name":"GPT-5","provider":"Codex","efforts":["low","medium","high"],"defaultEffort":"medium"},{"id":"codex/gpt-5-mini","name":"GPT-5 mini","provider":"Codex"}],"defaultModel":"codex/gpt-5","agents":["build"],"modes":[{"id":"auto-review","name":"Auto review"},{"id":"ask","name":"Ask"}],"defaultMode":"auto-review"}"#
        case "/v1/archive/terminal-log":
            let offset = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "offset" }?.value ?? "0") ?? 0
            let data = Self.buildOutput.subdata(in: min(offset, Self.buildOutput.count)..<Self.buildOutput.count)
            body = #"{"data":"\#(data.base64EncodedString())","offset":\#(offset),"next":\#(Self.buildOutput.count),"eof":true,"size":\#(Self.buildOutput.count),"status":"exited"}"#
        default:
            return (Data(#"{"error":{"code":"unavailable","message":"Not in the preview"}}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

#Preview("Archive") {
    ArchiveBrowser(model: ArchiveBrowserModel(store: ArchivePreviewData.store, environment: ArchivePreviewData.environment()),
                   terminalCache: ArchivePreviewData.terminalCache, actions: ArchiveActions(continued: { _ in }))
}

#Preview("Archive, offline") {
    ArchiveBrowser(model: ArchiveBrowserModel(store: ArchivePreviewData.store, environment: ArchivePreviewData.environment(online: false)),
                   terminalCache: ArchivePreviewData.terminalCache)
}

#Preview("Archived chat") {
    NavigationStack {
        ArchivedChatView(model: ArchivedChatModel(chatID: ArchivePreviewData.loginChatID, store: ArchivePreviewData.store,
                                                  environment: ArchivePreviewData.environment()),
                         actions: ArchiveActions(openChat: { _ in true }, continued: { _ in }))
    }
}

#Preview("Continue with…") {
    let chat = ArchivedChat(id: ArchivePreviewData.loginChatID, projectID: "p_web", provider: "claude", title: "Fix the login loop after passkey sign-in",
                            model: "claude/opus", createdAt: Date(), updatedAt: Date())
    ContinueChatSheet(model: ContinueChatModel(chat: chat, store: ArchivePreviewData.store, environment: ArchivePreviewData.environment(),
                                               workspaceName: "web-app")) { _ in }
}

#Preview("Terminal log") {
    NavigationStack {
        TerminalLogViewer(log: ArchivePreviewData.buildLog, cache: ArchivePreviewData.terminalCache, fetcher: ArchivePreviewData.client)
    }
}
#endif
