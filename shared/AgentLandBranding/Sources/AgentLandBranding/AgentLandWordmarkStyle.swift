import CoreGraphics
import Foundation

/// The title's face and look for one Home load.
public struct AgentLandWordmarkStyle: Hashable, Sendable {
    public let face: String
    public let look: AgentLandWordmarkLook

    public init(face: String, look: AgentLandWordmarkLook) {
        self.face = face
        self.look = look
    }

    /// The original title: Rubber Hose with its stepped bevel.
    public static let classic = AgentLandWordmarkStyle(face: "rubberHose", look: .bevel)
}

/// Every face's title, drawn into one fixed box per letter slot: the union of the faces' glyph boxes for that
/// letter, widened a cell left and up, two right and six down for the looks and drips. Every face and look of
/// a slot is the same size and place, so changing font or look is only a change of image.
final class WordmarkFontSet: @unchecked Sendable {
    /// Every bundled face that loads; nil only when Rubber Hose does not.
    static let shared = WordmarkFontSet(faces: AgentLandWordmarkFaces.all)

    /// The faces whose titles build, Rubber Hose first.
    let faces: [AgentLandWordmarkFace]
    let boxes: [WordmarkCellBox]
    /// Each slot's pivot on the arch (scene units) and turn (radians): the faces' mean.
    let pivots: [CGPoint]
    let angles: [CGFloat]
    private let artworks: [String: WordmarkArtwork]
    private let lock = NSLock()
    private var images: [ImageKey: CGImage] = [:]

    private struct ImageKey: Hashable {
        let style: AgentLandWordmarkStyle, slot: Int, ramp: String?, boosted: Bool, sparkle: [Int], mask: Bool
    }

    init?(faces: [AgentLandWordmarkFace]) {
        let built = faces.compactMap { face in WordmarkArtwork.artwork(for: face).map { (face, $0) } }
        guard built.contains(where: { $0.0.id == "rubberHose" }), let count = built.first?.1.glyphs.count,
              built.allSatisfy({ $0.1.glyphs.count == count }) else { return nil }
        self.faces = built.map(\.0)
        artworks = Dictionary(uniqueKeysWithValues: built.map { ($0.0.id, $0.1) })
        boxes = (0..<count).map { slot in
            let glyphs = built.map { $0.1.glyphs[slot] }
            let minColumn = glyphs.map(\.column).min()!, minRow = glyphs.map(\.row).min()!
            let maxColumn = glyphs.map { $0.column + $0.width }.max()!, maxRow = glyphs.map { $0.row + $0.height }.max()!
            return WordmarkCellBox(column: minColumn - 1, row: minRow - 1,
                                   width: maxColumn + 2 - (minColumn - 1), height: maxRow + 6 - (minRow - 1))
        }
        pivots = (0..<count).map { slot in
            let points = built.map { $0.1.glyphs[slot].arcPoint }
            return CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count), y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
        }
        angles = (0..<count).map { slot in built.map { $0.1.glyphs[slot].angle }.reduce(0, +) / CGFloat(built.count) }
    }

    /// Rubber Hose's title: the layout canvas and the marquee bulbs.
    var classic: WordmarkArtwork { artworks["rubberHose"]! }

    /// The glyph a style draws in a slot: its face's, or Rubber Hose's when the face is unknown.
    func glyph(_ style: AgentLandWordmarkStyle, slot: Int) -> WordmarkGlyph {
        (artworks[style.face] ?? artworks["rubberHose"]!).glyphs[slot]
    }

    /// The style's tones for a slot, lifted a tone (`boosted`, tones 2–4) or with a five-cell white sparkle
    /// centred on `sparkle` (absolute cells; only on drawn cells).
    func tones(_ style: AgentLandWordmarkStyle, slot: Int, ramp: AgentLandClownRamp?, boosted: Bool = false,
               sparkle: (column: Int, row: Int)? = nil) -> [UInt8] {
        let box = boxes[slot]
        var tones = style.look.tones(of: glyph(style, slot: slot), in: box, ramp: ramp)
        if boosted { tones = tones.map { (2...4).contains($0) ? $0 + 1 : $0 } }
        if let sparkle {
            for (dx, dy) in [(0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)] {
                let x = sparkle.column + dx - box.column, y = sparkle.row + dy - box.row
                guard (0..<box.width).contains(x), (0..<box.height).contains(y), tones[y * box.width + x] > 0 else { continue }
                tones[y * box.width + x] = 5
            }
        }
        return tones
    }

    /// The style's letter for a slot in a ramp's tones, or white without a ramp, filling the slot box.
    func face(_ style: AgentLandWordmarkStyle, slot: Int, ramp: AgentLandClownRamp?, boosted: Bool = false,
              sparkle: (column: Int, row: Int)? = nil) -> CGImage? {
        let key = ImageKey(style: style, slot: slot, ramp: ramp.map { "\($0)" }, boosted: boosted,
                           sparkle: sparkle.map { [$0.column, $0.row] } ?? [], mask: false)
        return cached(key) {
            let box = boxes[slot], tones = tones(style, slot: slot, ramp: ramp, boosted: boosted, sparkle: sparkle)
            guard let ramp else { return WordmarkBitmap.mask(width: box.width, height: box.height) { tones[$1 * box.width + $0] > 0 } }
            return AgentLandTonalArtwork.image(width: box.width, height: box.height, indices: tones, ramp: ramp)
        }
    }

    /// White wherever the style draws in a slot.
    func mask(_ style: AgentLandWordmarkStyle, slot: Int) -> CGImage? {
        let key = ImageKey(style: style, slot: slot, ramp: nil, boosted: false, sparkle: [], mask: true)
        return cached(key) {
            let box = boxes[slot], tones = tones(style, slot: slot, ramp: .night)
            return WordmarkBitmap.mask(width: box.width, height: box.height) { tones[$1 * box.width + $0] > 0 }
        }
    }

    /// Masks that build a slot's letter up from nothing to the whole of it in `count` steps (`count + 1`
    /// frames): its cells in a seeded order, its columns from the arch's middle outward, or its rows from the
    /// bottom up.
    func revealMasks(_ style: AgentLandWordmarkStyle, slot: Int, count: Int, order: WordmarkReveal) -> [CGImage] {
        let box = boxes[slot], tones = tones(style, slot: slot, ramp: .night)
        let lit = tones.indices.filter { tones[$0] > 0 }
        guard !lit.isEmpty, count > 0 else { return [] }
        let xs = lit.map { $0 % box.width }, ys = lit.map { $0 / box.width }
        let minX = xs.min()!, maxX = xs.max()!, maxY = ys.max()!, minY = ys.min()!
        var rank = [Int](repeating: Int.max, count: tones.count)
        if case let .seeded(seed) = order {
            var generator = AgentLandSeededGenerator(seed: seed)
            for (position, cell) in lit.shuffled(using: &generator).enumerated() { rank[cell] = position }
        }
        return (0...count).compactMap { step in
            let share = Double(step) / Double(count)
            let shown: (Int, Int) -> Bool
            switch order {
            case .seeded:
                let limit = Int((Double(lit.count) * share).rounded(.up))
                shown = { x, y in rank[y * box.width + x] < limit }
            case let .columnsFromMiddle(fromLeft):
                let columns = Int((Double(maxX - minX + 1) * share).rounded(.up))
                shown = { x, _ in fromLeft ? x < minX + columns : x > maxX - columns }
            case .rowsFromBottom:
                let rows = Int((Double(maxY - minY + 1) * share).rounded(.up))
                shown = { _, y in y > maxY - rows }
            }
            return WordmarkBitmap.mask(width: box.width, height: box.height) { x, y in tones[y * box.width + x] > 0 && shown(x, y) }
        }
    }

    /// From one style to another pixel by pixel in a seeded order, `steps + 1` frames: the first exactly
    /// `from`'s images, the last exactly `to`'s.
    func dissolve(from: AgentLandWordmarkStyle, to: AgentLandWordmarkStyle, slot: Int, steps: Int, seed: UInt64,
                  ramp: AgentLandClownRamp?) -> (faces: [CGImage], masks: [CGImage]) {
        let box = boxes[slot], a = tones(from, slot: slot, ramp: ramp), b = tones(to, slot: slot, ramp: ramp)
        var generator = AgentLandSeededGenerator(seed: seed)
        var rank = [Int](repeating: 0, count: a.count)
        for (position, cell) in Array(a.indices).shuffled(using: &generator).enumerated() { rank[cell] = position }
        var faces: [CGImage] = [], masks: [CGImage] = []
        for step in 0...max(1, steps) {
            if step == 0 || step == max(1, steps) {
                let style = step == 0 ? from : to
                if let face = face(style, slot: slot, ramp: ramp), let mask = mask(style, slot: slot) { faces.append(face); masks.append(mask) }
                continue
            }
            let limit = a.count * step / max(1, steps)
            let mixed = a.indices.map { rank[$0] < limit ? b[$0] : a[$0] }
            if let images = images(mixed, box: box, ramp: ramp) { faces.append(images.face); masks.append(images.mask) }
        }
        return (faces, masks)
    }

    /// Drips of two to six cells under about half the columns, growing over `steps` frames and drawing back:
    /// `2 steps + 1` frames, the first and last the plain letter.
    func drip(_ style: AgentLandWordmarkStyle, slot: Int, steps: Int, seed: UInt64,
              ramp: AgentLandClownRamp?) -> (faces: [CGImage], masks: [CGImage]) {
        let box = boxes[slot], base = tones(style, slot: slot, ramp: ramp)
        var generator = AgentLandSeededGenerator(seed: seed)
        let lengths = (0..<box.width).map { _ -> Int in
            Double.random(in: 0..<1, using: &generator) < 0.45 ? 0 : Int.random(in: 2...6, using: &generator)
        }
        func frame(_ step: Int) -> [UInt8] {
            var tones = base
            for x in 0..<box.width where lengths[x] > 0 {
                guard let bottom = (0..<box.height).last(where: { base[$0 * box.width + x] > 0 }) else { continue }
                let length = Int((Double(lengths[x] * step) / Double(steps)).rounded())
                for k in 1...max(1, length) where length > 0 && bottom + k < box.height {
                    tones[(bottom + k) * box.width + x] = k == length ? 1 : 2
                }
            }
            return tones
        }
        guard let plainFace = face(style, slot: slot, ramp: ramp), let plainMask = mask(style, slot: slot) else { return ([], []) }
        var faces = [plainFace], masks = [plainMask]
        for step in Array(1...steps) + Array((1..<steps).reversed()) {
            if let images = images(frame(step), box: box, ramp: ramp) { faces.append(images.face); masks.append(images.mask) }
        }
        faces.append(plainFace); masks.append(plainMask)
        return (faces, masks)
    }

    /// `count` distinct cells, each a drawn cell inside a letter's outline (tone above 1), chosen by `seed`.
    func sparkles(_ style: AgentLandWordmarkStyle, seed: UInt64, count: Int) -> [(slot: Int, column: Int, row: Int)] {
        var candidates: [(slot: Int, column: Int, row: Int)] = []
        for slot in boxes.indices {
            let box = boxes[slot], tones = tones(style, slot: slot, ramp: .night)
            for index in tones.indices where tones[index] > 1 && glyph(style, slot: slot).isOn(
                box.column + index % box.width - glyph(style, slot: slot).column, box.row + index / box.width - glyph(style, slot: slot).row) {
                candidates.append((slot, box.column + index % box.width, box.row + index / box.width))
            }
        }
        var generator = AgentLandSeededGenerator(seed: seed)
        return Array(candidates.shuffled(using: &generator).prefix(count))
    }

    private func images(_ tones: [UInt8], box: WordmarkCellBox, ramp: AgentLandClownRamp?) -> (face: CGImage, mask: CGImage)? {
        guard let mask = WordmarkBitmap.mask(width: box.width, height: box.height, { tones[$1 * box.width + $0] > 0 }) else { return nil }
        guard let ramp else { return (mask, mask) }
        return AgentLandTonalArtwork.image(width: box.width, height: box.height, indices: tones, ramp: ramp).map { ($0, mask) }
    }

    private func cached(_ key: ImageKey, make: () -> CGImage?) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        if let image = images[key] { return image }
        let image = make()
        if let image { images[key] = image }
        return image
    }
}

/// What a title animation is built from: the font set, the load's style and the ramp the letters are drawn in
/// (nil for a one-colour title, whose letters are tinted masks).
struct WordmarkStage: Sendable {
    let set: WordmarkFontSet
    let style: AgentLandWordmarkStyle
    let ramp: AgentLandClownRamp?
}

/// The order in which a reveal builds a letter up.
enum WordmarkReveal: Sendable {
    case seeded(UInt64), columnsFromMiddle(fromLeft: Bool), rowsFromBottom
}
