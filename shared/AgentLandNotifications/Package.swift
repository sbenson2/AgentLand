// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentLandNotifications",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "AgentLandNotifications", targets: ["AgentLandNotifications"]),
        // The in-memory NoticeDatabase for tests. Apps never link it.
        .library(name: "AgentLandNotificationsTesting", targets: ["AgentLandNotificationsTesting"])
    ],
    targets: [
        .target(name: "AgentLandNotifications", resources: [.process("Resources")]),
        .target(name: "AgentLandNotificationsTesting", dependencies: ["AgentLandNotifications"]),
        .testTarget(name: "AgentLandNotificationsTests", dependencies: ["AgentLandNotifications", "AgentLandNotificationsTesting"])
    ]
)
