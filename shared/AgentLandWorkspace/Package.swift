// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentLandWorkspace",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "AgentLandWorkspace", targets: ["AgentLandWorkspace"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", revision: "5d14406844143538cd8f8851d2d8a67c1fe443e5"),
        .package(path: "../AgentLandCore"),
        .package(path: "../AgentLandChat"),
        .package(path: "../AgentLandArchive"),
        .package(path: "../AgentLandDesign"),
        .package(path: "../AgentLandBranding")
    ],
    targets: [
        .target(
            name: "AgentLandWorkspace",
            dependencies: [
                .product(name: "AgentLandCore", package: "AgentLandCore"),
                .product(name: "AgentLandChat", package: "AgentLandChat"),
                .product(name: "AgentLandArchive", package: "AgentLandArchive"),
                .product(name: "AgentLandDesign", package: "AgentLandDesign"),
                .product(name: "AgentLandBranding", package: "AgentLandBranding"),
                // The terminal surface's renderer: SwiftTerm's UIKit view on iPhone and iPad, its
                // AppKit view on the Mac.
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        ),
        .testTarget(name: "AgentLandWorkspaceTests", dependencies: ["AgentLandWorkspace"])
    ]
)
