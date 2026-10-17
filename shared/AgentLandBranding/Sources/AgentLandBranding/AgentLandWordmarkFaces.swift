import CoreGraphics
import CoreText
import Foundation

/// One of the title's faces: AgentLand's own PixelLab Rubber Hose, or an SIL Open Font License display face
/// bundled with its licence (branding/wordmark.json "faces" records each file's source and hash).
public struct AgentLandWordmarkFace: Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    /// The font file's name in the package's resources, without its `.ttf` extension.
    let resource: String
    /// The licence text's name in the resources, without `.txt`; nil for AgentLand's own face.
    let licence: String?

    /// The bundled open-licence notice; nil for AgentLand's own face. Settings → About shows each.
    public var licenceURL: URL? { licence.flatMap { AgentLandWordmarkFaces.resource($0, extension: "txt") } }
}

/// The title's nine faces. Each Home load picks one (`AgentLandWordmarkPicker.nextStyle`); some idle
/// flourishes morph into another and back. Fonts are read straight from their files, never registered with
/// the system, so their names cannot clash with anything installed.
public enum AgentLandWordmarkFaces {
    /// In order: Rubber Hose first, the default.
    public static let all: [AgentLandWordmarkFace] = [
        AgentLandWordmarkFace(id: "rubberHose", displayName: "AgentLand Rubber Hose", resource: "AgentLandRubberHose", licence: nil),
        AgentLandWordmarkFace(id: "holtwood", displayName: "Holtwood One SC", resource: "HoltwoodOneSC-Regular", licence: "HoltwoodOneSC-OFL"),
        AgentLandWordmarkFace(id: "bungee", displayName: "Bungee", resource: "Bungee-Regular", licence: "Bungee-OFL"),
        AgentLandWordmarkFace(id: "chango", displayName: "Chango", resource: "Chango-Regular", licence: "Chango-OFL"),
        AgentLandWordmarkFace(id: "alfaSlabOne", displayName: "Alfa Slab One", resource: "AlfaSlabOne-Regular", licence: "AlfaSlabOne-OFL"),
        AgentLandWordmarkFace(id: "titanOne", displayName: "Titan One", resource: "TitanOne-Regular", licence: "TitanOne-OFL"),
        AgentLandWordmarkFace(id: "bowlbyOneSC", displayName: "Bowlby One SC", resource: "BowlbyOneSC-Regular", licence: "BowlbyOneSC-OFL"),
        AgentLandWordmarkFace(id: "shrikhand", displayName: "Shrikhand", resource: "Shrikhand-Regular", licence: "Shrikhand-OFL"),
        AgentLandWordmarkFace(id: "coiny", displayName: "Coiny", resource: "Coiny-Regular", licence: "Coiny-OFL"),
    ]

    /// The faces whose files load.
    public static var available: [AgentLandWordmarkFace] { all.filter { graphicsFont(for: $0) != nil } }

    /// The face at `size` points, or nil when its file is missing or unreadable.
    public static func font(_ face: AgentLandWordmarkFace, size: CGFloat) -> CTFont? {
        graphicsFont(for: face).map { CTFontCreateWithGraphicsFont($0, size, nil, nil) }
    }

    /// Every bundled open-licence notice, each headed by its font's name; Settings shows it.
    public static let licenseText: String = all.compactMap { face -> String? in
        guard let licence = face.licence, let url = resource(licence, extension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return "\(face.displayName)\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }.joined(separator: "\n\n")

    private static let cache = FontCache()

    private final class FontCache: @unchecked Sendable {
        private let lock = NSLock()
        private var fonts: [String: CGFont?] = [:]

        func font(for face: AgentLandWordmarkFace) -> CGFont? {
            lock.lock()
            defer { lock.unlock() }
            if let known = fonts[face.id] { return known }
            let loaded = AgentLandWordmarkFaces.resource(face.resource, extension: "ttf")
                .flatMap { CGDataProvider(url: $0 as CFURL) }
                .flatMap(CGFont.init)
            fonts[face.id] = loaded
            return loaded
        }
    }

    private static func graphicsFont(for face: AgentLandWordmarkFace) -> CGFont? { cache.font(for: face) }

    static func resource(_ name: String, extension type: String) -> URL? {
        let bundle = AgentLandBrandingResources.bundle
        return bundle.url(forResource: name, withExtension: type)
            ?? bundle.url(forResource: name, withExtension: type, subdirectory: "Fonts")
    }
}
