import CoreGraphics
import XCTest
@testable import AgentLandBranding

/// The title fits around a circus that stays at the opening's anchor (centre at 0.46 of the window height,
/// scale min(0.92, (W - 40) / 336, (H - 120) / 360), as AgentLandArtworkLayout computes it). It may grow past
/// the scene's scale, up to the container's width less the insets and 1.25 times the scene's scale, and stays
/// above the tent's anchor.
final class TitlePlacementTests: XCTestCase {
    private typealias G = AgentLandWordmarkGeometry
    private struct Device { let name: String; let window: CGSize; let content: CGRect; let compact: Bool }

    private let devices = [
        // Content: the Home area below the navigation bar (and the iPad tab strip), inside the safe area.
        Device(name: "iPhone 17 Pro", window: CGSize(width: 402, height: 874), content: CGRect(x: 0, y: 116, width: 402, height: 724), compact: false),
        Device(name: "iPhone 17 Pro Max", window: CGSize(width: 440, height: 956), content: CGRect(x: 0, y: 118, width: 440, height: 804), compact: false),
        Device(name: "iPhone SE", window: CGSize(width: 375, height: 667), content: CGRect(x: 0, y: 64, width: 375, height: 603), compact: false),
        Device(name: "iPhone 17 Pro landscape", window: CGSize(width: 874, height: 402), content: CGRect(x: 62, y: 32, width: 750, height: 349), compact: true),
        Device(name: "iPad mini", window: CGSize(width: 744, height: 1133), content: CGRect(x: 0, y: 116, width: 744, height: 997), compact: false),
        // The detail column beside the sidebar: the circus centres in it.
        Device(name: "iPad Pro 13-inch beside the sidebar", window: CGSize(width: 712, height: 1376), content: CGRect(x: 0, y: 116, width: 712, height: 1240), compact: false),
        Device(name: "iPad Pro 13-inch", window: CGSize(width: 1032, height: 1376), content: CGRect(x: 0, y: 116, width: 1032, height: 1240), compact: false),
    ]

    private func place(_ device: Device) -> (placement: AgentLandTitlePlacement, scale: CGFloat, centre: CGPoint) {
        let scale = max(0.1, min(0.92, (device.window.width - 40) / 336, (device.window.height - 120) / 360))
        let centre = CGPoint(x: device.window.width / 2 - device.content.minX, y: device.window.height * 0.46 - device.content.minY)
        return (AgentLandTitlePlacement(sceneCenter: centre, sceneScale: scale, container: device.content.size,
                                        compactHeight: device.compact), scale, centre)
    }

    func testTitleFitsAroundTheSceneWithoutMovingIt() {
        let canvas = G.canvas
        for device in devices {
            let (placement, scale, centre) = place(device)
            XCTAssertGreaterThanOrEqual(placement.scale * G.capHeight, 18, "\(device.name): capitals remain readable")
            XCTAssertGreaterThanOrEqual(placement.frame.minY, 8 - 1e-9, "\(device.name): below the navigation bar")
            XCTAssertGreaterThanOrEqual(placement.frame.minX, 16 - 1e-9, "\(device.name): inside the side insets")
            XCTAssertLessThanOrEqual(placement.frame.maxX, device.content.width - 16 + 1e-9, device.name)
            XCTAssertEqual(placement.frame.width / placement.frame.height, canvas.width / canvas.height, accuracy: 1e-6)
            let sceneTop = centre.y - 180 * scale
            if device.compact {
                XCTAssertTrue(placement.leadingSide, device.name)
                // Clear of the clown's orbit on the left of the tent.
                XCTAssertLessThanOrEqual(placement.frame.maxX, centre.x + (11 - 168) * scale, device.name)
            } else {
                XCTAssertFalse(placement.leadingSide, device.name)
                // Its bottom edge is where the scene-size arch's would be: in the scene's motion-free top band.
                let anchorY = sceneTop + canvas.maxY * scale
                XCTAssertEqual(placement.frame.maxY, anchorY, accuracy: 1e-6, device.name)
                XCTAssertLessThanOrEqual(placement.frame.maxY - sceneTop, 40 * scale, device.name)
                // Centred over the tent, unless that would cross a side inset.
                let half = placement.frame.width / 2
                let centred = min(max(centre.x + (canvas.midX - 168) * scale, 16 + half), device.content.width - 16 - half)
                XCTAssertEqual(placement.frame.midX, centred, accuracy: 1e-6, "\(device.name): centred over the tent")
                XCTAssertEqual(placement.frame.midX, centre.x, accuracy: 2, "\(device.name): within 2 pt of the tent's centre")
                // As large as the container's width, the room above the tent or 1.25 times the scene's scale
                // allows, whichever is least.
                XCTAssertEqual(placement.scale, min((anchorY - 8) / canvas.height, (device.content.width - 32) / canvas.width,
                                                    1.25 * scale),
                               accuracy: 1e-9, device.name)
            }
            print("\(device.name): scene scale \(scale), title scale \(placement.scale) (capitals \(placement.scale * G.capHeight) pt), title \(placement.frame)")
        }
    }

    /// On a phone the flat title spans the width less the insets, past the scene's own scale: wider, with
    /// bigger capitals than round 1's arch (canvas 309.75 x 154.875 units, bottom at 38.25, cap 34, never
    /// past the scene's scale) had on the same screen.
    func testTheTitleGrowsPastTheScenesScaleOnPhones() {
        for name in ["iPhone 17 Pro", "iPhone 17 Pro Max", "iPhone SE"] {
            let device = devices.first { $0.name == name }!
            let (placement, scale, centre) = place(device)
            let roundOneAnchor = centre.y + (38.25 - 180) * scale
            let roundOne = min(scale, (roundOneAnchor - 8) / 154.875, (device.content.width - 32) / 309.75)
            XCTAssertEqual(placement.frame.width, device.content.width - 32, accuracy: 1e-6, "\(name): the full width")
            XCTAssertGreaterThan(placement.frame.width, 309.75 * roundOne, "\(name): wider than round 1's arch")
            XCTAssertGreaterThan(placement.scale * G.capHeight, 20, "\(name): broad capitals remain readable")
            print("\(name): capitals \(placement.scale * G.capHeight) pt, round 1 \(34 * roundOne) pt; width \(placement.frame.width) pt, round 1 \(309.75 * roundOne) pt")
        }
        let wide = place(devices.first { $0.name == "iPad Pro 13-inch" }!)
        XCTAssertGreaterThan(wide.placement.scale, wide.scale, "Past the scene's scale when there is room")
    }

    /// On an iPad the width alone would make the title 1000 pt wide with 97 pt capitals over a 309 pt scene;
    /// it stops at 1.25 times the scene's scale, about 500 pt wide with 48 pt capitals.
    func testTheTitleStaysInProportionWithTheTentOnWideScreens() {
        for name in ["iPad mini", "iPad Pro 13-inch beside the sidebar", "iPad Pro 13-inch"] {
            let (placement, scale, _) = place(devices.first { $0.name == name }!)
            XCTAssertEqual(placement.scale, 1.25 * scale, accuracy: 1e-9, "\(name): stops at 1.25 times the scene's scale")
            let device = devices.first { $0.name == name }!
            XCTAssertLessThanOrEqual(placement.frame.width, device.content.width - 32, name)
            XCTAssertGreaterThan(placement.scale * G.capHeight, 45, "\(name): capitals still over 45 pt")
        }
    }
}
