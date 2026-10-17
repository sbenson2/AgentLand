// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentLandArchive",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "AgentLandArchive", targets: ["AgentLandArchive"])
    ],
    dependencies: [
        // GRDB (MIT), pinned exactly; its license is in ios/AgentLand/GRDB-LICENSE.txt and macos/licenses/.
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        // The same SwiftTerm revision as the iOS app and the Mac package.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", revision: "5d14406844143538cd8f8851d2d8a67c1fe443e5"),
        .package(path: "../AgentLandCore"),
        .package(path: "../AgentLandChat"),
        .package(path: "../AgentLandDesign")
    ],
    targets: [
        .target(
            name: "AgentLandArchive",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                "AgentLandCore",
                "AgentLandChat",
                "AgentLandDesign"
            ]
        ),
        .testTarget(name: "AgentLandArchiveTests", dependencies: ["AgentLandArchive"])
    ]
)
