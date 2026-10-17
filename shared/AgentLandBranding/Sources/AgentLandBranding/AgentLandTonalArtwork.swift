import CoreGraphics
import Foundation

/// All circus art uses the riders' packaged day/night ramps. Artwork stores day colours;
/// recolouring changes only palette indices, never geometry or alpha.
enum AgentLandTonalArtwork {
    static func tones(_ ramp: AgentLandClownRamp) -> [[UInt8]]? {
        AgentLandClownArtwork.rampTones[ramp]
    }

    static func image(width: Int, height: Int, indices: [UInt8], ramp: AgentLandClownRamp) -> CGImage? {
        guard indices.count == width * height, let colours = tones(ramp), colours.count == 5 else { return nil }
        var bytes = [UInt8](repeating: 0, count: indices.count * 4)
        for (index, tone) in indices.enumerated() where (1...5).contains(tone) {
            let colour = colours[Int(tone) - 1], offset = index * 4
            bytes[offset] = colour[0]; bytes[offset + 1] = colour[1]; bytes[offset + 2] = colour[2]; bytes[offset + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func recolour(_ source: CGImage, ramp: AgentLandClownRamp) -> CGImage? {
        if ramp == .day { return source }
        guard let day = tones(.day) else { return nil }
        var bytes = [UInt8](repeating: 0, count: source.width * source.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: source.width, height: source.height,
                                    bitsPerComponent: 8, bytesPerRow: source.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        }
        let indices: [UInt8] = stride(from: 0, to: bytes.count, by: 4).map { offset in
            guard bytes[offset + 3] == 255 else { return 0 }
            let colour = Array(bytes[offset..<offset + 3])
            return day.firstIndex(of: colour).map { UInt8($0 + 1) } ?? 0
        }
        return image(width: source.width, height: source.height, indices: indices, ramp: ramp)
    }
}

extension WordmarkGlyph {
    /// A one-pixel outline and stepped bevel, drawn after the broad letter is rasterized.
    func tonalImage(ramp: AgentLandClownRamp) -> CGImage? {
        let indices: [UInt8] = (0..<width * height).map { index in
            let x = index % width, y = index / width
            guard isOn(x, y) else { return 0 }
            if !isOn(x - 1, y) || !isOn(x + 1, y) || !isOn(x, y - 1) || !isOn(x, y + 1) { return 1 }
            if !isOn(x - 2, y) || !isOn(x, y - 2) { return 5 }
            if !isOn(x + 2, y) || !isOn(x, y + 2) { return 2 }
            return y < height / 2 ? 4 : 3
        }
        return AgentLandTonalArtwork.image(width: width, height: height, indices: indices, ramp: ramp)
    }
}
