import Foundation
import XCTest
@testable import AgentLandCore

/// Chat in workspaces (owner, 2026-10-12: Chat is Claude Code and Codex in the selected workspace):
/// `capabilities.workspaceChats`, version 1, read as the host prints it (plan step 1, `.evidence/agent-chat-20261012`).
final class WorkspaceChatsWireTests: XCTestCase {
    private static let claude = #"""
        {"id":"claude","name":"Claude Code","tools":[],"features":["events","parts","stop","clientMessageId","title","attachments","queue","effort","rewind","fork","regenerate","approvals","questions","modes","restoreFiles"],"attachmentTypes":["image/png","image/jpeg","image/gif","image/webp","text/plain","text/markdown","text/csv","application/json","application/pdf"],"auth":{"kind":"subscription","label":"Claude subscription"}}
        """#
    private static let codex = #"""
        {"id":"codex","name":"Codex","tools":[],"features":["events","parts","stop","clientMessageId","title","attachments","queue","effort","rewind","fork","approvals","questions","modes"],"attachmentTypes":["image/png","text/plain"],"auth":{"kind":"subscription","label":"ChatGPT subscription"}}
        """#
    private static let signedOutCodex = #"""
        {"id":"codex","name":"Codex","tools":[],"features":[],"auth":{"kind":"apiKey","label":"API key","reason":"subscription_required","message":"Sign in to Codex with your ChatGPT subscription (codex login)."}}
        """#

    private func capabilities(_ members: String) throws -> CapabilitiesResponse {
        try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(#"{"interactions":true,"terminal":true\#(members)}"#.utf8))
    }

    private func workspaceChats(_ json: String) throws -> WorkspaceChatsCapability? {
        try capabilities(#","workspaceChats":\#(json)"#).workspaceChats
    }

    func testTheHostsWorkspaceChatsAreRead() throws {
        let chats = try XCTUnwrap(workspaceChats(#"{"version":1,"providers":[\#(Self.claude)],"unavailableProviders":[\#(Self.signedOutCodex)]}"#))
        XCTAssertEqual(chats.providers.map(\.id), ["claude"])
        XCTAssertEqual(chats.providers.first?.name, "Claude Code")
        XCTAssertEqual(chats.providers.first?.auth, PlainChatAuth(kind: "subscription", label: "Claude subscription"))
        XCTAssertTrue(chats.providers.first?.features.contains("approvals") == true)
        XCTAssertEqual(chats.unavailableProviders.map(\.id), ["codex"])
        XCTAssertEqual(chats.unavailableProviders.first?.auth?.reason, "subscription_required")
        XCTAssertEqual(chats.provider("claude")?.name, "Claude Code")
        XCTAssertNil(chats.provider("codex"), "An unavailable provider is never offered")
        XCTAssertTrue(chats.offers(.claude))
        XCTAssertFalse(chats.offers(.codex))

        let both = try XCTUnwrap(workspaceChats(#"{"version":1,"providers":[\#(Self.claude),\#(Self.codex)],"unavailableProviders":[]}"#))
        XCTAssertEqual(both.providers.map(\.id), ["claude", "codex"])
        XCTAssertTrue(both.unavailableProviders.isEmpty)

        // Round trip, and both lists are always written, as the host writes them.
        let data = try JSONEncoder().encode(both)
        XCTAssertEqual(try ProtocolDecoder.decode(WorkspaceChatsCapability.self, from: data), both)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual((object["unavailableProviders"] as? [Any])?.count, 0)
    }

    /// Only version 1 is read; an entry this version cannot read offers no workspace chats. Inside it, entries are read
    /// one by one as `generalChats`' are: one it cannot read is left out, and only Claude Code and Codex are kept,
    /// each once (OpenCode's and ACP agents' workspace chats stay out of Chat).
    func testAnotherVersionOrAnUnreadableEntryOffersNone() throws {
        XCTAssertNil(try capabilities("").workspaceChats, "Older hosts list none")
        XCTAssertNil(try workspaceChats(#"{"version":2,"providers":[\#(Self.claude)],"unavailableProviders":[]}"#))
        XCTAssertNil(try workspaceChats(#"{"providers":[\#(Self.claude)],"unavailableProviders":[]}"#))
        XCTAssertNil(try workspaceChats("7"))
        XCTAssertNil(try workspaceChats(#"{"version":"1"}"#))

        let partly = try XCTUnwrap(workspaceChats(#"""
            {"version":1,"providers":["odd",{"id":"claude","name":"Claude Code","tools":null,"features":[]},
              {"id":"opencode","name":"OpenCode","tools":[],"features":[]},{"id":"gemini","name":"Gemini CLI","tools":[],"features":[]},
              \#(Self.codex),\#(Self.codex)],
             "unavailableProviders":[\#(Self.signedOutCodex),{"id":"claude","name":"Claude Code","tools":[],"features":[]}],
             "savedMemory":true,"later":{"a":1}}
            """#))
        XCTAssertEqual(partly.providers.map(\.id), ["codex"])
        XCTAssertEqual(partly.unavailableProviders.map(\.id), ["claude"], "A provider Chat can use is never also unavailable")

        let bare = try XCTUnwrap(workspaceChats(#"{"version":1}"#))
        XCTAssertTrue(bare.providers.isEmpty)
        XCTAssertTrue(bare.unavailableProviders.isEmpty)

        // The rest of the capabilities never pay for it.
        let host = try capabilities(#","workspaceChats":{"version":1,"providers":7},"chatFeatures":["events"]"#)
        XCTAssertEqual(host.chatFeatures, ["events"])
        XCTAssertEqual(host.workspaceChats?.providers, [])
    }

    /// A workspace chat's provider features come from `chatProviderInfo` while the host sends it (only while its
    /// OpenCode streams), else from the provider's `workspaceChats` entry.
    func testProviderFeaturesFallBackToTheWorkspaceEntry() throws {
        let entries = #","workspaceChats":{"version":1,"providers":[\#(Self.claude),\#(Self.codex)],"unavailableProviders":[]}"#
        let without = try capabilities(entries)
        XCTAssertNil(without.chatProviderInfo)
        for feature in [ChatProviderFeature.approvals, .questions, .modes, .effort, .rewind, .fork, .restoreFiles] {
            XCTAssertTrue(without.supports(feature, provider: "claude"), "\(feature)")
        }
        XCTAssertTrue(without.supports(.modes, provider: "codex"))
        XCTAssertFalse(without.supports(.restoreFiles, provider: "codex"))
        XCTAssertFalse(without.supports(.modes, provider: "opencode"))
        XCTAssertFalse(without.supports(.modes, provider: "gemini"))

        // chatProviderInfo wins where it names the provider; a provider it leaves out falls back.
        let with = try capabilities(entries + #","chatProviderInfo":{"claude":{"transport":"stream-json","features":["modes"]}}"#)
        XCTAssertTrue(with.supports(.modes, provider: "claude"))
        XCTAssertFalse(with.supports(.approvals, provider: "claude"))
        XCTAssertTrue(with.supports(.approvals, provider: "codex"))

        // An unavailable provider claims nothing, and older hosts without either claim nothing.
        let signedOut = try capabilities(#","workspaceChats":{"version":1,"providers":[],"unavailableProviders":[\#(Self.signedOutCodex)]}"#)
        XCTAssertFalse(signedOut.supports(.modes, provider: "codex"))
        XCTAssertFalse(try capabilities("").supports(.modes, provider: "claude"))
    }

    func testTheMemberwiseInitializerKeepsIt() {
        let chats = WorkspaceChatsCapability(providers: [PlainChatProvider(id: "claude", name: "Claude Code", features: ["modes"])])
        let host = CapabilitiesResponse(interactions: true, terminal: true, workspaceChats: chats)
        XCTAssertEqual(host.workspaceChats, chats)
        XCTAssertEqual(chats.version, 1)
        XCTAssertTrue(host.supports(.modes, provider: "claude"))
    }
}
