import CoreGraphics
import Foundation
import ImageIO

/// The seven stable ball identities used by a juggling performance. The values are
/// ordered to match the brief and are intentionally separate from the clown ramps.
enum AgentLandJugglingBall {
    static let rgb: [[UInt8]] = [
        [0xE0, 0x48, 0x3C], [0xEE, 0x8A, 0x2B], [0xF2, 0xC9, 0x4C],
        [0x4F, 0xAE, 0x5C], [0x3C, 0x8B, 0xD0], [0x5A, 0x5F, 0xC2],
        [0x92, 0x57, 0xC0]
    ]

    static let spriteSide = 16
    static let frames: [CGImage] = AgentLandBrandingResources.strip("JugglingBall", side: spriteSide)

    /// A sprite pixel in scene points: the rider's 0.75-point pixel, so the 10-pixel ball is 7.5 points
    /// wide (owner, 2026-10-12: slightly smaller than the 9-point ball of 2026-10-11).
    static let pixelSize: CGFloat = 0.75
    /// The ball's radius in scene points (five sprite pixels), for its roll along the ground.
    static let radius: CGFloat = 5 * pixelSize

    static let tintedFrames: [[CGImage]] = rgb.map { colour in
        frames.compactMap { image in tinted(image, by: colour) }
    }

    /// The one-pixel backdrop ring around the complete sprite silhouette. It is
    /// derived from the packaged alpha so the runtime never makes assumptions
    /// about which spin frame has the widest silhouette.
    static let ring: [CGImage] = frames.compactMap { image in
        guard image.width == spriteSide, image.height == spriteSide,
              let bytes = rgba(image) else { return nil }
        var alpha = [Bool](repeating: false, count: spriteSide * spriteSide)
        for index in alpha.indices { alpha[index] = bytes[index * 4 + 3] > 0 }
        var output = [UInt8](repeating: 0, count: alpha.count * 4)
        for y in 0..<spriteSide {
            for x in 0..<spriteSide where !alpha[y * spriteSide + x] {
                let nearby = (max(0, y - 1)...min(spriteSide - 1, y + 1)).contains { yy in
                    (max(0, x - 1)...min(spriteSide - 1, x + 1)).contains { xx in alpha[yy * spriteSide + xx] }
                }
                if nearby {
                    let offset = (y * spriteSide + x) * 4
                    output[offset...offset + 3] = [255, 255, 255, 255]
                }
            }
        }
        return makeImage(output, side: spriteSide)
    }

    static func tint(at index: Int) -> [UInt8] { rgb[((index % rgb.count) + rgb.count) % rgb.count] }

    static func frame(for spinFrame: Int) -> CGImage? {
        guard !frames.isEmpty else { return nil }
        return frames[((spinFrame % frames.count) + frames.count) % frames.count]
    }

    static func ringFrame(for spinFrame: Int) -> CGImage? {
        guard !ring.isEmpty else { return nil }
        return ring[((spinFrame % ring.count) + ring.count) % ring.count]
    }

    static func tintedFrame(tint: Int, spinFrame: Int) -> CGImage? {
        guard !tintedFrames.isEmpty else { return nil }
        let tintIndex = ((tint % tintedFrames.count) + tintedFrames.count) % tintedFrames.count
        let frames = tintedFrames[tintIndex]
        guard !frames.isEmpty else { return nil }
        return frames[((spinFrame % frames.count) + frames.count) % frames.count]
    }

    private static func tinted(_ image: CGImage, by colour: [UInt8]) -> CGImage? {
        guard let source = rgba(image) else { return nil }
        var output = [UInt8](repeating: 0, count: image.width * image.height * 4)
        for index in 0..<(image.width * image.height) {
            let from = index * 4, to = index * 4
            output[to] = UInt8((Int(source[from]) * Int(colour[0])) / 255)
            output[to + 1] = UInt8((Int(source[from + 1]) * Int(colour[1])) / 255)
            output[to + 2] = UInt8((Int(source[from + 2]) * Int(colour[2])) / 255)
            output[to + 3] = source[from + 3]
        }
        return makeImage(output, side: image.width)
    }

    /// Cropped strip images can retain the strip's row stride and pixel layout.
    /// Decode through Core Graphics before inspecting or tinting their pixels.
    private static func rgba(_ image: CGImage) -> [UInt8]? {
        AgentLandClownArtwork.rgbaBytes(image)
    }

    private static func makeImage(_ bytes: [UInt8], side: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}
