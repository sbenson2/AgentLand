import XCTest
@testable import AgentLandBranding

final class JugglingBallTests: XCTestCase {
    func testEightSpinFramesHaveTheExpectedSpriteAndAlpha() throws {
        XCTAssertEqual(AgentLandJugglingBall.frames.count, 8)
        XCTAssertEqual(AgentLandJugglingBall.tintedFrames.count, 7)
        for frame in AgentLandJugglingBall.frames {
            XCTAssertEqual(frame.width, 16); XCTAssertEqual(frame.height, 16)
            let source = try XCTUnwrap(AgentLandClownArtwork.rgbaBytes(frame))
            XCTAssertTrue(source.indices.filter { $0 % 4 == 3 }.allSatisfy { source[$0] == 0 || source[$0] == 255 })
        }
    }

    /// Owner, 2026-10-12: slightly smaller balls. The 10-pixel ball is centred in its cell and drawn at the
    /// rider's 0.75-point pixel, 7.5 points wide (it was 9).
    func testTenPixelBallIsCentredOnTheRidersPixelGrid() throws {
        XCTAssertEqual(AgentLandJugglingBall.pixelSize, 0.75)
        XCTAssertEqual(AgentLandJugglingBall.radius, 3.75)
        for (index, frame) in AgentLandJugglingBall.frames.enumerated() {
            let source = try XCTUnwrap(AgentLandClownArtwork.rgbaBytes(frame))
            let opaque = (0..<256).filter { source[$0 * 4 + 3] == 255 }
            let xs = opaque.map { $0 % 16 }, ys = opaque.map { $0 / 16 }
            XCTAssertEqual(ys.min(), 3, "frame \(index)"); XCTAssertEqual(ys.max(), 12, "frame \(index)")
            XCTAssertEqual(xs.min(), 3, "frame \(index)"); XCTAssertTrue([11, 12].contains(xs.max()!), "frame \(index)")
        }
    }

    func testTintMultipliesRgbAndPreservesAlpha() throws {
        for frameIndex in 0..<8 { for tintIndex in 0..<7 {
        let source = try XCTUnwrap(AgentLandClownArtwork.rgbaBytes(AgentLandJugglingBall.frames[frameIndex]))
        let tinted = try XCTUnwrap(AgentLandClownArtwork.rgbaBytes(AgentLandJugglingBall.tintedFrame(tint: tintIndex, spinFrame: frameIndex)!))
        let tint = AgentLandJugglingBall.tint(at: tintIndex)
        for pixel in stride(from: 0, to: source.count, by: 4) {
            XCTAssertEqual(tinted[pixel + 3], source[pixel + 3])
            XCTAssertEqual(tinted[pixel], UInt8(Int(source[pixel]) * Int(tint[0]) / 255))
            XCTAssertEqual(tinted[pixel + 1], UInt8(Int(source[pixel + 1]) * Int(tint[1]) / 255))
            XCTAssertEqual(tinted[pixel + 2], UInt8(Int(source[pixel + 2]) * Int(tint[2]) / 255))
        }
        } }
    }

    func testRingIsOnePixelOutsideEachFrameSilhouette() throws {
        for index in AgentLandJugglingBall.frames.indices {
            let source = try XCTUnwrap(AgentLandClownArtwork.rgbaBytes(AgentLandJugglingBall.frames[index]))
            let ring = try XCTUnwrap(AgentLandClownArtwork.rgbaBytes(AgentLandJugglingBall.ring[index]))
            for y in 0..<16 { for x in 0..<16 {
                let offset = (y * 16 + x) * 4
                guard ring[offset + 3] == 255 else { continue }
                XCTAssertEqual(source[offset + 3], 0, "Ring overlaps source at \(index):\(x),\(y)")
                let adjacent = (-1...1).flatMap { dy in (-1...1).compactMap { dx -> UInt8? in
                    let xx = x + dx, yy = y + dy
                    guard (0..<16).contains(xx), (0..<16).contains(yy) else { return nil }
                    return source[(yy * 16 + xx) * 4 + 3]
                }}
                XCTAssertTrue(adjacent.contains(255), "Ring pixel is not adjacent to silhouette")
            } }
        }
    }
}
