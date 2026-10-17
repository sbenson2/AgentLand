import CoreGraphics
import CoreText
import Foundation

/// Rounded PixelLab rubber-hose lettering on a shallow arch, in 336x360 circus scene units (y down).
/// The 48-unit capitals are widened before rasterization and follow a 42° sweep with a 680-unit radius.
/// Every turned glyph shares the tent's pixel grid (2.625 units per pixel, anchored at (42, 54)); a pixel
/// is on when at least half of it is covered. The canvas is symmetric about the tent's centre line even
/// though the first and last letter outlines have different widths.
public enum AgentLandWordmarkGeometry {
    public static let word = "AGENTLAND"
    public static let artUnit: CGFloat = 2.625
    /// A corner of the tent's pixel grid: the tent origin (42, 54) moved 16 pixels left and 68 up.
    public static let gridOrigin = CGPoint(x: 0, y: -124.5)
    public static let centre = CGPoint(x: 168, y: 640)
    public static let radius: CGFloat = 680
    public static let sweep: CGFloat = 42 * .pi / 180
    public static let capHeight: CGFloat = 48
    /// Broad marquee lettering, rasterized after widening so edges remain on the pixel grid.
    public static let letterWidth: CGFloat = 1.12
    /// Small marquee bulbs on an arc just outside the letters, lit only by animations.
    public static let bulbRadius: CGFloat = radius + capHeight + 8
    public static let bulbCount = 33
    public static let bulbSide = 2

    /// The hollow under the arch's apex, between the apex and the chord through its ends. Home shows the quip
    /// under the tent; sheets that still set a quip in the arch (AgentLandDesign's palette sheet) use this.
    public static var quipCentre: CGPoint {
        let apex = centre.y - radius, chord = centre.y - radius * cos(sweep / 2)
        return CGPoint(x: centre.x, y: (apex + chord) / 2)
    }
    /// At most two lines, clear of the letters.
    public static let quipSize = CGSize(width: 120, height: 36)

    /// The title's canvas (every letter and bulb) in circus scene units; the arch is centred on x = 168.
    public static var canvas: CGRect {
        WordmarkArtwork.shared?.canvas ?? CGRect(x: -115.5, y: -98.25, width: 567, height: 112.875)
    }
}

/// One letter of the title: its turned glyph rasterized on the tent grid.
struct WordmarkGlyph: Sendable {
    let character: Character
    /// Radians from the arch's apex; negative to the left.
    let angle: CGFloat
    /// The glyph's baseline centre on the circle, in scene units.
    let arcPoint: CGPoint
    /// Grid cell of the bitmap's top-left corner and its size in cells.
    let column: Int, row: Int, width: Int, height: Int
    /// Row-major, top row first.
    let pixels: [Bool]

    var frame: CGRect {
        CGRect(x: AgentLandWordmarkGeometry.gridOrigin.x + CGFloat(column) * AgentLandWordmarkGeometry.artUnit,
               y: AgentLandWordmarkGeometry.gridOrigin.y + CGFloat(row) * AgentLandWordmarkGeometry.artUnit,
               width: CGFloat(width) * AgentLandWordmarkGeometry.artUnit,
               height: CGFloat(height) * AgentLandWordmarkGeometry.artUnit)
    }

    func isOn(_ x: Int, _ y: Int) -> Bool {
        (0..<width).contains(x) && (0..<height).contains(y) && pixels[y * width + x]
    }
}

/// The title's artwork for one face, built once per process and face. `shared` is the PixelLab Rubber Hose
/// face's, which sets the layout canvas.
struct WordmarkArtwork: Sendable {
    let glyphs: [WordmarkGlyph]
    /// Top-left grid cell of each bulb (bulbSide x bulbSide cells), left to right along the arc.
    let bulbs: [(column: Int, row: Int)]
    /// The grid box holding every letter and bulb, in cells.
    let canvasColumn: Int, canvasRow: Int, canvasWidth: Int, canvasHeight: Int
    let fontSize: CGFloat
    let tracking: CGFloat
    let capHeight: CGFloat

    static let shared: WordmarkArtwork? = AgentLandWordmarkFont.font(size: 100).flatMap {
        make(font: $0, letterWidth: AgentLandWordmarkGeometry.letterWidth)
    }

    /// The artwork for a face, or nil when its file does not load; built once per face.
    static func artwork(for face: AgentLandWordmarkFace) -> WordmarkArtwork? {
        if face.id == "rubberHose", let shared { return shared }
        return cache.artwork(for: face)
    }

    private static let cache = ArtworkCache()

    private final class ArtworkCache: @unchecked Sendable {
        private let lock = NSLock()
        private var artworks: [String: WordmarkArtwork?] = [:]

        func artwork(for face: AgentLandWordmarkFace) -> WordmarkArtwork? {
            lock.lock()
            defer { lock.unlock() }
            if let known = artworks[face.id] { return known }
            let made = AgentLandWordmarkFaces.font(face, size: 100).flatMap { WordmarkArtwork.make(font: $0) }
            artworks[face.id] = made
            return made
        }
    }

    /// The canvas in scene units.
    var canvas: CGRect {
        let unit = AgentLandWordmarkGeometry.artUnit
        return CGRect(x: AgentLandWordmarkGeometry.gridOrigin.x + CGFloat(canvasColumn) * unit,
                      y: AgentLandWordmarkGeometry.gridOrigin.y + CGFloat(canvasRow) * unit,
                      width: CGFloat(canvasWidth) * unit, height: CGFloat(canvasHeight) * unit)
    }

    func bulbFrame(_ index: Int) -> CGRect {
        let unit = AgentLandWordmarkGeometry.artUnit, side = CGFloat(AgentLandWordmarkGeometry.bulbSide) * unit
        return CGRect(x: AgentLandWordmarkGeometry.gridOrigin.x + CGFloat(bulbs[index].column) * unit,
                      y: AgentLandWordmarkGeometry.gridOrigin.y + CGFloat(bulbs[index].row) * unit, width: side, height: side)
    }

    /// The title in `font` at the widest letter width, from the standard 1.12 down to 0.9 in steps of 0.02, at
    /// which no two neighbouring letters share a cell and every letter lies within three cells of the layout
    /// canvas (Rubber Hose's): a broad or slanted face is drawn a little narrower rather than touching or
    /// spilling. Nil when no width fits.
    static func make(font: CTFont) -> WordmarkArtwork? {
        guard let canvas = shared?.canvas else { return nil }
        let slack = canvas.insetBy(dx: -3 * AgentLandWordmarkGeometry.artUnit, dy: -3 * AgentLandWordmarkGeometry.artUnit)
        for step in 0...11 {
            guard let artwork = make(font: font, letterWidth: AgentLandWordmarkGeometry.letterWidth - 0.02 * CGFloat(step)) else { continue }
            if artwork.glyphs.allSatisfy({ slack.contains($0.frame) }) && !artwork.neighboursTouch { return artwork }
        }
        return nil
    }

    /// Whether two neighbouring letters share a lit cell.
    var neighboursTouch: Bool {
        zip(glyphs, glyphs.dropFirst()).contains { left, right in
            for y in 0..<right.height { for x in 0..<right.width where right.isOn(x, y) {
                if left.isOn(right.column + x - left.column, right.row + y - left.row) { return true }
            } }
            return false
        }
    }

    /// The title in `font`: the same arch, cap height, tracking rule, grid and half-coverage rule for every face.
    static func make(font base: CTFont, letterWidth: CGFloat) -> WordmarkArtwork? {
        typealias G = AgentLandWordmarkGeometry
        let probe = CTFontCreateCopyWithAttributes(base, 100, nil, nil)
        // Cap height from the "H" outline, as on the round-1 sheet.
        var character: UniChar = 72, glyph = CGGlyph(0), bounds = CGRect.zero
        CTFontGetGlyphsForCharacters(probe, &character, &glyph, 1)
        CTFontGetBoundingRectsForGlyphs(probe, .horizontal, &glyph, &bounds, 1)
        guard bounds.maxY > 0 else { return nil }
        let size = G.capHeight / (bounds.maxY / 100)
        let font = CTFontCreateCopyWithAttributes(base, size, nil, nil)

        let line = CTLineCreateWithAttributedString(NSAttributedString(string: G.word, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font]))
        var glyphs: [CGGlyph] = [], centres: [CGFloat] = [], advances: [CGFloat] = []
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            var g = [CGGlyph](repeating: 0, count: count), p = [CGPoint](repeating: .zero, count: count)
            var a = [CGSize](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &g)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &p)
            CTRunGetAdvances(run, CFRange(location: 0, length: count), &a)
            glyphs += g; advances += a.map(\.width); centres += zip(p, a).map { $0.x + $1.width / 2 }
        }
        let letters = Array(G.word)
        guard glyphs.count == letters.count, let first = centres.first, let last = centres.last else { return nil }
        let tracking = (G.radius * G.sweep - (last - first) * letterWidth) / CGFloat(letters.count - 1)

        var made: [WordmarkGlyph] = []
        for index in glyphs.indices {
            let along = (centres[index] - first) * letterWidth + CGFloat(index) * tracking
            let angle = -G.sweep / 2 + along / G.radius
            let point = CGPoint(x: G.centre.x + G.radius * sin(angle), y: G.centre.y - G.radius * cos(angle))
            // Glyph space is y-up from its baseline origin; centre it on its advance, flip to y-down,
            // turn it to the circle's normal and move it onto the baseline circle.
            var transform = CGAffineTransform(translationX: -advances[index] / 2, y: 0)
                .concatenating(CGAffineTransform(scaleX: letterWidth, y: -1))
                .concatenating(CGAffineTransform(rotationAngle: angle))
                .concatenating(CGAffineTransform(translationX: point.x, y: point.y))
            guard let path = CTFontCreatePathForGlyph(font, glyphs[index], &transform),
                  let raster = rasterize(path) else { return nil }
            made.append(WordmarkGlyph(character: letters[index], angle: angle, arcPoint: point,
                                      column: raster.column, row: raster.row, width: raster.width,
                                      height: raster.height, pixels: raster.pixels))
        }

        var bulbs: [(column: Int, row: Int)] = []
        for index in 0..<G.bulbCount {
            let angle = -G.sweep / 2 + G.sweep * CGFloat(index) / CGFloat(G.bulbCount - 1)
            let point = CGPoint(x: G.centre.x + G.bulbRadius * sin(angle), y: G.centre.y - G.bulbRadius * cos(angle))
            let half = CGFloat(G.bulbSide) / 2
            bulbs.append((Int(((point.x - G.gridOrigin.x) / G.artUnit - half).rounded()),
                          Int(((point.y - G.gridOrigin.y) / G.artUnit - half).rounded())))
        }

        let outlineMinColumn = min(made.map(\.column).min()!, bulbs.map(\.column).min()!)
        let minRow = min(made.map(\.row).min()!, bulbs.map(\.row).min()!)
        let outlineMaxColumn = max(made.map { $0.column + $0.width }.max()!, bulbs.map { $0.column + G.bulbSide }.max()!)
        let centreColumn = Int(((G.centre.x - G.gridOrigin.x) / G.artUnit).rounded())
        let halfWidth = max(centreColumn - outlineMinColumn, outlineMaxColumn - centreColumn)
        let minColumn = centreColumn - halfWidth, maxColumn = centreColumn + halfWidth
        let maxRow = max(made.map { $0.row + $0.height }.max()!, bulbs.map { $0.row + G.bulbSide }.max()!)
        return WordmarkArtwork(glyphs: made, bulbs: bulbs, canvasColumn: minColumn, canvasRow: minRow,
                               canvasWidth: maxColumn - minColumn, canvasHeight: maxRow - minRow,
                               fontSize: size, tracking: tracking, capHeight: bounds.maxY / 100 * size)
    }

    /// Grid cells at least half covered by the path, cropped to the lit cells.
    private static func rasterize(_ path: CGPath) -> (column: Int, row: Int, width: Int, height: Int, pixels: [Bool])? {
        typealias G = AgentLandWordmarkGeometry
        let box = path.boundingBoxOfPath
        let column = Int(((box.minX - G.gridOrigin.x) / G.artUnit).rounded(.down)) - 1
        let row = Int(((box.minY - G.gridOrigin.y) / G.artUnit).rounded(.down)) - 1
        let width = Int(((box.maxX - G.gridOrigin.x) / G.artUnit).rounded(.up)) + 1 - column
        let height = Int(((box.maxY - G.gridOrigin.y) / G.artUnit).rounded(.up)) + 1 - row
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Scene units (y down) to cells; bitmap rows run top to bottom in memory after the flip.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1 / G.artUnit, y: -1 / G.artUnit)
        context.translateBy(x: -(G.gridOrigin.x + CGFloat(column) * G.artUnit), y: -(G.gridOrigin.y + CGFloat(row) * G.artUnit))
        context.setShouldAntialias(true)
        context.setFillColor(gray: 1, alpha: 1)
        context.addPath(path)
        context.fillPath()
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let bytesPerRow = context.bytesPerRow
        var lit = [Bool](repeating: false, count: width * height)
        for y in 0..<height { for x in 0..<width { lit[y * width + x] = data[y * bytesPerRow + x] >= 128 } }
        let xs = lit.indices.filter { lit[$0] }.map { $0 % width }, ys = lit.indices.filter { lit[$0] }.map { $0 / width }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        var cropped: [Bool] = []
        for y in minY...maxY { for x in minX...maxX { cropped.append(lit[y * width + x]) } }
        return (column + minX, row + minY, maxX - minX + 1, maxY - minY + 1, cropped)
    }
}

// MARK: - Bitmaps

enum WordmarkBitmap {
    static func mask(width: Int, height: Int, _ lit: (Int, Int) -> Bool) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width where lit(x, y) {
            let offset = (y * width + x) * 4
            bytes[offset] = 255; bytes[offset + 1] = 255; bytes[offset + 2] = 255; bytes[offset + 3] = 255
        } }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// SplitMix64: a small, seedable generator for picking animations, letters and quips reproducibly.
public struct AgentLandSeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
