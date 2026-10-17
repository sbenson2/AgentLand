#if os(iOS)
import SwiftUI
import UIKit
import QuartzCore

/// The opening cover's circus runs on Core Animation's render server: Face ID and the first workspace load
/// can occupy the main thread without holding its frames. The cover shows the tent alone, breathing: the
/// doorway's dark fill under the mark, whose loop (`AgentLandTentLoop`) is `contents` keyframes on the
/// circus clock. No clown rides there, so there is no depth mask to hide one behind the tent.
struct AgentLandCircusCompositor: UIViewRepresentable {
    let animated: Bool
    let referenceDate: Date
    let tonalArt: Bool
    let ramp: AgentLandClownRamp
    let artOpacity: Double

    func makeUIView(context: Context) -> CircusCompositorView {
        CircusCompositorView(frame: CGRect(x: 0, y: 0, width: 336, height: 360))
    }

    func updateUIView(_ view: CircusCompositorView, context: Context) {
        view.configure(animated: animated, referenceDate: referenceDate, tonalArt: tonalArt, ramp: ramp,
                       artOpacity: artOpacity)
    }
}

final class CircusCompositorView: UIView {
    private static let tentRect = AgentLandTentArt.sceneRect

    /// The white mark's mask, whose contents are the tent's frames.
    private var markMask: CALayer?
    private var markLayer: CALayer?
    private var toneLayer: CALayer?
    private var configuredAnimation: Bool?
    private var configuredDate: Date?
    private var configuredRamp: AgentLandClownRamp?
    private var configuredTonalArt: Bool?
    private var configuredArtOpacity: Double?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isAccessibilityElement = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        buildLayers()
        CATransaction.commit()
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func configure(animated: Bool, referenceDate: Date, tonalArt: Bool, ramp: AgentLandClownRamp, artOpacity: Double) {
        guard configuredAnimation != animated || configuredDate != referenceDate ||
                configuredRamp != ramp || configuredTonalArt != tonalArt || configuredArtOpacity != artOpacity else { return }
        configuredAnimation = animated
        configuredDate = referenceDate
        configuredRamp = ramp
        configuredTonalArt = tonalArt
        configuredArtOpacity = artOpacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        markMask?.removeAllAnimations()
        toneLayer?.removeAllAnimations()
        markLayer?.isHidden = tonalArt
        toneLayer?.isHidden = !tonalArt
        markLayer?.opacity = Float(artOpacity)
        toneLayer?.opacity = Float(artOpacity)
        markMask?.contents = AgentLandTentArt.mark
        toneLayer?.contents = AgentLandTentArt.tonal(frame: nil, ramp: ramp)
        if animated, let loop = AgentLandTentLoop.artwork {
            let beginTime = CACurrentMediaTime() - max(0, Date().timeIntervalSince(referenceDate))
            if tonalArt {
                let frames = ramp == .day ? AgentLandTentArt.toneLoop : AgentLandTentArt.nightToneLoop
                if frames.count == loop.marks.count {
                    toneLayer?.add(Self.loopAnimation(frames, beginTime: beginTime), forKey: "circusTent")
                }
            } else {
                markMask?.add(Self.loopAnimation(loop.marks, beginTime: beginTime), forKey: "circusTent")
            }
        }
        CATransaction.commit()
    }

    private func buildLayers() {
        guard let tent = AgentLandTentArt.mark else { return }
        // The doorway is a hole in the mark: a dark opening, not a white panel.
        if let doorway = AgentLandTentArt.doorway {
            let rgb = AgentLandTheme.tentDoorwayRGB
            let shade = UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
            layer.addSublayer(Self.tintedLayer(image: doorway, color: shade, frame: Self.tentRect))
        }
        let markLayer = Self.tintedLayer(image: tent, color: .white, frame: Self.tentRect)
        self.markLayer = markLayer
        markMask = markLayer.mask
        layer.addSublayer(markLayer)
        let tone = CALayer()
        tone.frame = Self.tentRect
        tone.contentsGravity = .resize
        tone.magnificationFilter = .nearest
        tone.minificationFilter = .nearest
        tone.isHidden = true
        toneLayer = tone
        layer.addSublayer(tone)
    }

    /// Steps through the loop's frames on the render server, one per `AgentLandTentLoop.frameDuration`, in
    /// step with the work surfaces' timeline.
    static func loopAnimation(_ frames: [CGImage], beginTime: CFTimeInterval) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        // Discrete keyframes need one more key time than values: frame i holds until key time i + 1.
        animation.keyTimes = (0...frames.count).map { NSNumber(value: Double($0) / Double(max(1, frames.count))) }
        animation.calculationMode = .discrete
        animation.duration = AgentLandTentLoop.frameDuration * Double(frames.count)
        animation.repeatCount = .infinity
        animation.beginTime = beginTime
        return animation
    }

    private static func tintedLayer(image: CGImage, color: UIColor, frame: CGRect) -> CALayer {
        let fill = CALayer()
        fill.frame = frame
        fill.backgroundColor = color.cgColor
        let mask = CALayer()
        mask.frame = fill.bounds
        mask.contents = image
        mask.contentsGravity = .resize
        mask.magnificationFilter = .nearest
        mask.minificationFilter = .nearest
        fill.mask = mask
        return fill
    }
}
#endif
