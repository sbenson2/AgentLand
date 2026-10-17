// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "SwiftHostProbe",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../../shared/AgentLandCore")],
    targets: [.executableTarget(name: "SwiftHostProbe", dependencies: ["AgentLandCore"])],
    swiftLanguageModes: [.v5]
)
