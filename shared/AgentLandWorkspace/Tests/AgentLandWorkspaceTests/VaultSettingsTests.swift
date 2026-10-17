import XCTest
import AgentLandCore
@testable import AgentLandWorkspace

/// The vault's model for the Mac's Settings → Vault (docs/HOST-API.md "Vault"): the status as the host reports it,
/// its switches, folder, Try Again, adopt and Rebuild; refusals, lost answers and other hosts' answers; following the
/// status while the pane shows; and what `VaultText` says.
@MainActor final class VaultSettingsTests: XCTestCase {
    private let identity = ConnectionIdentity(host: "https://studio.local:9841", deviceID: "local-mac")
    private let hostID = "https://studio.local:9841|local-mac"
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
    }

    nonisolated static let withVault = #"{"interactions":true,"terminal":true,"vault":{"version":1}}"#
    nonisolated static let off = #"""
    {"enabled":false,"folder":"/Users/owner/AgentLand Vault","defaultFolder":"/Users/owner/AgentLand Vault","terminals":true,
     "state":"off","notes":0,"bytes":0,"pending":0,"skipped":0,"backfill":{"done":0,"total":0}}
    """#

    /// The status a host that keeps the vault the way the contract says answers after `body`'s change.
    nonisolated static func status(enabled: Bool, folder: String = "/Users/owner/AgentLand Vault", terminals: Bool = true,
                                   state: String? = nil) -> String {
        #"""
        {"enabled":\#(enabled),"folder":"\#(folder)","defaultFolder":"/Users/owner/AgentLand Vault","terminals":\#(terminals),
         "state":"\#(state ?? (enabled ? "writing" : "off"))","notes":12,"bytes":48000,"pending":3,"skipped":0,
         "backfill":{"done":12,"total":15},"lastWriteAt":"2026-10-12T12:00:00.000Z"}
        """#
    }

    private func attached(_ host: ScriptedHost, capabilities: String = VaultSettingsTests.withVault) async throws -> WorkspaceModel {
        let suite = "vault-\(UUID())"
        suites.append(suite)
        host.on("/v1/capabilities") { _ in (200, capabilities) }
        host.on("/v1/projects") { _ in (200, #"{"projects":[{"id":"a","name":"App"}]}"#) }
        let model = WorkspaceModel(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        model.attach(hostID: hostID, identity: identity,
                     client: APIClient(address: try ServerAddress(validating: "https://studio.local:9841"), token: "token", transport: host))
        model.hostName = "Studio Mac"
        await model.refreshProjects()
        return model
    }

    /// A host that keeps the vault's settings the way the contract says, starting off.
    private func vaultHost() -> ScriptedHost {
        let host = ScriptedHost()
        let kept = Kept()
        host.on("/v1/vault") { _ in (200, await kept.answer()) }
        host.on("/v1/vault/settings") { request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
            return (200, await kept.apply(body))
        }
        host.on("/v1/vault/rebuild") { _ in (200, await kept.answer()) }
        return host
    }

    private actor Kept {
        var enabled = false
        var folder = "/Users/owner/AgentLand Vault"
        var terminals = true

        func apply(_ body: [String: Any]) -> String {
            if let value = body["enabled"] as? Bool { enabled = value }
            if let value = body["folder"] as? String { folder = value.isEmpty ? "/Users/owner/AgentLand Vault" : value }
            if let value = body["terminals"] as? Bool { terminals = value }
            return answer()
        }

        func answer() -> String {
            enabled ? VaultSettingsTests.status(enabled: true, folder: folder, terminals: terminals) : VaultSettingsTests.off
        }
    }

    private func gets(_ host: ScriptedHost) -> Int { host.requests("/v1/vault").count }

    // MARK: Reading and changing

    func testTheStatusReadsAndEachChangeIsWhatTheHostAnswers() async throws {
        let host = vaultHost()
        let workspace = try await attached(host)
        let vault = workspace.vault
        XCTAssertTrue(vault.isAvailable)
        await vault.refresh()
        XCTAssertEqual(vault.status?.state, .off)
        XCTAssertFalse(vault.enabled)
        XCTAssertTrue(vault.terminals)
        XCTAssertEqual(vault.folder, "/Users/owner/AgentLand Vault")

        let on = await vault.setEnabled(true)
        XCTAssertTrue(on)
        XCTAssertEqual(host.bodies("/v1/vault/settings").last as NSDictionary?, ["enabled": true])
        XCTAssertTrue(vault.enabled)
        XCTAssertEqual(vault.status?.state, .writing)
        XCTAssertEqual(vault.status?.notes, 12)

        await vault.setFolder("/Users/owner/Notes/AgentLand")
        XCTAssertEqual(host.bodies("/v1/vault/settings").last as NSDictionary?, ["folder": "/Users/owner/Notes/AgentLand"])
        XCTAssertEqual(vault.folder, "/Users/owner/Notes/AgentLand")
        await vault.useDefaultFolder()
        XCTAssertEqual(host.bodies("/v1/vault/settings").last as NSDictionary?, ["folder": ""], "An empty folder is the default")
        XCTAssertEqual(vault.folder, "/Users/owner/AgentLand Vault")

        await vault.setTerminals(false)
        XCTAssertEqual(host.bodies("/v1/vault/settings").last as NSDictionary?, ["terminals": false])
        XCTAssertFalse(vault.terminals)

        await vault.tryAgain()
        XCTAssertEqual(host.bodies("/v1/vault/settings").last as NSDictionary?, ["enabled": true], "Try Again sends enabled again")
        await vault.adoptFolder()
        XCTAssertEqual(host.bodies("/v1/vault/settings").last as NSDictionary?, ["adopt": true])

        let rebuilt = await vault.rebuild()
        XCTAssertTrue(rebuilt)
        XCTAssertEqual(host.requests("/v1/vault/rebuild").count, 1)

        await vault.setEnabled(false)
        XCTAssertFalse(vault.enabled)
        XCTAssertEqual(vault.status?.state, .off)
        XCTAssertNil(vault.notice)
        XCTAssertEqual(gets(host), 1, "Answers the host confirmed need no read")
    }

    func testARefusedFolderSaysWhyInTheHostsWords() async throws {
        let host = vaultHost()
        let workspace = try await attached(host)
        await workspace.vault.refresh()
        host.on("/v1/vault/settings") { _ in
            (400, #"{"error":{"code":"invalid_folder","message":"The vault needs a folder of its own, not your home folder"}}"#)
        }
        let moved = await workspace.vault.setFolder("/Users/owner")
        XCTAssertFalse(moved)
        XCTAssertEqual(workspace.vault.notice?.title, "That folder can’t hold the vault")
        XCTAssertEqual(workspace.vault.notice?.message, "The vault needs a folder of its own, not your home folder")
        XCTAssertEqual(workspace.vault.folder, "/Users/owner/AgentLand Vault", "The folder stays as the host keeps it")
        XCTAssertFalse(workspace.vault.isChanging)

        host.on("/v1/vault/settings") { _ in
            (409, #"{"error":{"code":"folder_unwritable","message":"AgentLand cannot write in /Volumes/Locked: permission denied"}}"#)
        }
        let on = await workspace.vault.setEnabled(true)
        XCTAssertFalse(on)
        XCTAssertEqual(workspace.vault.notice?.title, "AgentLand can’t write in that folder")
        XCTAssertEqual(workspace.vault.notice?.message, "AgentLand cannot write in /Volumes/Locked: permission denied")
        XCTAssertFalse(workspace.vault.enabled, "The switch goes back to what the host keeps")
        XCTAssertEqual(gets(host), 1, "A refusal changed nothing; nothing to read again")
    }

    func testARebuildWhileOffReadsTheStatusAgain() async throws {
        let host = vaultHost()
        let workspace = try await attached(host)
        await workspace.vault.refresh()
        host.on("/v1/vault/rebuild") { _ in (409, #"{"error":{"code":"vault_off","message":"Turn the vault on to rebuild it"}}"#) }
        let rebuilt = await workspace.vault.rebuild()
        XCTAssertFalse(rebuilt)
        XCTAssertEqual(workspace.vault.notice?.title, "The vault is off")
        XCTAssertEqual(workspace.vault.notice?.message, "Turn the vault on to rebuild it")
        XCTAssertEqual(gets(host), 2, "Read again: the vault was turned off meanwhile")
    }

    /// A change whose answer was lost is not confirmed: the status is read again, and nothing is sent again.
    func testAChangeWhoseAnswerWasLostIsReadAgainNeverSentAgain() async throws {
        let host = vaultHost()
        let workspace = try await attached(host)
        await workspace.vault.refresh()
        host.on("/v1/vault/settings") { _ in (500, #"{"error":{"code":"vault_error","message":"The vault's settings or records could not be read or saved"}}"#) }
        let on = await workspace.vault.setEnabled(true)
        XCTAssertFalse(on)
        XCTAssertEqual(workspace.vault.notice?.title, "The vault may have been turned on")
        XCTAssertEqual(workspace.vault.notice?.tone, .warning)
        XCTAssertEqual(host.requests("/v1/vault/settings").count, 1)
        XCTAssertEqual(gets(host), 2, "Read again")

        host.on("/v1/vault/rebuild") { _ in throw URLError(.networkConnectionLost) }
        await workspace.vault.rebuild()
        XCTAssertEqual(workspace.vault.notice?.title, "The vault may have been rebuilt")
        XCTAssertEqual(host.requests("/v1/vault/rebuild").count, 1)
        XCTAssertEqual(gets(host), 3)
    }

    func testOneChangeAtATimeAndTheControlsShowWhatWasAsked() async throws {
        let host = vaultHost()
        let gate = Gate()
        let workspace = try await attached(host)
        await workspace.vault.refresh()
        host.on("/v1/vault/settings") { _ in
            await gate.wait()
            return (200, VaultSettingsTests.status(enabled: true))
        }
        let switching = Task { await workspace.vault.setEnabled(true) }
        await waitUntil("the change on its way") { workspace.vault.isChanging }
        XCTAssertEqual(workspace.vault.changing, .enabled(true))
        XCTAssertTrue(workspace.vault.enabled, "The switch shows what was asked")
        let other = await workspace.vault.setTerminals(false)
        XCTAssertFalse(other)
        let rebuild = await workspace.vault.rebuild()
        XCTAssertFalse(rebuild)
        XCTAssertEqual(host.requests("/v1/vault/settings").count, 1, "One change at a time")
        XCTAssertTrue(host.requests("/v1/vault/rebuild").isEmpty)
        await gate.open()
        _ = await switching.value
        XCTAssertFalse(workspace.vault.isChanging)
        XCTAssertTrue(workspace.vault.enabled)
        XCTAssertTrue(workspace.vault.terminals)

        // A folder on its way shows too; the default shows as the default folder.
        let held = Gate()
        host.on("/v1/vault/settings") { _ in
            await held.wait()
            return (200, VaultSettingsTests.status(enabled: true))
        }
        let moving = Task { await workspace.vault.useDefaultFolder() }
        await waitUntil("the folder on its way") { workspace.vault.isChanging }
        XCTAssertEqual(workspace.vault.folder, "/Users/owner/AgentLand Vault")
        await held.open()
        _ = await moving.value
    }

    /// Nothing is asked of a host that does not list the vault (a paired device, an older host), nor while the host
    /// is not connected.
    func testNothingIsSentWithoutTheCapabilityOrWhileOffline() async throws {
        let without = vaultHost()
        let bare = try await attached(without, capabilities: #"{"interactions":true,"terminal":true}"#)
        XCTAssertFalse(bare.vault.isAvailable)
        await bare.vault.refresh()
        await bare.vault.setEnabled(true)
        await bare.vault.rebuild()
        bare.vault.pollInterval = .milliseconds(5)
        let following = Task { await bare.vault.follow() }
        try await Task.sleep(for: .milliseconds(50))
        following.cancel()
        await following.value
        XCTAssertTrue(without.requests("/v1/vault").isEmpty)
        XCTAssertTrue(without.requests("/v1/vault/settings").isEmpty)
        XCTAssertTrue(without.requests("/v1/vault/rebuild").isEmpty)
        let other = try await attached(vaultHost(), capabilities: #"{"interactions":true,"terminal":true,"vault":{"version":2}}"#)
        XCTAssertFalse(other.vault.isAvailable, "Another version offers nothing")

        let host = vaultHost()
        let workspace = try await attached(host)
        await workspace.vault.refresh()
        workspace.reachable = false
        XCTAssertFalse(workspace.vault.canChange)
        let on = await workspace.vault.setEnabled(true)
        XCTAssertFalse(on)
        XCTAssertEqual(workspace.vault.notice?.title, "Studio Mac isn’t connected")
        XCTAssertTrue(host.requests("/v1/vault/settings").isEmpty)
        await workspace.vault.refresh()
        XCTAssertEqual(gets(host), 1, "Nothing is read while offline; the status stays")
        XCTAssertEqual(workspace.vault.status?.state, .off)
    }

    func testAHostWithoutAVaultSaysSo() async throws {
        let host = vaultHost()
        host.on("/v1/vault") { _ in (503, #"{"error":{"code":"vault_unavailable","message":"This host keeps no archive, so it has no vault"}}"#) }
        let workspace = try await attached(host)
        await workspace.vault.refresh()
        XCTAssertNil(workspace.vault.status)
        XCTAssertEqual(workspace.vault.loadIssue, "The vault isn’t available on Studio Mac right now.")

        host.on("/v1/vault/settings") { _ in (503, #"{"error":{"code":"vault_unavailable","message":"The host is stopping"}}"#) }
        await workspace.vault.setEnabled(true)
        XCTAssertEqual(workspace.vault.notice?.title, "The vault isn’t available on Studio Mac right now")
        XCTAssertEqual(workspace.vault.notice?.message, "Nothing was changed.")
    }

    /// An answer that arrives after another host was attached is dropped, and the model starts over with the host.
    func testAnAnswerForAnotherHostIsDropped() async throws {
        let host = vaultHost()
        let gate = Gate()
        host.on("/v1/vault") { _ in
            await gate.wait()
            return (200, VaultSettingsTests.off)
        }
        let workspace = try await attached(host)
        let reading = Task { await workspace.vault.refresh() }
        await waitUntil("the read") { !host.requests("/v1/vault").isEmpty }
        workspace.attach(hostID: "https://other.example|device-b", identity: ConnectionIdentity(host: "https://other.example", deviceID: "device-b"),
                         client: nil)
        await gate.open()
        await reading.value
        XCTAssertNil(workspace.vault.status)
    }

    func testAChangeAnsweredAfterAnotherHostWasAttachedIsDropped() async throws {
        let host = vaultHost()
        let gate = Gate()
        let workspace = try await attached(host)
        await workspace.vault.refresh()
        host.on("/v1/vault/settings") { _ in
            await gate.wait()
            return (200, VaultSettingsTests.status(enabled: true))
        }
        let switching = Task { await workspace.vault.setEnabled(true) }
        await waitUntil("the change on its way") { workspace.vault.isChanging }
        workspace.attach(hostID: "https://other.example|device-b", identity: ConnectionIdentity(host: "https://other.example", deviceID: "device-b"),
                         client: nil)
        XCTAssertNil(workspace.vault.status)
        XCTAssertFalse(workspace.vault.isChanging, "Everything goes with the host")
        await gate.open()
        let confirmed = await switching.value
        XCTAssertFalse(confirmed)
        XCTAssertNil(workspace.vault.status)
        XCTAssertNil(workspace.vault.notice)
    }

    /// A read made before a change the host confirmed no longer counts.
    func testAReadOlderThanAConfirmedChangeIsDropped() async throws {
        let host = vaultHost()
        let gate = Gate()
        let workspace = try await attached(host)
        await workspace.vault.refresh()
        host.on("/v1/vault") { _ in
            await gate.wait()
            return (200, VaultSettingsTests.off)
        }
        let reading = Task { await workspace.vault.refresh() }
        await waitUntil("the read") { host.requests("/v1/vault").count == 2 }
        await workspace.vault.setEnabled(true)
        await gate.open()
        await reading.value
        XCTAssertTrue(workspace.vault.enabled)
        XCTAssertEqual(workspace.vault.status?.state, .writing)
    }

    // MARK: Following

    func testFollowingReadsWhileThePaneShowsAndStopsWithIt() async throws {
        let host = vaultHost()
        let workspace = try await attached(host)
        let vault = workspace.vault
        XCTAssertEqual(vault.pollInterval, .seconds(2), "Every 2 s while the pane shows")
        vault.pollInterval = .milliseconds(10)
        let following = Task { await vault.follow() }
        await waitUntil("three reads") { self.gets(host) >= 3 }
        XCTAssertEqual(vault.status?.state, .off)
        following.cancel()
        await following.value
        let reads = gets(host)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(gets(host), reads, "Nothing is read once the pane went away")
    }

    func testFollowingWaitsWhileAChangeIsOnItsWayOrTheHostIsAway() async throws {
        let host = vaultHost()
        let gate = Gate()
        let workspace = try await attached(host)
        let vault = workspace.vault
        vault.pollInterval = .milliseconds(10)
        await vault.refresh()
        host.on("/v1/vault/settings") { _ in
            await gate.wait()
            return (200, VaultSettingsTests.status(enabled: true))
        }
        let switching = Task { await vault.setEnabled(true) }
        await waitUntil("the change on its way") { vault.isChanging }
        let following = Task { await vault.follow() }
        await waitUntil("the first read") { self.gets(host) == 2 }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(gets(host), 2, "No reads while a change is on its way")
        await gate.open()
        _ = await switching.value
        await waitUntil("reads again") { self.gets(host) >= 3 }

        workspace.reachable = false
        try await Task.sleep(for: .milliseconds(30))
        let reads = gets(host)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(gets(host), reads, "No reads while the host does not answer")
        following.cancel()
        await following.value
    }

    // MARK: Words

    func testVaultTextSaysWhatTheVaultDoes() throws {
        let writing = VaultStatus(enabled: true, state: .writing, notes: 120, bytes: 1_534_000, pending: 220,
                                  backfill: VaultBackfill(done: 120, total: 340))
        XCTAssertEqual(VaultText.stateLine(writing), "Writing notes: 120 of 340")
        XCTAssertEqual(VaultText.stateLine(VaultStatus(enabled: true, state: .writing, pending: 1)), "Writing 1 note")
        XCTAssertEqual(VaultText.stateLine(VaultStatus(enabled: true, state: .writing, pending: 3)), "Writing 3 notes")
        XCTAssertEqual(VaultText.stateLine(VaultStatus(enabled: true, state: .writing)), "Writing notes")
        XCTAssertEqual(VaultText.stateLine(VaultStatus(enabled: true, state: .current)), "Up to date")
        XCTAssertEqual(VaultText.stateLine(VaultStatus(enabled: false, state: .off)), "Off")
        XCTAssertEqual(VaultText.stateLine(VaultStatus(enabled: true, state: .unknown)), "Status unknown")

        let pauses: [(VaultPauseReason?, String)] = [
            (.folderMissing, "Paused: the folder is missing"),
            (.permission, "Paused: AgentLand isn’t allowed to use the folder"),
            (.lowSpace, "Paused: less than 1 GB free"),
            (.otherArchive, "Paused: another Mac’s AgentLand writes in this folder"),
            (.error, "Paused: something went wrong"),
            (.unknown, "Paused"),
            (nil, "Paused"),
        ]
        for (reason, line) in pauses {
            XCTAssertEqual(VaultText.stateLine(VaultStatus(enabled: true, state: .paused, reason: reason)), line)
        }

        XCTAssertEqual(VaultText.detail(VaultStatus(enabled: true, state: .paused, reason: .permission, message: "open: operation not permitted")),
                       "Allow AgentLand to use the folder in System Settings → Privacy & Security, then try again.")
        XCTAssertEqual(VaultText.detail(VaultStatus(enabled: true, state: .paused, reason: .folderMissing)),
                       "Connect the disk it’s on, or choose another folder. The vault tries again every 30 seconds.")
        XCTAssertEqual(VaultText.detail(VaultStatus(enabled: true, state: .paused, reason: .lowSpace)),
                       "Free some space on the folder’s disk. The vault tries again every 30 seconds.")
        XCTAssertEqual(VaultText.detail(VaultStatus(enabled: true, state: .paused, reason: .otherArchive)),
                       "Choose another folder, or use this one anyway: this Mac’s notes then go in it.")
        XCTAssertEqual(VaultText.detail(VaultStatus(enabled: true, state: .paused, reason: .error, message: "disk I/O error")), "disk I/O error",
                       "The host's words when nothing better is known")
        XCTAssertEqual(VaultText.detail(VaultStatus(enabled: true, state: .paused, reason: .error)), "The vault tries again every 30 seconds.")
        XCTAssertNil(VaultText.detail(writing))

        XCTAssertEqual(VaultText.summary(writing), "120 notes · 1.5 MB")
        XCTAssertEqual(VaultText.summary(VaultStatus(enabled: true, notes: 1, bytes: 900)), "1 note · 900 bytes")
        XCTAssertEqual(VaultText.summary(VaultStatus(enabled: true, notes: 12_345, bytes: 0)), "12,345 notes")
        XCTAssertNil(VaultText.summary(VaultStatus(enabled: false)), "Nothing written yet says nothing")

        XCTAssertNil(VaultText.skippedLine(writing))
        XCTAssertEqual(VaultText.skippedLine(VaultStatus(enabled: true, skipped: 1)),
                       "1 note left alone: edited without its end marker, or another file is in its place.")
        XCTAssertEqual(VaultText.skippedLine(VaultStatus(enabled: true, skipped: 2)),
                       "2 notes left alone: edited without their end marker, or another file is in their place.")

        let now = try XCTUnwrap(ChatTime.date("2026-10-12T12:00:30.000Z"))
        let written = VaultStatus(enabled: true, lastWriteAt: ChatTime.date("2026-10-12T12:00:00.000Z"))
        XCTAssertEqual(VaultText.lastWriteLine(written, now: now), "Last written just now")
        XCTAssertNil(VaultText.lastWriteLine(writing, now: now))

        XCTAssertEqual(VaultText.folderLine("/Users/owner/AgentLand Vault", home: "/Users/owner"), "~/AgentLand Vault")
        XCTAssertEqual(VaultText.folderLine("/Users/owner", home: "/Users/owner"), "~")
        XCTAssertEqual(VaultText.folderLine("/Users/ownership/Vault", home: "/Users/owner"), "/Users/ownership/Vault")
        XCTAssertEqual(VaultText.folderLine("/Volumes/Notes/Vault", home: "/Users/owner"), "/Volumes/Notes/Vault")

        XCTAssertEqual(VaultText.failedTitle(.enabled(true)), "The vault wasn’t turned on")
        XCTAssertEqual(VaultText.uncertainTitle(.enabled(false)), "The vault may have been turned off")
        XCTAssertEqual(VaultText.failedTitle(.folder("/x")), "The vault’s folder wasn’t changed")
        XCTAssertEqual(VaultText.uncertainTitle(.terminals(true)), "Terminal notes may have been turned on")
        XCTAssertEqual(VaultText.failedTitle(.terminals(false)), "Terminal notes weren’t turned off")
        XCTAssertEqual(VaultText.failedTitle(.tryAgain), "The vault didn’t start again")
        XCTAssertEqual(VaultText.uncertainTitle(.adopt), "The vault may have taken over the folder")
        XCTAssertEqual(VaultText.failedTitle(.rebuild), "The vault wasn’t rebuilt")
    }
}
