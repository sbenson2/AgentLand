import Foundation
import XCTest
@testable import AgentLandCore

final class ProgramCatalogTests: XCTestCase {
    func testKnownProgramsAndAgentsUseTheirProductNames() {
        XCTAssertEqual(TerminalProgram.known.map(\.displayName), ["Shell", "OpenCode", "Claude Code", "Codex"])
        XCTAssertEqual(AgentProvider.known.map(\.displayName), ["OpenCode", "Claude Code", "Codex"])
        XCTAssertEqual(TerminalProgram(id: "opencode"), .opencode, "A host's program name maps to the catalog entry")
        XCTAssertEqual(AgentProvider(id: "claude").displayName, "Claude Code")
    }

    /// Chat names Claude Code's and Codex's chats Claude Code and Codex, as Terminal does (owner, 2026-10-12 ~20:50,
    /// replacing Claude and ChatGPT); every other agent keeps its name.
    func testChatNamesClaudeCodeAndCodex() {
        XCTAssertEqual(AgentProvider.known.map(\.chatDisplayName), ["OpenCode", "Claude Code", "Codex"])
        XCTAssertEqual(AgentProvider(id: "gemini", name: "Gemini CLI").chatDisplayName, "Gemini CLI")
        XCTAssertEqual(AgentProvider(id: "claude", name: "Something else").chatDisplayName, "Claude Code")
        XCTAssertEqual([TerminalProgram.claude, .codex].map(\.displayName), ["Claude Code", "Codex"])
        XCTAssertEqual([TerminalProgram.claude, .codex].map(\.terminalTitle), ["Claude Code", "Codex"])
    }

    func testUnknownIDsShowAPlainTokenOrANeutralLabel() {
        XCTAssertEqual(TerminalProgram(id: "gemini").displayName, "gemini")
        XCTAssertEqual(AgentProvider(id: "aider-2.1").displayName, "aider-2.1")
        for id in ["", "   ", "rm -rf /", "line\nbreak", "ünïcode", String(repeating: "x", count: 65)] {
            XCTAssertEqual(TerminalProgram(id: id).displayName, "Unknown program", "\(id.debugDescription)")
            XCTAssertEqual(AgentProvider(id: id).displayName, "Unknown agent", "\(id.debugDescription)")
        }
    }

    /// The host takes ids of 1–64 characters (desktop/agents_registry.go): every one of them is offered
    /// and named, with names up to the host's 100 characters kept whole.
    func testIdsAndNamesUpToTheHostsLimitsAreAccepted() throws {
        let longest = String(repeating: "a", count: 64)
        let middle = "agent-with-a-name-longer-than-thirty-two"
        XCTAssertTrue(AgentID.isValid(longest))
        XCTAssertTrue(AgentID.isValid(middle))
        XCTAssertFalse(AgentID.isValid(longest + "a"))
        let name = String(repeating: "N", count: 100)
        XCTAssertEqual(AgentID.displayName(name), name, "A name the host accepts is kept whole")
        XCTAssertEqual(AgentID.displayName(name + "N")?.count, 100)
        XCTAssertTrue(AgentID.displayName(name + "N")?.hasSuffix("…") == true)

        let catalog = [AgentCatalogEntry(id: middle, name: name, chat: true, terminal: true),
                       AgentCatalogEntry(id: longest, name: "Longest", chat: true, terminal: true)].compactMap { $0 }
        XCTAssertEqual(catalog.count, 2, "Both ids are read")
        let host = CapabilitiesResponse(interactions: true, terminal: true, terminalPrograms: ["shell", middle, longest],
                                        chatProviders: ["opencode", middle, longest], agents: ["catalog", "install", "acp"],
                                        agentCatalog: catalog)
        XCTAssertEqual(AgentProvider.offered(by: host).map(\.id), ["opencode", middle, longest])
        XCTAssertEqual(TerminalProgram.offered(by: host).map(\.id), ["shell", middle, longest])
        let provider = AgentProvider.named(middle, by: host)
        XCTAssertEqual(provider.displayName, name)
        XCTAssertEqual(provider.newChatTitle, name + " chat", "The host counts <name> chat as its default title")
    }

    /// The apps take exactly the ids the host does (`agentIDPattern`, desktop/agents_registry.go:
    /// `^[a-z0-9][a-z0-9._-]{0,63}$`, never ending in `.json`), so an id the host would refuse is never
    /// offered, sent or named.
    func testAgentIDsFollowTheHostsRule() throws {
        let accepted = ["a", "0", "9lives", "gemini", "qwen-code", "claude-acp", "codex", "opencode", "shell", "factory-droid",
                        "a.b_c-d", "a..b", "agent.", "agent-", "agent_", "json", "x.json5", "x.jsonl", "notes.json.bak",
                        "a" + String(repeating: ".", count: 63), String(repeating: "z", count: 64)]
        for id in accepted {
            XCTAssertTrue(AgentID.isValid(id), "The host takes \(id.debugDescription)")
        }
        let refused = ["", "Gemini", "GEMINI", "gemini-CLI", "qwen_Code", ".icons", "_agent", "-agent", ".json", "registry.json", "a.json",
                       "x.JSON", String(repeating: "z", count: 65), "a b", " a", "a ", "a/b", "../etc", "a:b", "a+b", "a@b", "a\n", "\na",
                       "a\u{0}", "ünïcode", "é", "e\u{301}", "ａ", "ⅰ", "١"]
        for id in refused {
            XCTAssertFalse(AgentID.isValid(id), "The host refuses \(id.debugDescription)")
        }

        // The host never lists them, and one that did would be left out, as any id the host refuses.
        let body = #"""
        {"agents":[{"id":"Gemini","name":"Upper"},{"id":"_hidden","name":"Underscore"},{"id":"registry.json","name":"File"},
                   {"id":"gemini","name":"Gemini CLI"}]}
        """#
        XCTAssertEqual(try ProtocolDecoder.decode(AgentCatalog.self, from: Data(body.utf8)).agents.map(\.id), ["gemini"])
        XCTAssertNil(AgentCatalogEntry(id: "Gemini", name: "Upper", chat: true, terminal: true))
        let host = CapabilitiesResponse(interactions: true, terminal: true, terminalPrograms: ["shell", "Goose", "goose"],
                                        chatProviders: ["opencode", "Gemini", "gemini"], agents: ["catalog", "acp"])
        XCTAssertEqual(AgentProvider.offered(by: host).map(\.id), ["opencode", "gemini"])
        XCTAssertEqual(TerminalProgram.offered(by: host).map(\.id), ["shell", "goose"])
        XCTAssertEqual(AgentProvider(id: "Gemini", name: "Gemini CLI").displayName, "Unknown agent")
    }

    /// A new chat is made with "<agent> chat", which the host counts as a default title. When that is longer
    /// than the host's 200 bytes (a long name outside Latin scripts), it is made with none: the host then names
    /// it after its agent, still a default title, where a cut one would count as chosen and never be renamed.
    func testANewChatsTitleFitsTheHostOrIsLeftToIt() {
        let fits = String(repeating: "月", count: 65)
        XCTAssertEqual(AgentProvider(id: "kimi", name: fits).newChatTitle, fits + " chat", "195 bytes and \" chat\": 200")
        XCTAssertEqual(AgentProvider(id: "kimi", name: String(repeating: "月", count: 66)).newChatTitle, "", "203 bytes")
        let longest = AgentProvider(id: "kimi", name: String(repeating: "月", count: 100))
        XCTAssertEqual(longest.displayName.count, 100, "The name itself is shown whole")
        XCTAssertEqual(longest.newChatTitle, "")
        XCTAssertEqual(AgentProvider.opencode.newChatTitle, "New chat")
        XCTAssertEqual(AgentProvider.claude.newChatTitle, "Claude Code chat")
        XCTAssertEqual(AgentProvider(id: "gemini", name: "Gemini CLI").newChatTitle, "Gemini CLI chat")
    }

    func testHostProgramsAreOfferedOnceKnownOnesFirstThenTheOthersInTheHostsOrder() {
        // The host always lists the shell itself; the Mac menu used to add a second Shell item
        // and title-case the rest ("Opencode").
        let host = CapabilitiesResponse(interactions: true, terminal: true, terminalPrograms: ["shell", "opencode", "claude", "codex"])
        XCTAssertEqual(TerminalProgram.offered(by: host).map(\.displayName), ["Shell", "OpenCode", "Claude Code", "Codex"])
        let unordered = CapabilitiesResponse(interactions: true, terminal: true, terminalPrograms: ["codex", "gemini", "shell", "codex", "shell"])
        XCTAssertEqual(TerminalProgram.offered(by: unordered).map(\.id), ["shell", "codex", "gemini"],
                       "Programs this version cannot name are offered after the known ones, once each")
    }

    func testTheCatalogsTerminalAgentsAreOfferedWithTheHostsNames() {
        let catalog = [AgentCatalogEntry(id: "goose", name: "Goose", chat: true, terminal: true),
                       AgentCatalogEntry(id: "claude", name: "Claude Agent", chat: true, terminal: true),
                       AgentCatalogEntry(id: "zed-only", name: "Chat only", chat: true, terminal: false),
                       AgentCatalogEntry(id: "gemini", name: "Gemini CLI", chat: true, terminal: true)].compactMap { $0 }
        let host = CapabilitiesResponse(interactions: true, terminal: true,
                                        terminalPrograms: ["shell", "gemini", "opencode", "claude", "cursor-agent", "bad id", "goose"],
                                        agentCatalog: catalog)
        let offered = TerminalProgram.offered(by: host)
        XCTAssertEqual(offered.map(\.id), ["shell", "opencode", "claude", "goose", "gemini", "cursor-agent"],
                       "Known programs first in menu order; then the catalog's terminal agents in its order; then the rest of the list; invalid ids dropped")
        XCTAssertEqual(offered.map(\.displayName), ["Shell", "OpenCode", "Claude Code", "Goose", "Gemini CLI", "cursor-agent"],
                       "Known programs keep their names; the others take the host's name, or their id without one")
        XCTAssertEqual(offered.map(\.terminalTitle), ["Terminal", "OpenCode", "Claude Code", "Goose", "Gemini CLI", "cursor-agent"])
        XCTAssertEqual(offered[3].requestValue, "goose", "A program is sent by its id, never a command")
        XCTAssertFalse(offered.contains { $0.id == "zed-only" }, "An agent without a terminal program is not offered for terminals")
        XCTAssertEqual(TerminalProgram.offered(by: CapabilitiesResponse(interactions: true, terminal: false, agentCatalog: catalog)), [],
                       "A host without terminals offers none")
    }

    func testShellNeedsTerminalSupportButNotAProgramList() {
        XCTAssertEqual(TerminalProgram.offered(by: nil), [])
        XCTAssertEqual(TerminalProgram.offered(by: CapabilitiesResponse(interactions: true, terminal: false, terminalPrograms: ["shell", "opencode"])), [])
        // Hosts from before named terminals omit the list but still run a shell.
        XCTAssertEqual(TerminalProgram.offered(by: CapabilitiesResponse(interactions: true, terminal: true)), [.shell])
    }

    func testOpenCodeIsAlwaysOfferedAndOtherAgentsWhenListed() {
        XCTAssertEqual(AgentProvider.offered(by: nil), [.opencode])
        XCTAssertEqual(AgentProvider.offered(by: CapabilitiesResponse(interactions: true, terminal: true)), [.opencode])
        let host = CapabilitiesResponse(interactions: true, terminal: true, chatProviders: ["codex", "opencode", "gemini", "claude", "codex"])
        XCTAssertEqual(AgentProvider.offered(by: host), [.opencode, .claude, .codex, AgentProvider(id: "gemini")],
                       "An agent this version cannot name is offered after the known ones")
        XCTAssertEqual(AgentProvider.offered(by: host).last?.displayName, "gemini", "Without the host's catalog it goes by its id")
    }

    func testTheCatalogsChatAgentsAreOfferedWithTheHostsNamesInItsOrder() {
        let catalog = [AgentCatalogEntry(id: "goose", name: "Goose", chat: true, terminal: true),
                       AgentCatalogEntry(id: "codex", name: "Codex CLI", chat: true, terminal: true),
                       AgentCatalogEntry(id: "terminal-only", name: "Terminal only", chat: false, terminal: true),
                       AgentCatalogEntry(id: "gemini", name: "Gemini CLI", chat: true, terminal: true)].compactMap { $0 }
        let host = CapabilitiesResponse(interactions: true, terminal: true,
                                        chatProviders: ["opencode", "gemini", "claude", "codex", "amp-acp", "no/slash", String(repeating: "a", count: 65)],
                                        agents: ["catalog", "install", "acp"], agentCatalog: catalog)
        let offered = AgentProvider.offered(by: host)
        XCTAssertEqual(offered.map(\.id), ["opencode", "claude", "codex", "goose", "gemini", "amp-acp"],
                       "Known agents first in menu order; then the catalog's chat agents in its order; then the rest of chatProviders; invalid ids dropped")
        XCTAssertEqual(offered.map(\.displayName), ["OpenCode", "Claude Code", "Codex", "Goose", "Gemini CLI", "amp-acp"],
                       "Known agents keep their names; the others take the host's")
        XCTAssertEqual(offered.map(\.newChatTitle), ["New chat", "Claude Code chat", "Codex chat", "Goose chat", "Gemini CLI chat", "amp-acp chat"])
        XCTAssertEqual(offered[4].requestValue, "gemini")
        XCTAssertFalse(offered.contains { $0.id == "terminal-only" }, "An agent that cannot chat is not offered for chats")

        // Catalog agents are offered even when an older list leaves them out; the ones already known are
        // the same values as the catalog's statics, so comparisons with them still hold.
        let catalogOnly = CapabilitiesResponse(interactions: true, terminal: true, chatProviders: ["opencode"],
                                               agents: ["catalog", "install", "acp"], agentCatalog: catalog)
        XCTAssertEqual(AgentProvider.offered(by: catalogOnly).map(\.id), ["opencode", "codex", "goose", "gemini"])
        XCTAssertEqual(AgentProvider.offered(by: catalogOnly)[1], .codex)
    }

    /// The catalog's agents other than OpenCode, Claude Code and Codex chat through ACP: a host that does not
    /// list `acp` in `capabilities.agents` runs no such chats, so they are not offered for chats (their
    /// terminals still are).
    func testCatalogAgentsAreOfferedForChatsThroughACPOnlyWhenTheHostListsIt() {
        let catalog = [AgentCatalogEntry(id: "claude", name: "Claude Code", chat: true, terminal: true),
                       AgentCatalogEntry(id: "gemini", name: "Gemini CLI", chat: true, terminal: true)].compactMap { $0 }
        let withoutACP = CapabilitiesResponse(interactions: true, terminal: true, terminalPrograms: ["shell", "claude", "gemini"],
                                              chatProviders: ["opencode", "claude"], agents: ["catalog", "install"], agentCatalog: catalog)
        XCTAssertEqual(AgentProvider.offered(by: withoutACP), [.opencode, .claude], "No ACP chats without acp")
        XCTAssertEqual(TerminalProgram.offered(by: withoutACP).map(\.id), ["shell", "claude", "gemini"])
        XCTAssertFalse(AgentProvider(id: "gemini").isNative)
        XCTAssertTrue(AgentProvider.known.allSatisfy(\.isNative))

        let withACP = CapabilitiesResponse(interactions: true, terminal: true, terminalPrograms: ["shell", "claude", "gemini"],
                                           chatProviders: ["opencode", "claude"], agents: ["catalog", "install", "acp"], agentCatalog: catalog)
        XCTAssertEqual(AgentProvider.offered(by: withACP).map(\.displayName), ["OpenCode", "Claude Code", "Gemini CLI"])
    }

    func testAnIdTheHostListsIsAcceptedWithTheCatalogsNameWhateverItsFlags() {
        // The lists say what the host takes; the catalog names what it lists.
        let catalog = [AgentCatalogEntry(id: "goose", name: "Goose", chat: true, terminal: false),
                       AgentCatalogEntry(id: "kimi", name: "Kimi CLI", chat: false, terminal: true)].compactMap { $0 }
        let host = CapabilitiesResponse(interactions: true, terminal: true, terminalPrograms: ["shell", "goose"],
                                        chatProviders: ["opencode", "kimi"], agents: ["catalog", "acp"], agentCatalog: catalog)
        XCTAssertEqual(TerminalProgram.offered(by: host).map(\.displayName), ["Shell", "Kimi CLI", "Goose"])
        XCTAssertEqual(AgentProvider.offered(by: host).map(\.displayName), ["OpenCode", "Goose", "Kimi CLI"])
    }

    func testNamesComeFromTheCatalogForHostChatsAndTheTerminalProgramFollowsTheAgent() {
        let catalog = [AgentCatalogEntry(id: "gemini", name: "Gemini CLI", chat: true, terminal: true),
                       AgentCatalogEntry(id: "chat-only", name: "Chat Only", chat: true, terminal: false)].compactMap { $0 }
        let host = CapabilitiesResponse(interactions: true, terminal: true, terminalPrograms: ["shell", "claude"],
                                        chatProviders: ["opencode", "claude", "gemini", "chat-only"], agentCatalog: catalog)
        XCTAssertEqual(AgentProvider.named("gemini", by: host).displayName, "Gemini CLI")
        XCTAssertEqual(AgentProvider.named("claude", by: host), .claude)
        XCTAssertEqual(AgentProvider.named("mystery", by: host).displayName, "mystery")
        XCTAssertEqual(AgentProvider.named("../x", by: host).displayName, "Unknown agent")
        XCTAssertEqual(AgentProvider(id: "claude", name: "Something else").displayName, "Claude Code", "Known agents keep their names")
        XCTAssertEqual(AgentProvider(id: "bad id", name: "Looks fine").displayName, "Unknown agent", "An invalid id never shows a host's name")

        XCTAssertEqual(AgentProvider.named("gemini", by: host).terminalProgram(offeredBy: host)?.displayName, "Gemini CLI")
        XCTAssertEqual(AgentProvider.claude.terminalProgram(offeredBy: host), .claude)
        XCTAssertNil(AgentProvider.named("chat-only", by: host).terminalProgram(offeredBy: host), "No terminal program, no Open in Terminal")
        XCTAssertNil(AgentProvider.opencode.terminalProgram(offeredBy: host), "Not listed for terminals on this host")
        XCTAssertNil(AgentProvider.named("gemini", by: host).terminalProgram(offeredBy: nil))
    }

    /// Continue with another model (docs/HOST-API.md): for an ACP agent only `<id>/default` or no model, and no
    /// mode and no effort; the host answers anything else with 400 invalid_agent_options.
    func testContinueSendsAnACPAgentNoModeOrEffortAndOnlyItsDefaultModel() {
        let gemini = AgentProvider(id: "gemini", name: "Gemini CLI")
        XCTAssertFalse(gemini.continueTakesModeAndEffort)
        var settings = gemini.continueSettings(model: "gemini/default", mode: "yolo", effort: "high")
        XCTAssertEqual(settings.model, "gemini/default")
        XCTAssertNil(settings.mode)
        XCTAssertNil(settings.effort)
        settings = gemini.continueSettings(model: "codex/gpt", mode: nil, effort: nil)
        XCTAssertNil(settings.model, "Another agent's model is never sent for it")
        XCTAssertNil(gemini.continueSettings(model: nil, mode: "build", effort: nil).mode)

        for provider in AgentProvider.known {
            XCTAssertTrue(provider.continueTakesModeAndEffort)
            let kept = provider.continueSettings(model: "\(provider.id)/m", mode: "plan", effort: "high")
            XCTAssertEqual(kept.model, "\(provider.id)/m")
            XCTAssertEqual(kept.mode, "plan")
            XCTAssertEqual(kept.effort, "high")
        }
    }

    func testNewTabTitlesAndRequestValues() {
        XCTAssertEqual(TerminalProgram.shell.terminalTitle, "Terminal")
        XCTAssertEqual(TerminalProgram.opencode.terminalTitle, "OpenCode")
        XCTAssertEqual(TerminalProgram.claude.terminalTitle, "Claude Code")
        XCTAssertNil(TerminalProgram.shell.requestValue, "Every host version starts a shell without a program name")
        XCTAssertEqual(TerminalProgram.codex.requestValue, "codex")
        XCTAssertEqual(AgentProvider.opencode.newChatTitle, "New chat")
        XCTAssertEqual(AgentProvider.claude.newChatTitle, "Claude Code chat")
        XCTAssertEqual(AgentProvider.codex.newChatTitle, "Codex chat")
        XCTAssertNil(AgentProvider.opencode.requestValue, "Every host version starts an OpenCode chat without a provider")
        XCTAssertEqual(AgentProvider.claude.requestValue, "claude")
    }
}
