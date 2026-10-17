import CoreText
import Foundation

/// PixelLab's AgentLand Rubber Hose title face, registered only in this process.
/// Its 16-pixel glyphs keep the cartoon lettering consistent with the circus sprites.
/// Generation provenance and the packaged hash are recorded in branding/wordmark.json.
public enum AgentLandWordmarkFont {
    public static let postScriptName = "AgentLandRubberHose"
    public static let familyName = "AgentLand Rubber Hose"

    /// Registers the font once per process (a static `let` initializer runs exactly once, thread-safely)
    /// and reports whether CoreText now resolves the expected PostScript name to this file.
    public static var isRegistered: Bool { registration }

    private static let registration: Bool = {
        guard let url = fontURL else { return false }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            // A test host or another module may have registered the same file already.
            let code = (error?.takeRetainedValue()).map { CFErrorGetCode($0) } ?? 0
            guard code == CTFontManagerError.alreadyRegistered.rawValue else { return false }
        }
        let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
        return CTFontCopyPostScriptName(font) as String == postScriptName
    }()

    /// The registered font, or nil when the resource is missing or resolves to another face.
    public static func font(size: CGFloat) -> CTFont? {
        guard isRegistered else { return nil }
        return CTFontCreateWithName(postScriptName as CFString, size, nil)
    }

    static var fontURL: URL? {
        AgentLandBrandingResources.bundle.url(forResource: "AgentLandRubberHose", withExtension: "ttf")
            ?? AgentLandBrandingResources.bundle.url(forResource: "AgentLandRubberHose", withExtension: "ttf", subdirectory: "Fonts")
    }

    /// Every bundled open-licence font's notice (Holtwood One SC and the title's other faces), for Settings.
    public static var licenseText: String { AgentLandWordmarkFaces.licenseText }
}
