import AppKit
import ImageIO

// Asset packaging only: use the packaged PixelLab tent without changing its geometry.
// Run from the project root: swift scripts/render-brand-assets.swift
// The logo is the steamboat-style tent since 2026-10-12 (branding/tent-logo.json): scripts/package-logo.py writes the
// iPhone and Mac icons, the in-app mark, the menu-bar template and logo-light/dark.png. This script keeps the tent's
// shared resources and bounce previews; the former --macos-only is still accepted and changes nothing.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.isEmpty || arguments == ["--macos-only"] else {
    fatalError("Usage: swift scripts/render-brand-assets.swift")
}
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let branding = root.appendingPathComponent("branding")
// The owner's slate (#27313F): AgentLandDesign's brand color and the dark paper. A navy
// (#1E2C4D) was tried on 2026-09-24 and the owner asked for the slate theme back.
let darkPaper = NSColor(srgbRed: 0x27 / 255.0, green: 0x31 / 255.0, blue: 0x3F / 255.0, alpha: 1)
guard let black = NSImage(contentsOf: branding.appendingPathComponent("tent-mono.png")),
      let white = NSImage(contentsOf: branding.appendingPathComponent("tent-mono-white.png")),
      let doorwayMask = NSImage(contentsOf: branding.appendingPathComponent("tent-doorway.png")) else {
    fatalError("Run from the AgentLand root after swift scripts/package-tent.swift.")
}
// The doorway is a hole in the mark, filled with AgentLandTheme.tentDoorway (#1B222C) in every preview.
let doorwayShade = NSColor(srgbRed: 0x1B / 255.0, green: 0x22 / 255.0, blue: 0x2C / 255.0, alpha: 1)
let doorway = NSImage(size: doorwayMask.size, flipped: false) { rect in
    NSGraphicsContext.current?.imageInterpolation = .none
    doorwayMask.draw(in: rect)
    doorwayShade.setFill()
    rect.fill(using: .sourceAtop)
    return true
}

struct Pose { var x = 1.0; var y = 1.0; var height = 0.0 }
func pose(_ seconds: Double) -> Pose {
    let t = seconds.truncatingRemainder(dividingBy: 2.99)
    let rest = Pose(), squat = Pose(x: 1.035, y: 0.968, height: -0.024)
    let air = Pose(height: 0.082), land = Pose(x: 1.045, y: 0.94, height: -0.012)
    func mix(_ a: Pose, _ b: Pose, _ p: Double) -> Pose {
        let f = min(1, max(0, p)), s = f * f * (3 - 2 * f)
        return Pose(x: a.x + (b.x - a.x) * s, y: a.y + (b.y - a.y) * s, height: a.height + (b.height - a.height) * s)
    }
    if t < 2.4 { return rest }
    if t < 2.52 { return mix(rest, squat, (t - 2.4) / 0.12) }
    if t < 2.72 { return mix(squat, air, (t - 2.52) / 0.2) }
    if t < 2.83 { return mix(air, land, (t - 2.72) / 0.11) }
    return mix(land, rest, (t - 2.83) / 0.16)
}

func render(side: Int, dark: Bool, pose: Pose = Pose()) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .none
    let s = Double(side)
    let canvas = NSRect(x: 0, y: 0, width: s, height: s)
    NSColor.clear.setFill(); canvas.fill(using: .copy)
    (dark ? darkPaper : .white).setFill()
    canvas.fill()
    let mark = s * 0.76
    let rect = NSRect(x: (s - mark * pose.x) / 2, y: (s - mark) / 2 + s * pose.height,
        width: mark * pose.x, height: mark * pose.y)
    doorway.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    (dark ? white : black).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

try Data(contentsOf: branding.appendingPathComponent("tent-mono.png"))
    .write(to: root.appendingPathComponent("shared/AgentLandBranding/Sources/AgentLandBranding/Resources/TentMark.png"), options: .atomic)
try Data(contentsOf: branding.appendingPathComponent("tent-doorway.png"))
    .write(to: root.appendingPathComponent("shared/AgentLandBranding/Sources/AgentLandBranding/Resources/TentDoorway.png"), options: .atomic)

for (name, dark) in [("light", false), ("dark", true)] {
    let url = branding.appendingPathComponent("tent-bounce-\(name).gif")
    let frames = 60
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, frames, nil)!
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for frame in 0..<frames {
        let bitmap = render(side: 320, dark: dark, pose: pose(2.35 + Double(frame) * 2.99 / Double(frames)))
        CGImageDestinationAddImage(destination, bitmap.cgImage!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]] as CFDictionary)
    }
    guard CGImageDestinationFinalize(destination) else { fatalError("GIF export failed") }
}
print("Updated the shared tent and its bounce previews from PixelLab source.")
