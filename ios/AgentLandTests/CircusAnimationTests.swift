import XCTest
import SwiftUI
import UIKit
@testable import AgentLandBranding
import AgentLandDesign

@MainActor
final class CircusAnimationTests: XCTestCase {
    func testGoldClownsAndSpinningBallResourcesLoadOnIOS() {
        XCTAssertEqual(AgentLandClownArtwork.designs.map(\.name), AgentLandClownArtwork.designNames)
        for design in AgentLandClownArtwork.designs {
            XCTAssertEqual(design.frameCount, 72)
            XCTAssertEqual(design.juggling.rig.rightPalm.count, 72)
            XCTAssertEqual(design.juggling.rig.leftPalm.count, 72)
            XCTAssertEqual(design.loopDuration, 1.2, accuracy: 1e-9)
        }
        XCTAssertEqual(AgentLandClownMotion.frameDuration, 1.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(AgentLandJugglingBall.frames.count, 8)
        XCTAssertEqual(AgentLandJugglingBall.tintedFrames.count, 7)
        XCTAssertTrue(AgentLandJugglingBall.tintedFrames.allSatisfy { $0.count == 8 })
    }

    /// The opening cover shows the tent alone: no clown rides on it, whatever `showsClown` says. The clown
    /// comes out of the doorway only on a work surface, once it is revealed.
    func testCoverShowsNoClown() {
        for showsClown in [true, false] {
            let window = mountedCircus(reduceMotion: false, showsClown: showsClown)
            let layers = allLayers(in: window.layer)
            XCTAssertNil(compositedOrbit(in: window.layer), "No circusOrbit on the cover")
            XCTAssertFalse(layers.contains { layer in
                (layer.animationKeys() ?? []).contains { ["circusOrbit", "circusRide", "circusRideOutline", "circusBall", "circusGroundBall", "circusDepth"].contains($0) }
            }, "No rider, juggling or depth switching on the cover")
            XCTAssertFalse(layers.contains { $0.animation(forKey: "circusFlag") != nil }, "The pennant is part of the tent's loop now")
            window.isHidden = true
        }
    }

    /// The tent breathes on Core Animation's render server, so Face ID and loading cannot hold it: its
    /// PixelLab loop is discrete `contents` keyframes on the mark, twelve frames at 0.1 s (four 0.3 s beats
    /// of the circus clock), repeating for the whole opening.
    func testTentLoopRunsOnTheRenderServer() {
        let window = mountedCircus(reduceMotion: false)
        let layers = allLayers(in: window.layer)
        let mark = layers.compactMap { $0.animation(forKey: "circusTent") as? CAKeyframeAnimation }
        XCTAssertEqual(mark.count, 1, "The tent's mark steps through the loop")
        for animation in mark {
            XCTAssertEqual(animation.keyPath, "contents")
            XCTAssertEqual(animation.calculationMode, .discrete, "Pixel frames must not cross-fade")
            XCTAssertEqual(animation.values?.count, 12)
            XCTAssertEqual(animation.keyTimes?.count, 13, "Discrete keyframes need one more key time than values")
            XCTAssertEqual(animation.duration, 1.2, accuracy: 0.001, "Twelve frames at 0.1 s")
            XCTAssertEqual(animation.repeatCount, .infinity, "The loop lasts the whole opening")
        }
        window.isHidden = true
    }

    func testReduceMotionKeepsOpeningStill() {
        let window = mountedCircus(reduceMotion: true)
        XCTAssertNil(compositedOrbit(in: window.layer))
        XCTAssertTrue(allLayers(in: window.layer).allSatisfy { ($0.animationKeys() ?? []).isEmpty },
                      "Reduce Motion keeps the tent still")
        window.isHidden = true
    }

    /// The cover is the tent alone: the doorway's dark fill under the same shaded artwork as Home. With no clown to hide
    /// behind the tent, nothing is drawn in the cover's color (a depth mask would only paint slate on slate).
    func testCoverIsTheDoorwayAndTheTentAlone() {
        let cover = AgentLandColor.brand.uiColor.resolvedColor(with: UITraitCollection.current).cgColor
        let window = mountedCircus(reduceMotion: false, backdrop: AgentLandColor.brand.color)
        let tent = allLayers(in: window.layer).filter { !$0.isHidden && $0.mask != nil && $0.bounds.width == AgentLandTentArt.sceneRect.width }
        XCTAssertEqual(tent.count, 1, "Only the doorway needs a tint mask")
        let doorway = UIColor(red: 0x1B / 255.0, green: 0x22 / 255.0, blue: 0x2C / 255.0, alpha: 1).cgColor
        XCTAssertEqual(tent.first?.backgroundColor, doorway, "The doorway is drawn first, in its fixed dark shade")
        let artwork = paintedLayers(in: window.layer).filter { layer in
            guard !layer.isHidden, layer.mask == nil, layer.bounds.width == AgentLandTentArt.sceneRect.width, let contents = layer.contents else { return false }
            return CFGetTypeID(contents as CFTypeRef) == CGImage.typeID
        }
        XCTAssertEqual(artwork.count, 1, "The cover draws the shaded tent directly, without flattening its palette")
        if let contents = artwork.first?.contents {
            let image = contents as! CGImage // The CF type was checked above.
            let colors = opaqueColors(image)
            XCTAssertGreaterThanOrEqual(colors.count, 5, "The loading tent retains all five tones")
            XCTAssertTrue(colors.contains([0x90, 0x9D, 0xB3]), "Slate uses the same night midtone as Home")
            XCTAssertFalse(colors.contains([0x66, 0x72, 0x8A]), "The light-surface ramp must not leak onto slate")
        }
        XCTAssertFalse(tent.contains { $0.backgroundColor == cover }, "No depth mask on the cover")
        XCTAssertFalse(allLayers(in: window.layer).contains { $0.animation(forKey: "circusTentDepth") != nil })
        window.isHidden = true
    }

    private func opaqueColors(_ image: CGImage) -> Set<[UInt8]> {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Set(stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0 + 3] == 255 }
            .map { Array(bytes[$0..<$0 + 3]) })
    }

    func testCoverSoftensArtworkWithoutFadingTheDoorway() {
        let window = mountedCircus(reduceMotion: true, artOpacity: 0.4)
        let layers = paintedLayers(in: window.layer).filter { $0.bounds.width == AgentLandTentArt.sceneRect.width }
        let artwork = layers.first { layer in
            guard layer.mask == nil, let contents = layer.contents else { return false }
            return CFGetTypeID(contents as CFTypeRef) == CGImage.typeID
        }
        XCTAssertEqual(artwork?.opacity, 0.4)
        XCTAssertEqual(layers.first { $0.mask != nil }?.opacity, 1)
        window.isHidden = true
    }

    /// Launch shows the brand color before the first frame, so there is no white flash before the cover.
    func testLaunchScreenIsTheBrandColor() throws {
        let launch = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UILaunchScreen") as? [String: Any])
        let name = try XCTUnwrap(launch["UIColorName"] as? String)
        let color = try XCTUnwrap(UIColor(named: name, in: .main, compatibleWith: nil))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        let brand = AgentLandColor.brand.light
        XCTAssertEqual(Double(red), brand.red, accuracy: 0.002)
        XCTAssertEqual(Double(green), brand.green, accuracy: 0.002)
        XCTAssertEqual(Double(blue), brand.blue, accuracy: 0.002)
        XCTAssertEqual(alpha, 1)
    }

    /// The Home title runs its entrance on the render server with transform, opacity and contents keyframes
    /// only: position keyframes are how these tests recognise the clown's orbit.
    func testTitleEntranceUsesOnlyTransformOpacityAndContents() {
        let window = mountedTitle(active: true)
        let animations = allLayers(in: window.layer).flatMap { layer in
            (layer.animationKeys() ?? []).filter { $0.hasPrefix("wordmark") }.compactMap { layer.animation(forKey: $0) as? CAPropertyAnimation }
        }
        XCTAssertFalse(animations.isEmpty, "Revealing Home plays an entrance")
        for animation in animations {
            let keyPath = animation.keyPath ?? ""
            XCTAssertTrue(keyPath == "opacity" || keyPath == "contents" || keyPath.hasPrefix("transform."), keyPath)
            XCTAssertFalse(keyPath.contains("position"))
        }
        XCTAssertNil(compositedOrbit(in: window.layer), "The title never looks like the clown's orbit")
        window.isHidden = true
    }

    func testTitleRestsWhileCovered() {
        let window = mountedTitle(active: false)
        let animated = allLayers(in: window.layer).filter { layer in (layer.animationKeys() ?? []).contains { $0.hasPrefix("wordmark") } }
        XCTAssertTrue(animated.isEmpty, "A hidden or covered Home keeps the title still")
        window.isHidden = true
    }

    private func mountedTitle(active: Bool) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 440, height: 200)
        let quips = QuipStore(defaults: UserDefaults(suiteName: "CircusAnimationTests.quips")!,
                              provider: GrammarQuipProvider(), arguments: [], seed: 1)
        let controller = UIHostingController(rootView: AgentLandTitleBlock(
            scale: 0.92, color: .white, quipColor: .gray, active: active, referenceDate: Date(), quips: quips
        ).environment(\.scenePhase, .active))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        return window
    }

    private func mountedCircus(reduceMotion: Bool, showsClown: Bool = true, backdrop: Color? = nil,
                               artOpacity: Double = 1) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 336, height: 360)
        let controller = UIHostingController(rootView: AgentLandCircusLoading(
            forceReduceMotion: reduceMotion,
            authenticating: true,
            showsClown: showsClown,
            backdrop: backdrop,
            artOpacity: artOpacity
        ).environment(\.scenePhase, .active))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        return window
    }

    private func compositedOrbit(in layer: CALayer) -> CALayer? {
        if (layer.animationKeys() ?? []).contains(where: { key in
            guard let animation = layer.animation(forKey: key) as? CAPropertyAnimation else { return false }
            return animation.keyPath == "position" && animation.duration > 4
        }) { return layer }
        return (layer.sublayers ?? []).compactMap(compositedOrbit).first
    }

    /// Includes mask layers: the tinted tent animates its frames through its mask.
    private func allLayers(in layer: CALayer) -> [CALayer] {
        [layer] + (layer.mask.map(allLayers) ?? []) + (layer.sublayers ?? []).flatMap(allLayers)
    }

    /// Masks contain monochrome CGImages too, but they are not the artwork painted by a layer.
    private func paintedLayers(in layer: CALayer) -> [CALayer] {
        guard !layer.isHidden else { return [] }
        return [layer] + (layer.sublayers ?? []).flatMap(paintedLayers)
    }
}
