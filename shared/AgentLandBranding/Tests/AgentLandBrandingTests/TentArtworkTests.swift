import CoreGraphics
import ImageIO
import XCTest
@testable import AgentLandBranding

/// The mark, its depth mask, the doorway and the breathing loop are packaged together by
/// scripts/package-tent.swift from the logo's sprite (branding/tent-home.json); the rider's occlusion and the
/// doorway's fill depend on them lining up. Sizes come from the packaged geometry, not a fixed canvas.
final class TentArtworkTests: XCTestCase {
    /// The packaged images' side in sprite pixels.
    private var side: Int { AgentLandTentArt.geometry?.side ?? 0 }

    func testDepthMaskCoversTheMark() throws {
        let mark = try alpha("TentMark"), depth = try alpha("TentDepthMask")
        let doorway = try alpha("TentDoorway")
        for index in mark.indices where mark[index] {
            XCTAssertTrue(depth[index], "Mark pixel \(index % side),\(index / side) must be hidden behind by the depth mask")
        }
        // Every hole the outside cannot reach is filled, so the roof's white panels and the wall stripes hide
        // the rider as well as the ink does, and nothing outside the tent is.
        let tonal = try alpha("TentTone")
        let enclosed = Self.enclosed(by: zip(tonal, doorway).map { $0 || $1 }, side: side)
        let mismatched = depth.indices.filter { depth[$0] != enclosed[$0] }
        XCTAssertTrue(mismatched.isEmpty, "Depth must be exactly the enclosed tent; first mismatch at \(mismatched.first.map { "\($0 % side),\($0 / side)" } ?? "")")
        XCTAssertGreaterThan(depth.filter { $0 }.count, mark.filter { $0 }.count + doorway.filter { $0 }.count,
                             "The white panels and stripes must be filled, not only the ink")
    }

    func testDoorwayIsADarkOpeningInsideTheDepthMaskAtTheLeftFront() throws {
        let mark = try alpha("TentMark"), depth = try alpha("TentDepthMask"), doorway = try alpha("TentDoorway")
        let opening = doorway.indices.filter { doorway[$0] }
        XCTAssertGreaterThan(opening.count, 100, "The doorway must be a real opening, not a few pixels")
        for index in opening {
            XCTAssertFalse(mark[index], "Doorway pixel \(index % side),\(index / side) must be a hole in the mark so it renders dark")
            XCTAssertTrue(depth[index], "The rider must still hide behind the doorway")
        }
        // The three-quarter big top keeps its entrance at the lower left front, not centred.
        let markPixels = mark.indices.filter { mark[$0] }
        let markCentre = Double(markPixels.map { $0 % side }.reduce(0, +)) / Double(markPixels.count)
        let doorCentre = Double(opening.map { $0 % side }.reduce(0, +)) / Double(opening.count)
        let doorMiddle = Double(opening.map { $0 / side }.reduce(0, +)) / Double(opening.count)
        XCTAssertLessThan(doorCentre, markCentre - Double(side) / 10, "The doorway sits left of centre, as in the three-quarter view")
        XCTAssertGreaterThan(doorMiddle, Double(side) * 2 / 3, "The doorway is at the foot of the wall")
    }

    /// The door box is tight around the opening between the tied-back curtains (branding/tent-home.json):
    /// the curtain ties that touch the opening and the valance above it stay in the mark.
    func testDoorwayStaysInsideTheTightDoorBox() throws {
        let mark = try alpha("TentMark"), doorway = try alpha("TentDoorway")
        let opening = doorway.indices.filter { doorway[$0] }
        let geometry = try XCTUnwrap(AgentLandTentArt.geometry)
        XCTAssertEqual(opening.count, geometry.pixels)
        let columns = opening.map { $0 % side }, rows = opening.map { $0 / side }
        XCTAssertEqual(columns.min(), geometry.minX); XCTAssertEqual(columns.max(), geometry.maxX)
        XCTAssertEqual(rows.min(), geometry.minY); XCTAssertEqual(rows.max(), geometry.maxY)
        // About a fifth of the canvas is ink (2,000 of the old big top's 96 × 96).
        XCTAssertGreaterThan(mark.filter { $0 }.count, side * side / 5, "Curtains and outlines remain visible")
    }

    /// Home's tent is the logo (owner, 2026-10-12: "it needs to be the exact same pixel art"): every pixel of
    /// TentTone is the logo sprite's pixel in the crop window, mapped to the nearest day tone exactly as
    /// scripts/package-logo.py maps the logo, except the doorway, which is a hole filled at runtime.
    func testHomeTentIsTheLogoSpritePixelForPixel() throws {
        let branding = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("branding")
        struct Record: Decodable { struct Crop: Decodable { let x: Int, y: Int, side: Int }; let crop: Crop }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: branding.appendingPathComponent("tent-home.json")))
        XCTAssertEqual(record.crop.side, side)
        let logo = try Self.rgba(at: branding.appendingPathComponent("tent-logo-pixellab-source.png"))
        let tone = Self.rgba(try XCTUnwrap(AgentLandTentArt.tone)), door = try alpha("TentDoorway")
        let day = try XCTUnwrap(AgentLandClownArtwork.designs.first?.tones[.day])
        var mismatches = 0
        for index in 0..<(side * side) {
            let x = index % side + record.crop.x, y = index / side + record.crop.y
            let source = Array(logo.bytes[(y * logo.width + x) * 4..<(y * logo.width + x) * 4 + 4])
            let packaged = Array(tone[index * 4..<index * 4 + 4])
            guard source[3] >= 128 else {
                if packaged[3] != 0 { mismatches += 1 }
                continue
            }
            let nearest = day.indices.min { a, b in
                func distance(_ tone: Int) -> Double {
                    zip([0.3, 0.59, 0.11], (0..<3)).reduce(0) { $0 + $1.0 * pow(Double(Int(source[$1.1]) - Int(day[tone][$1.1])), 2) }
                }
                return distance(a) < distance(b)
            }!
            if door[index] {
                if packaged[3] != 0 || nearest != 0 { mismatches += 1 }
            } else if packaged != day[nearest] + [255] {
                mismatches += 1
            }
        }
        XCTAssertEqual(mismatches, 0, "Home's tent is the logo's pixels")
        // The crop removes only clear pixels.
        let inkOutside = (0..<(logo.width * logo.height)).filter { index in
            let x = index % logo.width, y = index / logo.width
            return logo.bytes[index * 4 + 3] >= 128
                && !((record.crop.x..<record.crop.x + side).contains(x) && (record.crop.y..<record.crop.y + side).contains(y))
        }
        XCTAssertTrue(inkOutside.isEmpty, "The crop window holds the whole logo")
    }

    // MARK: The breathing loop (branding/tent-loop.json)

    /// Twelve PixelLab frames at 0.1 s: one loop is four 0.3 s beats of the circus clock, like the clown's ride.
    func testTentLoopRunsTwelveFramesOnTheCircusClock() throws {
        let loop = try XCTUnwrap(AgentLandTentLoop.artwork, "TentLoop.png, TentLoopDepth.png and TentLoop.json are packaged")
        XCTAssertEqual(loop.marks.count, 12)
        XCTAssertEqual(loop.depths.count, 12)
        XCTAssertEqual(loop.frameDuration, 0.1, accuracy: 1e-9)
        XCTAssertEqual(AgentLandTentLoop.loopDuration, 1.2, accuracy: 1e-9)
        XCTAssertEqual(AgentLandTentLoop.loopDuration / AgentLandClownMotion.beat, 4, accuracy: 1e-9, "Four beats a loop")
        XCTAssertEqual((0..<24).map { AgentLandTentLoop.frameIndex(at: (Double($0) + 0.5) * 0.1) }, Array(0..<12) + Array(0..<12))
        XCTAssertEqual(AgentLandTentLoop.frameIndex(at: 0), 0)
        // One frame of the loop is the still mark itself.
        XCTAssertEqual(alpha(loop.marks[loop.stillFrame]), try alpha("TentMark"))
        XCTAssertEqual(alpha(loop.depths[loop.stillFrame]), try alpha("TentDepthMask"))
    }

    /// Only the roof and the pennant move: from the loop's fixed first row down (branding/tent-loop.json, the top
    /// of the valance) every frame is the still's pixels, so the valance and its scallops, the walls, curtains
    /// and doorway never move and the doorway's fill and the clown's door path hold.
    func testTentLoopKeepsTheValanceWallsCurtainsAndDoorwayStill() throws {
        let loop = try XCTUnwrap(AgentLandTentLoop.artwork)
        let geometry = try XCTUnwrap(AgentLandTentArt.geometry)
        // The outer scallops' top outline is row 46 of the packaged still; the doorway starts below the valance.
        let valanceTop = 46
        XCTAssertLessThanOrEqual(geometry.fixedFirstRow, valanceTop, "The fixed rows hold the valance and its scallops")
        XCTAssertLessThan(valanceTop, geometry.minY, "and the whole doorway")
        let still = try alpha("TentMark"), doorway = try alpha("TentDoorway")
        for (index, frame) in loop.marks.enumerated() {
            let mark = alpha(frame)
            let moved = (geometry.fixedFirstRow * side..<side * side).filter { mark[$0] != still[$0] }
            XCTAssertTrue(moved.isEmpty, "Loop frame \(index) moves \(moved.count) pixels below the roof, first at \(moved.first.map { "\($0 % side),\($0 / side)" } ?? "")")
            XCTAssertFalse(mark.indices.contains { mark[$0] && doorway[$0] }, "Loop frame \(index) keeps the doorway a hole")
        }
    }

    /// The roof breathes and the pennant flutters: the pennant (the rows above the roof's apex) moves in every
    /// step of the loop, the wrap included, and the roof's slopes lift by about a pixel and settle back.
    func testTheRoofBreathesAndThePennantMovesEveryFrame() throws {
        let loop = try XCTUnwrap(AgentLandTentLoop.artwork)
        let geometry = try XCTUnwrap(AgentLandTentArt.geometry)
        let marks = loop.marks.map(alpha), still = marks[loop.stillFrame]
        // The pennant and its pole are rows 6-19 of the packaged still; the roof's apex starts at row 20.
        let roofTop = 20, roof = roofTop * side..<geometry.fixedFirstRow * side
        var roofSteps: [Int] = [], roofLift: [Int] = []
        for index in marks.indices {
            let a = marks[index], b = marks[(index + 1) % marks.count]
            let flag = (0..<roofTop * side).filter { a[$0] != b[$0] }.count
            roofSteps.append(roof.filter { a[$0] != b[$0] }.count)
            roofLift.append(roof.filter { a[$0] != still[$0] }.count)
            XCTAssertGreaterThan(flag, 0, "The pennant moves from loop frame \(index)")
        }
        // Calmed on 2026-10-13 (the owner: "too strong"): at the top of the breath about 190 mark pixels differ
        // from the still, where the 2026-10-12 loop's swelling roof and dipping valance differed by 912 and its
        // steps redrew up to 383.
        XCTAssertGreaterThan(roofLift.max() ?? 0, 100, "The roof breathes visibly")
        XCTAssertLessThan(roofLift.max() ?? 0, 300, "Gently: the roof lifts by about a pixel and never swells")
        XCTAssertLessThan(roofSteps.max() ?? 0, 150, "Gently: no step redraws much of the roof")
        XCTAssertGreaterThan(Set(marks.map { $0.map { $0 ? "1" : "0" }.joined() }).count, 8,
                             "The generated breathing loop has distinct roof frames")
    }

    /// The owner asked for a much subtler breath (2026-10-13). Measured on the tonal frames as the change was
    /// judged: a pixel counts when its opacity flips or its colour moves by more than 60 in R + G + B from the
    /// still. The calm loop changes 3.4% of the tent's pixels on average and 6.7% at most; the 2026-10-12 loop
    /// changed 13% and 29%.
    func testTheBreathChangesLittleOfTheTent() throws {
        let loop = try XCTUnwrap(AgentLandTentLoop.artwork)
        let frames = AgentLandBrandingResources.squareStrip("TentToneLoop").map { Self.rgba($0) }
        XCTAssertEqual(frames.count, loop.marks.count)
        let still = frames[loop.stillFrame]
        let tent = stride(from: 0, to: still.count, by: 4).filter { still[$0 + 3] > 0 }.count
        let changed = frames.map { frame in
            stride(from: 0, to: frame.count, by: 4).filter { offset in
                guard (frame[offset + 3] > 0) == (still[offset + 3] > 0) else { return true }
                return frame[offset + 3] > 0 && (0..<3).map { abs(Int(frame[offset + $0]) - Int(still[offset + $0])) }.reduce(0, +) > 60
            }.count
        }
        let moving = changed.indices.filter { $0 != loop.stillFrame }.map { Double(changed[$0]) / Double(tent) }
        XCTAssertLessThanOrEqual(moving.reduce(0, +) / Double(moving.count), 0.06, "On average at most 6% of the tent changes")
        XCTAssertLessThanOrEqual(moving.max() ?? 1, 0.12, "No frame changes more than 12% of the tent")
        XCTAssertGreaterThan(moving.max() ?? 0, 0.03, "The pennant and the roof still move")
    }

    /// Each frame has its own depth mask: the tent that frame encloses, so a swelling roof still hides the rider.
    func testEveryLoopFrameHasItsOwnClosedDepthMask() throws {
        let loop = try XCTUnwrap(AgentLandTentLoop.artwork)
        let doorway = try alpha("TentDoorway"), stillDepth = try alpha("TentDepthMask")
        let tonalFrames = AgentLandBrandingResources.squareStrip("TentToneLoop").map(alpha)
        XCTAssertEqual(tonalFrames.count, loop.marks.count)
        // A gap in an outline would let the rider show through a roof panel: the depth keeps every still pixel
        // two or more inside the still's outline. Only the tent's body counts: the pennant, on a thin pole,
        // snaps to new places every frame.
        let deep = (0..<(side * side)).map { index -> Bool in
            let x = index % side, y = index / side
            return (-2...2).allSatisfy { dy in (-2...2).allSatisfy { dx in
                (0..<side).contains(x + dx) && (0..<side).contains(y + dy) && stillDepth[(y + dy) * side + x + dx]
            } }
        }
        let body = Self.largestRegion(of: deep, side: side)
        XCTAssertGreaterThan(body.filter { $0 }.count, deep.filter { $0 }.count * 9 / 10, "The pennant is a small part")
        for (index, depth) in loop.depths.map(alpha).enumerated() {
            let enclosed = Self.enclosed(by: zip(tonalFrames[index], doorway).map { $0 || $1 }, side: side)
            XCTAssertEqual(depth, enclosed, "Loop frame \(index)'s depth is the tent it encloses")
            let open = body.indices.filter { body[$0] && !depth[$0] }
            XCTAssertTrue(open.isEmpty, "Loop frame \(index)'s depth opens at \(open.first.map { "\($0 % side),\($0 / side)" } ?? "")")
        }
    }

    // MARK: Helpers

    /// Everything the outside cannot reach through the canvas edge (4-connected) past `solid`.
    static func enclosed(by solid: [Bool], side: Int) -> [Bool] {
        var outside = [Bool](repeating: false, count: side * side)
        var stack = (0..<side).flatMap { [($0, 0), ($0, side - 1), (0, $0), (side - 1, $0)] }
        while let (x, y) = stack.popLast() {
            guard (0..<side).contains(x), (0..<side).contains(y) else { continue }
            let index = y * side + x
            guard !outside[index], !solid[index] else { continue }
            outside[index] = true
            stack += [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
        }
        return outside.map { !$0 }
    }

    /// The largest 4-connected region of `mask`.
    static func largestRegion(of mask: [Bool], side: Int) -> [Bool] {
        var label = [Int](repeating: -1, count: mask.count), sizes: [Int] = []
        for start in mask.indices where mask[start] && label[start] < 0 {
            var stack = [start], size = 0
            label[start] = sizes.count
            while let index = stack.popLast() {
                size += 1
                let x = index % side, y = index / side
                for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
                where (0..<side).contains(nx) && (0..<side).contains(ny) && mask[ny * side + nx] && label[ny * side + nx] < 0 {
                    label[ny * side + nx] = sizes.count
                    stack.append(ny * side + nx)
                }
            }
            sizes.append(size)
        }
        guard let largest = sizes.indices.max(by: { sizes[$0] < sizes[$1] }) else { return mask }
        return label.map { $0 == largest }
    }

    static func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    static func rgba(at url: URL) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (rgba(image), image.width, image.height)
    }

    private func alpha(_ name: String) throws -> [Bool] {
        let url = try XCTUnwrap(AgentLandBrandingResources.bundle.url(forResource: name, withExtension: "png"), "\(name).png is packaged")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, side); XCTAssertEqual(image.height, side)
        return alpha(image)
    }

    private func alpha(_ image: CGImage) -> [Bool] {
        let bytes = Self.rgba(image)
        return (0..<(image.width * image.height)).map { bytes[$0 * 4 + 3] >= 128 }
    }
}
