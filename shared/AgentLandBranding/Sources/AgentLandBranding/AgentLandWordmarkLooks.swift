import CoreGraphics
import Foundation

/// How the title's letters are drawn, one look per Home load, always in the five ramp tones (1 outline,
/// 2 dark, 3 mid, 4 light, 5 white). `bevel` is the original stepped shading; the others add depth, a
/// shadow, a second outline or candy stripes.
public enum AgentLandWordmarkLook: String, CaseIterable, Sendable {
    case bevel, extrude, candyStripe, dropShadow, doubleOutline
}

/// A rectangle of the tent's art-pixel grid, in absolute cells (column and row from the grid origin).
struct WordmarkCellBox: Hashable, Sendable {
    let column: Int, row: Int, width: Int, height: Int

    /// In circus scene units.
    var frame: CGRect {
        let unit = AgentLandWordmarkGeometry.artUnit, origin = AgentLandWordmarkGeometry.gridOrigin
        return CGRect(x: origin.x + CGFloat(column) * unit, y: origin.y + CGFloat(row) * unit,
                      width: CGFloat(width) * unit, height: CGFloat(height) * unit)
    }
}

extension AgentLandWordmarkLook {
    /// The look's tone for every cell of `box` (row-major from the top; 0 empty, 1–5 the ramp) for `glyph`,
    /// which must lie inside the box. Without a ramp (a one-colour title) the night ramp's rule applies.
    func tones(of glyph: WordmarkGlyph, in box: WordmarkCellBox, ramp: AgentLandClownRamp?) -> [UInt8] {
        // Glyph-local coordinates of a box cell.
        func on(_ x: Int, _ y: Int) -> Bool { glyph.isOn(x, y) }
        let dx = box.column - glyph.column, dy = box.row - glyph.row
        var tones = [UInt8](repeating: 0, count: box.width * box.height)
        for by in 0..<box.height { for bx in 0..<box.width {
            let x = bx + dx, y = by + dy
            let tone: UInt8
            if on(x, y) {
                let edge = !on(x - 1, y) || !on(x + 1, y) || !on(x, y - 1) || !on(x, y + 1)
                if self == .candyStripe {
                    let band = (box.column + bx + box.row + by)
                    tone = edge ? 1 : (((band >= 0 ? band / 2 : (band - 1) / 2) & 1) == 1 ? 5 : 3)
                } else {
                    tone = Self.bevel(glyph, x, y)
                }
            } else {
                switch self {
                case .extrude: tone = on(x - 1, y - 1) || on(x - 2, y - 2) || on(x - 1, y - 2) || on(x - 2, y - 1) ? 2 : 0
                case .dropShadow: tone = on(x - 2, y - 2) ? 1 : 0
                case .doubleOutline:
                    let near = (-1...1).contains { oy in (-1...1).contains { ox in on(x + ox, y + oy) } }
                    tone = near ? (ramp == .day ? 2 : 5) : 0
                case .bevel, .candyStripe: tone = 0
                }
            }
            tones[by * box.width + bx] = tone
        } }
        if self == .extrude {
            // The extrusion's far edges are outlined where they meet the backdrop.
            let drawn = tones
            func empty(_ bx: Int, _ by: Int) -> Bool {
                bx >= box.width || by >= box.height || drawn[by * box.width + bx] == 0
            }
            for by in 0..<box.height { for bx in 0..<box.width where drawn[by * box.width + bx] == 2 && !on(bx + dx, by + dy) {
                if empty(bx + 1, by) || empty(bx, by + 1) || empty(bx + 1, by + 1) { tones[by * box.width + bx] = 1 }
            } }
        }
        return tones
    }

    /// The original stepped bevel (WordmarkGlyph.tonalImage): a one-pixel outline, white two pixels in from
    /// the top and left, dark two in from the bottom and right, light upper half, mid lower half.
    private static func bevel(_ glyph: WordmarkGlyph, _ x: Int, _ y: Int) -> UInt8 {
        if !glyph.isOn(x - 1, y) || !glyph.isOn(x + 1, y) || !glyph.isOn(x, y - 1) || !glyph.isOn(x, y + 1) { return 1 }
        if !glyph.isOn(x - 2, y) || !glyph.isOn(x, y - 2) { return 5 }
        if !glyph.isOn(x + 2, y) || !glyph.isOn(x, y + 2) { return 2 }
        return y < glyph.height / 2 ? 4 : 3
    }
}
