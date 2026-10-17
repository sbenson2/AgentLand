import AgentLandDesktop

// AgentLand.app's entry point, and the only source of its Xcode target. The
// app itself is AgentLandDesktopApp in the AgentLandDesktop package library,
// which the package tests also build.
@main
enum AgentLandMain {
    @MainActor static func main() {
        AgentLandDesktopApp.main()
    }
}
