import AppKit
import ApplicationServices
import CryptoKit
import Darwin

// Disposable connected UI check. Pass an isolated .uitest bundle and an output folder.
// The app owns a temporary Go host/OpenCode pair; no model request is sent. The app bundles no
// OpenCode: with AGENTLAND_OPENCODE_TEST_BINARY (for example the pinned one that
// scripts/prepare-opencode-runtime.py prints) it is put where the host installs it, so nothing
// downloads; without it the app gets OpenCode through the temporary host, which needs a network
// connection.
struct Failure: Error, CustomStringConvertible { let description: String }
func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(description: message) }
}
func wait(_ seconds: Double, until condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return condition()
}
func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
}
func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}
func button(_ root: AXUIElement, _ title: String) -> AXUIElement? {
    var queue = [(root, 0)]
    var count = 0
    while !queue.isEmpty && count < 1000 {
        let (item, depth) = queue.removeFirst(); count += 1
        let role = attribute(item, kAXRoleAttribute) as? String
        let label = attribute(item, kAXTitleAttribute) as? String
        let description = attribute(item, kAXDescriptionAttribute) as? String
        if (role == kAXButtonRole || role == kAXPopUpButtonRole || role == "AXMenuButton")
            && (label == title || description == title) { return item }
        if depth < 14 { queue += children(item).map { ($0, depth + 1) } }
    }
    return nil
}
func identified(_ root: AXUIElement, _ identifier: String) -> AXUIElement? {
    var queue = [(root, 0)]
    var count = 0
    while !queue.isEmpty && count < 4000 {
        let (item, depth) = queue.removeFirst(); count += 1
        if attribute(item, "AXIdentifier") as? String == identifier { return item }
        if depth < 22 { queue += children(item).map { ($0, depth + 1) } }
    }
    return nil
}
func identified(_ root: AXUIElement, withPrefix prefix: String) -> [AXUIElement] {
    var queue = [(root, 0)]
    var matches: [AXUIElement] = []
    var count = 0
    while !queue.isEmpty && count < 4000 {
        let (item, depth) = queue.removeFirst(); count += 1
        if (attribute(item, "AXIdentifier") as? String)?.hasPrefix(prefix) == true { matches.append(item) }
        if depth < 22 { queue += children(item).map { ($0, depth + 1) } }
    }
    return matches
}
func switcherShows(_ application: AXUIElement, _ title: String) -> Bool {
    guard let switcher = identified(application, "workspaceSwitcher") else { return false }
    let value = attribute(switcher, kAXValueAttribute) as? String ?? ""
    return value.contains(title)
}
/// The main window's title: the surface in front ("Home", "Home 2", "Files" …).
func mainWindowTitle(_ application: AXUIElement) -> String? {
    (attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []).compactMap { window -> String? in
        guard let raw = attribute(window, kAXSizeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgSize, &size)
        return size.width >= 760 ? attribute(window, kAXTitleAttribute) as? String : nil
    }.first
}
/// Chooses a command of the app's menu bar (File ▸ New Chat …) without opening its menu.
func chooseMenuCommand(_ application: AXUIElement, _ title: String) throws {
    var pid: pid_t = 0
    AXUIElementGetPid(application, &pid)
    guard let running = NSRunningApplication(processIdentifier: pid) else {
        throw Failure(description: "The session app is no longer running")
    }
    running.activate(options: [.activateAllWindows])
    try require(wait(5, until: { running.isActive }), "The session app did not activate for \(title)")
    guard let value = attribute(application, kAXMenuBarAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
        throw Failure(description: "The app has no menu bar")
    }
    let menuBar = unsafeBitCast(value, to: AXUIElement.self)
    var item: AXUIElement?
    try require(wait(5, until: { item = menuItem(menuBar, title); return item != nil }), "The menu bar has no \(title)")
    try require(wait(10, until: {
        item = menuItem(menuBar, title)
        return item.flatMap { attribute($0, kAXEnabledAttribute) as? Bool } == true
    }), "\(title) is not available in the active session window")
    try require(AXUIElementPerformAction(item!, kAXPressAction as CFString) == .success, "Could not choose \(title)")
}
/// Double-clicks the middle of `element`, as a person opens a row of a table.
func doubleClick(_ element: AXUIElement) throws {
    guard let rawPosition = attribute(element, kAXPositionAttribute), let rawSize = attribute(element, kAXSizeAttribute),
          CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else {
        throw Failure(description: "The element has no position to click")
    }
    var position = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(unsafeBitCast(rawPosition, to: AXValue.self), .cgPoint, &position)
    AXValueGetValue(unsafeBitCast(rawSize, to: AXValue.self), .cgSize, &size)
    let point = CGPoint(x: position.x + min(size.width / 2, 60), y: position.y + size.height / 2)
    for clickState in [1, 2] as [Int64] {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        else { throw Failure(description: "Could not create a double-click") }
        down.setIntegerValueField(.mouseEventClickState, value: clickState)
        up.setIntegerValueField(.mouseEventClickState, value: clickState)
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
}
func textArea(_ root: AXUIElement, containing text: String) -> AXUIElement? {
    var queue = [(root, 0)]
    var count = 0
    while !queue.isEmpty && count < 1000 {
        let (item, depth) = queue.removeFirst(); count += 1
        if attribute(item, kAXRoleAttribute) as? String == kAXTextAreaRole,
           (attribute(item, kAXValueAttribute) as? String)?.contains(text) == true { return item }
        if depth < 14 { queue += children(item).map { ($0, depth + 1) } }
    }
    return nil
}
func capture(_ pid: pid_t, _ path: URL) throws {
    var number: Int?
    let found = wait(5) {
        let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        number = all.first(where: {
            ($0[kCGWindowOwnerPID as String] as? Int32) == pid &&
                (($0[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Double ?? 0) >= 800
        })?[kCGWindowNumber as String] as? Int
        return number != nil
    }
    guard found, let number else { throw Failure(description: "No main window to capture") }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-l", String(number), path.path]
    try process.run(); process.waitUntilExit()
    try require(process.terminationStatus == 0, "Could not capture the AgentLand window")
}
func captureMenu(_ pid: pid_t, _ path: URL) throws {
    let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let owned = all.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
    guard let window = owned.first(where: {
        let bounds = $0[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let width = bounds["Width"] as? Double ?? 0
        let height = bounds["Height"] as? Double ?? 0
        return width > 100 && width < 700 && height > 100
    }), let number = window[kCGWindowNumber as String] as? Int else { throw Failure(description: "No menu window to capture") }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-l", String(number), path.path]
    try process.run(); process.waitUntilExit()
}
func run(_ executable: URL, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    try require(process.terminationStatus == 0, "Fixture command failed: \(executable.lastPathComponent)")
}
func commandOutput(_ executable: URL, _ arguments: [String]) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try require(process.terminationStatus == 0, "Fixture request failed: \(executable.lastPathComponent)")
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
func menuItem(_ root: AXUIElement, _ title: String) -> AXUIElement? {
    var queue = [(root, 0)]
    while !queue.isEmpty {
        let (item, depth) = queue.removeFirst()
        if attribute(item, kAXRoleAttribute) as? String == kAXMenuItemRole,
           attribute(item, kAXTitleAttribute) as? String == title { return item }
        if depth < 10 { queue += children(item).map { ($0, depth + 1) } }
    }
    return nil
}
func click(_ point: CGPoint) throws {
    guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
          let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
    else { throw Failure(description: "Could not create a menu click") }
    down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
}
func availablePort() throws -> Int {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    try require(descriptor >= 0, "Could not reserve a test port")
    defer { Darwin.close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: INADDR_ANY)
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    try require(bound == 0, "Could not reserve a test port")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let got = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.getsockname(descriptor, $0, &length)
        }
    }
    try require(got == 0, "Could not read the test port")
    return Int(UInt16(bigEndian: address.sin_port))
}

/// Puts `binary` where the host installs its managed OpenCode, as the host writes it: `<agents>/opencode/<version>/opencode`
/// in folders of mode 0700, and `current.json` with the program's SHA-256.
func seedManagedOpenCode(_ binary: URL, agents: URL) throws {
    let version = try commandOutput(binary, ["--version"]).split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
    try require(!version.isEmpty && !version.contains("/") && version != "." && version != "..", "Could not read the OpenCode version")
    let manager = FileManager.default
    let folder = agents.appendingPathComponent("opencode/\(version)", isDirectory: true)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    for path in [agents, agents.appendingPathComponent("opencode"), folder] {
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
    }
    let program = folder.appendingPathComponent("opencode")
    try manager.copyItem(at: binary, to: program)
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program.path)
    let digest = SHA256.hash(data: try Data(contentsOf: program)).map { String(format: "%02x", $0) }.joined()
    let record: [String: Any] = ["version": version, "command": program.path, "args": ["acp"], "sha256": digest,
                                 "installedAt": ISO8601DateFormatter().string(from: Date()), "kind": "binary",
                                 "name": "OpenCode", "unverified": false]
    let recordURL = agents.appendingPathComponent("opencode/current.json")
    try JSONSerialization.data(withJSONObject: record).write(to: recordURL)
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
}

func check() throws {
    try require(CommandLine.arguments.count == 3, "Pass an isolated AgentLand .uitest app and output folder")
    try require(AXIsProcessTrusted(), "Accessibility permission is required")
    let appURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    try require(Bundle(url: appURL)?.bundleIdentifier == "dev.agentland.desktop.uitest", "This check requires the isolated test bundle")
    try require(NSRunningApplication.runningApplications(withBundleIdentifier: "dev.agentland.desktop.uitest").isEmpty, "The isolated test app is already running")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let fixture = output.appendingPathComponent("fixture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let project = fixture.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try "Hello from the Mac session\n".write(to: project.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
    let state = fixture.appendingPathComponent("host.json")
    let hostBinary = appURL.appendingPathComponent("Contents/MacOS/agentland-host")
    try require(!FileManager.default.fileExists(atPath: appURL.appendingPathComponent("Contents/MacOS/opencode").path),
                "The app must bundle no OpenCode")
    try run(hostBinary, ["init", "--state", state.path, "--project", "fixture=Fixture=\(project.path)"])
    // The host's managed OpenCode lives here; the app runs it from here and stops it at the end.
    let agents = URL(fileURLWithPath: state.path + ".agents", isDirectory: true)
    let seeded = ProcessInfo.processInfo.environment["AGENTLAND_OPENCODE_TEST_BINARY"]
    if let seeded { try seedManagedOpenCode(URL(fileURLWithPath: seeded), agents: agents) }

    let bundleID = "dev.agentland.desktop.uitest"
    let defaults = UserDefaults(suiteName: bundleID)!
    let key = "dev.agentland.desktop.preferences.v1"
    let previous = defaults.data(forKey: key)
    let tabsKey = "agentland.tabs.workspace." + Data("agentland-session-test.local|local-mac".utf8).base64EncodedString()
    // The workspace the Mac opened and each workspace's last tab: none is assumed, so Home lists it.
    let workspaceKeys = ["agentland.desktop.workspace.current.agentland-session-test.local|local-mac",
                         "agentland.desktop.workspace.selection.agentland-session-test.local|local-mac"]
    let previousTabs = defaults.data(forKey: tabsKey)
    let previousWorkspace = workspaceKeys.map { defaults.object(forKey: $0) }
    defaults.removeObject(forKey: tabsKey)
    for workspaceKey in workspaceKeys { defaults.removeObject(forKey: workspaceKey) }
    defer {
        if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        if let previousTabs { defaults.set(previousTabs, forKey: tabsKey) } else { defaults.removeObject(forKey: tabsKey) }
        for (workspaceKey, value) in zip(workspaceKeys, previousWorkspace) {
            if let value { defaults.set(value, forKey: workspaceKey) } else { defaults.removeObject(forKey: workspaceKey) }
        }
    }
    let port = try availablePort()
    let preferences: [String: Any] = [
        "projectDirectory": project.path, "projectName": "Fixture", "projectID": "fixture",
        "openCodeURL": "http://127.0.0.1:4197", "listenAddress": "0.0.0.0:\(port)",
        "terminalEnabled": true, "connectionMode": "trustedHTTPS", "certificatePath": "", "keyPath": "",
        "advertisedHost": "agentland-session-test.local", "managedOpenCode": true,
        "connectionDesired": true, "onboardingComplete": true
    ]
    defaults.set(try JSONSerialization.data(withJSONObject: preferences), forKey: key)
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.environment["AGENTLAND_TEST_STATE_PATH"] = state.path
    var launched: NSRunningApplication?
    var launchError: Error?
    var complete = false
    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
        launched = app; launchError = error; complete = true
    }
    try require(wait(15, until: { complete }), "App launch timed out")
    guard launchError == nil, let app = launched else { throw Failure(description: "Could not launch isolated app: \(String(describing: launchError))") }
    var menuShown = false
    defer {
        if menuShown {
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        if !app.isTerminated {
            _ = app.terminate()
            if !wait(20, until: { app.isTerminated }) { _ = app.forceTerminate() }
        }
        let ps = try? commandOutput(URL(fileURLWithPath: "/bin/ps"), ["-axo", "pid=,command="])
        let bundlePaths = [appURL.path, appURL.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/")]
        let agentsPaths = [agents.path, agents.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/")]
        for line in ps?.split(separator: "\n") ?? [] {
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count == 2, let pid = Int32(fields[0]) else { continue }
            let command = String(fields[1])
            if bundlePaths.contains(where: { command.hasPrefix($0 + "/Contents/MacOS/agentland-host ") })
                || agentsPaths.contains(where: { command.hasPrefix($0 + "/opencode/") }) {
                Darwin.kill(pid, SIGTERM)
            }
        }
    }
    let application = AXUIElementCreateApplication(app.processIdentifier)
    // The shared full-width workspace, with this Mac's host running and its centered switcher on Home.
    // Getting OpenCode through the host first (no seeded one) takes longer.
    let ready = wait(seeded == nil ? 300 : 70) {
        identified(application, "workspaceSwitcher") != nil && identified(application, "homeBrowseFiles") != nil
    }
    if !ready {
        try? capture(app.processIdentifier, output.appendingPathComponent("session-startup-failed.png"))
        throw Failure(description: "The workspace window did not reach Home; inspect the startup capture")
    }
    try capture(app.processIdentifier, output.appendingPathComponent("session-home.png"))
    print("PASS: AgentLand opened to the full-width shared workspace")

    // No workspace is assumed: the centered switcher contains the folder, and choosing it opens Files.
    guard let switcher = identified(application, "workspaceSwitcher") else { throw Failure(description: "The workspace switcher disappeared") }
    try require(AXUIElementPerformAction(switcher, kAXPressAction as CFString) == .success, "Could not open the workspace switcher")
    var workspaceRow: AXUIElement?
    try require(wait(8, until: {
        workspaceRow = identified(application, "workspacePickerProject-fixture")
        return workspaceRow != nil
    }), "The workspace switcher did not list Fixture")
    try require(AXUIElementPerformAction(workspaceRow!, kAXPressAction as CFString) == .success, "Could not open the workspace")
    if !wait(10, until: { identified(application, "file-hello.txt") != nil }) {
        try? capture(app.processIdentifier, output.appendingPathComponent("session-files-failed.png"))
        throw Failure(description: "The temporary project file was not listed")
    }
    try require(identified(application, "fileActions") != nil && identified(application, "workspaceSwitcher") != nil,
                "Files did not keep the centered switcher and trailing actions")
    try capture(app.processIdentifier, output.appendingPathComponent("session-files.png"))
    print("PASS: Files loaded from the temporary connected host")

    // New Home Tab stays a menu command; the toolbar keeps navigation in its centered switcher.
    try require(identified(application, "newHomeTab") == nil, "The toolbar must not add a New Home Tab button")
    try chooseMenuCommand(application, "New Home Tab")
    try require(wait(5, until: { switcherShows(application, "Home 2") }), "The new Home tab is not in front")
    print("PASS: New Home Tab (menu bar) added a Home tab in front")

    // ⌘N from the menu bar, as the shared commands carry it.
    try chooseMenuCommand(application, "New Chat")
    // Every empty chat, a standalone one or (on older hosts) the workspace's, shows the landing over its composer.
    try require(wait(10, until: { identified(application, "plainChatLanding") != nil }), "Chat landing did not appear")
    try require(wait(10, until: { button(application, "Send") != nil }), "Chat composer did not appear")
    if let chatSwitcher = identified(application, "workspaceSwitcher") {
        try require(AXUIElementPerformAction(chatSwitcher, kAXPressAction as CFString) == .success,
                    "Could not inspect retained chats in the workspace switcher")
        try require(wait(5, until: {
            identified(application, withPrefix: "workspacePickerTab-").contains {
                attribute($0, kAXSelectedAttribute) as? Bool == true
            }
        }), "The picker did not retain the selected standalone chat")
        guard let closePicker = identified(application, "workspacePickerClose") else { throw Failure(description: "The picker has no Close") }
        try require(AXUIElementPerformAction(closePicker, kAXPressAction as CFString) == .success, "Could not close the picker")
    }
    try capture(app.processIdentifier, output.appendingPathComponent("session-chat.png"))
    print("PASS: Chat session and composer opened")

    try chooseMenuCommand(application, "New Terminal")
    try require(wait(10, until: { identified(application, "terminalCanvas") != nil }), "Terminal surface did not appear")
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    try capture(app.processIdentifier, output.appendingPathComponent("session-terminal.png"))
    print("PASS: Interactive terminal opened")
    // Closing the tab leaves the shell on the host; the check stops the host at the end.
    try chooseMenuCommand(application, "Close Tab")

    // ⌘1 is Home; its Browse Files action shows the workspace's retained Files tab again.
    try chooseMenuCommand(application, "Home")
    var browse: AXUIElement?
    try require(wait(5, until: { browse = identified(application, "homeBrowseFiles"); return browse != nil }), "Home did not come back")
    try require(AXUIElementPerformAction(browse!, kAXShowMenuAction as CFString) == .success, "Could not open Browse Files")
    var filesDestination: AXUIElement?
    let filesDestinationReady = wait(5, until: {
        filesDestination = menuItem(application, "Files")
        return filesDestination != nil
    })
    if !filesDestinationReady {
        try? capture(app.processIdentifier, output.appendingPathComponent("session-files-menu-failed.png"))
        var queue = [(application, 0)]
        var visited = 0
        while !queue.isEmpty && visited < 4000 {
            let (element, depth) = queue.removeFirst(); visited += 1
            let role = attribute(element, kAXRoleAttribute) as? String ?? "?"
            let title = attribute(element, kAXTitleAttribute) as? String ?? ""
            if role.contains("Menu") || title == "Files" {
                print("FILES MENU \(depth) \(role) \(title)")
            }
            if depth < 24 { queue += children(element).map { ($0, depth + 1) } }
        }
        throw Failure(description: "Browse Files did not expose its Files destination")
    }
    try require(AXUIElementPerformAction(filesDestination!, kAXPressAction as CFString) == .success,
                "Could not choose the Files destination")
    try require(wait(8, until: { identified(application, "file-hello.txt") != nil }), "Files did not come back")
    guard let file = identified(application, "file-hello.txt") else { throw Failure(description: "Temporary file disappeared") }
    try doubleClick(file)
    try require(wait(8, until: { identified(application, "saveFile") != nil }), "File editor did not appear")
    try capture(app.processIdentifier, output.appendingPathComponent("session-editor.png"))
    print("PASS: File editor opened in a workspace tab")
    if let editor = textArea(application, containing: "Hello from the Mac session") {
        let changed = "Edited through the Mac workspace\n"
        try require(AXUIElementSetAttributeValue(editor, kAXValueAttribute as CFString, changed as CFString) == .success,
                    "Could not enter text into the editor")
        try require(wait(5, until: { identified(application, "saveFile").flatMap { attribute($0, kAXEnabledAttribute) as? Bool } == true }),
                    "Editing did not enable Save")

        // Switching through the centered picker retains the editor and its unsaved draft.
        guard let editorSwitcher = identified(application, "workspaceSwitcher") else { throw Failure(description: "Editor lost the workspace switcher") }
        try require(AXUIElementPerformAction(editorSwitcher, kAXPressAction as CFString) == .success, "Could not open the picker from Editor")
        var homeRow: AXUIElement?
        try require(wait(5, until: { homeRow = identified(application, "workspacePickerHome"); return homeRow != nil }),
                    "The picker did not list Home")
        try require(AXUIElementPerformAction(homeRow!, kAXPressAction as CFString) == .success, "Could not switch to Home")
        try require(wait(5, until: { identified(application, "homeBrowseFiles") != nil }), "Home did not open from the picker")
        guard let homeSwitcher = identified(application, "workspaceSwitcher") else { throw Failure(description: "Home lost the workspace switcher") }
        try require(AXUIElementPerformAction(homeSwitcher, kAXPressAction as CFString) == .success, "Could not reopen the picker")
        var editorRow: AXUIElement?
        try require(wait(5, until: { editorRow = button(application, "hello.txt"); return editorRow != nil }),
                    "The picker did not retain the editor tab")
        try require(AXUIElementPerformAction(editorRow!, kAXPressAction as CFString) == .success, "Could not return to the editor")
        try require(wait(5, until: { textArea(application, containing: changed) != nil }), "The editor draft was lost across switching")

        // Close Tab preserves the existing dirty-editor confirmation and Keep Editing path.
        try chooseMenuCommand(application, "Close Tab")
        var keepEditing: AXUIElement?
        try require(wait(5, until: { keepEditing = button(application, "Keep Editing"); return keepEditing != nil }),
                    "Closing a dirty editor did not ask what to do")
        try require(AXUIElementPerformAction(keepEditing!, kAXPressAction as CFString) == .success, "Keep Editing failed")
        try require(wait(5, until: { textArea(application, containing: changed) != nil }), "Keep Editing closed the draft")
        try chooseMenuCommand(application, "Save")
        try require(wait(5, until: { (try? String(contentsOf: project.appendingPathComponent("hello.txt"), encoding: .utf8)) == changed }),
                    "Saving did not update the temporary project file")
        print("PASS: picker switching retained the dirty editor, Close Tab confirmed, and Save wrote exact text")
    } else { throw Failure(description: "Editor text area is not accessible") }

    let pin = try commandOutput(hostBinary, ["pair", "--pin", "--state", state.path])
    let curl = URL(fileURLWithPath: "/usr/bin/curl")
    let endpoint = "https://127.0.0.1:\(port)"
    let pairBody = String(decoding: try JSONSerialization.data(withJSONObject: ["code": pin, "deviceName": "Test iPad"]), as: UTF8.self)
    let pairResponse = try commandOutput(curl, ["--noproxy", "*", "-kfsS", "--max-time", "5", "-H", "Content-Type: application/json", "-d", pairBody, endpoint + "/v1/pair"])
    guard let pairData = pairResponse.data(using: .utf8),
          let pair = try JSONSerialization.jsonObject(with: pairData) as? [String: String],
          let token = pair["token"] else { throw Failure(description: "Could not pair the temporary iPad") }
    _ = try commandOutput(curl, ["--noproxy", "*", "-kfsS", "--max-time", "5", "-H", "Content-Type: application/json", "-H", "Authorization: Bearer " + token,
                          "-d", "{\"active\":true}", endpoint + "/v1/device/presence"])
    RunLoop.current.run(until: Date().addingTimeInterval(3))
    var extras: AXUIElement?
    let menuReady = wait(5) {
        guard let value = attribute(application, "AXExtrasMenuBar"), CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        extras = unsafeBitCast(value, to: AXUIElement.self)
        return extras != nil
    }
    try require(menuReady, "The test app's menu-bar item is missing")
    guard let extra = extras,
          let menuBarItem = children(extra).first(where: { attribute($0, kAXRoleAttribute) as? String == kAXMenuBarItemRole }),
          let rawPosition = attribute(menuBarItem, kAXPositionAttribute),
          let rawSize = attribute(menuBarItem, kAXSizeAttribute),
          CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID()
    else { throw Failure(description: "Could not locate the menu-bar icon") }
    var position = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(unsafeBitCast(rawPosition, to: AXValue.self), .cgPoint, &position)
    AXValueGetValue(unsafeBitCast(rawSize, to: AXValue.self), .cgSize, &size)
    try click(CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2))
    menuShown = true
    if !wait(6, until: { menuItem(menuBarItem, "Test iPad") != nil }) {
        try? captureMenu(app.processIdentifier, output.appendingPathComponent("active-menu-failed.png"))
        var queue = [(menuBarItem, 0)]
        while !queue.isEmpty {
            let (item, depth) = queue.removeFirst()
            let role = attribute(item, kAXRoleAttribute) as? String ?? "?"
            let title = attribute(item, kAXTitleAttribute) as? String ?? ""
            let description = attribute(item, kAXDescriptionAttribute) as? String ?? ""
            print("MENU \(depth) \(role) \(title) \(description)")
            if depth < 7 { queue += children(item).map { ($0, depth + 1) } }
        }
        throw Failure(description: "The active iPad was missing from the native menu")
    }
    print("PASS: Native menu listed the currently active iPad")
    CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
    menuShown = false
    _ = try commandOutput(curl, ["--noproxy", "*", "-kfsS", "--max-time", "5", "-H", "Content-Type: application/json", "-H", "Authorization: Bearer " + token,
                          "-d", "{\"active\":false}", endpoint + "/v1/device/presence"])
    RunLoop.current.run(until: Date().addingTimeInterval(3))
    try click(CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2))
    menuShown = true
    try require(wait(6, until: { menuItem(menuBarItem, "No active devices") != nil && menuItem(menuBarItem, "Test iPad") == nil }),
                "The menu retained an iPad after it stopped using AgentLand")
    print("PASS: Native menu removed the inactive iPad")
}

do { try check() } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
