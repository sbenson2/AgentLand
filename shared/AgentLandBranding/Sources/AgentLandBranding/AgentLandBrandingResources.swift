import CoreGraphics
import Foundation
import ImageIO

enum AgentLandBrandingResources {
    private static let bundleName = "AgentLandBranding_AgentLandBranding"

    static let bundle: Bundle = {
        resolve(mainBundle: .main, fallback: .module)
    }()

    static func resolve(mainBundle: Bundle, fallback: @autoclosure () -> Bundle) -> Bundle {
        if let direct = mainBundle.url(forResource: bundleName, withExtension: "bundle"),
           let resolved = Bundle(url: direct) {
            return resolved
        }
        if let resources = mainBundle.resourceURL {
            let candidate = resources.appendingPathComponent("\(bundleName).bundle")
            if let resolved = Bundle(url: candidate) {
                return resolved
            }
        }
        return fallback()
    }

    /// A packaged PNG, decoded without named-image lookup so iOS and macOS read the same file.
    static func image(_ name: String) -> CGImage? {
        guard let url = bundle.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The square frames of a packaged horizontal strip, left to right.
    static func strip(_ name: String, side: Int = 96) -> [CGImage] {
        guard let strip = image(name), strip.height == side, strip.width >= side, strip.width % side == 0 else { return [] }
        return (0..<(strip.width / side)).compactMap { strip.cropping(to: CGRect(x: $0 * side, y: 0, width: side, height: side)) }
    }

    /// A strip of square frames as tall as the image (the tent's loops, whose side TentGeometry.json gives).
    static func squareStrip(_ name: String) -> [CGImage] {
        guard let strip = image(name), strip.height > 0, strip.width % strip.height == 0 else { return [] }
        let side = strip.height
        return (0..<(strip.width / side)).compactMap { strip.cropping(to: CGRect(x: $0 * side, y: 0, width: side, height: side)) }
    }

    static func json<Value: Decodable>(_ name: String, as type: Value.Type) -> Value? {
        guard let url = bundle.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
