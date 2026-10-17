import CoreGraphics
import XCTest
@testable import AgentLandBranding

final class ClownMotionTests: XCTestCase {
    func testSixDesignsArePackagedWithSeventyTwoFramesAndPalms() {
        XCTAssertEqual(AgentLandClownArtwork.designs.map(\.name), AgentLandClownArtwork.designNames)
        for design in AgentLandClownArtwork.designs {
            XCTAssertEqual(design.frameCount, 72, design.name)
            XCTAssertEqual(design.juggling.rig.rightPalm.count, 72, design.name)
            XCTAssertEqual(design.juggling.rig.leftPalm.count, 72, design.name)
        }
    }

    func testRideLoopTimingShowsEachFrameOnce() {
        XCTAssertEqual(AgentLandClownArtwork.framesPerRide, 72)
        XCTAssertEqual(AgentLandClownMotion.frameDuration, 1.0 / 60.0, accuracy: 1e-12)
        XCTAssertEqual(AgentLandClownMotion.framesPerBeat, 18)
        XCTAssertEqual(AgentLandClownMotion.beat, 0.3, accuracy: 1e-12)
        for design in AgentLandClownArtwork.designs {
            XCTAssertEqual(design.loopDuration, 1.2, accuracy: 1e-9)
            XCTAssertEqual((0..<72).map { AgentLandClownMotion.frameIndex(at: (Double($0) + 0.5) / 60, frameCount: 72) }, Array(0..<72))
        }
    }

    func testWheelIsLowestOpaqueSilhouette() {
        var sharedRow: Int?
        for design in AgentLandClownArtwork.designs {
            for frame in design.dayFrames {
                let bytes = (try? XCTUnwrap(AgentLandClownArtwork.rgbaBytes(frame))) ?? []
                let rows = (0..<frame.height).filter { row in
                    (0..<frame.width).contains { bytes[(row * frame.width + $0) * 4 + 3] > 0 }
                }
                let row = try? XCTUnwrap(rows.max())
                if let row { sharedRow = sharedRow ?? row; XCTAssertEqual(row, sharedRow, "\(design.name): wheel remains planted") }
            }
        }
    }
}
