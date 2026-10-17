import CoreGraphics
import Foundation

/// The tent's breathing loop (branding/tent-loop.json): PixelLab frames of the still tent (the logo's sprite,
/// branding/tent-home.json) in which, once a loop, the roof's slopes lift by about a pixel and settle, and the
/// pennant flutters every frame, while the valance and its scallops, the walls, curtains and doorway keep the
/// still's pixels (calmed on 2026-10-13). scripts/package-tent.swift writes the marks and a depth mask per frame
/// in playback order; the loop runs on the circus clock, one frame per 0.1 s, four 0.3 s beats a loop.
enum AgentLandTentLoop {
    struct Artwork {
        let marks: [CGImage]
        let depths: [CGImage]
        let frameDuration: TimeInterval
        /// The loop frame that is the still mark (TentMark.png).
        let stillFrame: Int
    }

    static let artwork: Artwork? = {
        struct Info: Decodable { let frameDuration: Double; let frames: Int; let stillFrame: Int }
        let marks = AgentLandBrandingResources.squareStrip("TentLoop")
        let depths = AgentLandBrandingResources.squareStrip("TentLoopDepth")
        guard let info = AgentLandBrandingResources.json("TentLoop", as: Info.self), info.frameDuration > 0,
              marks.count == info.frames, depths.count == info.frames, info.frames > 0,
              (0..<info.frames).contains(info.stillFrame) else { return nil }
        return Artwork(marks: marks, depths: depths, frameDuration: info.frameDuration, stillFrame: info.stillFrame)
    }()

    static var frameCount: Int { artwork?.marks.count ?? 0 }
    static var frameDuration: TimeInterval { artwork?.frameDuration ?? 0.1 }
    static var loopDuration: TimeInterval { frameDuration * Double(max(1, frameCount)) }

    /// The loop frame shown `elapsed` seconds into the circus clock.
    static func frameIndex(at elapsed: TimeInterval) -> Int {
        guard frameCount > 0, elapsed > 0 else { return 0 }
        return Int((elapsed / frameDuration).rounded(.down)) % frameCount
    }
}

/// The tent's still images, decoded once. They live outside the views (whose statics belong to the main
/// actor), so `AgentLandCircusLoading.prepareArtwork()` can decode them off the main thread.
enum AgentLandTentArt {
    static let mark = AgentLandBrandingResources.image("TentMark")
    /// The doorway: a hole in the mark, filled with a fixed dark shade.
    static let doorway = AgentLandBrandingResources.image("TentDoorway")
    /// Everything the outside cannot reach: hides a clown behind the tent.
    static let depth = AgentLandBrandingResources.image("TentDepthMask")
    static let tone = AgentLandBrandingResources.image("TentTone")
    static let nightTone = tone.flatMap { AgentLandTonalArtwork.recolour($0, ramp: .night) }
    static let toneLoop = AgentLandBrandingResources.squareStrip("TentToneLoop")
    static let nightToneLoop = toneLoop.compactMap { AgentLandTonalArtwork.recolour($0, ramp: .night) }
    static let geometry = AgentLandBrandingResources.json("TentGeometry", as: Geometry.self)

    /// One sprite pixel of the tent in scene points: the logo's 101-pixel-wide tent is about 215 pt wide, the
    /// width of the big top it replaced (branding/tent-home.json).
    static let pointsPerPixel: CGFloat = 2.125
    /// The 336 × 360 scene's centre, where the tent's square is centred.
    static let sceneCenter = CGPoint(x: 168, y: 180)
    /// Where the packaged square (TentTone, TentMark, the doorway and the depth masks) sits in the scene.
    static let sceneRect = geometry?.sceneRect ?? Geometry.sceneRect(side: 113)

    struct Geometry: Decodable, Sendable {
        /// The packaged images' side in sprite pixels.
        let side: Int
        let minX: Int, maxX: Int, minY: Int, maxY: Int, pixels: Int, fixedFirstRow: Int

        static func sceneRect(side: Int) -> CGRect {
            let points = CGFloat(side) * AgentLandTentArt.pointsPerPixel
            return CGRect(x: AgentLandTentArt.sceneCenter.x - points / 2, y: AgentLandTentArt.sceneCenter.y - points / 2,
                          width: points, height: points)
        }

        var sceneRect: CGRect { Self.sceneRect(side: side) }
        /// The doorway's bottom edge in scene points: the wheel stands on it.
        var threshold: CGFloat { sceneRect.minY + CGFloat(maxY + 1) * AgentLandTentArt.pointsPerPixel }
        /// The clown's centre with its wheel (row 94 of its 96, centre row 48, 0.75 pt a pixel) on the threshold,
        /// in the middle of the opening.
        var doorCenter: CGPoint {
            CGPoint(x: sceneRect.minX + CGFloat(minX + maxX + 1) / 2 * AgentLandTentArt.pointsPerPixel,
                    y: threshold - (94 - 48) * 0.75)
        }
    }

    static func tonal(frame: Int?, ramp: AgentLandClownRamp) -> CGImage? {
        let frames = ramp == .day ? toneLoop : nightToneLoop
        if let frame, frames.indices.contains(frame) { return frames[frame] }
        return ramp == .day ? tone : nightTone
    }
}

/// Decodes the circus's art once, in a detached utility-priority task: the balls, the tent loop, the tent's still
/// images, the rope, the title's letters and, last, the clown designs (their ride strips, fills and juggling).
/// Each is a `static let`, so whichever caller comes first decodes it and the rest wait for that one decode;
/// started early, it keeps the decoding off the main thread when Home is revealed. The quick art goes first, so
/// the main thread finds it ready; the designs take seconds in a debug build, and the views never wait for them
/// (`AgentLandClownArtwork.prepared`).
enum AgentLandCircusArtworkPreparation {
    static let task = Task.detached(priority: .utility) {
        _ = AgentLandJugglingBall.frames
        _ = AgentLandJugglingBall.ring
        _ = AgentLandJugglingBall.tintedFrames
        _ = AgentLandTentLoop.artwork
        _ = AgentLandTentArt.mark
        _ = AgentLandTentArt.doorway
        _ = AgentLandTentArt.depth
        _ = AgentLandTentArt.nightTone
        _ = AgentLandTentArt.nightToneLoop
        _ = AgentLandTentArt.geometry
        _ = AgentLandTightropeArt.nightImage
        _ = AgentLandTightropeArt.nightPoles
        _ = AgentLandTightropeArt.layout
        _ = WordmarkArtwork.shared
        _ = WordmarkFontSet.shared
        _ = AgentLandClownArtwork.designs
    }
}
