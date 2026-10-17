import CoreGraphics
import XCTest
@testable import AgentLandBranding
#if os(macOS)
import AppKit
#endif

/// scripts/package-logo.py packages the logo's in-app mark from the tent sprite and the menu-bar template from
/// the glyph drawn by hand for the bar's 1x grid (branding/tent-menubar.txt). AgentLandMark recolours the mark by
/// palette index, so it must hold only the day ramp's exact tones.
final class LogoTests: XCTestCase {
    func testMarkIsASquareOfTheDayRampAndRecoloursToNight() throws {
        let day = try XCTUnwrap(AgentLandTonalArtwork.tones(.day))
        let image = try XCTUnwrap(AgentLandBrandingResources.image("LogoMark"), "LogoMark.png is packaged")
        XCTAssertEqual(image.width, image.height, "The mark is square")
        let side = image.width, mark = rgba(image)
        let opaque = mark.filter { $0[3] != 0 }
        for pixel in opaque {
            XCTAssertEqual(pixel[3], 255, "No partial alpha")
            XCTAssertTrue(day.contains(Array(pixel[0..<3])), "\(pixel) is not a day tone")
        }
        // Cropped to the tent: its pixels reach both edges of the square's long axis.
        let points = mark.indices.filter { mark[$0][3] != 0 }.map { ($0 % side, $0 / side) }
        let width = (points.map(\.0).max() ?? 0) - (points.map(\.0).min() ?? 0) + 1
        let height = (points.map(\.1).max() ?? 0) - (points.map(\.1).min() ?? 0) + 1
        XCTAssertEqual(max(width, height), side, "The square is the tent's own bounding box, padded")
        XCTAssertGreaterThan(opaque.count, side * side / 3, "The tent fills most of its frame")
        let night = try XCTUnwrap(AgentLandTonalArtwork.recolour(image, ramp: .night))
        XCTAssertEqual(rgba(night).map { $0[3] }, mark.map { $0[3] }, "Recolouring keeps every pixel's alpha")
    }

    func testMenuBarTemplateIsAPixelExactOneXGlyphAndItsDouble() throws {
        let one = try XCTUnwrap(AgentLandBrandingResources.image("LogoMenuBar"), "LogoMenuBar.png is packaged")
        let two = try XCTUnwrap(AgentLandBrandingResources.image("LogoMenuBar-2x"), "LogoMenuBar-2x.png is packaged")
        XCTAssertEqual([one.width, one.height], [22, 22])
        XCTAssertEqual([two.width, two.height], [44, 44])
        let small = rgba(one), large = rgba(two)
        XCTAssertTrue(small.allSatisfy { [0, 120, 255].contains($0[3]) }, "Only the glyph's two alpha levels and clear")
        XCTAssertTrue(small.allSatisfy { $0[0..<3].allSatisfy { $0 == 0 } }, "A template is black")
        XCTAssertGreaterThan(small.filter { $0[3] == 255 }.count, small.filter { $0[3] == 120 }.count,
                             "Mostly solid, so the bar paints it mostly white in Dark")
        for y in 0..<44 {
            for x in 0..<44 {
                XCTAssertEqual(large[y * 44 + x], small[(y / 2) * 22 + x / 2], "2x is the 1x doubled at (\(x), \(y))")
            }
        }
    }

    #if os(macOS)
    @MainActor
    func testMenuBarImageKeepsBothBitmapsAtTheirOwnSize() throws {
        let image = AgentLandMenuBarIcon.image
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 22, height: 22), "Any other size would resample the art")
        let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        XCTAssertEqual(reps.map(\.pixelsWide).sorted(), [22, 44])
        XCTAssertTrue(reps.allSatisfy { $0.size == NSSize(width: 22, height: 22) })
    }
    #endif

    private func rgba(_ image: CGImage) -> [[UInt8]] {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return stride(from: 0, to: bytes.count, by: 4).map { Array(bytes[$0..<$0 + 4]) }
    }
}
