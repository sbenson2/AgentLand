// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentLandDesign",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "AgentLandDesign", targets: ["AgentLandDesign"])
    ],
    dependencies: [
        // Test-only: the opt-in palette sheet draws the real tent, clown and title.
        .package(path: "../AgentLandBranding")
    ],
    targets: [
        .target(name: "AgentLandDesign"),
        .testTarget(
            name: "AgentLandDesignTests",
            dependencies: [
                "AgentLandDesign",
                .product(name: "AgentLandBranding", package: "AgentLandBranding")
            ]
        )
    ]
)
