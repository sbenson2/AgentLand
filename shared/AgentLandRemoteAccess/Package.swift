// swift-tools-version: 6.2
import PackageDescription

// The phone's side of remote access (docs/HOST-API.md "Remote access (iroh)", "The two apps"): the
// device's iroh key in its Keychain, the phone's endpoint and the loopback bridge `APIClient` reaches the
// Mac through. The iPhone and iPad app links it; the route logic that decides when the tunnel is tried
// stays in the app and AgentLandCore.
let package = Package(
    name: "AgentLandRemoteAccess",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "AgentLandRemoteAccess", targets: ["AgentLandRemoteAccess"])
    ],
    dependencies: [
        .package(path: "../AgentLandCore"),
        .package(path: "../AgentLandIroh")
    ],
    targets: [
        .target(name: "AgentLandRemoteAccess", dependencies: [
            .product(name: "AgentLandCore", package: "AgentLandCore"),
            .product(name: "AgentLandIroh", package: "AgentLandIroh")
        ]),
        .testTarget(name: "AgentLandRemoteAccessTests", dependencies: ["AgentLandRemoteAccess"])
    ]
)
