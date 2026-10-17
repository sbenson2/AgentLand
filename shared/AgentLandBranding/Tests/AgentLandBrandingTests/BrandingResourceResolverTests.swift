import Foundation
import XCTest
@testable import AgentLandBranding

final class BrandingResourceResolverTests: XCTestCase {
    func testPrefersBundleInMacOSAppResources() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AgentLandBrandingTests-\(UUID().uuidString).app", isDirectory: true)
        let resources = root.appendingPathComponent("Contents/Resources", isDirectory: true)
        let brandingBundle = resources.appendingPathComponent("AgentLandBranding_AgentLandBranding.bundle", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: brandingBundle, withIntermediateDirectories: true)
        try "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>dev.agentland.branding.host</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>"
            .write(to: root.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        try "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>dev.agentland.branding.test</string></dict></plist>"
            .write(to: brandingBundle.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: brandingBundle.appendingPathComponent("TentMark.png"))

        let appBundle = try XCTUnwrap(Bundle(path: root.path))
        var fallbackRequested = false
        func fallback() -> Bundle { fallbackRequested = true; return .main }
        let resolved = AgentLandBrandingResources.resolve(mainBundle: appBundle, fallback: fallback())

        XCTAssertEqual(resolved.bundleURL.standardizedFileURL, brandingBundle.standardizedFileURL)
        XCTAssertFalse(fallbackRequested, "An installed app must not evaluate a missing source-tree fallback.")
    }
}
