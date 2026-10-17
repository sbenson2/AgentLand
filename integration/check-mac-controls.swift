import AppKit
import ApplicationServices

// Bounded interaction check against a newly launched isolated AgentLand process. It creates and restores a
// disposable .uitest preference/state fixture, but never starts a host or touches the owner's data. Requires
// Accessibility and Screen Recording access for the terminal running it.
struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(description: message) }
}

func wait(_ timeout: Double, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    return condition()
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
    return result
}

func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(value, to: AXUIElement.self)
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func findButton(_ root: AXUIElement, named name: String) -> AXUIElement? {
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var visited = 0
    while !queue.isEmpty && visited < 500 {
        let (element, depth) = queue.removeFirst()
        visited += 1
        let role = attribute(element, kAXRoleAttribute) as? String
        let title = attribute(element, kAXTitleAttribute) as? String
        let description = attribute(element, kAXDescriptionAttribute) as? String
        if role == kAXButtonRole && (title == name || description == name) { return element }
        if depth < 10 { queue += children(element).map { ($0, depth + 1) } }
    }
    return nil
}

func findIdentified(_ root: AXUIElement, _ identifier: String) -> AXUIElement? {
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var visited = 0
    while !queue.isEmpty && visited < 2000 {
        let (element, depth) = queue.removeFirst()
        visited += 1
        if attribute(element, "AXIdentifier") as? String == identifier { return element }
        if depth < 16 { queue += children(element).map { ($0, depth + 1) } }
    }
    return nil
}

/// The Settings window (2026-10-16, in the style of Safari's): its title is the pane in front.
func accessibleSettingsWindow(_ application: AXUIElement) -> AXUIElement? {
    (attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []).first { window in
        settingsPaneTitles.contains(attribute(window, kAXTitleAttribute) as? String ?? "")
    }
}

/// The Settings window's toolbar tabs, in order, with the saved choice's raw values.
let settingsPanes: [(title: String, id: String)] = [
    ("General", "general"), ("Workspaces", "workspace"), ("Agents", "agents"), ("Vault", "vault"),
    ("Devices", "devices"), ("Terminals", "terminals"), ("Remote Access", "remoteAccess"),
    ("Notifications", "notifications"), ("API Keys (Later)", "provider"), ("Advanced", "advanced")
]
let settingsPaneTitles = Set(settingsPanes.map { $0.title })

/// A pane's toolbar tab: by its identifier, else the toolbar button with its title.
func settingsTab(_ window: AXUIElement, _ pane: (title: String, id: String)) -> AXUIElement? {
    if let tab = findIdentified(window, "macSettingsPane-\(pane.id)") { return tab }
    guard let toolbar = children(window).first(where: { attribute($0, kAXRoleAttribute) as? String == kAXToolbarRole }) else { return nil }
    return findButton(toolbar, named: pane.title)
}

func findMenuItem(_ root: AXUIElement, named name: String) -> AXUIElement? {
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var visited = 0
    while !queue.isEmpty && visited < 500 {
        let (element, depth) = queue.removeFirst()
        visited += 1
        let role = attribute(element, kAXRoleAttribute) as? String
        let title = attribute(element, kAXTitleAttribute) as? String
        if role == kAXMenuItemRole && title == name { return element }
        if depth < 10 { queue += children(element).map { ($0, depth + 1) } }
    }
    return nil
}

func click(at point: CGPoint) throws {
    guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                             mouseCursorPosition: point, mouseButton: .left),
          let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                           mouseCursorPosition: point, mouseButton: .left) else {
        throw CheckFailure(description: "Could not create a mouse click")
    }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

func chooseMenuCommand(_ application: AXUIElement, _ title: String) throws {
    guard let value = attribute(application, kAXMenuBarAttribute), CFGetTypeID(value) == AXUIElementGetTypeID(),
          let command = findMenuItem(unsafeBitCast(value, to: AXUIElement.self), named: title) else {
        throw CheckFailure(description: "The app menu has no \(title)")
    }
    try require(wait(5, until: { attribute(command, kAXEnabledAttribute) as? Bool == true }), "\(title) is unavailable")
    try require(AXUIElementPerformAction(command, kAXPressAction as CFString) == .success, "Choosing \(title) failed")
}

/// Verifies the native command is exactly ⌘, and invokes that same menu item. Posting a key-code 43 CGEvent is
/// keyboard-layout dependent; the menu's AX command character/modifiers are the system's authoritative shortcut.
func invokeCommandComma(_ application: AXUIElement) throws {
    guard let value = attribute(application, kAXMenuBarAttribute), CFGetTypeID(value) == AXUIElementGetTypeID(),
          let command = findMenuItem(unsafeBitCast(value, to: AXUIElement.self), named: "Settings…") else {
        throw CheckFailure(description: "The native Settings command is missing")
    }
    try require(attribute(command, kAXMenuItemCmdCharAttribute) as? String == ",",
                "The native Settings command is not bound to comma")
    // AX uses bit 3 for “no Command”; zero is Command with no Shift, Option or Control.
    try require(attribute(command, kAXMenuItemCmdModifiersAttribute) as? Int == 0,
                "The native Settings command is not bound to ⌘,")
    try require(attribute(command, kAXEnabledAttribute) as? Bool == true, "The native Settings command is unavailable")
    try require(AXUIElementPerformAction(command, kAXPressAction as CFString) == .success,
                "Invoking the native ⌘, command failed")
}

func frame(of element: AXUIElement) -> CGRect? {
    guard let rawPosition = attribute(element, kAXPositionAttribute), let rawSize = attribute(element, kAXSizeAttribute),
          CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
    var position = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(unsafeBitCast(rawPosition, to: AXValue.self), .cgPoint, &position)
    AXValueGetValue(unsafeBitCast(rawSize, to: AXValue.self), .cgSize, &size)
    return CGRect(origin: position, size: size)
}

func windows(_ pid: pid_t) -> [[String: Any]] {
    let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return all.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
}

/// The app's ordinary windows (Settings, Setup, Pair a Device): layer 0, not the menu-bar item or its menu.
func mainWindows(_ pid: pid_t) -> [[String: Any]] {
    windows(pid).filter {
        let bounds = $0[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let width = bounds["Width"] as? Double ?? 0
        let height = bounds["Height"] as? Double ?? 0
        return ($0[kCGWindowLayer as String] as? Int) == 0 && width >= 300 && height >= 100
    }
}

func capture(_ window: [String: Any], at url: URL) throws {
    guard let number = window[kCGWindowNumber as String] as? Int else {
        throw CheckFailure(description: "Owned window has no capture ID")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-l", String(number), url.path]
    try process.run()
    if !wait(5, until: { !process.isRunning }) { process.terminate() }
    try require(!process.isRunning && process.terminationStatus == 0, "Owned window capture failed")
}

func capture(_ region: CGRect, at url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-R", "\(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))", url.path]
    try process.run()
    if !wait(5, until: { !process.isRunning }) { process.terminate() }
    try require(!process.isRunning && process.terminationStatus == 0, "Visible region capture failed")
}

func run(_ executable: URL, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    try require(process.terminationStatus == 0, "Fixture command failed: \(executable.lastPathComponent)")
}

func check() throws {
    try require(CommandLine.arguments.count == 3, "Pass the AgentLand.app path and screenshot directory")
    try require(AXIsProcessTrusted(), "Accessibility permission is required for the running terminal")
    let url = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    guard let bundleID = Bundle(url: url)?.bundleIdentifier,
          bundleID == "dev.agentland.desktop.uitest" else {
        throw CheckFailure(description: "This check requires the isolated AgentLand .uitest bundle")
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let previous = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
    try require(previous.isEmpty, "Quit other AgentLand copies before this check; macOS reopening selects an existing instance by bundle identifier")
    // Give the isolated app a complete, stopped fixture so Settings is available from Home without
    // starting a host or touching the owner's preferences or state.
    let defaults = UserDefaults(suiteName: bundleID)!
    let preferencesKey = "dev.agentland.desktop.preferences.v1"
    let settingsPaneKey = "agentland.desktop.settingsPane"
    let previousPreferences = defaults.data(forKey: preferencesKey)
    let previousSettingsPane = defaults.string(forKey: settingsPaneKey)
    let fixture = output.appendingPathComponent("controls-fixture-\(UUID().uuidString)", isDirectory: true)
    let project = fixture.appendingPathComponent("project", isDirectory: true)
    let state = fixture.appendingPathComponent("host.json")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let hostBinary = url.appendingPathComponent("Contents/MacOS/agentland-host")
    try run(hostBinary, ["init", "--state", state.path, "--project", "fixture=Fixture=\(project.path)"])
    let preferences: [String: Any] = [
        "projectDirectory": project.path, "projectName": "Fixture", "projectID": "fixture",
        "openCodeURL": "http://127.0.0.1:4197", "listenAddress": "0.0.0.0:0",
        "terminalEnabled": true, "connectionMode": "trustedHTTPS", "certificatePath": "", "keyPath": "",
        "advertisedHost": "agentland-controls-test.local", "managedOpenCode": true,
        "connectionDesired": false, "onboardingComplete": true
    ]
    defaults.set(try JSONSerialization.data(withJSONObject: preferences), forKey: preferencesKey)
    defaults.set("general", forKey: settingsPaneKey)
    defer {
        if let previousPreferences { defaults.set(previousPreferences, forKey: preferencesKey) }
        else { defaults.removeObject(forKey: preferencesKey) }
        if let previousSettingsPane { defaults.set(previousSettingsPane, forKey: settingsPaneKey) }
        else { defaults.removeObject(forKey: settingsPaneKey) }
        try? FileManager.default.removeItem(at: fixture)
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.environment["AGENTLAND_TEST_STATE_PATH"] = state.path
    if let appearance = ProcessInfo.processInfo.environment["AGENTLAND_TEST_APPEARANCE"],
       ["Light", "Dark"].contains(appearance) {
        configuration.arguments = ["-AppleInterfaceStyle", appearance]
    }
    var launched: NSRunningApplication?
    var launchError: Error?
    var completed = false
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
        launched = app; launchError = error; completed = true
    }
    try require(wait(15, until: { completed }), "Launch timed out")
    guard launchError == nil, let app = launched,
          !previous.contains(app.processIdentifier), app.bundleURL?.standardizedFileURL == url else {
        throw CheckFailure(description: "Failed to launch an owned AgentLand instance: \(String(describing: launchError))")
    }
    defer {
        if !app.isTerminated {
            _ = app.terminate()
            if !wait(8, until: { app.isTerminated }) { _ = app.forceTerminate() }
        }
    }
    let application = AXUIElementCreateApplication(app.processIdentifier)
    var item: AXUIElement?
    try require(wait(8, until: {
        guard let extras = elementAttribute(application, "AXExtrasMenuBar") else { return false }
        item = children(extras).first { attribute($0, kAXRoleAttribute) as? String == kAXMenuBarItemRole }
        return item != nil
    }), "The menu-bar item is missing")
    try require(app.activationPolicy == .accessory, "Server app unexpectedly appears in the Dock")
    try require(!wait(2, until: { !mainWindows(app.processIdentifier).isEmpty }), "Configured startup opened a window")
    print("PASS: configured startup is menu-bar-only, without a Dock icon or workspace window")

    func openMenu() throws -> AXUIElement {
        guard let item, let rect = frame(of: item) else { throw CheckFailure(description: "Menu-bar item has no bounds") }
        try click(at: CGPoint(x: rect.midX, y: rect.midY))
        try require(wait(4, until: { findMenuItem(item, named: "Settings…") != nil }), "Menu did not open")
        return item
    }
    let menu = try openMenu()
    for title in ["Open AgentLand", "Start Server", "Pair a Device…", "Settings…", "Quit AgentLand Server"] {
        try require(findMenuItem(menu, named: title) != nil, "Menu is missing \(title)")
    }
    if let pair = findMenuItem(menu, named: "Pair a Device…") {
        try require(attribute(pair, kAXEnabledAttribute) as? Bool == false, "Pairing is enabled while the server is stopped")
    }
    guard let settings = findMenuItem(menu, named: "Settings…") else { throw CheckFailure(description: "Missing Settings") }
    if let parent = elementAttribute(settings, kAXParentAttribute), let rect = frame(of: parent) {
        try capture(rect, at: output.appendingPathComponent("mac-server-menu.png"))
    }
    try require(AXUIElementPerformAction(settings, kAXPressAction as CFString) == .success, "Could not open Settings")
    try require(wait(5, until: { accessibleSettingsWindow(application) != nil }), "Settings window did not open")
    guard let settingsWindow = accessibleSettingsWindow(application) else { throw CheckFailure(description: "Missing Settings window") }
    try require(attribute(settingsWindow, kAXTitleAttribute) as? String == "General", "Settings did not open on the saved pane")
    try require(findIdentified(application, "workspaceSwitcher") == nil, "Native workspace is still exposed")
    try require(findButton(settingsWindow, named: "Open AgentLand") != nil, "General has no browser launcher")
    for pane in settingsPanes {
        guard let control = settingsTab(settingsWindow, pane) else {
            throw CheckFailure(description: "Settings has no \(pane.title) tab")
        }
        try require(AXUIElementPerformAction(control, kAXPressAction as CFString) == .success, "Could not select \(pane.title)")
        // The window is titled with the pane in front.
        try require(wait(2, until: { attribute(settingsWindow, kAXTitleAttribute) as? String == pane.title }), "\(pane.title) did not select")
    }
    if let general = settingsTab(settingsWindow, settingsPanes[0]) {
        _ = AXUIElementPerformAction(general, kAXPressAction as CFString)
    }
    if let window = mainWindows(app.processIdentifier).first {
        try capture(window, at: output.appendingPathComponent("mac-server-settings.png"))
    }
    guard let close = elementAttribute(settingsWindow, kAXCloseButtonAttribute) else { throw CheckFailure(description: "Missing close button") }
    try require(AXUIElementPerformAction(close, kAXPressAction as CFString) == .success, "Settings did not close")
    try require(wait(4, until: { mainWindows(app.processIdentifier).isEmpty }), "Settings window remained open")
    try require(!app.isTerminated, "Closing settings terminated the server app")
    print("PASS: the Settings window has every tab, titled with the pane in front; closing it leaves the app running")

    let reopened = try openMenu()
    guard let reopenSettings = findMenuItem(reopened, named: "Settings…") else { throw CheckFailure(description: "Missing Settings") }
    _ = AXUIElementPerformAction(reopenSettings, kAXPressAction as CFString)
    try require(wait(4, until: { accessibleSettingsWindow(application) != nil }), "Settings did not reopen")
    app.activate(options: [.activateIgnoringOtherApps])
    try chooseMenuCommand(application, "Close Window")
    try require(wait(4, until: { mainWindows(app.processIdentifier).isEmpty }), "Close Window did not close Settings")
    try require(!app.isTerminated, "Close Window terminated the app")
    print("PASS: Close Window leaves the server app running")

    let finalMenu = try openMenu()
    guard let quit = findMenuItem(finalMenu, named: "Quit AgentLand Server") else { throw CheckFailure(description: "Missing explicit server quit") }
    try require(AXUIElementPerformAction(quit, kAXPressAction as CFString) == .success, "Explicit server quit failed")
    try require(wait(8, until: { app.isTerminated }), "App did not quit after explicit Quit AgentLand Server")
    print("PASS: explicit Quit AgentLand Server exits normally")
}

do {
    try check()
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
