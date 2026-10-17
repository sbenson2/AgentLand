import CoreGraphics
import SwiftUI
import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import AgentLandDesign

/// Collects values written while SwiftUI lays out a view that `ImageRenderer` is drawing.
final class RenderRecorder: @unchecked Sendable {
    var tapTargets: [CGRect] = []
}

/// Announcements a component made, in order.
@MainActor
final class AnnouncementLog {
    var entries: [(text: String, priority: AgentLandAnnouncer.Priority)] = []

    var announcer: AgentLandAnnouncer {
        AgentLandAnnouncer { [self] text, priority in entries.append((text, priority)) }
    }
}

struct RenderResult {
    let image: CGImage
    /// Hit areas reported by `minimumTapTarget`, tiles and primary buttons, in the rendered view's points.
    let tapTargets: [CGRect]

    var size: CGSize { CGSize(width: image.width, height: image.height) }

    /// RGBA bytes in sRGB, top row first.
    private var bytes: [UInt8] {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    /// True when at least one pixel is not transparent.
    var hasVisiblePixels: Bool {
        let bytes = bytes
        return stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 0 }
    }

    /// The opaque color at a point (in points, top-left origin; the render tests use scale 1), or nil
    /// where the pixel is not fully opaque.
    func color(at point: CGPoint) -> AgentLandRGB? {
        let x = Int(point.x), y = Int(point.y)
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        let bytes = bytes, index = (y * image.width + x) * 4
        guard bytes[index + 3] == 255 else { return nil }
        return AgentLandRGB(UInt32(bytes[index]) << 16 | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]))
    }
}

/// Channels within one step of rounding.
func assertColor(_ actual: AgentLandRGB?, equals expected: AgentLandRGB, _ message: String,
                 file: StaticString = #filePath, line: UInt = #line) {
    guard let actual else { return XCTFail("\(message): no opaque pixel", file: file, line: line) }
    let channels = [(actual.hex >> 16, expected.hex >> 16), ((actual.hex >> 8) & 0xFF, (expected.hex >> 8) & 0xFF),
                    (actual.hex & 0xFF, expected.hex & 0xFF)]
    XCTAssertTrue(channels.allSatisfy { abs(Int($0.0 & 0xFF) - Int($0.1 & 0xFF)) <= 1 },
                  "\(message): \(actual) is not \(expected)", file: file, line: line)
}

/// The opaque color a token draws in an appearance: on iPhone and iPad a token with a system color draws that color
/// (`AgentLandColor.system`), resolved for the appearance; elsewhere the token's own value.
@MainActor
func drawnColor(_ token: AgentLandColor, _ appearance: AgentLandAppearance) -> AgentLandRGB {
    #if canImport(UIKit)
    if token.system != nil {
        let traits = UITraitCollection { traits in
            traits.userInterfaceStyle = appearance.isDark ? .dark : .light
            traits.accessibilityContrast = appearance.increasedContrast ? .high : .normal
        }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        token.uiColor.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let bytes = [red, green, blue].map { UInt32((min(1, max(0, $0)) * 255).rounded()) }
        return AgentLandRGB(bytes[0] << 16 | bytes[1] << 8 | bytes[2])
    }
    #endif
    return token.rgb(for: appearance)
}

/// The text sizes the render tests use: the default and the largest accessibility size.
let renderTestTypeSizes: [DynamicTypeSize] = [.large, .accessibility5]

@MainActor
func render<V: View>(_ view: V, width: CGFloat? = nil, typeSize: DynamicTypeSize = .large,
                     colorScheme: ColorScheme = .light, minimumTapTarget: CGFloat = AgentLandTapTarget.platformMinimum,
                     announcer: AgentLandAnnouncer = AgentLandAnnouncer { _, _ in },
                     file: StaticString = #filePath, line: UInt = #line) throws -> RenderResult {
    let recorder = RenderRecorder()
    let root = view
        .frame(width: width)
        .environment(\.dynamicTypeSize, typeSize)
        .environment(\.colorScheme, colorScheme)
        .environment(\.agentLandMinimumTapTarget, minimumTapTarget)
        .environment(\.agentLandAnnouncer, announcer)
        .overlayPreferenceValue(TapTargetPreferenceKey.self) { anchors in
            GeometryReader { proxy in
                let _ = { recorder.tapTargets = anchors.map { proxy[$0] } }()
                Color.clear
            }
        }
    let renderer = ImageRenderer(content: root)
    renderer.scale = 1
    let image = try XCTUnwrap(renderer.cgImage, "nothing rendered", file: file, line: line)
    return RenderResult(image: image, tapTargets: recorder.tapTargets)
}

/// Every hit area is at least `minimum` on each side.
func assertTapTargets(_ result: RenderResult, count: Int, minimum: CGFloat, _ message: String,
                      file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(result.tapTargets.count, count, "\(message): hit areas \(result.tapTargets)", file: file, line: line)
    for rect in result.tapTargets {
        XCTAssertGreaterThanOrEqual(rect.width, minimum - 0.5, "\(message): \(rect)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.height, minimum - 0.5, "\(message): \(rect)", file: file, line: line)
    }
    for (index, rect) in result.tapTargets.enumerated() {
        for other in result.tapTargets[(index + 1)...] {
            let overlap = rect.intersection(other)
            XCTAssertTrue(overlap.isNull || overlap.width < 0.5 || overlap.height < 0.5,
                          "\(message): hit areas overlap \(rect) \(other)", file: file, line: line)
        }
    }
}
