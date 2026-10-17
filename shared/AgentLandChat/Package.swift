// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentLandChat",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "AgentLandChat", targets: ["AgentLandChat"])
    ],
    dependencies: [
        .package(path: "../AgentLandCore"),
        .package(path: "../AgentLandBranding"),
        .package(path: "../AgentLandDesign")
    ],
    targets: [
        .target(name: "AgentLandChat", dependencies: ["AgentLandCore", "AgentLandBranding", "AgentLandDesign"]),
        .testTarget(name: "AgentLandChatTests", dependencies: ["AgentLandChat"])
    ]
)
