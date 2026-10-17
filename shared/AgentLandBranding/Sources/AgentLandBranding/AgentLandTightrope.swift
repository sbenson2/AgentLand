import CoreGraphics
import Foundation

/// The tightrope rig (branding/tightrope/, TightropeRig.png): a PixelLab rope between two striped poles in the
/// riders' day tones, drawn at the tent's 2.625 points a pixel, centred on the tent and standing on the ring
/// floor in front of it. It stands in for the tent during the tightrope act.
///
/// The rope's free run between the two platforms is drawn live (`Bend`), so it gives under the wheel: the rig is
/// shown without it (`poles`) and the rope is two straight runs from the platforms down to the wheel, on the
/// riders' 0.75-point grid.
enum AgentLandTightropeArt {
    /// In rig pixels: the rope's row and its first and last columns, its free run between the platforms, and
    /// the poles' bottom row.
    struct Geometry: Decodable, Sendable {
        let ropeRow: Int, ropeStart: Int, ropeEnd: Int, ropeFreeStart: Int, ropeFreeEnd: Int, ground: Int
    }

    /// In scene points.
    struct Layout: Sendable {
        let frame: CGRect
        /// The rider's centre when its wheel (sprite row 94) is on the straight rope.
        let riderY: CGFloat
        /// Halfway along the rope.
        let middle: CGFloat
        /// Where a ball dropped from the rope lands, the height of a ball's centre resting on the floor.
        let floor: CGFloat
        /// The rope's top edge at rest.
        let ropeTop: CGFloat
        /// Where the rope leaves each platform: the free run, which gives under the wheel.
        let anchors: ClosedRange<CGFloat>
    }

    /// The rope pressed down at `contact` (the wheel's) to `depth` points below its rest, straight from each
    /// platform to there. Off the free run it stays straight.
    struct Bend: Equatable, Sendable {
        var contact: CGFloat
        var depth: CGFloat

        static let straight = Bend(contact: 0, depth: 0)

        /// How far below its rest the rope's top edge is at `x`, on the riders' 0.75-point grid.
        func drop(at x: CGFloat, layout: Layout = AgentLandTightropeArt.layout) -> CGFloat {
            let anchors = layout.anchors
            guard depth != 0, anchors.contains(contact), anchors.contains(x) else { return 0 }
            let share = x <= contact
                ? (x - anchors.lowerBound) / max(contact - anchors.lowerBound, 0.001)
                : (anchors.upperBound - x) / max(anchors.upperBound - contact, 0.001)
            return snapped(depth * min(1, share))
        }

        /// The free run as 0.75-point columns one rig pixel thick, runs of equal height merged. The column
        /// under the wheel is exactly as deep as the wheel sits.
        func columns(layout: Layout = AgentLandTightropeArt.layout) -> [CGRect] {
            let anchors = layout.anchors, step: CGFloat = 0.75
            let count = Int(((anchors.upperBound - anchors.lowerBound) / step).rounded())
            var rects: [CGRect] = []
            for index in 0..<count {
                let x = anchors.lowerBound + CGFloat(index) * step
                let under = contact >= x && contact < x + step
                let y = layout.ropeTop + (under ? drop(at: contact, layout: layout) : drop(at: x + step / 2, layout: layout))
                if let last = rects.last, last.minY == y, abs(last.maxX - x) < 1e-6 {
                    rects[rects.count - 1].size.width += step
                } else {
                    rects.append(CGRect(x: x, y: y, width: step, height: pixel))
                }
            }
            return rects
        }
    }

    static let pixel: CGFloat = 2.625
    /// The poles' feet stand on the ring floor here, in front of the tent.
    static let floorY: CGFloat = 340
    static let image = AgentLandBrandingResources.image("TightropeRig")
    static let nightImage = image.flatMap { AgentLandTonalArtwork.recolour($0, ramp: .night) }
    static let geometry = AgentLandBrandingResources.json("TightropeRig", as: Geometry.self)
    /// The rig without the rope's free run, which the scene draws bent under the wheel.
    static let poles = image.flatMap(withoutFreeRope)
    static let nightPoles = poles.flatMap { AgentLandTonalArtwork.recolour($0, ramp: .night) }
    /// The rope's tone: the rig's dark fill.
    static let ropeTone = 2

    static func image(_ ramp: AgentLandClownRamp) -> CGImage? { ramp == .day ? image : nightImage }
    static func poles(_ ramp: AgentLandClownRamp) -> CGImage? { ramp == .day ? poles : nightPoles }

    private static var rig: Geometry {
        geometry ?? Geometry(ropeRow: 14, ropeStart: 13, ropeEnd: 137, ropeFreeStart: 29, ropeFreeEnd: 122, ground: 93)
    }

    static let layout: Layout = {
        let width = CGFloat(image?.width ?? 152) * pixel, height = CGFloat(image?.height ?? 96) * pixel
        let top = floorY - CGFloat(rig.ground + 1) * pixel
        let frame = CGRect(x: 168 - width / 2, y: top, width: width, height: height)
        let rope = top + CGFloat(rig.ropeRow) * pixel
        return Layout(frame: frame, riderY: rope - (94 - 48) * 0.75,
                      middle: frame.minX + CGFloat(rig.ropeStart + rig.ropeEnd + 1) / 2 * pixel,
                      floor: floorY - 1.5, ropeTop: rope,
                      anchors: (frame.minX + CGFloat(rig.ropeFreeStart) * pixel)...(frame.minX + CGFloat(rig.ropeFreeEnd + 1) * pixel))
    }()

    /// Scene lengths on the riders' 0.75-point pixel grid.
    static func snapped(_ value: CGFloat) -> CGFloat { (value / 0.75).rounded() * 0.75 }

    private static func withoutFreeRope(_ source: CGImage) -> CGImage? {
        guard var bytes = AgentLandClownArtwork.rgbaBytes(source) else { return nil }
        let row = rig.ropeRow
        for x in rig.ropeFreeStart...rig.ropeFreeEnd where row < source.height && x < source.width {
            let offset = (row * source.width + x) * 4
            bytes.replaceSubrange(offset..<offset + 4, with: [0, 0, 0, 0])
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: source.width, height: source.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: source.width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
