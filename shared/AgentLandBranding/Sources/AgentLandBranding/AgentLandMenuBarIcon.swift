#if os(macOS)
import AppKit

/// MenuBarExtra uses the label image's intrinsic size. A frame around the
/// regular GeometryReader-based mark does not constrain that menu-bar image.
@MainActor
public enum AgentLandMenuBarIcon {
    /// The template's size in points: the hand-drawn glyph's own grid (branding/tent-menubar.txt).
    static let side: CGFloat = 22

    public static let image: NSImage = {
        // LogoMenuBar is the tent drawn by hand for the bar's 1x grid, black with two alpha levels;
        // LogoMenuBar-2x is the same pixels doubled (scripts/package-logo.py). Each is its own bitmap rep at
        // 22 pt, so AppKit picks the one for the display's scale and never resamples: an image of any
        // other size (NSStatusBar.system.thickness was used before) scales the art and blurs it at 1x.
        // The 24-pt bar centres a 22-pt image on whole pixels.
        let size = NSSize(width: side, height: side)
        let reps = [("LogoMenuBar", 1), ("LogoMenuBar-2x", 2)].compactMap { name, scale -> NSBitmapImageRep? in
            guard let pixels = AgentLandBrandingResources.image(name),
                  pixels.width == Int(side) * scale, pixels.height == Int(side) * scale else { return nil }
            let rep = NSBitmapImageRep(cgImage: pixels)
            rep.size = size
            return rep
        }
        let image: NSImage
        if reps.count == 2 {
            image = NSImage(size: size)
            image.addRepresentations(reps)
        } else {
            image = NSImage(systemSymbolName: "tent", accessibilityDescription: "AgentLand")!
            image.size = size
        }
        image.isTemplate = true
        return image
    }()
}
#endif
