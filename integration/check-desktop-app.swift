import AppKit

// A bounded launch/quit check for the installed product bundle. It never starts
// a host, imports state, or touches another application's process.
guard (2...3).contains(CommandLine.arguments.count) else { fatalError("Pass the AgentLand.app path and optional screenshot output path.") }
let url = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
// Xcode builds the branding bundle with Contents/Resources inside; Bundle finds
// the tent in either layout.
guard let bundle = Bundle(url: url), bundle.bundleIdentifier == "dev.agentland.desktop",
      bundle.executableURL?.lastPathComponent == "AgentLandDesktop",
      let brandingURL = bundle.url(forResource: "AgentLandBranding_AgentLandBranding", withExtension: "bundle"),
      Bundle(url: brandingURL)?.url(forResource: "TentMark", withExtension: "png") != nil else {
    fatalError("Expected the independent AgentLand app with its packaged tent resource.")
}
let previous = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "dev.agentland.desktop").map(\.processIdentifier))
let configuration = NSWorkspace.OpenConfiguration()
configuration.createsNewApplicationInstance = true
var launched: NSRunningApplication?
var launchError: Error?
var completed = false
NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
    launched = app; launchError = error; completed = true
}
func wait(_ timeout: Double, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    return condition()
}
guard wait(15, until: { completed }), launchError == nil, let app = launched,
      !previous.contains(app.processIdentifier), app.bundleURL?.standardizedFileURL == url else {
    fatalError("AgentLand did not launch as a new process: \(String(describing: launchError))")
}
// Give SwiftUI time to resolve its resources and construct the controls.
_ = wait(3, until: { app.isTerminated })
guard !app.isTerminated else { fatalError("The app exited during controls startup.") }
if CommandLine.arguments.count == 3 {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let windowID = windows.first(where: {
        ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier &&
        ($0[kCGWindowLayer as String] as? Int) == 0 &&
        (($0[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Double ?? 0) >= 300
    })?[kCGWindowNumber as String] as? Int
    if let windowID {
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", String(windowID), CommandLine.arguments[2]]
        do {
            try capture.run()
            if !wait(5, until: { !capture.isRunning }) { capture.terminate() }
            if !capture.isRunning && capture.terminationStatus == 0 {
                print("Captured the owned AgentLand window.")
            } else { print("Window capture unavailable; startup/quit verification continues.") }
        } catch { print("Window capture unavailable: \(error.localizedDescription)") }
    } else { print("No visible AgentLand window was available to capture.") }
}
let requestedQuit = app.terminate()
let quit = requestedQuit && wait(8, until: { app.isTerminated })
if !quit { _ = app.forceTerminate(); fatalError("The owned app did not quit normally within eight seconds.") }
print("PASS: packaged macOS app launched, remained running through controls startup, and quit normally.")
