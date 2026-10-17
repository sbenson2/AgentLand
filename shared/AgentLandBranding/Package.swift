// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentLandBranding",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "AgentLandBranding", targets: ["AgentLandBranding"])
    ],
    targets: [
        .target(
            name: "AgentLandBranding",
            resources: [.process("Resources")]
        ),
        .testTarget(name: "AgentLandBrandingTests", dependencies: ["AgentLandBranding"])
    ]
)
