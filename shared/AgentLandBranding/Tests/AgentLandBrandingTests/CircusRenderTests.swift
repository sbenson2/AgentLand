import SwiftUI
import ImageIO
import XCTest
#if os(macOS)
import AppKit
#endif
@testable import AgentLandBranding

/// The circus art is decoded off the main thread before Home is revealed.
final class CircusPreparationTests: XCTestCase {
    /// `prepareArtwork()` returns at once and starts one decode however often it is called; afterwards the
    /// designs, the tent loop and the title are ready.
    func testPreparingTheArtworkTwiceIsSafe() async {
        let start = Date()
        AgentLandCircusLoading.prepareArtwork()
        AgentLandCircusLoading.prepareArtwork()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.01, "It only starts the work")
        let first = AgentLandCircusArtworkPreparation.task
        AgentLandCircusLoading.prepareArtwork()
        XCTAssertEqual(first, AgentLandCircusArtworkPreparation.task, "One task, however often it is called")
        await first.value
        await Task.detached { AgentLandCircusLoading.prepareArtwork() }.value
        XCTAssertEqual(AgentLandClownArtwork.designs.count, 6)
        XCTAssertNotNil(AgentLandTentLoop.artwork)
        XCTAssertNotNil(AgentLandTentArt.mark)
        XCTAssertNotNil(AgentLandTentArt.depth)
        XCTAssertNotNil(WordmarkArtwork.shared)
    }

    /// The views read the designs through `prepared`, which never waits for the decode: a main-thread read of
    /// `designs` while the decode ran held the main thread for the whole decode (batch 5's stall).
    func testPreparedDesignsNeverWaitForTheDecode() async throws {
        let decode = Task.detached(priority: .utility) { AgentLandClownArtwork.designs }
        try await Task.sleep(for: .milliseconds(50))
        let start = Date()
        for _ in 0..<1_000 { _ = AgentLandClownArtwork.prepared }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1, "Read at once, decoded or not")
        let designs = await decode.value
        let prepared = try XCTUnwrap(AgentLandClownArtwork.prepared, "Published once decoded")
        XCTAssertEqual(prepared.designs.map(\.name), designs.map(\.name))
        XCTAssertLessThanOrEqual(prepared.at, Date())
    }

    /// Designs decoded after the reveal start the show then, seeded by the reveal, so the first clown still curls
    /// out of the doorway; designs ready before it change nothing.
    @MainActor
    func testDesignsDecodedAfterTheRevealStartTheShowThen() {
        let designs = AgentLandClownArtwork.designs
        let reference = Date(timeIntervalSinceReferenceDate: 780_000_000)
        let reveal = reference.addingTimeInterval(10)
        let late = CircusStage().choreography(reveal: reveal, start: reveal.addingTimeInterval(4), referenceDate: reference,
                                              designs: designs, now: reveal.addingTimeInterval(5))
        XCTAssertEqual(late.reveal, 14, accuracy: 1e-9)
        XCTAssertEqual(late.seed, AgentLandCircusChoreography.seed(for: reveal))
        let onTime = CircusStage().choreography(reveal: reveal, referenceDate: reference, designs: designs,
                                                now: reveal.addingTimeInterval(5))
        XCTAssertEqual(onTime.reveal, 10, accuracy: 1e-9)
        XCTAssertEqual(onTime.seed, late.seed)
    }
}

/// The work surface's SwiftUI scene, rendered by SwiftUI itself: a clown is out on the ring only when motion
/// is allowed; Reduce Motion shows the still tent, while pausing keeps the selected stage without a clown.
@MainActor
final class CircusRenderTests: XCTestCase {
    private typealias C = AgentLandCircusChoreography
    /// A work surface renders its whole stage, centred on the 336-point scene: scene x is pixel x less the inset.
    private let width = Int(AgentLandCircusLoading.stageSize.width)
    private var inset: Int { (width - 336) / 2 }

    /// A visible moment just after the outward curl joins the near half of the ring.
    private struct Moment { let reference: Date; let revealedAt: Date; let elapsed: Double; let centre: CGPoint }

    private func moment() throws -> Moment {
        #if os(macOS)
        _ = NSApplication.shared // the view reads NSApp's activity on macOS
        #endif
        // A future reference keeps fixed preview times outside the old-reveal catch-up path.
        let reference = Date(timeIntervalSinceReferenceDate: 4_000_000_000)
        let revealedAt = reference.addingTimeInterval(10)
        let show = C(reveal: 10, seed: C.seed(for: revealedAt))
        let first = try XCTUnwrap(show.appearance(at: 11))
        let elapsed = first.join + 0.1
        let state = try XCTUnwrap(show.state(at: elapsed))
        XCTAssertEqual(state.layer, .front)
        return Moment(reference: reference, revealedAt: revealedAt, elapsed: elapsed, centre: state.center)
    }

    private func render(_ moment: Moment, showsClown: Bool = true, animated: Bool = true, reduceMotion: Bool = false,
                        backdrop: Color = .black, mark: Color = .white, tonalArt: Bool = false, scale: CGFloat = 1,
                        writeTo: URL? = nil) throws -> [UInt8] {
        #if os(macOS)
        _ = NSApplication.shared
        #endif
        let scene = AgentLandCircusLoading(fixedElapsed: moment.elapsed, forceReduceMotion: reduceMotion, showsClown: showsClown,
                                           animated: animated, markColor: mark, workSurface: true,
                                           referenceDate: moment.reference, backdrop: backdrop, revealedAt: moment.revealedAt, tonalArt: tonalArt)
        // On a background of the backdrop's colour the depth mask draws nothing visible: only the clown differs.
        let renderer = ImageRenderer(content: scene.background(backdrop))
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.cgImage, "SwiftUI renders the scene")
        XCTAssertEqual(image.width, width * Int(scale)); XCTAssertEqual(image.height, 360 * Int(scale))
        if let writeTo {
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(writeTo as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        guard scale == 1 else { return [] }
        var bytes = [UInt8](repeating: 0, count: width * 360 * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: 360, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: 360))
        }
        return bytes
    }

    /// Scene points (y down) of the pixels that differ.
    private func differences(_ a: [UInt8], _ b: [UInt8]) -> [CGPoint] {
        (0..<(width * 360)).compactMap { index in
            let offset = index * 4
            let same = (0..<3).allSatisfy { abs(Int(a[offset + $0]) - Int(b[offset + $0])) < 8 }
            return same ? nil : CGPoint(x: index % width - inset, y: index / width)
        }
    }

    /// Native SwiftUI scene frames include the actual portal masks, not a separate preview compositor.
    func testWriteNativeSpiralSequence() throws {
        guard let directory = ProcessInfo.processInfo.environment["AGENTLAND_SPIRAL_EVIDENCE"] else {
            throw XCTSkip("Set AGENTLAND_SPIRAL_EVIDENCE to render the native spiral sequence")
        }
        let base = try moment()
        let show = C(reveal: base.revealedAt.timeIntervalSince(base.reference), seed: C.seed(for: base.revealedAt))
        let first = try XCTUnwrap(show.appearance(at: base.elapsed))
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        for (name, start, end) in [("native-outward", first.emerge, first.join + 0.7),
                                   ("native-inward", first.turn - 0.7, first.gone)] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let count = Int(ceil((end - start) * 30))
            for step in 0...count {
                let time = min(end, start + Double(step) / 30)
                let state = C.state(of: first, at: time)
                let sample = Moment(reference: base.reference, revealedAt: base.revealedAt, elapsed: time, centre: state.center)
                let paper = Color(.sRGB, red: 244 / 255, green: 240 / 255, blue: 231 / 255)
                let ink = Color(.sRGB, red: 53 / 255, green: 64 / 255, blue: 82 / 255)
                let pixels = try render(sample, backdrop: paper, mark: ink, tonalArt: true,
                                        writeTo: folder.appendingPathComponent(String(format: "frame-%03d.png", step)))
                if state.opacity > 0.1 {
                    let bare = try render(sample, showsClown: false, backdrop: paper, mark: ink, tonalArt: true)
                    let riderBounds = CGRect(x: state.center.x - 36, y: state.center.y - 36, width: 72, height: 72)
                    let riderPixels = differences(pixels, bare).filter { riderBounds.contains($0) }
                    XCTAssertGreaterThan(riderPixels.count, 20, "The rider stays visible at \(name) frame \(step)")
                }
            }
        }
    }

    /// Native SwiftUI frames, at 30 a second and twice the scene's scale, of the first whole tightrope act in each
    /// style on a tightrope reveal, from just before the clown comes out to just after it has gone:
    /// `<style>-act/frame-NNNN.png`, with each act's plan.
    func testWriteNativeTightropeSequence() throws {
        guard let directory = ProcessInfo.processInfo.environment["AGENTLAND_TIGHTROPE_EVIDENCE"] else {
            throw XCTSkip("Set AGENTLAND_TIGHTROPE_EVIDENCE to render the native tightrope acts")
        }
        let base = try moment()
        // A reveal whose own draw is the tightrope, as the scene draws it.
        let revealedAt = try XCTUnwrap((0..<500).lazy.map { base.revealedAt.addingTimeInterval(Double($0) / 1000) }
            .first { C(reveal: $0.timeIntervalSince(base.reference), seed: C.seed(for: $0)).tightrope })
        let show = C(reveal: revealedAt.timeIntervalSince(base.reference), seed: C.seed(for: revealedAt))
        let acts = show.appearances(through: 3600).filter { $0.act != .ring }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let paper = Color(.sRGB, red: 244 / 255, green: 240 / 255, blue: 231 / 255)
        let ink = Color(.sRGB, red: 53 / 255, green: 64 / 255, blue: 82 / 255)
        var plans: [String] = []
        for turning in [false, true] {
            let act = try XCTUnwrap(acts.first { $0.act == .rope(turning: turning) })
            let name = "\(turning ? "turning" : "backward")-act"
            plans.append("\(name): \(act.ropeRuns) beats, out at \(act.join - show.reveal) s after the reveal")
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let start = act.emerge - 0.1, end = act.gone + 0.1
            for step in 0...Int(ceil((end - start) * 30)) {
                let sample = Moment(reference: base.reference, revealedAt: revealedAt, elapsed: start + Double(step) / 30,
                                    centre: .zero)
                _ = try render(sample, backdrop: paper, mark: ink, tonalArt: true, scale: 2,
                               writeTo: folder.appendingPathComponent(String(format: "frame-%04d.png", step)))
            }
        }
        try plans.joined(separator: "\n").write(to: root.appendingPathComponent("plans.txt"), atomically: true, encoding: .utf8)
    }

    func testMotionShowsTheClownOnTheRing() throws {
        let moment = try moment()
        let clown = try render(moment)
        let bare = try render(moment, showsClown: false)
        let changed = differences(clown, bare)
        XCTAssertGreaterThan(changed.count, 300, "The rider's pixels are drawn")
        // They are the clown's: within its sprite, and its balls above it.
        for point in changed {
            XCTAssertLessThanOrEqual(abs(point.x - moment.centre.x), 40, "Pixel \(point) is not the clown's")
            XCTAssertTrue((moment.centre.y - 80...moment.centre.y + 40).contains(point.y), "Pixel \(point) is not the clown's")
        }
    }

    /// SwiftUI draws the rider in the tones of the backdrop it resolves: the day ramp on the paper, the night ramp on
    /// slate, never tinted with the tent's colour. Tones 2-4 tell the ramps apart (white is in both).
    func testTheRiderIsDrawnInTheBackdropsRamp() throws {
        let moment = try moment()
        let design = try XCTUnwrap(AgentLandClownArtwork.designs.first)
        let day = try XCTUnwrap(design.tones[.day]), night = try XCTUnwrap(design.tones[.night])
        func colour(_ hex: UInt32) -> Color {
            Color(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
        }
        for (paper, mark, own, other) in [(UInt32(0xF4F0E7), UInt32(0x354052), day, night), (0x27313F, 0xD6DDE7, night, day)] {
            let clown = try render(moment, backdrop: colour(paper), mark: colour(mark))
            let bare = try render(moment, showsClown: false, backdrop: colour(paper), mark: colour(mark))
            var matches = [0, 0]
            for point in differences(clown, bare) {
                let offset = (Int(point.y) * width + Int(point.x) + inset) * 4
                let pixel = (0..<3).map { Int(clown[offset + $0]) }
                for (slot, ramp) in [own, other].enumerated() where ramp[1...3].contains(where: { tone in
                    (0..<3).allSatisfy { abs(Int(tone[$0]) - pixel[$0]) <= 2 }
                }) { matches[slot] += 1 }
            }
            XCTAssertGreaterThan(matches[0], 200, String(format: "#%06X: the rider's fills are this backdrop's tones", paper))
            XCTAssertEqual(matches[1], 0, String(format: "#%06X: none are the other ramp's", paper))
        }
    }

    func testReduceMotionShowsTheStillTentAndNoClown() throws {
        let moment = try moment()
        let still = try render(moment, showsClown: false, animated: false)
        let reduced = try render(moment, reduceMotion: true)
        XCTAssertTrue(differences(reduced, still).isEmpty, "Reduce Motion: the still tent, no clown")
        XCTAssertFalse(differences(try render(moment), still).isEmpty, "Motion changes the picture")
    }

    func testPausedTightropeKeepsItsStage() throws {
        #if os(macOS)
        _ = NSApplication.shared
        #endif
        _ = AgentLandClownArtwork.designs
        let reference = Date(timeIntervalSinceReferenceDate: 4_000_000_000)
        let reveal = try XCTUnwrap((10...100).map { reference.addingTimeInterval(Double($0)) }
            .first { C(reveal: $0.timeIntervalSince(reference), seed: C.seed(for: $0)).tightrope })
        let moment = Moment(reference: reference, revealedAt: reveal,
                            elapsed: reveal.timeIntervalSince(reference) + 5, centre: .zero)
        let paused = try render(moment, animated: false)
        let tent = try render(moment, showsClown: false, animated: false)
        XCTAssertFalse(differences(paused, tent).isEmpty, "Pausing must not swap the tightrope for the tent")
    }

    private func stageMoment(tightrope: Bool, afterReveal: Double) throws -> Moment {
        #if os(macOS)
        _ = NSApplication.shared
        #endif
        let reference = Date(timeIntervalSinceReferenceDate: 4_000_000_000)
        // Choosing a stage must not itself decode the clown sprites.
        let reveal = try XCTUnwrap((10...100).map { reference.addingTimeInterval(Double($0)) }
            .first { C(reveal: 0, seed: C.seed(for: $0), jugglings: []).tightrope == tightrope })
        return Moment(reference: reference, revealedAt: reveal,
                      elapsed: reveal.timeIntervalSince(reference) + afterReveal, centre: .zero)
    }

    func testStageBeforeClownDecodeMatchesPreparedStage() throws {
        let moment = try stageMoment(tightrope: true, afterReveal: 5)
        let before = try render(moment, animated: false)
        _ = AgentLandClownArtwork.designs
        let prepared = try render(moment, animated: false)
        XCTAssertTrue(differences(before, prepared).isEmpty, "Loading performers must not change the selected stage")
    }

    func testSelectedStageIsPresentFromFirstFrame() throws {
        _ = AgentLandClownArtwork.designs
        let evidence = ProcessInfo.processInfo.environment["AGENTLAND_STAGE_EVIDENCE"].map { URL(fileURLWithPath: $0) }
        if let evidence { try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true) }
        for tightrope in [false, true] {
            let name = tightrope ? "tightrope" : "tent"
            let settled = try render(stageMoment(tightrope: tightrope, afterReveal: 5), animated: false,
                                     writeTo: evidence?.appendingPathComponent("\(name)-settled.png"))
            for elapsed in [-0.01, 0, 0.3, 0.6] {
                let initial = try render(stageMoment(tightrope: tightrope, afterReveal: elapsed), animated: false,
                                         writeTo: evidence?.appendingPathComponent("\(name)-\(elapsed).png"))
                XCTAssertTrue(differences(initial, settled).isEmpty,
                              "\(name) must be the only stage from the first frame (\(elapsed)s), without a crossfade")
            }
        }
    }

    func testPendingRevealShowsNeitherStage() throws {
        let reference = Date(timeIntervalSinceReferenceDate: 4_000_000_000)
        let pending = Moment(reference: reference, revealedAt: .distantFuture, elapsed: 10, centre: .zero)
        let pixels = try render(pending, animated: false)
        XCTAssertTrue(stride(from: 0, to: pixels.count, by: 4).allSatisfy {
            pixels[$0] == 0 && pixels[$0 + 1] == 0 && pixels[$0 + 2] == 0
        }, "Wait for the shared reveal instead of displaying a provisional stage")
    }

    func testAPausedSceneShowsTheStillTentAndNoClown() throws {
        let moment = try moment()
        let still = try render(moment, showsClown: false, animated: false)
        let paused = try render(moment, animated: false)
        XCTAssertTrue(differences(paused, still).isEmpty, "animated false: the still tent, no clown")
    }
}
