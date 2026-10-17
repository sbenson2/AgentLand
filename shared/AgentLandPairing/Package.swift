// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentLandPairing",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "AgentLandPairing", targets: ["AgentLandPairing"])],
    targets: [
        .target(name: "AgentLandPairing"),
        .testTarget(name: "AgentLandPairingTests", dependencies: ["AgentLandPairing"])
    ]
)
