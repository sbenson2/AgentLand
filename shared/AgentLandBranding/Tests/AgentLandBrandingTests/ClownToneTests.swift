import CoreGraphics
import ImageIO
import XCTest
@testable import AgentLandBranding

final class ClownToneTests: XCTestCase {
    func testEveryPackagedFrameUsesFiveDayTonesAndBinaryAlpha() throws {
        for design in AgentLandClownArtwork.designs {
            let tones = try XCTUnwrap(design.tones[.day])
            XCTAssertEqual(tones.count, 5)
            for frame in design.indices {
                XCTAssertGreaterThanOrEqual(Set(frame.filter { $0 > 0 }).count, 4, design.name)
                XCTAssertTrue(frame.allSatisfy { $0 <= 5 }, design.name)
            }
            let url = try XCTUnwrap(AgentLandBrandingResources.bundle.url(forResource: "ClownRide-\(design.name)", withExtension: "png"))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let strip = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(strip.width, 96 * 72)
            let bytes = try XCTUnwrap(AgentLandClownArtwork.rgbaBytes(strip))
            for index in stride(from: 0, to: bytes.count, by: 4) {
                XCTAssertTrue(bytes[index + 3] == 0 || bytes[index + 3] == 255)
                if bytes[index + 3] == 255 { XCTAssertTrue(tones.contains([bytes[index], bytes[index + 1], bytes[index + 2]])) }
            }
        }
    }

    func testDayAndNightRampsRemainOrderedAndDistinct() {
        for design in AgentLandClownArtwork.designs {
            XCTAssertEqual(design.tones[.day]?.count, 5)
            XCTAssertEqual(design.tones[.night]?.count, 5)
            XCTAssertNotEqual(design.tones[.day], design.tones[.night])
        }
    }

    func testBackdropChoosesTheExpectedRamp() {
        XCTAssertEqual(AgentLandClownRamp.forBackdrop(linearRed: 0.02, green: 0.03, blue: 0.04), .night)
        XCTAssertEqual(AgentLandClownRamp.forBackdrop(linearRed: 0.8, green: 0.7, blue: 0.6), .day)
    }
}
