// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentLandCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "AgentLandCore", targets: ["AgentLandCore"])],
    targets: [
        .target(name: "AgentLandCore"),
        .testTarget(name: "AgentLandCoreTests", dependencies: ["AgentLandCore"]),
    ]
)
