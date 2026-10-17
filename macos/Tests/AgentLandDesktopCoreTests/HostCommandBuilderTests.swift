import XCTest
@testable import AgentLandDesktopCore
@testable import AgentLandDesktop

final class HostCommandBuilderTests: XCTestCase {
    func testDeviceOutputSeparatesAuthorizationFromRecentPresence() {
        let output = "one\tactive\t2026-01-01T00:00:00Z\tiPhone\tonline\n" +
            "two\tactive\t2026-01-01T00:00:00Z\tiPad\toffline\n" +
            "three\trevoked\t2026-01-01T00:00:00Z\tOld phone\toffline\n"
        let devices = HostOutputParser.devices(output)
        XCTAssertEqual(devices.map(\.name), ["iPhone", "iPad", "Old phone"])
        XCTAssertEqual(devices.filter(\.isPresent).map(\.name), ["iPhone"])
        XCTAssertEqual(HostOutputParser.devices("legacy\tactive\t2026-01-01T00:00:00Z\tPaired\n").filter(\.isPresent).count, 0)
    }
    /// The Pair a Device window sees a device that pairs: a new ID, or one that paired again over its own record
    /// (docs/HOST-API.md, "Pairing again"), whose paired time the devices command reports changed.
    @MainActor func testThePairingPanelSeesADeviceThatPairsAgain() {
        let phone = ManagedDevice(id: "one", status: "active", createdAt: "2026-10-01T00:00:00Z", name: "iPhone", isPresent: false)
        let known = ["one": "2026-10-01T00:00:00Z"]
        XCTAssertNil(PairingPanel.paired([phone], known: known), "nothing paired")
        let again = ManagedDevice(id: "one", status: "active", createdAt: "2026-10-17T09:00:00Z", name: "iPhone", isPresent: false)
        XCTAssertEqual(PairingPanel.paired([again], known: known)?.device.id, "one")
        XCTAssertEqual(PairingPanel.paired([again], known: known)?.again, true)
        let new = ManagedDevice(id: "two", status: "active", createdAt: "2026-10-17T09:00:00Z", name: "iPad", isPresent: false)
        XCTAssertEqual(PairingPanel.paired([again, new], known: known)?.device.id, "two", "a new device first")
        XCTAssertEqual(PairingPanel.paired([again, new], known: known)?.again, false)
    }
    func testInitBuildsSeparateArgumentsForProjectWithSpaces() throws {
        let command = try HostCommandBuilder.initCommand(
            statePath: "/Users/me/Library/Application Support/AgentLand/host.json",
            project: ProjectConfiguration(id: "workspace", name: "Client work", directory: "/Users/me/Projects/Client work"),
            openCodeURL: "http://127.0.0.1:4197",
            passwordEnvironment: "AGENTLAND_OPENCODE_PASSWORD"
        )

        XCTAssertEqual(command.arguments, [
            "init", "--state", "/Users/me/Library/Application Support/AgentLand/host.json",
            "--opencode-url", "http://127.0.0.1:4197",
            "--password-env", "AGENTLAND_OPENCODE_PASSWORD",
            "--project", "workspace=Client work=/Users/me/Projects/Client work"
        ])
    }

    func testServeRejectsNonLoopbackDevelopmentHTTP() throws {
        XCTAssertThrowsError(try HostCommandBuilder.serveCommand(
            statePath: "/tmp/host.json",
            listenAddress: "0.0.0.0:9841",
            tls: .developmentHTTP,
            terminalEnabled: false
        )) { error in
            XCTAssertEqual(error as? HostCommandError, .developmentHTTPRequiresLoopback)
        }
    }

    func testServeAddsTLSFilesWithoutShellInterpolation() throws {
        let command = try HostCommandBuilder.serveCommand(
            statePath: "/tmp/host state.json",
            listenAddress: "192.168.1.8:9841",
            tls: .certificate(certificatePath: "/tmp/cert file.pem", keyPath: "/tmp/key file.pem"),
            terminalEnabled: true
        )

        XCTAssertEqual(command.arguments, [
            "serve", "--state", "/tmp/host state.json", "--listen", "192.168.1.8:9841",
            "--cert", "/tmp/cert file.pem", "--key", "/tmp/key file.pem", "--enable-terminal"
        ])
    }

    func testServeAddsPreviewListenerOnTheListenerHost() throws {
        let tls = TLSConfiguration.certificate(certificatePath: "/tmp/cert.pem", keyPath: "/tmp/key.pem")
        let command = try HostCommandBuilder.serveCommand(
            statePath: "/tmp/host.json", listenAddress: "0.0.0.0:9841", tls: tls, terminalEnabled: false, previewPort: 9842
        )
        XCTAssertEqual(command.arguments, [
            "serve", "--state", "/tmp/host.json", "--listen", "0.0.0.0:9841",
            "--cert", "/tmp/cert.pem", "--key", "/tmp/key.pem", "--enable-preview", "--preview-listen", "0.0.0.0:9842"
        ])
        let loopback = try HostCommandBuilder.serveCommand(
            statePath: "/tmp/host.json", listenAddress: "[::1]:9841", tls: tls, terminalEnabled: true, previewPort: 9900
        )
        XCTAssertEqual(loopback.arguments.suffix(4), ["--enable-terminal", "--enable-preview", "--preview-listen", "[::1]:9900"])
        let off = try HostCommandBuilder.serveCommand(
            statePath: "/tmp/host.json", listenAddress: "0.0.0.0:9841", tls: tls, terminalEnabled: false
        )
        XCTAssertFalse(off.arguments.contains("--enable-preview"))
        XCTAssertFalse(off.arguments.contains("--preview-listen"))
        XCTAssertFalse(off.arguments.contains("--advertised-host"))
    }

    func testTheAdvertisedNameTurnsOnTheHostsRoutesOverHTTPSOnly() throws {
        let tls = TLSConfiguration.certificate(certificatePath: "/tmp/cert.pem", keyPath: "/tmp/key.pem")
        let command = try HostCommandBuilder.serveCommand(
            statePath: "/tmp/host.json", listenAddress: "0.0.0.0:9841", tls: tls, terminalEnabled: false,
            advertisedHost: "Robins-Mac-mini.local"
        )
        XCTAssertEqual(command.arguments.suffix(2), ["--advertised-host", "Robins-Mac-mini.local"])
        let development = try HostCommandBuilder.serveCommand(
            statePath: "/tmp/host.json", listenAddress: "127.0.0.1:9841", tls: .developmentHTTP, terminalEnabled: false,
            advertisedHost: "Robins-Mac-mini.local"
        )
        XCTAssertFalse(development.arguments.contains("--advertised-host"), "Development HTTP lists no routes")
        XCTAssertThrowsError(try HostCommandBuilder.serveCommand(
            statePath: "/tmp/host.json", listenAddress: "0.0.0.0:9841", tls: tls, terminalEnabled: false,
            advertisedHost: "https://mac.local"
        ))
    }

    /// The tunnel socket is `tunnel.sock` beside the state file, passed at every HTTPS start whether or
    /// not remote access is on, and left out when its path would not fit a Unix socket's.
    func testTheTunnelSocketLiesBesideTheStateFileOverHTTPSOnly() throws {
        let statePath = "/Users/someone/Library/Application Support/agentland/host.json"
        let socket = try XCTUnwrap(HostCommandBuilder.tunnelSocketPath(statePath: statePath))
        XCTAssertEqual(socket, "/Users/someone/Library/Application Support/agentland/tunnel.sock")
        let tls = TLSConfiguration.certificate(certificatePath: "/tmp/cert.pem", keyPath: "/tmp/key.pem")
        let command = try HostCommandBuilder.serveCommand(statePath: statePath, listenAddress: "0.0.0.0:9841", tls: tls,
                                                          terminalEnabled: false, tunnelSocket: socket)
        XCTAssertEqual(command.arguments.suffix(2), ["--tunnel-socket", socket])
        let development = try HostCommandBuilder.serveCommand(statePath: statePath, listenAddress: "127.0.0.1:9841",
                                                              tls: .developmentHTTP, terminalEnabled: false, tunnelSocket: socket)
        XCTAssertFalse(development.arguments.contains("--tunnel-socket"), "the tunnel carries the HTTPS listener's TLS")

        let longFolder = "/" + String(repeating: "f", count: 92)
        XCTAssertNil(HostCommandBuilder.tunnelSocketPath(statePath: longFolder + "/host.json"))
        let fits = "/" + String(repeating: "f", count: 90)
        XCTAssertEqual(HostCommandBuilder.tunnelSocketPath(statePath: fits + "/host.json")?.utf8.count, 103)
        XCTAssertNil(HostCommandBuilder.tunnelSocketPath(statePath: "relative/host.json"))
    }

    /// The host's OpenCode terminals share the managed OpenCode's config and storage, so the app passes its root
    /// only when it runs that OpenCode.
    func testServeCommandPassesTheManagedOpenCodeHome() throws {
        let root = URL(fileURLWithPath: "/tmp/AgentLand/OpenCode", isDirectory: true)
        let managed = try HostCommandBuilder.serveCommand(statePath: "/tmp/host.json", listenAddress: "127.0.0.1:9841",
                                                          tls: .developmentHTTP, terminalEnabled: true, openCodeHome: root)
        let index = try XCTUnwrap(managed.arguments.firstIndex(of: "--opencode-home"))
        XCTAssertEqual(managed.arguments[index + 1], "/tmp/AgentLand/OpenCode")
        let other = try HostCommandBuilder.serveCommand(statePath: "/tmp/host.json", listenAddress: "127.0.0.1:9841",
                                                        tls: .developmentHTTP, terminalEnabled: true)
        XCTAssertFalse(other.arguments.contains("--opencode-home"))
    }

    /// Plain chats' web search: the host names the search service to devices only when the app runs the
    /// host's OpenCode with it and says so, over either listener.
    func testTheSearchServiceIsNamedOnlyWhenTheAppSetsIt() throws {
        let https = TLSConfiguration.certificate(certificatePath: "/tmp/cert.pem", keyPath: "/tmp/key.pem")
        for listener in [https, TLSConfiguration.developmentHTTP] {
            let named = try HostCommandBuilder.serveCommand(statePath: "/tmp/host.json", listenAddress: "127.0.0.1:9841",
                                                            tls: listener, terminalEnabled: false,
                                                            webSearchProvider: ManagedOpenCodeRuntime.webSearchProvider)
            XCTAssertEqual(named.arguments.suffix(2), ["--websearch-provider", "exa"])
            for unknown in [nil, ""] {
                let command = try HostCommandBuilder.serveCommand(statePath: "/tmp/host.json", listenAddress: "127.0.0.1:9841",
                                                                  tls: listener, terminalEnabled: false, webSearchProvider: unknown)
                XCTAssertFalse(command.arguments.contains("--websearch-provider"))
            }
        }
    }

    func testServeRefusesPreviewsWithoutHTTPSOrOnTheListenerPort() {
        let tls = TLSConfiguration.certificate(certificatePath: "/tmp/cert.pem", keyPath: "/tmp/key.pem")
        XCTAssertThrowsError(try HostCommandBuilder.serveCommand(
            statePath: "/tmp/host.json", listenAddress: "127.0.0.1:9841", tls: .developmentHTTP, terminalEnabled: false, previewPort: 9842
        )) { error in
            XCTAssertEqual(error as? HostCommandError, .previewRequiresHTTPS)
        }
        for port: UInt16 in [9841, 0] {
            XCTAssertThrowsError(try HostCommandBuilder.serveCommand(
                statePath: "/tmp/host.json", listenAddress: "0.0.0.0:9841", tls: tls, terminalEnabled: false, previewPort: port
            )) { error in
                XCTAssertEqual(error as? HostCommandError, .invalidPreviewPort)
            }
        }
    }

    func testTLSInitializationKeepsAdvertisedHostAsOneArgument() throws {
        let command = try HostCommandBuilder.tlsInitializeCommand(
            directory: "/Users/me/Library/Application Support/AgentLand/certificates",
            hosts: ["agentland.local", "192.168.1.25"]
        )

        XCTAssertEqual(command.arguments, [
            "tls", "init", "--directory", "/Users/me/Library/Application Support/AgentLand/certificates",
            "--hosts", "agentland.local,192.168.1.25"
        ])
    }

    func testDesktopPairingRequestsNumericPINWithoutChangingCLICompatibility() {
        let desktop = HostCommandBuilder.pairingCommand(statePath: "/tmp/host.json", securePIN: true)
        let existingCLI = HostCommandBuilder.pairingCommand(statePath: "/tmp/host.json")

        XCTAssertEqual(desktop.arguments, ["pair", "--state", "/tmp/host.json", "--expires", "600s", "--pin"])
        XCTAssertEqual(existingCLI.arguments, ["pair", "--state", "/tmp/host.json", "--expires", "600s"])
    }

    func testConfigurationUpdateKeepsEveryConfiguredProject() throws {
        let projects = [
            ProjectConfiguration(id: "workspace", name: "Current", directory: "/tmp/current"),
            ProjectConfiguration(id: "archive", name: "Archive", directory: "/tmp/archive")
        ]

        let command = try HostCommandBuilder.configureCommand(
            statePath: "/tmp/host.json",
            projects: projects,
            openCodeURL: "http://127.0.0.1:4197",
            passwordEnvironment: "AGENTLAND_OPENCODE_PASSWORD"
        )

        XCTAssertEqual(command.arguments.suffix(4), ["--project", "workspace=Current=/tmp/current", "--project", "archive=Archive=/tmp/archive"])
    }

    /// The Advanced switch for coding agents typed in Terminal: the same state file `serve` gets, since the host reads the
    /// switch beside it.
    func testHookCommandArguments() {
        let state = "/Users/me/Library/Application Support/agentland/host.json"
        XCTAssertEqual(HostCommandBuilder.terminalHookCommand(statePath: state, action: .on).arguments,
                       ["terminals", "hook", "on", "--state", state])
        XCTAssertEqual(HostCommandBuilder.terminalHookCommand(statePath: state, action: .off).arguments,
                       ["terminals", "hook", "off", "--state", state])
        XCTAssertEqual(HostCommandBuilder.terminalHookCommand(statePath: state, action: .pause).arguments,
                       ["terminals", "hook", "pause", "--state", state])
        XCTAssertEqual(HostCommandBuilder.terminalHookCommand(statePath: state, action: .on).environment, [:])
    }

    /// Open in Terminal's script: every path and the ID one word each, whatever spaces and quotes they hold.
    func testAttachScriptQuotesPaths() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentland attach 'quoted' \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let binary = folder.appendingPathComponent("Agent Land's host").path
        let state = "/Users/o'neil/Application Support/host.json"
        let script = TerminalAttachScript.contents(binary: binary, statePath: state, terminalID: "term_0123456789abcdef")
        let quotedBinary = binary.replacingOccurrences(of: "'", with: #"'\''"#)
        XCTAssertEqual(script, "#!/bin/zsh\nexec '\(quotedBinary)' terminals attach --state '/Users/o'\\''neil/Application Support/host.json' 'term_0123456789abcdef'\n")

        // Run as Terminal runs it, with a stand-in host that prints the words it was given, one a line.
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\"\n".utf8).write(to: URL(fileURLWithPath: binary))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary)
        let command = folder.appendingPathComponent("attach.command")
        try Data(script.utf8).write(to: command)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        let process = Process()
        let output = Pipe()
        process.executableURL = command
        process.standardOutput = output
        // Not the developer's ~/.zshenv, which may print.
        process.environment = ["HOME": folder.path, "ZDOTDIR": folder.path, "PATH": "/usr/bin:/bin"]
        try process.run()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: printed, as: UTF8.self),
                       ["terminals", "attach", "--state", state, "term_0123456789abcdef"].map { $0 + "\n" }.joined())
    }

    func testReplacingAProjectPreservesUneditedProjects() {
        let existing = [
            ProjectConfiguration(id: "workspace", name: "Old", directory: "/tmp/old"),
            ProjectConfiguration(id: "archive", name: "Archive", directory: "/tmp/archive")
        ]
        let updated = ProjectConfiguration(id: "workspace", name: "New", directory: "/tmp/new")

        XCTAssertEqual(ProjectConfiguration.replacing(existing, with: updated), [
            updated,
            ProjectConfiguration(id: "archive", name: "Archive", directory: "/tmp/archive")
        ])
    }
}
