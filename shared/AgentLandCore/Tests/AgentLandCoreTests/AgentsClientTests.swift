import Foundation
import XCTest
@testable import AgentLandCore

/// The agent catalog's wire (docs/AGENT-CATALOG-PLAN.md, "Host contract"): capabilities, `GET /v1/agents`,
/// the icon, the three changes with their refusals, and `GET /v1/providers`, through a real `URLSession`
/// answered by the stub protocol, so bodies, queries and headers are the ones production sends.
final class AgentsClientTests: XCTestCase {
    func testLocalAutomaticUpdatesAreExplicitAndSurviveEncoding() throws {
        let decoder = JSONDecoder()
        let current = try decoder.decode(AgentInfo.self, from: Data(#"{"id":"codex","source":"local","state":"installed","autoUpdates":true}"#.utf8))
        XCTAssertTrue(current.canUpdate)
        XCTAssertFalse(current.isManaged)
        // A host's explicit capability enables the local updater; source alone does not.
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        XCTAssertEqual(encoded["autoUpdates"] as? Bool, true)
        for field in ["", ",\"autoUpdates\":false", ",\"autoUpdates\":\"true\""] {
            let raw = "{\"id\":\"codex\",\"source\":\"local\",\"state\":\"installed\"" + field + "}"
            let legacy = try decoder.decode(AgentInfo.self, from: Data(raw.utf8))
            XCTAssertFalse(legacy.canUpdate)
            let legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
            XCTAssertNotEqual(legacyJSON["autoUpdates"] as? Bool, true)
        }
        let missing = try decoder.decode(AgentInfo.self, from: Data(#"{"id":"codex","source":"local","state":"notInstalled","autoUpdates":true}"#.utf8))
        XCTAssertFalse(missing.canUpdate)
        let unknown = try decoder.decode(AgentInfo.self, from: Data(#"{"id":"codex","source":"external","state":"installed","autoUpdates":true}"#.utf8))
        XCTAssertFalse(unknown.canUpdate)
    }

    func testAgentInfoReadsUpdateWaitingTerminals() throws {
        let decoder = JSONDecoder()
        func agent(_ extra: String) throws -> AgentInfo {
            try decoder.decode(AgentInfo.self, from: Data(#"{"id":"codex","name":"Codex","source":"local","state":"installed"\#(extra)}"#.utf8))
        }
        XCTAssertEqual(try agent(#","updateWaitingTerminals":2"#).updateWaitingTerminals, 2)
        XCTAssertNil(try agent("").updateWaitingTerminals)
        let wrong = try agent(#","updateWaitingTerminals":"two""#)
        XCTAssertNil(wrong.updateWaitingTerminals)
        XCTAssertEqual(wrong.name, "Codex")
        let again = try decoder.decode(AgentInfo.self, from: JSONEncoder().encode(try agent(#","updateWaitingTerminals":3"#)))
        XCTAssertEqual(again.updateWaitingTerminals, 3)
    }

    func testManualLocalUpdateRemainsAvailableWhenAutomaticUpdatesAreOff() throws {
        let agent = try JSONDecoder().decode(AgentInfo.self, from: Data(#"{"id":"codex","source":"local","state":"installed","autoUpdates":false,"supportsUpdates":true}"#.utf8))
        XCTAssertTrue(agent.canUpdate)
        let catalog = try JSONDecoder().decode(AgentCatalog.self, from: Data(#"{"automaticUpdates":false,"agents":[]}"#.utf8))
        XCTAssertEqual(catalog.automaticUpdates, false)
        XCTAssertEqual(try JSONDecoder().decode(AgentCatalog.self, from: JSONEncoder().encode(catalog)).automaticUpdates, false)
        XCTAssertEqual(catalog.replacing(agent).automaticUpdates, false)
    }

    func testNamedAgentTerminalAllowsPreparationTimeAndBoundsItsNotice() async throws {
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.timeoutInterval, 120)
            return (201, Data(#"{"id":"t1","title":"Codex","projectId":"p","status":"running","updateNotice":"Update\n deferred\u202e."}"#.utf8))
        }
        guard case let .created(terminal) = await (try client()).createTerminal(projectID: "p", title: "Codex", rows: 24, cols: 80, program: "codex") else { return XCTFail("Expected terminal") }
        XCTAssertEqual(terminal.updateNotice, "Update deferred.")
    }

    func testShellCreationKeepsNormalTimeoutAndAgentPreparationFailureIsConfirmed() async throws {
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.timeoutInterval, 20)
            return (409, Self.refusal("agent_update_failed", "No terminal was created"))
        }
        let outcome = await (try client()).createTerminal(projectID: "p", title: "Terminal", rows: 24, cols: 80)
        XCTAssertEqual(outcome, .failed(.server(code: "agent_update_failed", message: "No terminal was created")))
        let raw = #"{"id":"t1","title":"Codex","projectId":"p","status":"running","updateNotice":"\#(String(repeating: "x", count: 1000))"}"#
        let terminal = try JSONDecoder().decode(RemoteTerminal.self, from: Data(raw.utf8))
        XCTAssertEqual(terminal.updateNotice?.count, 600)
        XCTAssertTrue(terminal.updateNotice?.hasSuffix("…") == true)
    }

    private func client() throws -> APIClient {
        APIClient(address: try ServerAddress(validating: "https://mac.example:9841"), token: "device-token", transport: ArchiveStubTransport())
    }

    private func json(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(data)) as? [String: Any])
    }

    private static func refusal(_ code: String, _ message: String = "Refused") -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"\#(message)"}}"#.utf8)
    }

    static let gemini = #"""
    {"id":"gemini","name":"Gemini CLI","description":"Google's agent.","website":"https://github.com/google-gemini/gemini-cli",
     "license":"Apache-2.0","source":"registry","state":"installed","installedVersion":"0.61.0","latestVersion":"0.62.0",
     "previousVersion":"0.60.1","updatedAt":"2026-09-26T20:00:00.000Z","chat":true,"terminal":true,"verified":true,
     "sha256":"abc","cmd":"/secret/path","futureField":{"nested":[1,2]}}
    """#

    // MARK: Capabilities

    func testCapabilitiesReadTheAgentFeaturesAndTheCatalogLeavingOutWhatTheyCannotRead() throws {
        let body = #"""
        {"interactions":true,"terminal":true,"chatProviders":["opencode","claude","gemini"],"terminalPrograms":["shell","gemini"],
         "agents":["catalog","install","acp","updateSettings","later"],
         "agentCatalog":[{"id":"gemini","name":"Gemini  CLI\n","chat":true,"terminal":true,"extra":1},
                         {"id":"goose","chat":true},
                         {"id":"rm -rf /","name":"Bad","chat":true,"terminal":true},
                         {"name":"No id","chat":true},
                         "not an object",
                         {"id":"gemini","name":"Second copy","chat":false,"terminal":false},
                         {"id":"cursor","name":"Cursor","chat":"yes","terminal":true}],
         "somethingNew":{"a":1}}
        """#
        let capabilities = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(body.utf8))
        XCTAssertTrue(AgentFeature.allCases.allSatisfy(capabilities.supportsAgents))
        XCTAssertEqual(capabilities.agentCatalog?.map(\.id), ["gemini", "goose", "cursor"],
                       "Invalid ids, unreadable entries and a second entry for an id are left out")
        XCTAssertEqual(capabilities.agentCatalog?.first, AgentCatalogEntry(id: "gemini", name: "Gemini CLI", chat: true, terminal: true),
                       "Names are one plain line")
        XCTAssertEqual(capabilities.agentCatalog?[1].name, "goose", "An entry without a name goes by its id")
        XCTAssertEqual(capabilities.agentCatalog?[1].terminal, false)
        XCTAssertEqual(capabilities.agentCatalog?[2].chat, false, "A flag this version cannot read counts as false")

        let older = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(#"{"interactions":true,"terminal":true}"#.utf8))
        XCTAssertEqual(older.agents, [])
        XCTAssertNil(older.agentCatalog)
        XCTAssertFalse(AgentFeature.allCases.contains(where: older.supportsAgents), "A host without the entry claims nothing")

        let odd = try ProtocolDecoder.decode(CapabilitiesResponse.self,
                                             from: Data(#"{"interactions":true,"terminal":true,"agents":{"catalog":true},"agentCatalog":"all"}"#.utf8))
        XCTAssertEqual(odd.agents, [], "An entry this version cannot read offers nothing")
        XCTAssertNil(odd.agentCatalog)

        // Encoded and read again (a saved copy), the catalog stays as it was read.
        let again = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: JSONEncoder().encode(capabilities))
        XCTAssertEqual(again, capabilities)
    }

    // MARK: The catalog

    func testTheCatalogReadsEveryFieldIgnoresUnknownOnesAndLeavesOutAgentsItCannotRead() async throws {
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/agents")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer device-token")
            return (200, Data(#"""
            {"registry":{"fetchedAt":"2026-09-26T20:00:00Z","error":"The registry answered 503.","etag":"x"},
             "agents":[\#(Self.gemini),
                       {"id":"cursor","name":"Cursor","source":"registry","state":"notInstalled","chat":true,"terminal":true,"verified":false,
                        "website":"https://www.cursor.com/cli"},
                       {"id":"claude","name":"Claude Code","source":"local","state":"installed","installedVersion":"2.1.280"},
                       {"id":"opencode","name":"OpenCode","source":"bundled","state":"installed","installedVersion":"1.18.31",
                        "restartWanted":true,"idleForSeconds":620},
                       {"id":"future","name":"Future","source":"plugin","state":"paused","website":"javascript:alert(1)"},
                       {"id":"no good id!","name":"Bad"},
                       {"name":"No id"},
                       7]}
            """#.utf8))
        }
        let catalog = try await (try client()).agents()
        XCTAssertEqual(catalog.agents.map(\.id), ["gemini", "cursor", "claude", "opencode", "future"])
        XCTAssertEqual(catalog.registry?.error, "The registry answered 503.")
        XCTAssertEqual(catalog.registry?.fetchedAt, try Date("2026-09-26T20:00:00Z", strategy: .iso8601))

        let gemini = catalog.agents[0]
        XCTAssertEqual(gemini.name, "Gemini CLI")
        XCTAssertEqual(gemini.description, "Google's agent.")
        XCTAssertEqual(gemini.license, "Apache-2.0")
        XCTAssertEqual(gemini.source, .registry)
        XCTAssertEqual(gemini.state, .installed)
        XCTAssertEqual(gemini.installedVersion, "0.61.0")
        XCTAssertEqual(gemini.latestVersion, "0.62.0")
        XCTAssertEqual(gemini.previousVersion, "0.60.1")
        XCTAssertEqual(gemini.updatedAt, try Date("2026-09-26T20:00:00.000Z", strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)))
        XCTAssertNil(gemini.lastError)
        XCTAssertTrue(gemini.chat && gemini.terminal && gemini.verified)
        XCTAssertTrue(gemini.isInstalled)
        XCTAssertTrue(gemini.isManaged)
        XCTAssertEqual(gemini.websiteName, "github.com")

        let cursor = catalog.agents[1]
        XCTAssertEqual(cursor.state, .notInstalled)
        XCTAssertFalse(cursor.verified)
        XCTAssertFalse(cursor.isInstalled)
        XCTAssertEqual(cursor.websiteName, "cursor.com", "The source is named without www.")

        XCTAssertEqual(catalog.agents[2].source, .local)
        XCTAssertFalse(catalog.agents[2].isManaged, "The Mac's own copies keep their own updaters")
        XCTAssertEqual(catalog.agents[3].source, .bundled)
        XCTAssertTrue(catalog.agents[3].restartWanted)
        XCTAssertEqual(catalog.agents[3].idleForSeconds, 620)

        let future = catalog.agents[4]
        XCTAssertEqual(future.source, .other("plugin"), "A source this version does not know is kept as sent")
        XCTAssertEqual(future.state, .other("paused"))
        XCTAssertFalse(future.state.isRunning)
        XCTAssertNil(future.website, "Only web addresses are kept")
        XCTAssertFalse(future.verified, "Without the flag a download counts as unverified")
    }

    func testStatesAndTextAreBoundedAndReadLeniently() throws {
        let long = String(repeating: "x", count: 5_000)
        let body = #"""
        {"agents":[{"id":"a","name":"‮evil‬ Name\u0007","state":"installing","description":"Line one\r\n\r\n\r\nLine two\u0000","lastError":"\#(long)"},
                   {"id":"b","state":"updating","installedVersion":"1.0"},
                   {"id":"c","state":"failed","installedVersion":"1.0","lastError":"The check failed."},
                   {"id":"d","state":"failed","lastError":"npm was not found."},
                   {"id":"e","installedVersion":"2.0"},
                   {"id":"f"}]}
        """#
        let catalog = try ProtocolDecoder.decode(AgentCatalog.self, from: Data(body.utf8))
        let states = catalog.agents.map(\.state)
        XCTAssertEqual(states, [.installing, .updating, .failed, .failed, .installed, .notInstalled],
                       "Without a state, an installed version means installed")
        XCTAssertEqual(catalog.agents[0].name, "evil Name", "Control and direction characters are dropped from names")
        XCTAssertEqual(catalog.agents[0].description, "Line one\n\nLine two")
        XCTAssertEqual(catalog.agents[0].lastError?.count, 1_000, "Cut at the host's own limit")
        XCTAssertTrue(catalog.agents[0].lastError?.hasSuffix("…") == true)
        XCTAssertTrue(catalog.agents[0].state.isRunning)
        XCTAssertTrue(catalog.agents[1].state.isRunning)
        XCTAssertTrue(catalog.agents[1].isInstalled, "An update runs on an installed version")
        XCTAssertTrue(catalog.agents[2].isInstalled, "A failed update keeps the installed version")
        XCTAssertFalse(catalog.agents[3].isInstalled, "A failed install installed nothing")
        XCTAssertEqual(catalog.agents[5].name, "f")

        XCTAssertThrowsError(try ProtocolDecoder.decode(AgentCatalog.self, from: Data(#"{"agents":"none"}"#.utf8)),
                             "A catalog that is not a list is an answer this version cannot read")

        // A copy encoded and read again is the same.
        XCTAssertEqual(try ProtocolDecoder.decode(AgentCatalog.self, from: JSONEncoder().encode(catalog)), catalog)
    }

    /// AgentLand's chats run on OpenCode, so it is never offered for uninstall, whatever its source; other
    /// registry agents are, and agents found on the Mac never.
    func testOnlyRegistryAgentsOtherThanOpenCodeCanBeUninstalled() {
        XCTAssertFalse(AgentInfo(id: "opencode", name: "OpenCode", source: .registry, state: .installed, installedVersion: "1.18.32").canUninstall)
        XCTAssertTrue(AgentInfo(id: "opencode", name: "OpenCode", source: .registry, state: .installed).isManaged, "Still updated by AgentLand")
        XCTAssertFalse(AgentInfo(id: "opencode", name: "OpenCode", source: .bundled, state: .installed).canUninstall)
        XCTAssertTrue(AgentInfo(id: "gemini", name: "Gemini CLI", source: .registry, state: .installed, installedVersion: "0.61.0").canUninstall)
        XCTAssertFalse(AgentInfo(id: "claude", name: "Claude Code", source: .local, state: .installed).canUninstall)
    }

    /// `uninstalling` is a known state: an uninstall runs on the host, counted as work like an install or an
    /// update, and the agent stays installed until the host has removed it.
    func testTheUninstallingStateIsKnownAndTheAgentStaysInstalledUntilItEnds() throws {
        let body = #"""
        {"agents":[{"id":"gemini","source":"registry","state":"uninstalling","installedVersion":"0.61.0","latestVersion":"0.62.0"}]}
        """#
        let catalog = try ProtocolDecoder.decode(AgentCatalog.self, from: Data(body.utf8))
        let gemini = try XCTUnwrap(catalog.agents.first)
        XCTAssertEqual(gemini.state, .uninstalling, "Not a state this version does not know")
        XCTAssertEqual(gemini.state.rawValue, "uninstalling")
        XCTAssertTrue(gemini.state.isRunning, "Work runs on the host")
        XCTAssertTrue(gemini.isInstalled, "Still there until the host removed it")
        XCTAssertTrue(gemini.isPresent)
        XCTAssertEqual(gemini.installedVersion, "0.61.0")
        XCTAssertEqual(try ProtocolDecoder.decode(AgentCatalog.self, from: JSONEncoder().encode(catalog)), catalog, "A saved copy keeps it")
    }

    /// A registry agent with nothing that runs on this Mac carries `"supported": false`; the host leaves the
    /// field out when true, so a missing value is supported.
    func testAnAgentWithNothingForThisMacIsReadAsUnsupported() throws {
        let body = #"""
        {"agents":[{"id":"windsurf","source":"registry","state":"notInstalled","verified":false,"supported":false},
                   {"id":"gemini","source":"registry","state":"notInstalled","verified":true},
                   {"id":"odd","source":"registry","state":"notInstalled","supported":"no"}]}
        """#
        let catalog = try ProtocolDecoder.decode(AgentCatalog.self, from: Data(body.utf8))
        XCTAssertEqual(catalog.agents.map(\.supported), [false, true, true], "Only an explicit false is unsupported")
        let again = try ProtocolDecoder.decode(AgentCatalog.self, from: JSONEncoder().encode(catalog))
        XCTAssertEqual(again, catalog, "A saved copy keeps it")
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(catalog.agents[1]), encoding: .utf8))
        XCTAssertFalse(encoded.contains("supported"), "Left out when true, as the host does")
    }

    /// Which agents are on the Mac: a registry agent with an installed version; a local or bundled one while
    /// its state says so. The host lists Claude Code and Codex as local and notInstalled when their commands
    /// are missing (docs/HOST-API.md "The catalog").
    func testAnAgentIsPresentOnlyWhileItsStateSaysItIsThere() throws {
        let body = #"""
        {"agents":[{"id":"claude","source":"local","state":"installed","installedVersion":"2.1.280"},
                   {"id":"codex","source":"local","state":"notInstalled"},
                   {"id":"opencode","source":"bundled","state":"installing","installedVersion":"1.18.31"},
                   {"id":"goose","source":"local","state":"updating","installedVersion":"1.9.0"},
                   {"id":"gemini","source":"registry","state":"updating","installedVersion":"0.61.0"},
                   {"id":"cursor","source":"registry","state":"notInstalled"},
                   {"id":"amp","source":"registry","state":"installing"},
                   {"id":"kimi","source":"registry","state":"failed","lastError":"uv was not found."},
                   {"id":"qwen","source":"registry","state":"failed","installedVersion":"0.4.0"}]}
        """#
        let catalog = try ProtocolDecoder.decode(AgentCatalog.self, from: Data(body.utf8))
        XCTAssertEqual(catalog.agents.filter(\.isPresent).map(\.id), ["claude", "opencode", "goose", "gemini", "qwen"],
                       "Claude Code without its command is not there; OpenCode being taken over still is")
    }

    /// What the host accepts fits whole (desktop/agents_registry.go, agents_install.go, providers.go): ids of
    /// 64, names and licenses of 100, `lastError` of 1000; providers' names of 200 and 16 key variables of 128.
    func testTextWithinTheHostsLimitsIsKeptWhole() throws {
        let id = String(repeating: "g", count: 64)
        let name = String(repeating: "N", count: 100)
        let license = String(repeating: "L", count: 100)
        let error = String(repeating: "e", count: 1_000)
        let body = #"""
        {"agents":[{"id":"\#(id)","name":"\#(name)","license":"\#(license)","lastError":"\#(error)","state":"failed"},
                   {"id":"\#(id)x","name":"Too long an id"},
                   {"id":"longer","name":"\#(name)N","license":"\#(license)L","lastError":"\#(error)e"}]}
        """#
        let catalog = try ProtocolDecoder.decode(AgentCatalog.self, from: Data(body.utf8))
        XCTAssertEqual(catalog.agents.map(\.id), [id, "longer"], "An id of 64 is read; one of 65 is not an id the host sends")
        let kept = catalog.agents[0]
        XCTAssertEqual(kept.name, name)
        XCTAssertEqual(kept.license, license)
        XCTAssertEqual(kept.lastError, error)
        let cut = catalog.agents[1]
        XCTAssertEqual(cut.name.count, 100)
        XCTAssertTrue(cut.name.hasSuffix("…"))
        XCTAssertEqual(cut.license?.count, 100)
        XCTAssertEqual(cut.lastError?.count, 1_000)

        let variables = (1...17).map { "KEY_\($0)_" + String(repeating: "X", count: 128 - "KEY_\($0)_".count) }
        let providerName = String(repeating: "P", count: 200)
        let providers = try ProtocolDecoder.decode(ModelProvidersResponse.self, from: Data(#"""
        {"providers":[{"id":"wide","name":"\#(providerName)","connected":true,"env":[\#(variables.map { "\"\($0)\"" }.joined(separator: ","))]}]}
        """#.utf8)).providers
        XCTAssertEqual(providers.first?.name, providerName)
        XCTAssertEqual(providers.first?.env, Array(variables.prefix(16)), "16 variables of up to 128 characters, as the host lists them")
    }

    func testTheIconComesFromTheHostWithItsIdBounded() async throws {
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path d="M0 0h16v16H0z"/></svg>"#.utf8)
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.url?.host, "mac.example", "Icons come from the host, never the registry's CDN")
            XCTAssertEqual(request.url?.path, "/v1/agents/icon")
            XCTAssertEqual(request.url?.query, "id=gemini")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer device-token")
            return (200, svg)
        }
        let api = try client()
        let icon = try await api.agentIcon(id: "gemini")
        XCTAssertEqual(icon.data, svg)
        XCTAssertNil(icon.contentType, "No type named: the app tells the kind by the bytes")

        ArchiveStubProtocol.install { _, _ in (200, Data(count: APIClient.agentIconLimit + 1)) }
        do {
            _ = try await api.agentIcon(id: "gemini")
            XCTFail("An icon over the limit is refused")
        } catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }

        ArchiveStubProtocol.install { _, _ in (404, Self.refusal("unknown_agent", "No such agent.")) }
        do {
            _ = try await api.agentIcon(id: "gemini")
            XCTFail("A missing icon throws")
        } catch { XCTAssertEqual(error as? ClientError, .server(code: "unknown_agent", message: "No such agent.")) }

        ArchiveStubProtocol.install { _, _ in XCTFail("An id that is not a plain token is never sent"); return (200, svg) }
        do {
            _ = try await api.agentIcon(id: "../etc")
            XCTFail("An invalid id throws")
        } catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        XCTAssertTrue(ArchiveStubProtocol.requests.isEmpty)
    }

    /// The icon carries the type the host names (`image/svg+xml` or `image/png`). 404 `not_found` is no icon;
    /// 503 `icon_unavailable` is an icon the host could not fetch in time, to be asked for again later.
    func testTheIconCarriesItsTypeAndTellsAMissingIconFromOneNotFetchedYet() async throws {
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path d="M0 0h16v16H0z"/></svg>"#.utf8)
        let typed = APIClient(address: try ServerAddress(validating: "https://mac.example:9841"), token: "device-token",
                              transport: FixedAnswer(status: 200, body: svg, headers: ["Content-Type": "image/svg+xml; charset=utf-8"]))
        let icon = try await typed.agentIcon(id: "gemini")
        XCTAssertEqual(icon, AgentIconData(data: svg, contentType: "image/svg+xml"))
        XCTAssertEqual(AgentIconData.mediaType(" Image/PNG "), "image/png")

        for (status, code, unavailable) in [(503, "icon_unavailable", true), (404, "not_found", false)] {
            let api = APIClient(address: try ServerAddress(validating: "https://mac.example:9841"), token: "device-token",
                                transport: FixedAnswer(status: status, body: Self.refusal(code, "Words."), headers: ["Content-Type": "application/json"]))
            do {
                _ = try await api.agentIcon(id: "gemini")
                XCTFail("\(status) throws")
            } catch {
                XCTAssertEqual((error as? ClientError)?.isIconUnavailable, unavailable, code)
            }
        }
        XCTAssertTrue(ClientError.unexpectedStatus(503).isIconUnavailable, "A 503 without a body too")
        XCTAssertFalse(ClientError.unreachable.isIconUnavailable)
    }

    // MARK: Changes

    func testChangesSendTheIdAndAllowUnverifiedOnlyWhenConfirmed() async throws {
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            return (202, Data(#"{"id":"gemini","name":"Gemini CLI","source":"registry","state":"installing","chat":true,"terminal":true,"verified":true}"#.utf8))
        }
        let api = try client()
        guard case let .accepted(agent) = await api.installAgent(id: "gemini") else { return XCTFail("202 is accepted") }
        XCTAssertEqual(agent?.state, .installing)
        XCTAssertEqual(ArchiveStubProtocol.requests.last?.request.url?.path, "/v1/agents/install")
        XCTAssertEqual(try json(ArchiveStubProtocol.requests.last?.body) as NSDictionary, ["id": "gemini"] as NSDictionary,
                       "allowUnverified goes out only after a confirmation")

        _ = await api.installAgent(id: "cursor", allowUnverified: true)
        XCTAssertEqual(try json(ArchiveStubProtocol.requests.last?.body) as NSDictionary, ["id": "cursor", "allowUnverified": true] as NSDictionary)

        _ = await api.updateAgent(id: "gemini")
        XCTAssertEqual(ArchiveStubProtocol.requests.last?.request.url?.path, "/v1/agents/update")
        XCTAssertEqual(try json(ArchiveStubProtocol.requests.last?.body) as NSDictionary, ["id": "gemini"] as NSDictionary)

        // An update the registry moved to a download without a checksum, after the person confirmed it.
        _ = await api.updateAgent(id: "cursor", allowUnverified: true)
        XCTAssertEqual(ArchiveStubProtocol.requests.last?.request.url?.path, "/v1/agents/update")
        XCTAssertEqual(try json(ArchiveStubProtocol.requests.last?.body) as NSDictionary, ["id": "cursor", "allowUnverified": true] as NSDictionary)

        _ = await api.uninstallAgent(id: "gemini")
        XCTAssertEqual(ArchiveStubProtocol.requests.last?.request.url?.path, "/v1/agents/uninstall")
        XCTAssertEqual(try json(ArchiveStubProtocol.requests.last?.body) as NSDictionary, ["id": "gemini"] as NSDictionary)

        // An answer this version cannot read still means the host took it.
        ArchiveStubProtocol.install { _, _ in (202, Data("accepted".utf8)) }
        var outcome = await api.updateAgent(id: "gemini")
        XCTAssertEqual(outcome, .accepted(nil))

        ArchiveStubProtocol.install { _, _ in XCTFail("An invalid id is never sent"); return (202, Data()) }
        outcome = await api.installAgent(id: "a b")
        XCTAssertEqual(outcome, .failed(.invalidResponse))
    }

    func testRefusalsAreNamedServerErrorsAreUncertainAndUndeliveredRequestsFail() async throws {
        let api = try client()
        let cases: [(Int, String, AgentRefusal)] = [
            (404, "unknown_agent", .unknownAgent), (409, "agent_busy", .busy), (409, "not_managed", .notManaged),
            (409, "agent_required", .required), (400, "unsupported_platform", .unsupportedPlatform),
            (400, "unverified_download", .unverifiedDownload),
        ]
        for (status, code, reason) in cases {
            ArchiveStubProtocol.install { _, _ in (status, Self.refusal(code, "Words for \(code).")) }
            let outcome = await api.installAgent(id: "cursor")
            XCTAssertEqual(outcome, .refused(reason, message: "Words for \(code)."), code)
        }
        // AgentLand's chats need OpenCode: the host refuses its uninstall, a refusal this version knows.
        ArchiveStubProtocol.install { _, _ in (409, Self.refusal("agent_required", "AgentLand needs OpenCode.")) }
        let required = await api.uninstallAgent(id: "opencode")
        XCTAssertEqual(required, .refused(.required, message: "AgentLand needs OpenCode."))
        ArchiveStubProtocol.install { _, _ in (403, Self.refusal("forbidden", "Not allowed.")) }
        var outcome = await api.updateAgent(id: "gemini")
        XCTAssertEqual(outcome, .failed(.server(code: "forbidden", message: "Not allowed.")))
        ArchiveStubProtocol.install { _, _ in (500, Self.refusal("internal", "It broke.")) }
        outcome = await api.updateAgent(id: "gemini")
        XCTAssertEqual(outcome, .uncertain, "A server error may have started the work")
        ArchiveStubProtocol.install { _, _ in (502, Data()) }
        outcome = await api.uninstallAgent(id: "gemini")
        XCTAssertEqual(outcome, .uncertain)
        ArchiveStubProtocol.install { _, _ in throw URLError(.cannotConnectToHost) }
        outcome = await api.installAgent(id: "gemini")
        XCTAssertEqual(outcome, .failed(.unreachable), "Provably not sent")
        ArchiveStubProtocol.install { _, _ in throw URLError(.networkConnectionLost) }
        outcome = await api.installAgent(id: "gemini")
        XCTAssertEqual(outcome, .uncertain, "A lost connection may have delivered it")
    }

    // MARK: Providers

    func testProvidersReadWhatIsConnectedAndNeverAKey() async throws {
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/providers")
            return (200, Data(#"""
            {"providers":[{"id":"anthropic","name":"Anthropic","connected":true,"models":12,"env":["ANTHROPIC_API_KEY"],"key":"never shown"},
                          {"id":"openrouter","name":"OpenRouter","connected":false,"models":150,"env":["OPENROUTER_API_KEY"]},
                          {"id":"ollama","connected":false},
                          {"id":"","name":"Empty"},
                          {"name":"No id"},
                          {"id":"odd","name":"Odd","connected":"yes","models":-3}]}
            """#.utf8))
        }
        let providers = try await (try client()).modelProviders()
        XCTAssertEqual(providers.map(\.id), ["anthropic", "openrouter", "ollama", "odd"])
        XCTAssertEqual(providers[0], ModelProvider(id: "anthropic", name: "Anthropic", connected: true, models: 12, env: ["ANTHROPIC_API_KEY"]))
        XCTAssertEqual(providers[2].name, "ollama")
        XCTAssertEqual(providers[3].connected, false, "A flag this version cannot read counts as not connected")
        XCTAssertEqual(providers[3].models, 0)

        ArchiveStubProtocol.install { _, _ in (503, Self.refusal(ModelProviderErrorCode.catalogUnavailable, "OpenCode isn't answering.")) }
        do {
            _ = try await (try client()).modelProviders()
            XCTFail("503 throws")
        } catch {
            XCTAssertEqual(error as? ClientError, .server(code: "provider_catalog_unavailable", message: "OpenCode isn't answering."))
        }
    }

    func testTheSignInErrorIsRecognized() {
        XCTAssertTrue(ClientError.server(code: "agent_auth_required", message: "Sign in").isAgentAuthRequired)
        XCTAssertFalse(ClientError.server(code: "provider_auth", message: "Sign in").isAgentAuthRequired)
        XCTAssertFalse(ClientError.unreachable.isAgentAuthRequired)
    }
}

/// One answer with the headers given, for every request.
private final class FixedAnswer: APITransport, @unchecked Sendable {
    let status: Int
    let body: Data
    let headers: [String: String]

    init(status: Int, body: Data, headers: [String: String]) {
        self.status = status; self.body = body; self.headers = headers
    }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
}
