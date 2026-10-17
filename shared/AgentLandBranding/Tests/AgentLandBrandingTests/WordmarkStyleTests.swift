import CoreGraphics
import CoreText
import XCTest
@testable import AgentLandBranding

/// The title's faces, their artworks, looks and the font set that paints every face and look into fixed
/// letter boxes.
final class WordmarkStyleTests: XCTestCase {
    func testEveryFaceLoadsFromItsBundledFile() throws {
        XCTAssertEqual(AgentLandWordmarkFaces.all.map(\.id),
                       ["rubberHose", "holtwood", "bungee", "chango", "alfaSlabOne", "titanOne", "bowlbyOneSC", "shrikhand", "coiny"])
        XCTAssertEqual(AgentLandWordmarkFaces.available, AgentLandWordmarkFaces.all, "Every bundled file loads")
        for face in AgentLandWordmarkFaces.all {
            let font = try XCTUnwrap(AgentLandWordmarkFaces.font(face, size: 40), face.id)
            var h: UniChar = 72, glyph = CGGlyph(0)
            XCTAssertTrue(CTFontGetGlyphsForCharacters(font, &h, &glyph, 1), "\(face.id) has capitals")
        }
    }

    func testEveryOpenLicenceFontShipsItsLicence() {
        let text = AgentLandWordmarkFaces.licenseText
        for face in AgentLandWordmarkFaces.all where face.id != "rubberHose" {
            XCTAssertTrue(text.contains(face.displayName), face.displayName)
        }
        XCTAssertGreaterThanOrEqual(text.components(separatedBy: "SIL OPEN FONT LICENSE Version 1.1").count - 1, 8)
        XCTAssertEqual(AgentLandWordmarkFont.licenseText, text, "Settings shows every notice")
    }

    func testEveryFaceBuildsALegibleTitleOnTheArch() throws {
        let canvas = AgentLandWordmarkGeometry.canvas, unit = AgentLandWordmarkGeometry.artUnit
        for face in AgentLandWordmarkFaces.all {
            let art = try XCTUnwrap(WordmarkArtwork.artwork(for: face), face.id)
            XCTAssertEqual(String(art.glyphs.map(\.character)), "AGENTLAND")
            XCTAssertEqual(art.capHeight, 48, accuracy: 0.001)
            for glyph in art.glyphs {
                XCTAssertTrue((16...25).contains(glyph.height), "\(face.id) \(glyph.character) is \(glyph.height) cells tall")
                XCTAssertTrue(canvas.insetBy(dx: -3 * unit, dy: -3 * unit).contains(glyph.frame), "\(face.id) within three cells of the canvas")
            }
            // Neighbours never share a lit cell.
            for (a, b) in zip(art.glyphs, art.glyphs.dropFirst()) {
                XCTAssertTrue(litCells(a).isDisjoint(with: litCells(b)), "\(face.id) \(a.character)\(b.character)")
            }
        }
        XCTAssertEqual(WordmarkArtwork.shared?.canvas, AgentLandWordmarkGeometry.canvas, "Layout canvas unchanged")
    }

    func testBevelIsTodaysShading() throws {
        let set = try XCTUnwrap(WordmarkFontSet.shared), art = try XCTUnwrap(WordmarkArtwork.shared)
        for ramp in [AgentLandClownRamp.day, .night] {
            for (slot, glyph) in art.glyphs.enumerated() {
                let box = set.boxes[slot], tones = AgentLandWordmarkLook.bevel.tones(of: glyph, in: box, ramp: ramp)
                XCTAssertEqual(drawnCells(tones, box), litCells(glyph), "Nothing but the letter is drawn")
                // Every lit cell carries the tone today's tonalImage gives it.
                let today = toneIndices(try XCTUnwrap(glyph.tonalImage(ramp: ramp)), ramp: ramp)
                for y in 0..<glyph.height { for x in 0..<glyph.width where glyph.isOn(x, y) {
                    let cell = (glyph.row + y - box.row) * box.width + (glyph.column + x - box.column)
                    XCTAssertEqual(tones[cell], today[y * glyph.width + x], "\(glyph.character) (\(x), \(y))")
                } }
            }
        }
    }

    func testLooksUseOnlyTheRampAndStayInTheirBox() throws {
        let set = try XCTUnwrap(WordmarkFontSet.shared)
        for face in set.faces { for look in AgentLandWordmarkLook.allCases { for ramp in [AgentLandClownRamp.day, .night] {
            let art = try XCTUnwrap(WordmarkArtwork.artwork(for: face))
            for (slot, glyph) in art.glyphs.enumerated() {
                let box = set.boxes[slot], tones = look.tones(of: glyph, in: box, ramp: ramp)
                XCTAssertEqual(tones.count, box.width * box.height)
                XCTAssertTrue(tones.allSatisfy { $0 <= 5 })
                XCTAssertTrue(litCells(glyph).isSubset(of: drawnCells(tones, box)), "\(face.id) \(look) keeps every glyph cell")
                let style = AgentLandWordmarkStyle(face: face.id, look: look)
                let image = try XCTUnwrap(set.face(style, slot: slot, ramp: ramp)), mask = try XCTUnwrap(set.mask(style, slot: slot))
                XCTAssertEqual([image.width, image.height, mask.width, mask.height], [box.width, box.height, box.width, box.height],
                               "Every face and look fills the same slot box")
                XCTAssertEqual(opaqueCells(mask, box), drawnCells(tones, box), "\(face.id) \(look): the mask covers exactly what the look draws")
                XCTAssertEqual(opaqueCells(image, box), drawnCells(tones, box), "\(face.id) \(look): the face draws exactly the look")
            }
        } } }
    }

    func testExtrudeAndShadowFallDownRightAndTheDoubleOutlineIsOneCell() throws {
        let set = try XCTUnwrap(WordmarkFontSet.shared), art = try XCTUnwrap(WordmarkArtwork.shared)
        for (slot, glyph) in art.glyphs.enumerated() {
            let box = set.boxes[slot], lit = litCells(glyph)
            func extra(_ look: AgentLandWordmarkLook, _ ramp: AgentLandClownRamp) -> Set<Int> {
                drawnCells(look.tones(of: glyph, in: box, ramp: ramp), box).subtracting(lit)
            }
            let extrude = extra(.extrude, .night), shadow = extra(.dropShadow, .night), double = extra(.doubleOutline, .night)
            XCTAssertFalse(extrude.isEmpty); XCTAssertFalse(shadow.isEmpty); XCTAssertFalse(double.isEmpty)
            for key in extrude { XCTAssertTrue([(1, 1), (2, 2), (1, 2), (2, 1)].contains { lit.contains(key - cellKey($0.0, $0.1) + cellKey(0, 0)) }, "Extrusion falls down-right") }
            for key in shadow { XCTAssertTrue(lit.contains(key - cellKey(2, 2) + cellKey(0, 0)), "The shadow is the letter two cells down-right") }
            for key in double {
                XCTAssertTrue((-1...1).contains { dy in (-1...1).contains { dx in lit.contains(key + cellKey(dx, dy) - cellKey(0, 0)) } },
                              "The second outline is one cell round the letter")
            }
            XCTAssertTrue(lit.allSatisfy { !double.contains($0) })
        }
    }

    func testAMissingFaceIsSkipped() throws {
        let missing = AgentLandWordmarkFace(id: "missing", displayName: "Missing", resource: "NoSuchFont", licence: nil)
        let set = try XCTUnwrap(WordmarkFontSet(faces: [AgentLandWordmarkFaces.all[0], missing]))
        XCTAssertEqual(set.faces.map(\.id), ["rubberHose"])
        XCTAssertNil(WordmarkFontSet(faces: [missing]), "No Rubber Hose, no title")
    }
}

/// A grid cell (absolute column and row) packed into one integer.
func cellKey(_ column: Int, _ row: Int) -> Int { (row + 10_000) * 100_000 + (column + 10_000) }

/// The glyph's lit cells, in absolute grid cells.
func litCells(_ glyph: WordmarkGlyph) -> Set<Int> {
    var cells = Set<Int>()
    for y in 0..<glyph.height { for x in 0..<glyph.width where glyph.isOn(x, y) { cells.insert(cellKey(glyph.column + x, glyph.row + y)) } }
    return cells
}

/// The drawn cells of a slot's tones, in absolute grid cells.
func drawnCells(_ tones: [UInt8], _ box: WordmarkCellBox) -> Set<Int> {
    var cells = Set<Int>()
    for y in 0..<box.height { for x in 0..<box.width where tones[y * box.width + x] > 0 { cells.insert(cellKey(box.column + x, box.row + y)) } }
    return cells
}

/// The image's opaque pixels, one per cell of `box`, in absolute grid cells.
func opaqueCells(_ image: CGImage, _ box: WordmarkCellBox) -> Set<Int> {
    let bytes = AgentLandClownArtwork.rgbaBytes(image) ?? []
    var cells = Set<Int>()
    for y in 0..<image.height { for x in 0..<image.width where bytes[(y * image.width + x) * 4 + 3] > 0 {
        cells.insert(cellKey(box.column + x, box.row + y))
    } }
    return cells
}

/// Each pixel's tone index (0 transparent, 1–5 the ramp's tones).
func toneIndices(_ image: CGImage, ramp: AgentLandClownRamp) -> [UInt8] {
    let bytes = AgentLandClownArtwork.rgbaBytes(image) ?? [], tones = AgentLandTonalArtwork.tones(ramp) ?? []
    return (0..<(image.width * image.height)).map { index in
        guard bytes[index * 4 + 3] > 0 else { return 0 }
        let colour = (0..<3).map { Int(bytes[index * 4 + $0]) }
        let best = tones.enumerated().min { a, b in
            zip(a.element, colour).reduce(0) { $0 + abs(Int($1.0) - $1.1) } < zip(b.element, colour).reduce(0) { $0 + abs(Int($1.0) - $1.1) }
        }
        return UInt8((best?.offset ?? -1) + 1)
    }
}
