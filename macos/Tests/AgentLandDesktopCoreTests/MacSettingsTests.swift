import Foundation
import SwiftUI
import XCTest
import AgentLandCore
import AgentLandWorkspace
@testable import AgentLandDesktopCore
@testable import AgentLandDesktop

/// The Settings window's panes edit `HostController`, which saves the same preferences as the old
/// inline Settings page: a value set through a pane's binding is there for the next launch.
final class MacSettingsTests: XCTestCase {
    /// The Settings window's toolbar tabs, in order, like Safari's (2026-10-16). Vault, the archive's Markdown copy,
    /// follows Agents. Memory and Chat Tools are gone: Chat is Claude Code and Codex in the workspace, with no AgentLand
    /// memory or tools (owner, 2026-10-12: memory "dont need"). The saved choice keeps its raw values.
    func testThePanesAreTheTenTheMacNeeds() {
        XCTAssertEqual(MacSettingsPane.allCases.map(\.title),
                       ["General", "Workspaces", "Agents", "Vault", "Devices", "Terminals", "Remote Access",
                        "Notifications", "API Keys (Later)", "Advanced"])
        XCTAssertEqual(MacSettingsPane.allCases.map(\.systemImage),
                       ["gearshape", "folder", "shippingbox", "books.vertical", "ipad.and.iphone", "terminal", "network",
                        "bell.badge", "key", "gearshape.2"])
        XCTAssertEqual(MacSettingsPane.allCases.map(\.rawValue),
                       ["general", "workspace", "agents", "vault", "devices", "terminals", "remoteAccess", "notifications",
                        "provider", "advanced"], "the choice saved in agentland.desktop.settingsPane")
        XCTAssertNil(MacSettingsPane(rawValue: "memory"), "A saved Memory choice opens General")
        XCTAssertNil(MacSettingsPane(rawValue: "chatTools"), "A saved Chat Tools choice opens General")
    }

    /// Agents shows Chat's sign-ins above the agents (Subscriptions only, 2026-10-12): each Claude Code and Codex sign-in
    /// the host lists in `capabilities.workspaceChats`, then one Chat cannot use with the host's words on what to do. A
    /// host that names none (not running, or older) shows nothing there.
    @MainActor
    func testTheAgentsPaneShowsTheSignInsChatRunsOn() throws {
        let capabilities = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(#"""
            {"interactions":true,"terminal":true,"workspaceChats":{"version":1,
              "providers":[{"id":"claude","name":"Claude Code","tools":[],"features":[],
                "auth":{"kind":"subscription","label":"Claude subscription"}}],
              "unavailableProviders":[{"id":"codex","name":"Codex","tools":[],"features":[],
                "auth":{"kind":"apiKey","label":"API key","reason":"subscription_required",
                        "message":"Codex is signed in with an API key. Sign in with your ChatGPT subscription (codex login)."}}]}}
            """#.utf8))
        let suite = "MacSettingsTests.signIns.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = WorkspaceModel(defaults: defaults, keys: .desktop)
        model.capabilities = capabilities

        let signIns = MacAgentsSettingsPane.signIns(model)
        XCTAssertEqual(signIns.rows.map(\.name), ["Claude Code", "Codex"])
        XCTAssertEqual(signIns.rows.map(\.value), ["Claude subscription", "API key"])
        XCTAssertEqual(signIns.rows[1].detail,
                       "Codex is signed in with an API key. Sign in with your ChatGPT subscription (codex login).")
        XCTAssertEqual(MacChatSignIns.title, "Chat")

        XCTAssertEqual(signIns.rows.map(\.status), ["Signed in with your Claude subscription", "API key"])
        XCTAssertEqual(signIns.rows.map(\.signInCommand), [nil, "codex login"], "the same rows as setup's")
        let shown = NSHostingView(rootView: MacChatSignIns(signIns: signIns, icons: model.agents.icons).frame(width: 520))
        XCTAssertGreaterThan(shown.fittingSize.height, 60, "Two sign-ins, the second with what to do, and the rule under them")
        let none = NSHostingView(rootView: MacChatSignIns(signIns: PlainChatSignIns(nil as WorkspaceChatsCapability?),
                                                          icons: model.agents.icons))
        XCTAssertEqual(none.fittingSize.height, 0, "Nothing while the host names no sign-in")

        // The pane draws them above the agents; with the host gone it shows only the agents.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: MacAgentsSettingsPane().environment(model))
        window.contentView?.layoutSubtreeIfNeeded()
        model.capabilities = nil
        XCTAssertTrue(MacAgentsSettingsPane.signIns(model).rows.isEmpty)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// A folder in an Obsidian vault (it or a folder above it holds `.obsidian`) offers `<vault>/AgentLand`; a folder
    /// already that, or inside it, and a folder in no vault are taken as they are.
    func testAFolderInAnObsidianVaultOffersAFolderOfItsOwn() {
        let folders: Set<String> = ["/Users/me/Notes/.obsidian", "/Volumes/Disk/.obsidian"]
        let resolve = { (path: String) in VaultFolderChoice.resolve(path, isFolder: folders.contains) }
        XCTAssertEqual(resolve("/Users/me/Notes"),
                       .obsidian(.init(chosen: "/Users/me/Notes", vault: "/Users/me/Notes", suggested: "/Users/me/Notes/AgentLand")))
        XCTAssertEqual(resolve("/Users/me/Notes/Projects/AI/"),
                       .obsidian(.init(chosen: "/Users/me/Notes/Projects/AI", vault: "/Users/me/Notes",
                                       suggested: "/Users/me/Notes/AgentLand")), "a folder above holds .obsidian")
        XCTAssertEqual(resolve("/Volumes/Disk"),
                       .obsidian(.init(chosen: "/Volumes/Disk", vault: "/Volumes/Disk", suggested: "/Volumes/Disk/AgentLand")))
        XCTAssertEqual(resolve("/Users/me/Notes/AgentLand"), .folder("/Users/me/Notes/AgentLand"))
        XCTAssertEqual(resolve("/Users/me/Notes/AgentLand/Old"), .folder("/Users/me/Notes/AgentLand/Old"))
        XCTAssertEqual(resolve("/Users/me/Notes AgentLand"), .folder("/Users/me/Notes AgentLand"), "a name that only begins the same")
        XCTAssertEqual(resolve("/Users/me/AgentLand Vault"), .folder("/Users/me/AgentLand Vault"))
    }

    /// On disk, `.obsidian` counts only as a folder of its own, as the host looks for it: not a file, not a link.
    func testOnlyARealObsidianFolderMakesAVault() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        let real = root.appendingPathComponent("Real"), file = root.appendingPathComponent("File"), link = root.appendingPathComponent("Link")
        for folder in [real, file, link] { try manager.createDirectory(at: folder, withIntermediateDirectories: true) }
        try manager.createDirectory(at: real.appendingPathComponent(".obsidian/plugins"), withIntermediateDirectories: true)
        try Data().write(to: file.appendingPathComponent(".obsidian"))
        try manager.createSymbolicLink(at: link.appendingPathComponent(".obsidian"), withDestinationURL: real.appendingPathComponent(".obsidian"))

        guard case let .obsidian(offer) = VaultFolderChoice.resolve(real.appendingPathComponent("Sub").path) else {
            return XCTFail("a folder inside a vault, even one not made yet, is in it")
        }
        XCTAssertEqual(offer.suggested, real.path + "/AgentLand")
        XCTAssertEqual(VaultFolderChoice.resolve(file.path), .folder(file.path))
        XCTAssertEqual(VaultFolderChoice.resolve(link.path), .folder(link.path))
    }

    /// The probe writes and removes a file where the vault goes, or in the nearest folder above it while it isn't made
    /// yet, and leaves nothing; a folder it can't write in says so, in words that say what to do.
    func testTheProbeLeavesNothingAndSaysWhyItFailed() throws {
        let root = try temporaryFolder()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("Locked").path)
            try? FileManager.default.removeItem(at: root)
        }
        let manager = FileManager.default
        XCTAssertNil(VaultFolderChoice.probe(root.path))
        XCTAssertNil(VaultFolderChoice.probe(root.appendingPathComponent("Not/Made/Yet").path))
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: root.path), [], "nothing left, nothing made")

        let locked = root.appendingPathComponent("Locked")
        try manager.createDirectory(at: locked, withIntermediateDirectories: false)
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        XCTAssertEqual(VaultFolderChoice.probe(locked.path), VaultText.probePermission)
        XCTAssertEqual(VaultFolderChoice.probe(locked.appendingPathComponent("AgentLand").path), VaultText.probePermission)
        XCTAssertEqual(VaultText.probePermission,
                       "macOS didn’t allow it. Allow AgentLand to use the folder in System Settings → Privacy & Security, or choose another folder.")

        let file = root.appendingPathComponent("file.md")
        try Data().write(to: file)
        XCTAssertEqual(VaultFolderChoice.probe(file.path), "“\(file.path)” is a file. Choose a folder for the vault.")
        XCTAssertNotNil(VaultFolderChoice.probe(file.appendingPathComponent("Inside").path), "a path under a file is no folder")
    }

    /// Open in Obsidian: `obsidian://open?path=` when Obsidian knows the folder's vault (its own list, else the host's
    /// `obsidianVault`); otherwise Obsidian is given the Obsidian vault the folder is in, or the folder itself.
    func testOpenInObsidianUsesTheLinkOnlyForAVaultObsidianKnows() throws {
        let folder = "/Users/me/My Notes/AgentLand"
        let link = try XCTUnwrap(URL(string: "obsidian://open?path=%2FUsers%2Fme%2FMy%20Notes%2FAgentLand"))
        XCTAssertEqual(ObsidianLink.opening(folder: folder, knownVaults: ["/Users/me/My Notes"], obsidianVault: nil), .url(link))
        XCTAssertEqual(ObsidianLink.opening(folder: folder + "/", knownVaults: ["/Users/me/My Notes/"], obsidianVault: nil), .url(link))
        XCTAssertEqual(ObsidianLink.opening(folder: folder, knownVaults: nil, obsidianVault: "/Users/me/My Notes"), .url(link),
                       "without Obsidian's list, the host's word")
        XCTAssertEqual(ObsidianLink.opening(folder: folder, knownVaults: ["/Users/me/My"], obsidianVault: "/Users/me/My Notes"),
                       .folder(URL(fileURLWithPath: "/Users/me/My Notes", isDirectory: true)),
                       "a vault Obsidian doesn't know opens as itself, not as its AgentLand folder")
        XCTAssertEqual(ObsidianLink.opening(folder: "/Users/me/AgentLand Vault", knownVaults: [], obsidianVault: nil),
                       .folder(URL(fileURLWithPath: "/Users/me/AgentLand Vault", isDirectory: true)))
        XCTAssertEqual(ObsidianLink.openURL(path: "/Users/me/Ré & Co?#")?.absoluteString,
                       "obsidian://open?path=%2FUsers%2Fme%2FR%C3%A9%20%26%20Co%3F%23")

        let json = Data(#"{"vaults":{"a1":{"path":"/Users/me/My Notes","ts":1,"open":true},"b2":{"path":"/Volumes/Disk"},"c3":{"ts":2}}}"#.utf8)
        XCTAssertEqual(ObsidianLink.knownVaults(from: json), ["/Users/me/My Notes", "/Volumes/Disk"])
        XCTAssertNil(ObsidianLink.knownVaults(from: Data("[]".utf8)))
        XCTAssertNil(ObsidianLink.knownVaults(at: URL(fileURLWithPath: "/nonexistent/obsidian.json")))
    }

    /// The pane's own words beside the model's `VaultText`.
    func testTheVaultPaneSaysWhatItDoes() {
        XCTAssertEqual(VaultText.switchDetail(enabled: false, terminals: true), "Off: nothing is written")
        XCTAssertEqual(VaultText.switchDetail(enabled: true, terminals: true), "Chats and terminals are written to the folder as Markdown notes")
        XCTAssertEqual(VaultText.switchDetail(enabled: true, terminals: false), "Chats are written to the folder as Markdown notes")
        XCTAssertTrue(VaultText.footer.hasSuffix("Keys and tokens are masked, but the vault isn’t a secure store."))

        let root = VaultFolderChoice.Offer(chosen: "/Users/me/Notes", vault: "/Users/me/Notes", suggested: "/Users/me/Notes/AgentLand")
        XCTAssertEqual(VaultText.offerTitle(root), "Use a folder of its own in “Notes”?")
        XCTAssertEqual(VaultText.offerMessage(root),
                       "“Notes” is an Obsidian vault. AgentLand can write its notes in “Notes/AgentLand”, apart from yours.")
        XCTAssertEqual(VaultText.useSuggested(root), "Use “Notes/AgentLand”")
        XCTAssertEqual(VaultText.useChosen(root), "Use “Notes”")
        let inside = VaultFolderChoice.Offer(chosen: "/Users/me/Notes/Projects", vault: "/Users/me/Notes", suggested: "/Users/me/Notes/AgentLand")
        XCTAssertEqual(VaultText.offerMessage(inside),
                       "“Projects” is in the Obsidian vault “Notes”. AgentLand can write its notes in “Notes/AgentLand” instead.")
        XCTAssertEqual(VaultText.useChosen(inside), "Use “Projects”")

        XCTAssertEqual(VaultText.folderMissingMessage(enabled: false), "AgentLand makes it when you turn the vault on.")
        XCTAssertEqual(VaultText.folderMissingMessage(enabled: true), "Connect the disk it’s on, or choose another folder.")
        XCTAssertEqual(VaultText.rebuildMessage,
                       "Notes and images deleted from the folder come back. Nothing is deleted, and text below a note’s end marker stays.")
        XCTAssertEqual(VaultText.folderLine("/Users/me/AgentLand Vault", home: "/Users/me"), "~/AgentLand Vault")
    }

    /// AI Providers says which OpenCode runs, why the host's previous version runs when it does, what waits
    /// for a restart and when that comes. Nothing says OpenCode comes with AgentLand: the app bundles none.
    func testTheAIProvidersPaneSaysWhatRunsWhatWaitsAndWhy() {
        let record = ManagedAgentRecord(version: "1.19.0", command: "opencode")
        XCTAssertEqual(AIProvidersText.running(nil), "OpenCode isn’t running.")
        XCTAssertEqual(AIProvidersText.running(OpenCodeRuntimeReport(source: .managed(record), version: "1.19.0")),
                       "OpenCode 1.19.0, installed and updated by the host")
        let previous = ManagedAgentRecord(version: "1.18.32", command: "opencode")
        XCTAssertEqual(AIProvidersText.running(OpenCodeRuntimeReport(source: .previous(previous), version: "1.18.32")),
                       "OpenCode 1.18.32, the host’s previous version")
        XCTAssertEqual(AIProvidersText.unavailable, "OpenCode isn’t available.")
        XCTAssertEqual(AIProvidersText.chatUsesSubscriptions,
                       "Chat runs Claude Code and Codex with your Claude and ChatGPT subscriptions, not these keys. API keys are for later.")

        let fellBack = OpenCodeRuntimeReport(source: .previous(previous), version: "1.18.32",
                                             fallbackReason: "OpenCode 1.19.0 didn’t start. AgentLand runs the previous version, 1.18.32.")
        XCTAssertEqual(AIProvidersText.notes(report: fellBack, pending: false, hostReportsIdle: nil, activity: nil),
                       ["OpenCode 1.19.0 didn’t start. AgentLand runs the previous version, 1.18.32."])
        XCTAssertEqual(ProviderKeyError.externalOpenCode.errorDescription,
                       "Keys here are for the OpenCode that AgentLand runs. Turn on “Manage OpenCode automatically” in Advanced to use them.")
        XCTAssertEqual(AdvancedText.openCode,
                       "AgentLand gets OpenCode through its host and keeps it up to date. Turn off “Manage OpenCode automatically” only to use an OpenCode service you run yourself.")
        for text in [AIProvidersText.running(fellBack), AIProvidersText.externalOpenCode, AIProvidersText.notListed,
                     ProviderKeyError.externalOpenCode.errorDescription ?? "", AdvancedText.openCode] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains("bundled") || text.contains("included with AgentLand")
                           || text.contains("AgentLand's own") || text.contains("AgentLand’s own"), text)
        }
        XCTAssertEqual(AIProvidersText.notes(report: nil, pending: true, hostReportsIdle: true, activity: "Restarted OpenCode at 3:05 PM."),
                       ["Your changes wait for OpenCode to restart, which AgentLand does as soon as no chat, terminal or device is active.",
                        "Restarted OpenCode at 3:05 PM."])
        // A host without the catalog, or one AgentLand does not read it from (development HTTP): nothing
        // restarts on its own, and neither the note nor the footer says it will.
        XCTAssertEqual(AIProvidersText.notes(report: nil, pending: true, hostReportsIdle: false, activity: nil),
                       ["Your changes apply when AgentLand next starts the host. AgentLand can’t tell when this host is idle, so it doesn’t restart the host on its own. Disconnect and Connect to apply them now."])
        XCTAssertEqual(AIProvidersText.restartRule(hostReportsIdle: false),
                       "Keys stay in your Keychain; saving one doesn’t check it. OpenCode picks up key and model changes when AgentLand next starts the host.")
        for reports in [true, nil] as [Bool?] {
            let rule = AIProvidersText.restartRule(hostReportsIdle: reports)
            XCTAssertTrue(rule.hasSuffix("which AgentLand does as soon as no chat, terminal or device is active on this Mac’s host."), rule)
            XCTAssertFalse(rule.contains("10 minutes"), "changed settings wait for nothing but what runs")
        }

        let azure = OpenCodeProviderRow(id: "azure", name: "Azure", connected: false, models: [OpenCodeModelOption(id: "a", name: "A")],
                                        keyVariable: "AZURE_API_KEY", savedKeyVariable: "AZURE_API_KEY",
                                        variables: ["AZURE_RESOURCE_NAME", "AZURE_API_KEY"])
        XCTAssertEqual(AIProvidersText.detail(azure), "Not connected · 1 model · Key saved as AZURE_API_KEY")
        XCTAssertEqual(AIProvidersText.keyNotes(azure, replacing: []), [
            "AgentLand keeps the key in your Keychain and gives it to OpenCode as AZURE_API_KEY. Saving it doesn’t check it; Azure does when a chat uses it.",
            "Azure also reads AZURE_RESOURCE_NAME, which AgentLand doesn’t set."])
        let copilot = OpenCodeProviderRow(id: "github-copilot", name: "GitHub Copilot", connected: true, models: [], keyVariable: "GITHUB_TOKEN",
                                          savedKeyVariable: nil, variables: ["GITHUB_TOKEN"])
        XCTAssertEqual(AIProvidersText.detail(copilot), "Connected · 0 models")
        // Every provider whose saved key goes is named in the sheet and in Save's confirmation.
        XCTAssertEqual(AIProvidersText.keyNotes(copilot, replacing: ["GitHub Models"]).last,
                       "GitHub Models uses GITHUB_TOKEN too. OpenCode reads one GITHUB_TOKEN, so saving this key deletes the key saved for GitHub Models.")
        XCTAssertEqual(AIProvidersText.replaceTitle(["GitHub Models"]), "Replace the key saved for GitHub Models?")
        XCTAssertEqual(AIProvidersText.replaceMessage(copilot, replacing: ["GitHub Models"]),
                       "OpenCode reads one GITHUB_TOKEN. AgentLand deletes the key saved for GitHub Models from your Keychain and saves this one for GitHub Copilot.")
        XCTAssertEqual(AIProvidersText.replaceButton(["GitHub Models"]), "Replace Key")
        let two = ["GitHub Models", "retired"]
        XCTAssertEqual(AIProvidersText.keyNotes(copilot, replacing: two).last,
                       "GitHub Models and retired use GITHUB_TOKEN too. OpenCode reads one GITHUB_TOKEN, so saving this key deletes the keys saved for GitHub Models and retired.")
        XCTAssertEqual(AIProvidersText.replaceTitle(two), "Replace the keys saved for GitHub Models and retired?")
        XCTAssertEqual(AIProvidersText.replaceButton(two), "Replace Keys")
        XCTAssertEqual(AIProvidersText.list(["A", "B", "C"]), "A, B and C")
        XCTAssertNil(AIProvidersText.replacesNote(variable: "GITHUB_TOKEN", replacing: []))
        XCTAssertEqual(AIProvidersText.keyNotes(copilot, replacing: []).count, 1, "nothing to replace, nothing said")
        let unlisted = OpenCodeProviderRow(id: "retired", name: "retired", connected: nil, models: nil, keyVariable: "RETIRED_API_KEY",
                                           savedKeyVariable: "RETIRED_API_KEY", variables: ["RETIRED_API_KEY"])
        XCTAssertEqual(AIProvidersText.detail(unlisted), "Not listed by OpenCode now · Key saved as RETIRED_API_KEY")
    }

    @MainActor
    func testTerminalRoutingTexts() {
        XCTAssertEqual(MacSettings.terminalRouting.title, "Open coding agents from Terminal in AgentLand")
        XCTAssertEqual(MacSettings.advancedToggles.map(\.title), ["Manage OpenCode automatically"])
        XCTAssertEqual(MacSettings.terminalToggles.map(\.title),
                       ["Allow paired devices to open terminal sessions", "Open coding agents from Terminal in AgentLand"],
                       "in Terminals, right under terminal access")
        XCTAssertEqual(AdvancedText.routingFootnote, "Typing claude, codex, opencode or another coding agent in Terminal starts it inside AgentLand, so you can keep going from your other devices. Takes effect in new Terminal windows.")
        XCTAssertEqual(AdvancedText.routingNeedsTerminals, "Turn on terminal access first.")
        // The note follows the state: off and unable to turn on, on and paused, on behind an older keeper's terminals.
        let older = KeeperState(state: "running", adopts: false)
        func note(access: Bool, routing: Bool, keeper: KeeperState?) -> String? {
            AdvancedText.routingNote(terminalAccess: access, routing: routing, keeper: keeper)
        }
        XCTAssertEqual(note(access: false, routing: false, keeper: nil), "Turn on terminal access first.")
        XCTAssertEqual(note(access: false, routing: true, keeper: nil), "Paused while terminal access is off.")
        XCTAssertEqual(note(access: true, routing: true, keeper: older),
                       "Starts once the terminals open now have ended (an older AgentLand runs them).")
        XCTAssertNil(note(access: true, routing: false, keeper: older), "Off: nothing waits")
        XCTAssertNil(note(access: true, routing: true, keeper: KeeperState(state: "running", adopts: true)))
        XCTAssertNil(note(access: true, routing: true, keeper: KeeperState(state: "running")), "Unknown shows nothing")
        XCTAssertNil(note(access: true, routing: true, keeper: nil))
        XCTAssertEqual(AdvancedText.routingZshOnly("bash"), "Your shell is bash; this works only in zsh.")
    }

    /// The zsh note shows only for a login shell that isn't zsh; the user database's shell wins over $SHELL.
    func testTheZshNoteShowsOnlyForAnotherShell() {
        XCTAssertNil(AdvancedText.routingShellNote(loginShell: "/bin/zsh"))
        XCTAssertNil(AdvancedText.routingShellNote(loginShell: "/opt/homebrew/bin/zsh"))
        XCTAssertEqual(AdvancedText.routingShellNote(loginShell: "/opt/homebrew/bin/fish"), "Your shell is fish; this works only in zsh.")
        XCTAssertEqual(AdvancedText.routingShellNote(loginShell: "/bin/bash"), "Your shell is bash; this works only in zsh.")
        XCTAssertNil(AdvancedText.routingShellNote(loginShell: nil), "unknown: no note")
        XCTAssertNil(AdvancedText.routingShellNote(loginShell: ""))

        XCTAssertEqual(AdvancedText.loginShell(userDatabase: { "/bin/bash" }, environment: ["SHELL": "/bin/zsh"]), "/bin/bash")
        XCTAssertEqual(AdvancedText.loginShell(userDatabase: { nil }, environment: ["SHELL": "/bin/zsh"]), "/bin/zsh")
        XCTAssertEqual(AdvancedText.loginShell(userDatabase: { "" }, environment: ["SHELL": "/usr/local/bin/fish"]), "/usr/local/bin/fish")
        XCTAssertNil(AdvancedText.loginShell(userDatabase: { nil }, environment: [:]))
        XCTAssertNotNil(AdvancedText.loginShell(), "this Mac's user has one")
    }

    @MainActor
    func testEveryTextAndSwitchSettingIsSavedForTheNextLaunch() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let host = fixture.controller()
        let bindings = ObservedObject(wrappedValue: host).projectedValue

        var expectedText: [String: String] = [:]
        for setting in MacSettings.workspace + MacSettings.advancedText {
            let value = "/value/\(setting.title.replacingOccurrences(of: " ", with: "-"))"
            bindings[dynamicMember: setting.keyPath].wrappedValue = value
            expectedText[setting.title] = value
        }
        var expectedSwitches: [String: Bool] = [:]
        for setting in MacSettings.advancedToggles + MacSettings.terminalToggles {
            let value = !host[keyPath: setting.keyPath]
            bindings[dynamicMember: setting.keyPath].wrappedValue = value
            expectedSwitches[setting.title] = value
        }
        bindings.connectionMode.wrappedValue = .developmentHTTP

        let saved = try XCTUnwrap(fixture.defaults.data(forKey: "dev.agentland.desktop.preferences.v1"),
                                  "the preferences the Mac has always saved")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertEqual(json["projectDirectory"] as? String, expectedText["Folder"])
        XCTAssertEqual(json["listenAddress"] as? String, expectedText["Listen address"])

        let relaunched = fixture.controller()
        for setting in MacSettings.workspace + MacSettings.advancedText {
            XCTAssertEqual(relaunched[keyPath: setting.keyPath], expectedText[setting.title], setting.title)
        }
        for setting in MacSettings.advancedToggles + MacSettings.terminalToggles {
            XCTAssertEqual(relaunched[keyPath: setting.keyPath], expectedSwitches[setting.title], setting.title)
        }
        XCTAssertEqual(relaunched.connectionMode, .developmentHTTP)
        // Editing settings never changes the desired connection; only Connect and Disconnect do.
        XCTAssertFalse(relaunched.connectionDesired)
    }

    /// Devices rename and remove workspaces while the host runs; each start merges the saved default
    /// back into the host's state, so the default follows the host's list instead of undoing them.
    @MainActor
    func testTheSavedDefaultWorkspaceFollowsRenamesAndRemovalsOnTheHost() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let host = fixture.controller()
        host.projectID = "fixture"
        host.projectName = "Fixture"
        host.projectDirectory = "/Users/me/Fixture"

        host.followWorkspaces([Project(id: "other", name: "Other")])
        XCTAssertEqual(host.projectID, "fixture", "A list without folders (an older host) changes nothing")

        host.followWorkspaces([Project(id: "fixture", name: "Renamed", directory: "/Users/me/Fixture"),
                               Project(id: "b", name: "B", directory: "/Users/me/B")])
        XCTAssertEqual(host.projectID, "fixture")
        XCTAssertEqual(host.projectName, "Renamed", "The next start keeps the new name")

        host.followWorkspaces([Project(id: "b", name: "B", directory: "/Users/me/B"),
                               Project(id: "c", name: "C", directory: "/Users/me/C")], preferred: "c")
        XCTAssertEqual([host.projectID, host.projectName, host.projectDirectory], ["c", "C", "/Users/me/C"],
                       "A removed default is replaced by the workspace open in the window, never added back")
        host.followWorkspaces([Project(id: "b", name: "B", directory: "/Users/me/B")], preferred: "gone")
        XCTAssertEqual(host.projectID, "b", "Without that, the first workspace listed")

        let relaunched = fixture.controller()
        XCTAssertEqual([relaunched.projectID, relaunched.projectName, relaunched.projectDirectory], ["b", "B", "/Users/me/B"])
    }

    @MainActor
    func testTheExternalServicePasswordIsNeverSavedInPreferences() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let host = fixture.controller()
        ObservedObject(wrappedValue: host).projectedValue.openCodePassword.wrappedValue = "external-secret"
        host.projectName = "Touch preferences"
        let saved = try XCTUnwrap(fixture.defaults.data(forKey: "dev.agentland.desktop.preferences.v1"))
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("external-secret"))
    }
}

private func temporaryFolder() throws -> URL {
    // Resolved, so paths compare with what the probe and the folder checks see (/var is a link to /private/var).
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentland-vault-pane-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.resolvingSymlinksInPath()
}

private struct SettingsFixture {
    let root: URL
    let suite: String
    let defaults: UserDefaults

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentland-settings-unit-\(UUID().uuidString)")
        suite = "dev.agentland.settings-test.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @MainActor func controller() -> HostController {
        HostController(statePath: root.appendingPathComponent("host.json").path, runner: RefusingRunner(), secrets: MemorySecrets(),
                       preferences: defaults, runtime: IdleRuntime())
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class MemorySecrets: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func save(_ secret: String, account: String) throws { lock.withLock { values[account] = secret } }
    func load(account: String) throws -> String? { lock.withLock { values[account] } }
    func delete(account: String) throws { lock.withLock { values[account] = nil } }
}

private struct RefusingRunner: HostCommandRunning {
    func run(_ command: HostCommand) throws -> CommandOutput {
        throw DesktopError.commandFailed("Settings tests run no commands.")
    }
}

private actor IdleRuntime: OpenCodeRuntimeRunning {
    func start(directory: String, password: String, providerEnvironment: [String: String], model: String?) async throws -> URL {
        throw DesktopError.commandFailed("Settings tests start nothing.")
    }
    func stop() async throws {}
    func isRunning() -> Bool { false }
    func endpoint() -> URL? { nil }
}
