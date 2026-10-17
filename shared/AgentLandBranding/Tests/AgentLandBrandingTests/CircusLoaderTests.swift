import CoreGraphics
import XCTest
@testable import AgentLandBranding

/// The circus loader's packaged frames (scripts/package-circus-loader.mjs) and the runs made from them.
final class CircusLoaderTests: XCTestCase {
    func testEveryObjectBouncesAndMeltsIntoEveryOther() throws {
        let manifest = try XCTUnwrap(AgentLandCircusLoaderFrames.manifest)
        XCTAssertEqual(manifest.objects.count, 10)
        XCTAssertEqual(manifest.side, 96)
        for prefix in ["CircusLoader", "CircusLoaderNight"] {
            for object in manifest.objects {
                XCTAssertEqual(AgentLandBrandingResources.strip("\(prefix)Idle-\(object)").count, manifest.idleFrames, object)
                for other in manifest.objects where other != object {
                    XCTAssertEqual(AgentLandBrandingResources.strip("\(prefix)Change-\(object)-\(other)").count, manifest.changeFrames,
                                   "\(prefix): \(object) melts into \(other)")
                }
            }
        }
    }

    func testFramesUseOnlyTheRidersTonesWithHardEdges() throws {
        let manifest = try XCTUnwrap(AgentLandCircusLoaderFrames.manifest)
        for (prefix, ramp) in [("CircusLoader", AgentLandClownRamp.day), ("CircusLoaderNight", .night)] {
            let tones = Set(try XCTUnwrap(AgentLandClownArtwork.rampTones[ramp]).map { $0.map(String.init).joined(separator: ",") })
            for name in manifest.objects.map({ "\(prefix)Idle-\($0)" }) + ["\(prefix)Change-ball-club", "\(prefix)Change-bigtop-ticket"] {
                for frame in AgentLandBrandingResources.strip(name) {
                    let bytes = try XCTUnwrap(AgentLandClownArtwork.rgbaBytes(frame))
                    for offset in stride(from: 0, to: bytes.count, by: 4) where bytes[offset + 3] > 0 {
                        XCTAssertEqual(bytes[offset + 3], 255, "\(name): no partial alpha")
                        XCTAssertTrue(tones.contains(bytes[offset..<offset + 3].map(String.init).joined(separator: ",")), "\(name): its ramp's tones")
                    }
                }
            }
        }
    }

    func testARunLoopsThroughDifferentObjectsRecolouredForItsBackdrop() throws {
        let manifest = try XCTUnwrap(AgentLandCircusLoaderFrames.manifest)
        let run = AgentLandCircusLoaderFrames.run(ramp: .night, reduceMotion: false)
        let perObject = 2 * manifest.idleFrames + manifest.changeFrames
        XCTAssertEqual(run.count, AgentLandCircusLoaderFrames.runLength * perObject)
        let night = Set(try XCTUnwrap(AgentLandClownArtwork.rampTones[.night]).map { $0.map(String.init).joined(separator: ",") })
        let bytes = try XCTUnwrap(AgentLandClownArtwork.rgbaBytes(run[0]))
        var opaque = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) where bytes[offset + 3] > 0 {
            opaque += 1
            XCTAssertTrue(night.contains(bytes[offset..<offset + 3].map(String.init).joined(separator: ",")), "Night tones on the slate cover")
        }
        XCTAssertGreaterThan(opaque, 500, "The first frame shows an object")
        // Under Reduce Motion each object rests still, one frame held for a second, with no melt.
        let still = AgentLandCircusLoaderFrames.run(ramp: .day, reduceMotion: true)
        XCTAssertEqual(still.count, AgentLandCircusLoaderFrames.runLength * Int(manifest.framesPerSecond))
    }
}
