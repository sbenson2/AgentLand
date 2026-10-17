import XCTest
@testable import AgentLandNotifications

/// An iOS device build decides whether it may use CloudKit from its embedded provisioning profile.
final class ProvisionedEntitlementsTests: XCTestCase {
    /// A profile as iOS ships it: the property list inside a CMS envelope (bytes around it).
    private func profile(entitlements: [String: Any]) throws -> Data {
        let plist = try PropertyListSerialization.data(fromPropertyList: ["Name": "iOS Team Provisioning Profile",
                                                                          "Entitlements": entitlements],
                                                       format: .xml, options: 0)
        return Data([0x30, 0x82, 0x3A, 0x01, 0x06, 0x09]) + plist + Data([0xA0, 0x82, 0x0D, 0x00])
    }

    /// Xcode's team profiles grant the iCloud services as the wildcard "*".
    func testAProfileWithTheContainerAllowsCloudKit() throws {
        let data = try profile(entitlements: [
            "aps-environment": "development",
            "com.apple.developer.icloud-container-identifiers": ["iCloud.dev.agentland"],
            "com.apple.developer.icloud-services": "*",
        ])
        let granted = NoticeCloudKit.provisionedEntitlements(profile: data)
        XCTAssertNil(NoticeCloudKit.unavailability(environment: [:], entitlement: { NoticeCloudKit.provisionedGrant($0, in: granted) }))
    }

    /// The App ID had iCloud but no container assigned: the profile's list is empty, and CloudKit
    /// stays off instead of ending the app in CKContainer.
    func testAProfileWithoutTheContainerKeepsCloudKitOff() throws {
        let data = try profile(entitlements: [
            "aps-environment": "development",
            "com.apple.developer.icloud-container-identifiers": [String](),
            "com.apple.developer.icloud-services": "*",
        ])
        let granted = NoticeCloudKit.provisionedEntitlements(profile: data)
        XCTAssertEqual(NoticeCloudKit.unavailability(environment: [:], entitlement: { NoticeCloudKit.provisionedGrant($0, in: granted) }),
                       .notSignedForICloud)
    }

    func testAWildcardProfileOrNoProfileKeepsCloudKitOff() throws {
        let wildcard = NoticeCloudKit.provisionedEntitlements(profile: try profile(entitlements: ["get-task-allow": true]))
        XCTAssertEqual(NoticeCloudKit.unavailability(environment: [:], entitlement: { wildcard[$0] }), .notSignedForICloud)
        XCTAssertTrue(NoticeCloudKit.provisionedEntitlements(profile: Data("not a profile".utf8)).isEmpty)
    }
}
