// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentLandDesktop",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AgentLandDesktopCore", targets: ["AgentLandDesktopCore"]),
        // The whole SwiftUI app. AgentLandDesktop.xcodeproj links it into
        // AgentLand.app, whose only source is the entry point in App/.
        .library(name: "AgentLandDesktop", targets: ["AgentLandDesktop"]),
        // Test tooling, never bundled: the Mac side of remote access on loopback for the phone's
        // simulator UI test (integration/check-ios-product.py, testConnectsThroughIrohTunnel).
        .executable(name: "agentland-remote-access-loopback", targets: ["RemoteAccessLoopback"])
    ],
    dependencies: [
        .package(path: "../shared/AgentLandCore"),
        .package(path: "../shared/AgentLandBranding"),
        .package(path: "../shared/AgentLandChat"),
        .package(path: "../shared/AgentLandDesign"),
        // iroh's Swift bindings as AgentLand builds them (remote access; off by default). Its
        // VerifyIrohLib plugin checks the library against third_party/iroh-ffi/IrohLib.sha256.
        .package(path: "../shared/AgentLandIroh"),
        .package(path: "../shared/AgentLandNotifications"),
        .package(path: "../shared/AgentLandPairing"),
        // The workspace window: the same shell and surfaces as iPhone and iPad (it brings SwiftTerm).
        .package(path: "../shared/AgentLandWorkspace")
    ],
    targets: [
        .target(name: "AgentLandDesktopCore", dependencies: ["AgentLandPairing", "AgentLandCore", "AgentLandNotifications", "AgentLandIroh"]),
        .target(name: "AgentLandDesktop", dependencies: ["AgentLandDesktopCore", "AgentLandCore", "AgentLandBranding", "AgentLandChat", "AgentLandDesign", "AgentLandNotifications", "AgentLandPairing", "AgentLandWorkspace"]),
        .executableTarget(name: "RemoteAccessLoopback", dependencies: ["AgentLandDesktopCore", "AgentLandCore"], path: "Tools/RemoteAccessLoopback"),
        .testTarget(name: "AgentLandDesktopCoreTests", dependencies: [
            "AgentLandDesktopCore", "AgentLandDesktop", "AgentLandCore", "AgentLandPairing", "AgentLandNotifications", "AgentLandWorkspace",
            "AgentLandIroh",
            .product(name: "AgentLandNotificationsTesting", package: "AgentLandNotifications")
        ])
    ]
)
