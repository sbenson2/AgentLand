import CoreGraphics
import ImageIO
import XCTest
@testable import AgentLandBranding

final class TonalArtworkTests: XCTestCase {
    func testLauncherTitleHasBroadLettersOnAShallowArch() throws {
        let art = try XCTUnwrap(WordmarkArtwork.shared)
        XCTAssertGreaterThanOrEqual(art.capHeight, 48)
        XCTAssertLessThan(AgentLandWordmarkGeometry.sweep, 50 * .pi / 180)
        XCTAssertGreaterThan(art.canvas.width, 460)
        XCTAssertGreaterThan(art.canvas.width / art.canvas.height, 4.5)
    }

    func testTentUsesTheClownsFiveDayTonesWithAnOpaquePixelGrid() throws {
        let tent = try XCTUnwrap(AgentLandBrandingResources.image("TentTone"))
        let clown = try XCTUnwrap(AgentLandClownArtwork.designs.first)
        let palette = Set(try XCTUnwrap(clown.tones[.day]).map { $0.map(String.init).joined(separator: ",") })
        let bytes = rgba(tent)
        var seen = Set<String>()
        for offset in stride(from: 0, to: bytes.count, by: 4) where bytes[offset + 3] > 0 {
            XCTAssertEqual(bytes[offset + 3], 255, "No partial alpha at a pixel edge")
            let colour = bytes[offset..<offset + 3].map(String.init).joined(separator: ",")
            XCTAssertTrue(palette.contains(colour), "Tent colour \(colour) belongs to the shared ramp")
            seen.insert(colour)
        }
        XCTAssertEqual(seen, palette, "Roof, curtains and walls use the full five-tone ramp")
    }

    func testTonalLoopAndDepthFramesStayAlignedAndKeepTheDoorOpen() throws {
        let tones = AgentLandBrandingResources.squareStrip("TentToneLoop")
        let loop = try XCTUnwrap(AgentLandTentLoop.artwork)
        let door = rgba(try XCTUnwrap(AgentLandTentArt.doorway))
        XCTAssertEqual(tones.count, loop.marks.count)
        for (index, frame) in tones.enumerated() {
            let pixels = rgba(frame), mark = rgba(loop.marks[index]), depth = rgba(loop.depths[index])
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                if mark[offset + 3] > 0 { XCTAssertEqual(pixels[offset + 3], 255, "Frame \(index) keeps every outline pixel") }
                if pixels[offset + 3] > 0 { XCTAssertEqual(depth[offset + 3], 255) }
                if door[offset + 3] > 0 { XCTAssertEqual(pixels[offset + 3], 0, "Frame \(index) doorway stays open") }
            }
        }
    }

    func testNightRampPreservesEveryTonalPixelAndItsAlpha() throws {
        let clown = try XCTUnwrap(AgentLandClownArtwork.designs.first)
        let day = try XCTUnwrap(clown.tones[.day]), night = try XCTUnwrap(clown.tones[.night])
        let tentFrames = AgentLandBrandingResources.squareStrip("TentToneLoop")
        let glyphs = try XCTUnwrap(WordmarkArtwork.shared).glyphs
        let images = tentFrames + glyphs.compactMap { $0.tonalImage(ramp: .day) }
        for source in images {
            let dark = try XCTUnwrap(AgentLandTonalArtwork.recolour(source, ramp: .night))
            XCTAssertEqual(dark.width, source.width)
            XCTAssertEqual(dark.height, source.height)
            let original = rgba(source), recoloured = rgba(dark)
            for offset in stride(from: 0, to: original.count, by: 4) {
                XCTAssertEqual(recoloured[offset + 3], original[offset + 3], "Palette changes preserve geometry")
                guard original[offset + 3] > 0 else { continue }
                let index = try XCTUnwrap(day.firstIndex(of: Array(original[offset..<offset + 3])))
                XCTAssertEqual(Array(recoloured[offset..<offset + 3]), night[index])
            }
        }
    }

    /// Only the darkest opening is cut: every doorway pixel is the logo sprite's darkest tone (the same weighted
    /// mapping as scripts/package-logo.py), so the shaded curtains remain.
    func testDoorwayDoesNotEraseTheShadedCurtains() throws {
        let branding = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("branding")
        struct Record: Decodable { struct Crop: Decodable { let x: Int, y: Int }; let crop: Crop }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: branding.appendingPathComponent("tent-home.json")))
        let url = branding.appendingPathComponent("tent-logo-pixellab-source.png")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil)), 0, nil))
        let original = rgba(image)
        let doorImage = try XCTUnwrap(AgentLandTentArt.doorway)
        let door = rgba(doorImage)
        let palette = try XCTUnwrap(AgentLandClownArtwork.designs.first?.tones[.day])
        for offset in stride(from: 0, to: door.count, by: 4) where door[offset + 3] > 0 {
            let pixel = offset / 4
            let x = pixel % doorImage.width + record.crop.x, y = pixel / doorImage.width + record.crop.y
            let source = (y * image.width + x) * 4
            let closest = palette.indices.min { a, b in
                func distance(_ i: Int) -> Double {
                    zip([0.3, 0.59, 0.11], 0..<3).reduce(0) { $0 + $1.0 * pow(Double(Int(original[source + $1.1]) - Int(palette[i][$1.1])), 2) }
                }
                return distance(a) < distance(b)
            }
            XCTAssertEqual(closest, 0, "Only the darkest opening is cut; shaded curtains remain")
        }
    }

    func testClownEntranceUsesThePackagedDoorwayThreshold() throws {
        let doorImage = try XCTUnwrap(AgentLandTentArt.doorway)
        let door = rgba(doorImage), side = doorImage.width
        let rect = AgentLandTentArt.sceneRect, scale = AgentLandTentArt.pointsPerPixel
        XCTAssertEqual(rect.width, CGFloat(side) * scale, accuracy: 0.001, "The packaged square at the tent's pixel size")
        XCTAssertEqual(rect.midX, 168, accuracy: 0.001); XCTAssertEqual(rect.midY, 180, accuracy: 0.001)
        let pixels = stride(from: 0, to: door.count, by: 4).filter { door[$0 + 3] > 0 }.map { $0 / 4 }
        let bottomRow = try XCTUnwrap(pixels.map { $0 / side }.max())
        XCTAssertEqual(AgentLandCircusChoreography.threshold, rect.minY + CGFloat(bottomRow + 1) * scale, accuracy: 0.001)
        let xs = pixels.map { $0 % side }
        let left = rect.minX + CGFloat(try XCTUnwrap(xs.min())) * scale
        let right = rect.minX + CGFloat(try XCTUnwrap(xs.max()) + 1) * scale
        XCTAssertEqual(AgentLandCircusChoreography.doorCenter.x, (left + right) / 2, accuracy: 0.001)
        XCTAssertEqual(AgentLandCircusChoreography.doorCenter.y + 34.5, AgentLandCircusChoreography.threshold, accuracy: 0.001)
    }

    /// The logo's tent keeps about the old big top's size in the scene (215.25 × 207.4 pt, its lowest pixel at
    /// y 285), centred under the title.
    func testTheTentKeepsTheOldBigTopsSizeAndGround() throws {
        let tone = try XCTUnwrap(AgentLandTentArt.tone)
        let bytes = rgba(tone), side = tone.width
        let opaque = (0..<(side * side)).filter { bytes[$0 * 4 + 3] > 0 }
        let door = rgba(try XCTUnwrap(AgentLandTentArt.doorway))
        let silhouette = opaque + (0..<(side * side)).filter { door[$0 * 4 + 3] > 0 }
        let rect = AgentLandTentArt.sceneRect, scale = AgentLandTentArt.pointsPerPixel
        let minX = rect.minX + CGFloat(try XCTUnwrap(silhouette.map { $0 % side }.min())) * scale
        let maxX = rect.minX + CGFloat(try XCTUnwrap(silhouette.map { $0 % side }.max()) + 1) * scale
        let maxY = rect.minY + CGFloat(try XCTUnwrap(silhouette.map { $0 / side }.max()) + 1) * scale
        XCTAssertEqual(maxX - minX, 215.25, accuracy: 215.25 * 0.05, "About the old big top's width")
        XCTAssertEqual((minX + maxX) / 2, 168, accuracy: 1.5, "Centred in the scene, under the title")
        XCTAssertEqual(maxY, 285, accuracy: 2, "On the old big top's ground line")
    }

    private func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}
