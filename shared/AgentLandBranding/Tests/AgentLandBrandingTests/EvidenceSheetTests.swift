import CoreGraphics
import CoreText
import ImageIO
import QuartzCore
import UniformTypeIdentifiers
import XCTest
#if os(macOS)
import Metal
#endif
@testable import AgentLandBranding

/// Evidence sheets, drawn from the shipped resources and the motion functions the app uses, in the
/// layers AgentLandCircusLoading draws on a work surface: the back clown, the tent's depth mask, the doorway's
/// fill, the clown in the doorway (seen through the opening), the tent's loop frame, the ground balls, the front
/// clown and the doorway clown past the threshold. It runs only when AGENTLAND_BRANDING_EVIDENCE names a folder.
final class EvidenceSheetTests: XCTestCase {
    private struct Palette { let name: String; let paper: UInt32; let ink: UInt32; var ramp: AgentLandClownRamp = .night }
    private let slate = Palette(name: "Slate (the empty-chat landing, dark paper)", paper: 0x27313F, ink: 0xD6DDE7)
    private let light = Palette(name: "Home, light paper", paper: 0xF4F0E7, ink: 0x354052, ramp: .day)
    private static let doorwayShade: UInt32 = 0x1B222C

    private var folder: URL? {
        ProcessInfo.processInfo.environment["AGENTLAND_BRANDING_EVIDENCE"].map { URL(fileURLWithPath: $0) }
    }

    /// Each design on the ring in front of the tent, juggling, on light paper and on slate.
    func testWriteDesignRenders() throws {
        guard let folder else { throw XCTSkip("Set AGENTLAND_BRANDING_EVIDENCE to a folder to write the renders") }
        let designs = AgentLandClownArtwork.designs
        XCTAssertEqual(designs.count, 6)
        let scale: CGFloat = 8.0 / 3.0, top: CGFloat = 40, bottom: CGFloat = 360
        let panel = CGSize(width: 336 * scale, height: (bottom - top) * scale), gap: CGFloat = 20, header: CGFloat = 44
        let sheet = try canvas(width: Int(CGFloat(designs.count) * (panel.width + gap) + gap), height: Int(2 * (panel.height + gap + header) + gap))
        for (column, design) in designs.enumerated() {
            // A moment on the near side of the ring, three balls up, on its own performance clock.
            let lap = AgentLandClownMotion.orbitPeriod
            let join = AgentLandCircusChoreography.fadeDuration + AgentLandCircusChoreography.rideDuration
            let appearance = AgentLandCircusChoreography.Appearance(design: column, emerge: 0, join: join, stop: join + 60,
                                                                    turn: join + 10 * lap, back: join + 10 * lap + 0.5,
                                                                    gone: join + 10 * lap + 0.9, offset: 0)
            let time = join + 6 * lap + lap * 0.07 + Double(column) * 0.1
            for (row, palette) in [light, slate].enumerated() {
                let origin = CGPoint(x: gap + CGFloat(column) * (panel.width + gap), y: gap + CGFloat(1 - row) * (panel.height + gap + header))
                let painter = Painter(context: sheet, origin: origin, scale: scale, top: top, size: panel)
                painter.background(palette.paper)
                try drawScene(painter, time: time, clowns: [(appearance, design)], palette: palette, ground: [])
                label("\(design.name)  ·  \(palette.name)", in: sheet, at: CGPoint(x: origin.x, y: origin.y + panel.height + 12), size: 16)
            }
        }
        try write(sheet.makeImage()!, to: folder.appendingPathComponent("designs.png"))
    }

    /// Every packaged ride frame of every design at 8x, as the app draws it: in the day tones on paper (top two
    /// rows) and in the night tones on slate (bottom two), each with its backdrop-coloured ring.
    func testWriteRideFramesAt8x() throws {
        guard let folder else { throw XCTSkip("Set AGENTLAND_BRANDING_EVIDENCE to a folder to write the frames") }
        for design in AgentLandClownArtwork.designs {
            let side = 96 * 8, gap = 8, labelHeight = 30
            let sheet = try canvas(width: 6 * (side + gap) + gap, height: 4 * (side + gap + labelHeight) + gap)
            for (band, palette) in [light, slate].enumerated() {
                let tones = try XCTUnwrap(design.tones[palette.ramp])
                for (index, frame) in design.indices.enumerated() {
                    let row = band * 2 + index / 6
                    let x = gap + (index % 6) * (side + gap), y = gap + (3 - row) * (side + gap + labelHeight)
                    let ring = alpha(design.outlines[index])
                    sheet.setFillColor(color(palette.paper == light.paper ? 0xE4DFD3 : 0x3A4658))
                    sheet.fill(CGRect(x: x, y: y, width: side, height: side))
                    for py in 0..<96 { for px in 0..<96 {
                        let tone = frame[py * 96 + px]
                        guard tone > 0 || ring[py * 96 + px] else { continue }
                        sheet.setFillColor(tone > 0 ? cgColor(tones[Int(tone) - 1]) : color(palette.paper))
                        sheet.fill(CGRect(x: x + px * 8, y: y + (95 - py) * 8, width: 8, height: 8))
                    } }
                    label(String(format: "%@ frame %02d (%.1f s), %@ tones", design.name, index, Double(index) * 0.1,
                                 palette.ramp == .day ? "day" : "night"), in: sheet, at: CGPoint(x: x, y: y + side + 8), size: 16)
                }
            }
            try write(sheet.makeImage()!, to: folder.appendingPathComponent("ride-\(design.name)-8x.png"))
        }
    }

    /// Every ride frame of every design at 1x, the size the sprite's pixels have on a 3x screen at the scene's
    /// scale: one row per design on paper in the day tones and on slate in the night tones.
    func testWriteRideStripAt1x() throws {
        guard let folder else { throw XCTSkip("Set AGENTLAND_BRANDING_EVIDENCE to a folder to write the strip") }
        let designs = AgentLandClownArtwork.designs
        let sheet = try canvas(width: 2 * 12 * 96, height: designs.count * 96)
        for (row, design) in designs.enumerated() {
            for (band, palette) in [light, slate].enumerated() {
                let tones = try XCTUnwrap(design.tones[palette.ramp])
                let left = band * 12 * 96, top = (designs.count - 1 - row) * 96
                sheet.setFillColor(color(palette.paper))
                sheet.fill(CGRect(x: left, y: top, width: 12 * 96, height: 96))
                for (index, frame) in design.indices.enumerated() {
                    for py in 0..<96 { for px in 0..<96 where frame[py * 96 + px] > 0 {
                        sheet.setFillColor(cgColor(tones[Int(frame[py * 96 + px]) - 1]))
                        sheet.fill(CGRect(x: left + index * 96 + px, y: top + 95 - py, width: 1, height: 1))
                    } }
                }
            }
        }
        try write(sheet.makeImage()!, to: folder.appendingPathComponent("ride-strip-1x.png"))
    }

    /// The two-tone riders that shipped before (branding/archive/2026-09-28-clown-two-tone/, drawn as the app drew
    /// them: ink in the surface's colour, light details and ring in the backdrop) next to the tonal ones, each
    /// design's frames 0, 3, 6 and 9 at 3x on paper and on slate; and each surface as a GIF of all twelve frames
    /// at 0.1 s, old on the left of each pair.
    func testWriteOldNextToNew() throws {
        guard let folder else { throw XCTSkip("Set AGENTLAND_BRANDING_EVIDENCE to a folder to write the comparison") }
        let archive = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("branding/archive/2026-09-28-clown-two-tone")
        let designs = AgentLandClownArtwork.designs
        func oldFrames(_ name: String) throws -> [[UInt8]] {
            let url = archive.appendingPathComponent("\(name)/ClownRide-\(name).png")
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let strip = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let bytes = try XCTUnwrap(AgentLandClownArtwork.rgbaBytes(strip))
            // 1: ink (white), 2: light detail (black), 0: transparent.
            return (0..<(strip.width / 96)).map { frame in
                (0..<(96 * 96)).map { index in
                    let offset = ((index / 96) * strip.width + frame * 96 + index % 96) * 4
                    return bytes[offset + 3] < 128 ? 0 : bytes[offset] >= 128 ? 1 : 2
                }
            }
        }
        /// One frame's colours, row by row. Before, everything but the ink showed the backdrop.
        func picture(old: [UInt8]?, new: [UInt8]?, palette: Palette, design: AgentLandClownDesign) -> [UInt32] {
            if let old { return old.map { $0 == 1 ? palette.ink : palette.paper } }
            let tones = design.tones[palette.ramp]!
            return new!.map { $0 == 0 ? palette.paper : hex(tones[Int($0) - 1]) }
        }
        func paint(_ colours: [UInt32], in context: CGContext, at origin: CGPoint, scale: Int, height: Int) {
            for py in 0..<96 { for px in 0..<96 {
                context.setFillColor(color(colours[py * 96 + px]))
                context.fill(CGRect(x: Int(origin.x) + px * scale, y: height - Int(origin.y) - (py + 1) * scale, width: scale, height: scale))
            } }
        }
        // The sheet.
        let scale = 3, cell = 96 * scale, gap = 6, header = 26
        let picks = [0, 3, 6, 9]
        let columns = 4 * picks.count
        let width = columns * (cell + gap) + 3 * 16 + gap, height = designs.count * (cell + gap + header) + header + gap
        let sheet = try canvas(width: width, height: height)
        for (column, title) in ["before, day", "after, day tones", "before, slate", "after, night tones"].enumerated() {
            label(title, in: sheet, at: CGPoint(x: gap + column * (picks.count * (cell + gap) + 16), y: height - 18), size: 16)
        }
        for (row, design) in designs.enumerated() {
            let old = try oldFrames(design.name)
            XCTAssertEqual(old.count, 12)
            let top = header + row * (cell + gap + header)
            label(design.name, in: sheet, at: CGPoint(x: gap, y: height - top - 18), size: 15)
            for (group, (palette, isOld)) in [(light, true), (light, false), (slate, true), (slate, false)].enumerated() {
                for (slot, index) in picks.enumerated() {
                    let colours = picture(old: isOld ? old[index] : nil, new: isOld ? nil : design.indices[index], palette: palette, design: design)
                    paint(colours, in: sheet, at: CGPoint(x: gap + group * (picks.count * (cell + gap) + 16) + slot * (cell + gap), y: top + header),
                          scale: scale, height: height)
                }
            }
        }
        try write(sheet.makeImage()!, to: folder.appendingPathComponent("old-vs-new.png"))
        // The GIFs: three designs a row, each as a before/after pair.
        for palette in [light, slate] {
            let gifScale = 2, pair = 2 * 96 * gifScale + gap, perRow = 3
            let gifWidth = perRow * (pair + 3 * gap) + gap, gifHeight = 2 * (96 * gifScale + gap) + gap
            let url = folder.appendingPathComponent(palette.ramp == .day ? "old-vs-new-paper.gif" : "old-vs-new-slate.gif")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 12, nil))
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            let olds = try designs.map { try oldFrames($0.name) }
            for index in 0..<12 {
                let frame = try canvas(width: gifWidth, height: gifHeight)
                frame.setFillColor(color(palette.paper)); frame.fill(CGRect(x: 0, y: 0, width: gifWidth, height: gifHeight))
                for (slot, design) in designs.enumerated() {
                    let left = gap + (slot % perRow) * (pair + 3 * gap), top = gap + (slot / perRow) * (96 * gifScale + gap)
                    paint(picture(old: olds[slot][index], new: nil, palette: palette, design: design), in: frame,
                          at: CGPoint(x: left, y: top), scale: gifScale, height: gifHeight)
                    paint(picture(old: nil, new: design.indices[index], palette: palette, design: design), in: frame,
                          at: CGPoint(x: left + 96 * gifScale + gap, y: top), scale: gifScale, height: gifHeight)
                }
                CGImageDestinationAddImage(destination, frame.makeImage()!,
                                           [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1,
                                                                            kCGImagePropertyGIFUnclampedDelayTime: 0.1]] as CFDictionary)
            }
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            print("Wrote \(url.path)")
        }
    }

    /// The tent loop: its 12 frames at 4x in a strip, and a GIF at 0.1 s a frame (light paper and slate).
    func testWriteTentLoop() throws {
        guard let folder else { throw XCTSkip("Set AGENTLAND_BRANDING_EVIDENCE to a folder to write the loop") }
        let loop = try XCTUnwrap(AgentLandTentLoop.artwork)
        let doorwayImage = try XCTUnwrap(AgentLandBrandingResources.image("TentDoorway"))
        let doorway = alpha(doorwayImage), tentSide = doorwayImage.width
        func frameImage(_ index: Int, palette: Palette, scale: Int) throws -> CGImage {
            let tones = try XCTUnwrap(AgentLandTentArt.tonal(frame: index, ramp: palette.ramp))
            let pixels = try XCTUnwrap(AgentLandClownArtwork.rgbaBytes(tones))
            let image = try canvas(width: tentSide * scale, height: tentSide * scale)
            image.setFillColor(color(palette.paper)); image.fill(CGRect(x: 0, y: 0, width: tentSide * scale, height: tentSide * scale))
            for y in 0..<tentSide { for x in 0..<tentSide where pixels[(y * tentSide + x) * 4 + 3] > 0 || doorway[y * tentSide + x] {
                let offset = (y * tentSide + x) * 4
                let shade = pixels[offset + 3] > 0
                    ? UInt32(pixels[offset]) << 16 | UInt32(pixels[offset + 1]) << 8 | UInt32(pixels[offset + 2])
                    : Self.doorwayShade
                image.setFillColor(color(shade))
                image.fill(CGRect(x: x * scale, y: (tentSide - 1 - y) * scale, width: scale, height: scale))
            } }
            return image.makeImage()!
        }
        let scale = 4, gap = 8, side = tentSide * scale
        let strip = try canvas(width: loop.marks.count * (side + gap) + gap, height: 2 * (side + gap) + 40)
        for index in loop.marks.indices {
            for (row, palette) in [light, slate].enumerated() {
                strip.draw(try frameImage(index, palette: palette, scale: scale),
                           in: CGRect(x: gap + index * (side + gap), y: gap + (1 - row) * (side + gap), width: side, height: side))
            }
            label(String(format: "%02d  %.1f s%@", index, Double(index) * loop.frameDuration, index % 3 == 0 ? "  beat" : ""), in: strip,
                  at: CGPoint(x: gap + index * (side + gap), y: 2 * (side + gap) + 12), size: 16)
        }
        try write(strip.makeImage()!, to: folder.appendingPathComponent("tent-loop-strip.png"))
        for palette in [light, slate] {
            let url = folder.appendingPathComponent(palette.paper == light.paper ? "tent-loop-light.gif" : "tent-loop-slate.gif")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, loop.marks.count, nil))
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            for index in loop.marks.indices {
                CGImageDestinationAddImage(destination, try frameImage(index, palette: palette, scale: 4),
                                           [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: loop.frameDuration,
                                                                            kCGImagePropertyGIFUnclampedDelayTime: loop.frameDuration]] as CFDictionary)
            }
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
    }

    /// The door choreography, frame by frame on light paper: fading in inside the doorway, riding out past the
    /// threshold to the ring, and back in at the pass by the door to fade out.
    func testWriteDoorChoreography() throws {
        guard let folder else { throw XCTSkip("Set AGENTLAND_BRANDING_EVIDENCE to a folder to write the choreography") }
        let show = AgentLandCircusChoreography(reveal: 3.0, seed: 2026_09_27)
        let first = try XCTUnwrap(show.appearance(at: 4))
        let design = AgentLandClownArtwork.designs[first.design]
        let moments: [(String, Double)] = [
            ("fade in 1/3", first.emerge + 0.05), ("fade in 2/3", first.emerge + 0.15), ("in the doorway", first.emerge + 0.25),
            ("riding out", first.emerge + 0.35), ("past the threshold", first.emerge + 0.5), ("out", first.emerge + 0.65),
            ("on the ring", first.join + 0.2), ("juggling", first.join + 3.85 * AgentLandClownMotion.orbitPeriod), ("last lap", first.turn - 0.9),
            ("riding in", first.turn + 0.15), ("at the door", first.turn + 0.35), ("fading out", first.gone - 0.15),
        ]
        let scale: CGFloat = 2, top: CGFloat = 150, bottom: CGFloat = 360
        let panel = CGSize(width: 336 * scale, height: (bottom - top) * scale), gap: CGFloat = 12, header: CGFloat = 34
        let columns = 6
        let sheet = try canvas(width: Int(CGFloat(columns) * (panel.width + gap) + gap), height: Int(2 * (panel.height + header + gap) + gap))
        for (index, (name, time)) in moments.enumerated() {
            let origin = CGPoint(x: gap + CGFloat(index % columns) * (panel.width + gap),
                                 y: gap + CGFloat(1 - index / columns) * (panel.height + header + gap))
            let painter = Painter(context: sheet, origin: origin, scale: scale, top: top, size: panel)
            painter.background(light.paper)
            try drawScene(painter, time: time, clowns: [(first, design)], palette: light, ground: show.groundBalls(at: time))
            label(String(format: "%@  %.2f s", name, time - first.emerge), in: sheet, at: CGPoint(x: origin.x, y: origin.y + panel.height + 8), size: 15)
        }
        try write(sheet.makeImage()!, to: folder.appendingPathComponent("door-choreography.png"))
        // The schedule of the first hour, for review.
        let lines = show.appearances(through: 3600).map { a in
            String(format: "%@ out %.1f s, ring %.1f s, stops %.1f s, turns %.1f s, gone %.1f s", AgentLandClownArtwork.designs[a.design].name,
                   a.emerge, a.join, a.stop, a.turn, a.gone)
        }
        try lines.joined(separator: "\n").write(to: folder.appendingPathComponent("schedule-first-hour.txt"), atomically: true, encoding: .utf8)
    }

    /// The flat title over the scene at rest, on the three surfaces.
    func testWriteTitleSheet() throws {
        guard let folder else { throw XCTSkip("Set AGENTLAND_BRANDING_EVIDENCE to a folder to write the title sheet") }
        let artwork = try XCTUnwrap(WordmarkArtwork.shared)
        let canvasRect = artwork.canvas
        let scale: CGFloat = 2, top = floor(canvasRect.minY) - 12, bottom: CGFloat = 360
        let left = min(0, floor(canvasRect.minX) - 12), right = max(336, ceil(canvasRect.maxX) + 12)
        let panel = CGSize(width: (right - left) * scale, height: (bottom - top) * scale), gap: CGFloat = 20
        let palettes = [Palette(name: "Title and tent: slate palette", paper: 0x27313F, ink: 0xFFFFFF), light,
                        Palette(name: "Home, dark paper", paper: 0x27313F, ink: 0xD6DDE7)]
        let sheet = try canvas(width: Int(CGFloat(palettes.count) * (panel.width + gap) + gap), height: Int(panel.height + 2 * gap + 30))
        let show = AgentLandCircusChoreography(reveal: 0, seed: 9)
        let appearance = try XCTUnwrap(show.appearance(at: 1))
        let design = AgentLandClownArtwork.designs[appearance.design]
        for (index, palette) in palettes.enumerated() {
            let origin = CGPoint(x: gap + CGFloat(index) * (panel.width + gap), y: gap)
            let painter = Painter(context: sheet, origin: origin, scale: scale, top: top, size: panel, left: left)
            painter.background(palette.paper)
            try drawScene(painter, time: appearance.join + 1.4, clowns: index == 0 ? [] : [(appearance, design)], palette: palette, ground: [])
            for glyph in artwork.glyphs {
                try painter.image(XCTUnwrap(glyph.tonalImage(ramp: palette.ramp)), in: glyph.frame)
            }
            label(palette.name, in: sheet, at: CGPoint(x: origin.x, y: origin.y + panel.height + 8), size: 16)
        }
        try write(sheet.makeImage()!, to: folder.appendingPathComponent("title-sheet.png"))
    }

    #if os(macOS)
    /// Frames of four entrances as Core Animation itself renders them (CARenderer into a Metal texture at
    /// fixed media times), from the same layers and keyframes the apps use, white on slate.
    @MainActor
    func testWriteEntranceFrameStrip() throws {
        guard let folder else { throw XCTSkip("Set AGENTLAND_BRANDING_EVIDENCE to a folder to write the frame strip") }
        let rows: [(String, (WordmarkLayerController) -> Void)] = [AgentLandWordmarkEntrance.dropAndBounce, .arcUnfurl, .pixelAssemble, .marqueeLightUp]
            .map { kind in (kind.rawValue, { $0.playEntrance(kind) }) }
        try writeFrameStrip(rows, times: stride(from: 0.0, through: 1.4, by: 0.2).map { $0 }, ramp: nil,
                            to: folder.appendingPathComponent("entrance-frames.png"))
    }

    /// The title's new entrances and flourishes as Core Animation renders them, each row in its own picked
    /// face and look on the night ramp over slate. Runs only when AGENTLAND_TITLE_STYLE_EVIDENCE names a folder.
    @MainActor
    func testWriteNewTitleMotionFrames() throws {
        guard let folder = ProcessInfo.processInfo.environment["AGENTLAND_TITLE_STYLE_EVIDENCE"].map({ URL(fileURLWithPath: $0) }) else {
            throw XCTSkip("Set AGENTLAND_TITLE_STYLE_EVIDENCE to a folder to write the new title motion")
        }
        let entrances: [AgentLandWordmarkEntrance] = [.tossUp, .spinIn, .slotShuffle, .inkFill, .stamp, .stretchSnap]
        try writeFrameStrip(entrances.map { kind in (kind.rawValue, { $0.playEntrance(kind) }) },
                            times: stride(from: 0.0, through: 1.4, by: 0.175).map { $0 }, ramp: .night,
                            to: folder.appendingPathComponent("new-entrances.png"))
        let flourishes: [AgentLandWordmarkFlourish] = [.fontFlip, .fontDissolve, .jellyWobble, .dominoTip, .sparkleTwinkle,
                                                       .spotlightSweep, .leapfrog, .dripAndReform]
        try writeFrameStrip(flourishes.map { kind in (kind.rawValue, { $0.rest(); $0.playFlourish(kind) }) },
                            times: stride(from: 0.0, through: 2.8, by: 0.35).map { $0 }, ramp: .night,
                            to: folder.appendingPathComponent("new-flourishes.png"))
    }

    /// One row per animation: the title's layers rendered by CARenderer at each of `times` after `play`.
    @MainActor
    private func writeFrameStrip(_ rows: [(String, (WordmarkLayerController) -> Void)], times: [Double], ramp: AgentLandClownRamp?,
                                 to url: URL) throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let canvas = AgentLandWordmark.canvas
        let scale: CGFloat = 1.6
        let width = Int(canvas.width * scale), height = Int(canvas.height * scale)
        let gap = 8, label = 260
        let sheetWidth = label + times.count * (width + gap), sheetHeight = rows.count * (height + gap) + 40
        let sheet = try XCTUnwrap(CGContext(data: nil, width: sheetWidth, height: sheetHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        sheet.setFillColor(color(0xFFFFFF)); sheet.fill(CGRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))
        for (column, time) in times.enumerated() {
            self.label(String(format: "%.2f s", time), in: sheet, at: CGPoint(x: CGFloat(label + column * (width + gap)), y: CGFloat(sheetHeight - 26)), size: 15)
        }
        let suite = "EvidenceSheetTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for (row, (name, play)) in rows.enumerated() {
            let controller = WordmarkLayerController(defaults: defaults)
            // As in the Mac host view: flipped geometry, top-left origin.
            controller.root.isGeometryFlipped = true
            controller.root.backgroundColor = color(0x27313F)
            controller.layout(in: CGRect(x: 0, y: 0, width: width, height: height))
            controller.update(color: color(0xFFFFFF), motionAllowed: ramp != nil, referenceDate: Date(), flourishRequests: 0, ramp: ramp)
            controller.rest()
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            let renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue as String: queue])
            renderer.layer = controller.root
            renderer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            CATransaction.flush()
            let start = CACurrentMediaTime()
            play(controller)
            CATransaction.flush()
            let y = sheetHeight - 40 - (row + 1) * (height + gap)
            let styleName = ramp == nil ? "" : " (\(controller.style.face), \(controller.style.look.rawValue))"
            self.label(name + styleName, in: sheet, at: CGPoint(x: 8, y: CGFloat(y + height / 2)), size: 13)
            for (column, time) in times.enumerated() {
                renderer.beginFrame(atTime: start + time, timeStamp: nil)
                renderer.addUpdate(renderer.bounds)
                renderer.render()
                renderer.endFrame()
                let done = try XCTUnwrap(queue.makeCommandBuffer())
                done.commit()
                done.waitUntilCompleted()
                var raw = [UInt8](repeating: 0, count: width * height * 4)
                texture.getBytes(&raw, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                // The renderer's first texture row is the bottom of the picture; BGRA becomes RGBA.
                var bytes = [UInt8](repeating: 0, count: raw.count)
                for row in 0..<height {
                    for x in 0..<width {
                        let from = ((height - 1 - row) * width + x) * 4, to = (row * width + x) * 4
                        bytes[to] = raw[from + 2]; bytes[to + 1] = raw[from + 1]; bytes[to + 2] = raw[from]; bytes[to + 3] = raw[from + 3]
                    }
                }
                let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
                let frame = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
                sheet.draw(frame, in: CGRect(x: label + column * (width + gap), y: y, width: width, height: height))
            }
            controller.rest()
        }
        try write(try XCTUnwrap(sheet.makeImage()), to: url)
    }
    #endif

    /// Every face in every look, the whole arch at rest, on slate (night ramp) and on the paper (day ramp).
    /// Runs only when AGENTLAND_TITLE_STYLE_EVIDENCE names a folder.
    func testWriteTitleStyleSheet() throws {
        guard let folder = ProcessInfo.processInfo.environment["AGENTLAND_TITLE_STYLE_EVIDENCE"].map({ URL(fileURLWithPath: $0) }) else {
            throw XCTSkip("Set AGENTLAND_TITLE_STYLE_EVIDENCE to a folder to write the style sheet")
        }
        let set = try XCTUnwrap(WordmarkFontSet.shared)
        let unit = AgentLandWordmarkGeometry.artUnit, margin = 4 * unit, scale: CGFloat = 0.9
        let area = AgentLandWordmarkGeometry.canvas.insetBy(dx: -margin, dy: -margin)
        let cell = CGSize(width: area.width * scale, height: (area.height + 8 * unit) * scale), gap: CGFloat = 10, label: CGFloat = 170
        for (name, ramp, paper) in [("slate", AgentLandClownRamp.night, UInt32(0x27313F)), ("paper", .day, 0xF4F0E7)] {
            let looks = AgentLandWordmarkLook.allCases
            let sheet = try canvas(width: Int(label + CGFloat(looks.count) * (cell.width + gap)),
                                   height: Int(CGFloat(set.faces.count) * (cell.height + gap) + 40))
            sheet.interpolationQuality = .none
            for (column, look) in looks.enumerated() {
                self.label(look.rawValue, in: sheet, at: CGPoint(x: label + CGFloat(column) * (cell.width + gap), y: CGFloat(sheet.height) - 26), size: 15)
            }
            for (row, face) in set.faces.enumerated() {
                let y = CGFloat(sheet.height) - 40 - CGFloat(row + 1) * (cell.height + gap)
                self.label(face.displayName, in: sheet, at: CGPoint(x: 8, y: y + cell.height / 2), size: 14)
                for (column, look) in looks.enumerated() {
                    let x = label + CGFloat(column) * (cell.width + gap)
                    sheet.setFillColor(color(paper)); sheet.fill(CGRect(x: x, y: y, width: cell.width, height: cell.height))
                    for slot in set.boxes.indices {
                        let frame = set.boxes[slot].frame
                        let image = try XCTUnwrap(set.face(AgentLandWordmarkStyle(face: face.id, look: look), slot: slot, ramp: ramp))
                        // Scene y runs down; the sheet's runs up.
                        sheet.draw(image, in: CGRect(x: x + (frame.minX - area.minX) * scale,
                                                     y: y + cell.height - (frame.maxY - area.minY) * scale,
                                                     width: frame.width * scale, height: frame.height * scale))
                    }
                }
            }
            try write(try XCTUnwrap(sheet.makeImage()), to: folder.appendingPathComponent("title-styles-\(name).png"))
        }
    }

    // MARK: - The scene, layer by layer

    /// Paints scene rectangles (scene units, y down) into a panel of the sheet (device pixels, y up).
    private struct Painter {
        let context: CGContext
        let origin: CGPoint
        let scale: CGFloat
        /// Scene y at the panel's top edge, and scene x at its left edge.
        let top: CGFloat
        let size: CGSize
        var left: CGFloat = 0

        func background(_ hex: UInt32) {
            context.setFillColor(EvidenceSheetTests.cgColor(hex))
            context.fill(CGRect(origin: origin, size: size))
        }

        func fill(_ scene: CGRect, _ hex: UInt32) {
            let rect = CGRect(x: origin.x + (scene.minX - left) * scale, y: origin.y + size.height - (scene.maxY - top) * scale,
                              width: scene.width * scale, height: scene.height * scale)
            guard rect.intersects(CGRect(origin: origin, size: size)) else { return }
            context.saveGState()
            context.clip(to: CGRect(origin: origin, size: size))
            context.setFillColor(EvidenceSheetTests.cgColor(hex))
            context.fill(rect)
            context.restoreGState()
        }

        func image(_ image: CGImage, in frame: CGRect) throws {
            let bytes = try XCTUnwrap(AgentLandClownArtwork.rgbaBytes(image))
            let sx = frame.width / CGFloat(image.width), sy = frame.height / CGFloat(image.height)
            for y in 0..<image.height { for x in 0..<image.width {
                let offset = (y * image.width + x) * 4
                guard bytes[offset + 3] > 0 else { continue }
                let hex = UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2])
                fill(CGRect(x: frame.minX + CGFloat(x) * sx, y: frame.minY + CGFloat(y) * sy,
                            width: sx, height: sy), hex)
            } }
        }
    }

    /// The work surface's layers at `time` (AgentLandCircusLoading.scene).
    private func drawScene(_ painter: Painter, time: Double, clowns: [(AgentLandCircusChoreography.Appearance, AgentLandClownDesign)],
                           palette: Palette, ground: [AgentLandJuggling.GroundBall]) throws {
        let loop = try XCTUnwrap(AgentLandTentLoop.artwork)
        let frame = AgentLandTentLoop.frameIndex(at: time)
        let depth = alpha(loop.depths[frame])
        let doorway = alpha(try XCTUnwrap(AgentLandBrandingResources.image("TentDoorway")))
        let rect = AgentLandTentArt.sceneRect, scale = AgentLandTentArt.pointsPerPixel
        let side = Int((rect.width / scale).rounded())
        func tent(_ pixels: [Bool], _ hex: UInt32) {
            for y in 0..<side { for x in 0..<side where pixels[y * side + x] {
                painter.fill(CGRect(x: rect.minX + CGFloat(x) * scale, y: rect.minY + CGFloat(y) * scale, width: scale, height: scale), hex)
            } }
        }
        func inDoorway(_ point: CGPoint) -> Bool {
            let x = Int(((point.x - rect.minX) / scale).rounded(.down)), y = Int(((point.y - rect.minY) / scale).rounded(.down))
            return (0..<side).contains(x) && (0..<side).contains(y) && doorway[y * side + x]
        }
        let states = clowns.map { (AgentLandCircusChoreography.state(of: $0.0, at: time), $0.1) }
        for (state, design) in states where state.layer == .behind { drawClown(painter, state, design, time: time, palette: palette, fill: false) { _ in true } }
        for ball in ground where !ball.front { drawBall(painter, ball: ball, palette: palette) }
        tent(depth, palette.paper)
        tent(doorway, Self.doorwayShade)
        for (state, design) in states where state.layer == .door {
            drawClown(painter, state, design, time: time, palette: palette, fill: true) {
                inDoorway($0) && $0.y < state.portalEdge
            }
        }
        try painter.image(XCTUnwrap(AgentLandTentArt.tonal(frame: frame, ramp: palette.ramp)),
                          in: AgentLandTentArt.sceneRect)
        for ball in ground where ball.front { drawBall(painter, ball: ball, palette: palette) }
        for (state, design) in states where state.layer == .front { drawClown(painter, state, design, time: time, palette: palette, fill: true) { _ in true } }
        for (state, design) in states where state.layer == .door {
            drawClown(painter, state, design, time: time, palette: palette, fill: true) { $0.y >= state.portalEdge }
        }
    }

    private func drawClown(_ painter: Painter, _ state: AgentLandCircusChoreography.State, _ design: AgentLandClownDesign, time: Double,
                           palette: Palette, fill: Bool, clip: (CGPoint) -> Bool) {
        guard state.opacity > 0 else { return }
        painter.context.saveGState()
        painter.context.setAlpha(state.opacity)
        defer { painter.context.restoreGState() }
        let index = AgentLandClownMotion.frameIndex(at: time, frameCount: design.frameCount)
        let flip: CGFloat = state.facingLeft ? -1 : 1
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: state.center.x + flip * (x + 0.5 - 48) * 0.75, y: state.center.y + (y + 0.5 - 48) * 0.75)
        }
        func pixel(_ x: CGFloat, _ y: CGFloat, _ hex: UInt32) {
            let centre = point(x, y)
            guard clip(centre) else { return }
            painter.fill(CGRect(x: centre.x - 0.375, y: centre.y - 0.375, width: 0.75, height: 0.75), hex)
        }
        let frame = design.indices[index], ring = alpha(design.outlines[index]), tones = design.tones[palette.ramp]!
        for y in 0..<96 { for x in 0..<96 {
            let tone = frame[y * 96 + x]
            if tone > 0 { pixel(CGFloat(x), CGFloat(y), hex(tones[Int(tone) - 1])) }
            else if fill && ring[y * 96 + x] { pixel(CGFloat(x), CGFloat(y), palette.paper) }
        } }
        for ball in AgentLandCircusChoreography.balls(of: state, at: time, juggling: design.juggling) {
            let colours = AgentLandClownArtwork.rgbaBytes(AgentLandJugglingBall.tintedFrame(tint: ball.tint, spinFrame: ball.spinFrame)!)!
            let rim = alpha(AgentLandJugglingBall.ringFrame(for: ball.spinFrame)!)
            for y in 0..<16 { for x in 0..<16 {
                let index = y * 16 + x, offset = index * 4
                let colour = colours[offset + 3] > 0 ? hex(Array(colours[offset..<offset + 3])) : nil
                if let ink = colour ?? (fill && rim[index] ? palette.paper : nil) {
                    pixel(ball.point.x - 8 + CGFloat(x), ball.point.y - 8 + CGFloat(y), ink)
                }
            } }
        }
    }

    private func drawBall(_ painter: Painter, ball: AgentLandJuggling.GroundBall, palette: Palette) {
        let colours = AgentLandClownArtwork.rgbaBytes(AgentLandJugglingBall.tintedFrame(tint: ball.tint, spinFrame: ball.spinFrame)!)!
        let rim = alpha(AgentLandJugglingBall.ringFrame(for: ball.spinFrame)!)
        painter.context.saveGState()
        painter.context.setAlpha(ball.opacity)
        defer { painter.context.restoreGState() }
        for y in 0..<16 { for x in 0..<16 {
            let index = y * 16 + x, offset = index * 4
            let colour = colours[offset + 3] > 0 ? hex(Array(colours[offset..<offset + 3])) : nil
            if let ink = colour ?? (rim[index] ? palette.paper : nil) {
                painter.fill(CGRect(x: ball.point.x + (CGFloat(x) - 8) * 0.75, y: ball.point.y + (CGFloat(y) - 8) * 0.75,
                                    width: 0.75, height: 0.75), ink)
            }
        } }
    }

    // MARK: - Helpers

    private func canvas(width: Int, height: Int) throws -> CGContext {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color(0xFFFFFF)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setShouldAntialias(false)
        return context
    }

    private func write(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        print("Wrote \(url.path)")
    }

    static func cgColor(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    private func color(_ hex: UInt32) -> CGColor { Self.cgColor(hex) }
    private func cgColor(_ rgb: [UInt8]) -> CGColor { Self.cgColor(hex(rgb)) }
    private func hex(_ rgb: [UInt8]) -> UInt32 { UInt32(rgb[0]) << 16 | UInt32(rgb[1]) << 8 | UInt32(rgb[2]) }

    private func label(_ text: String, in context: CGContext, at point: CGPoint, size: CGFloat) {
        context.saveGState()
        context.setShouldAntialias(true)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateUIFontForLanguage(.system, size, nil)!,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(0x1F2328)]))
        context.textPosition = point
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func alpha(_ image: CGImage) -> [Bool] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return (0..<(image.width * image.height)).map { bytes[$0 * 4 + 3] >= 128 }
    }
}
