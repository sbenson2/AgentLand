import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// M6 font sheet for the arched "AGENTLAND" title over the real shipped tent (branding/tent-mono.png and
// tent-doorway.png at 252 scene units, as on Home). Candidate fonts come from branding/fonts/<Family>/ and
// are registered for this process only (CTFontManagerRegisterFontsForURL, .process); nothing is installed.
//
// Scene units follow AgentLandCircusLoading (336x360, tent 252x252 at 42,54, 2.625 units per art pixel).
// Arches: letters on a circle, glyph centres spread evenly by advance over the sweep, baseline on the circle:
//   160°: centre (168, 40), baseline radius 112     180°: centre (168, 24), baseline radius 100
// Cap height 34 units (measured from each font's "H"); a font too wide for the sweep at cap 34 is scaled down
// until its letters fit with 1 unit of tracking, and the sheet says so. CRISP draws the glyph outlines;
// PIXEL rasterizes them on the tent's own pixel grid (anchored at the tent's origin, 2.625 units per pixel,
// a pixel is on when at least half covered) and draws that grid nearest-neighbor. The sample quip is set in
// the regular system font, at most two lines 140 units wide, centred in the arch's hollow.
//
// Usage (from the project root): swift scripts/render-wordmark-sheet.swift [out-dir]
// Writes wordmark-sheet.png (white on slate #27313F) and wordmark-sheet-light.png (#354052 on #F4F0E7).
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".evidence/branding-round1-20260923",
                 relativeTo: root)
let word = "AGENTLAND"
let quip = "Now juggling three agents at once"
let targetCap: CGFloat = 34
let artUnit: CGFloat = 2.625                       // scene units per tent art pixel (252 / 96)
let pixelsPerArt: CGFloat = 4                      // sheet pixels per art pixel, so the grid stays exact
let scale = pixelsPerArt / artUnit                 // sheet pixels per scene unit
let tentOrigin = CGPoint(x: 42, y: 54)
let gridColumns = 128, gridRows = 168              // scene x 0...336, y -124.5...316.5
let sceneOrigin = CGPoint(x: tentOrigin.x - 16 * artUnit, y: tentOrigin.y - 68 * artUnit)
let cellWidth = Int(CGFloat(gridColumns) * pixelsPerArt), cellHeight = Int(CGFloat(gridRows) * pixelsPerArt)

struct Arch { let name: String; let centre: CGPoint; let radius: CGFloat; let sweep: CGFloat }
let arches = [Arch(name: "160° arch", centre: CGPoint(x: 168, y: 40), radius: 112, sweep: 160 * .pi / 180),
              Arch(name: "180° arch", centre: CGPoint(x: 168, y: 24), radius: 100, sweep: .pi)]
let families: [(family: String, file: String)] = [
    ("Rye", "Rye/Rye-Regular.ttf"), ("Sancreek", "Sancreek/Sancreek-Regular.ttf"), ("Ewert", "Ewert/Ewert-Regular.ttf"),
    ("Diplomata SC", "DiplomataSC/DiplomataSC-Regular.ttf"), ("Holtwood One SC", "HoltwoodOneSC/HoltwoodOneSC-Regular.ttf"),
]

func cgColor(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}

// The shipped tent's mark and doorway masks.
func alphaMask(_ path: String) -> [Bool] {
    let url = root.appendingPathComponent(path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width == 96, image.height == 96 else {
        fatalError("Run from the AgentLand root: \(path) is missing.")
    }
    var bytes = [UInt8](repeating: 0, count: 96 * 96 * 4)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: 96, height: 96, bitsPerComponent: 8, bytesPerRow: 96 * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 96, height: 96))
    }
    return (0..<(96 * 96)).map { bytes[$0 * 4 + 3] >= 128 }
}
let tentMark = alphaMask("branding/tent-mono.png"), tentDoorway = alphaMask("branding/tent-doorway.png")

// Fonts: registered for this process only.
struct Face { let family: String; let postScriptName: String; let capRatio: CGFloat; let file: String }
let faces: [Face] = families.map { entry in
    let url = root.appendingPathComponent("branding/fonts/" + entry.file)
    var error: Unmanaged<CFError>?
    if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
        // Already registered in this process is fine; anything else is fatal.
        let registered = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]) != nil
        guard registered else { fatalError("Cannot register \(url.path)") }
    }
    guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
          let name = CTFontDescriptorCopyAttribute(descriptors[0], kCTFontNameAttribute) as? String else {
        fatalError("No font in \(url.path)")
    }
    let probe = CTFontCreateWithName(name as CFString, 100, nil)
    // Cap height from the "H" outline: Rye's OS/2 capHeight field is far too small.
    var character: UniChar = 72, glyph = CGGlyph(0), bounds = CGRect.zero
    CTFontGetGlyphsForCharacters(probe, &character, &glyph, 1)
    CTFontGetBoundingRectsForGlyphs(probe, .horizontal, &glyph, &bounds, 1)
    return Face(family: entry.family, postScriptName: name, capRatio: bounds.maxY / 100, file: entry.file)
}

struct Layout { let paths: [CGPath]; let size: CGFloat; let cap: CGFloat; let tracking: CGFloat; let fitted: Bool }

func layout(_ face: Face, _ arch: Arch) -> Layout {
    func measure(_ size: CGFloat) -> (glyphs: [CGGlyph], centres: [CGFloat], advances: [CGFloat], font: CTFont) {
        let font = CTFontCreateWithName(face.postScriptName as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: word, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font]))
        var glyphs: [CGGlyph] = [], centres: [CGFloat] = [], advances: [CGFloat] = []
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var g = [CGGlyph](repeating: 0, count: count), p = [CGPoint](repeating: .zero, count: count)
            var a = [CGSize](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &g)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &p)
            CTRunGetAdvances(run, CFRange(location: 0, length: count), &a)
            glyphs += g; advances += a.map { $0.width }; centres += zip(p, a).map { $0.x + $1.width / 2 }
        }
        return (glyphs, centres, advances, font)
    }
    let arc = arch.radius * arch.sweep, gaps = CGFloat(word.count - 1), minimumTracking: CGFloat = 1
    var size = targetCap / face.capRatio
    var metrics = measure(size)
    var span = metrics.centres.last! - metrics.centres.first!
    var fitted = false
    if (arc - span) / gaps < minimumTracking {
        size *= (arc - gaps * minimumTracking) / span
        metrics = measure(size)
        span = metrics.centres.last! - metrics.centres.first!
        fitted = true
    }
    let tracking = (arc - span) / gaps
    var paths: [CGPath] = []
    for (index, glyph) in metrics.glyphs.enumerated() {
        let along = metrics.centres[index] - metrics.centres[0] + CGFloat(index) * tracking
        let angle = -arch.sweep / 2 + along / arch.radius
        let point = CGPoint(x: arch.centre.x + arch.radius * sin(angle), y: arch.centre.y - arch.radius * cos(angle))
        // Glyph space is y-up from the baseline origin; the scene is y-down. Centre on the advance, flip,
        // turn to the circle's normal, move onto the baseline circle.
        var transform = CGAffineTransform(translationX: -metrics.advances[index] / 2, y: 0)
            .concatenating(CGAffineTransform(scaleX: 1, y: -1))
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX: point.x, y: point.y))
        if let path = CTFontCreatePathForGlyph(metrics.font, glyph, &transform) { paths.append(path) }
    }
    return Layout(paths: paths, size: size, cap: size * face.capRatio, tracking: tracking, fitted: fitted)
}

/// Grid pixels covered at least halfway by the paths, on the tent's grid.
func rasterize(_ paths: [CGPath]) -> [Bool] {
    let context = CGContext(data: nil, width: gridColumns, height: gridRows, bitsPerComponent: 8, bytesPerRow: gridColumns,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    context.setFillColor(gray: 0, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: gridColumns, height: gridRows))
    context.translateBy(x: 0, y: CGFloat(gridRows)); context.scaleBy(x: 1 / artUnit, y: -1 / artUnit)
    context.translateBy(x: -sceneOrigin.x, y: -sceneOrigin.y)
    context.setShouldAntialias(true)
    context.setFillColor(gray: 1, alpha: 1)
    for path in paths { context.addPath(path) }
    context.fillPath()
    let data = context.data!.assumingMemoryBound(to: UInt8.self)
    // Bitmap rows run top to bottom in memory, matching scene y-down after the flip above.
    return (0..<(gridColumns * gridRows)).map { data[$0] >= 128 }
}

struct Palette { let paper: UInt32; let ink: UInt32; let quip: UInt32; let name: String }
let doorShade: UInt32 = 0x1B222C

func cell(_ face: Face, _ arch: Arch, pixel: Bool, palette: Palette) -> (CGImage, Layout) {
    let context = CGContext(data: nil, width: cellWidth, height: cellHeight, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(cgColor(palette.paper)); context.fill(CGRect(x: 0, y: 0, width: cellWidth, height: cellHeight))
    // Scene units, y-down.
    context.translateBy(x: 0, y: CGFloat(cellHeight)); context.scaleBy(x: scale, y: -scale)
    context.translateBy(x: -sceneOrigin.x, y: -sceneOrigin.y)
    // The tent: exact art pixels, doorway filled with the fixed shade.
    context.setShouldAntialias(false)
    for y in 0..<96 {
        for x in 0..<96 {
            let index = y * 96 + x
            guard tentMark[index] || tentDoorway[index] else { continue }
            context.setFillColor(cgColor(tentMark[index] ? palette.ink : doorShade))
            context.fill(CGRect(x: tentOrigin.x + CGFloat(x) * artUnit, y: tentOrigin.y + CGFloat(y) * artUnit, width: artUnit, height: artUnit))
        }
    }
    let result = layout(face, arch)
    context.setFillColor(cgColor(palette.ink))
    if pixel {
        let grid = rasterize(result.paths)
        for index in grid.indices where grid[index] {
            context.fill(CGRect(x: sceneOrigin.x + CGFloat(index % gridColumns) * artUnit,
                                y: sceneOrigin.y + CGFloat(index / gridColumns) * artUnit, width: artUnit, height: artUnit))
        }
    } else {
        context.setShouldAntialias(true)
        for path in result.paths { context.addPath(path) }
        context.fillPath()
    }
    // The quip, centred in the hollow between the arch's apex and the chord through its ends.
    context.setShouldAntialias(true)
    let apex = arch.centre.y - arch.radius, chord = arch.centre.y - arch.radius * cos(arch.sweep / 2)
    let paragraph: CTParagraphStyle = {
        var alignment = CTTextAlignment.center
        return withUnsafeBytes(of: &alignment) { bytes in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: bytes.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
    }()
    var quipSize: CGFloat = 15
    var framesetter: CTFramesetter
    var fit: CGSize
    repeat {
        let attributed = NSAttributedString(string: quip, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateUIFontForLanguage(.system, quipSize, nil)!,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(palette.quip),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph])
        framesetter = CTFramesetterCreateWithAttributedString(attributed)
        fit = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
                                                           CGSize(width: 140, height: 1000), nil)
        quipSize -= 0.5
    } while fit.height > quipSize * 1.3 * 2 + 4 && quipSize > 11
    let box = CGRect(x: 168 - 70, y: (apex + chord) / 2 - ceil(fit.height) / 2, width: 140, height: ceil(fit.height))
    context.saveGState()
    context.translateBy(x: box.minX, y: box.maxY); context.scaleBy(x: 1, y: -1)
    context.textMatrix = .identity
    CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                         CGPath(rect: CGRect(origin: .zero, size: box.size), transform: nil), nil), context)
    context.restoreGState()
    return (context.makeImage()!, result)
}

func sheet(_ palette: Palette) -> CGImage {
    let labelWidth = 250, gap = 16, titleHeight = 118, headerHeight = 34, rowGap = 24
    let width = labelWidth + arches.count * 2 * (cellWidth + gap) + gap
    let height = titleHeight + headerHeight + faces.count * (cellHeight + rowGap) + gap
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(cgColor(0xFFFFFF)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    func text(_ string: String, x: Int, top: Int, size: CGFloat, bold: Bool = false, color: UInt32 = 0x1F2328, width w: CGFloat = 3000) {
        let attributed = NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)!,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(color)])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil, CGSize(width: w, height: 2000), nil)
        let rect = CGRect(x: CGFloat(x), y: CGFloat(height - top) - ceil(fit.height), width: w, height: ceil(fit.height))
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil), context)
    }
    text("AgentLand M6 round 1: arched title fonts, \(palette.name) (2026-09-23)", x: 16, top: 14, size: 24, bold: true)
    text("\"\(word)\" over the shipped tent at 252 scene units (Home size). 160° arch: letters on a circle centred at scene (168, 40), baseline radius 112. 180° arch: centre (168, 24), radius 100. Cap height 34 units from each font's H unless marked fitted. PIXEL = rasterized on the tent's own 2.625-unit pixel grid (half-covered pixels on), drawn nearest-neighbor; CRISP = vector outlines. Quip in the regular system font, 140 units wide, centred in the arch's hollow. Fonts are OFL files from google/fonts at b5efa9c, registered for this process only.",
         x: 16, top: 50, size: 14, color: 0x57606A, width: CGFloat(width - 32))
    let columns = arches.flatMap { arch in [(arch, false), (arch, true)] }
    for (column, entry) in columns.enumerated() {
        text("\(entry.0.name), \(entry.1 ? "PIXEL grid" : "CRISP")", x: labelWidth + column * (cellWidth + gap), top: titleHeight + 6, size: 17, bold: true)
    }
    for (row, face) in faces.enumerated() {
        let top = titleHeight + headerHeight + row * (cellHeight + rowGap)
        var notes: [String] = []
        for (column, entry) in columns.enumerated() {
            let (image, result) = cell(face, entry.0, pixel: entry.1, palette: palette)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: labelWidth + column * (cellWidth + gap), y: height - top - cellHeight, width: cellWidth, height: cellHeight))
            if !entry.1 {
                notes.append(String(format: "%@: size %.1f, cap %.1f, tracking %+.1f%@", entry.0.name, result.size, result.cap, result.tracking,
                                    result.fitted ? " (FITTED: too wide for cap 34 on this arc)" : ""))
            }
        }
        text(face.family, x: 16, top: top + 8, size: 22, bold: true, width: CGFloat(labelWidth - 28))
        text("\(face.file)\n\(face.postScriptName)\n\n" + notes.joined(separator: "\n\n"), x: 16, top: top + 40, size: 13, color: 0x57606A,
             width: CGFloat(labelWidth - 28))
    }
    return context.makeImage()!
}

func write(_ image: CGImage, _ name: String) {
    let url = outDir.appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Cannot write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write \(url.path)") }
    print("Wrote \(url.path) (\(image.width)x\(image.height))")
}

var records: [[String: Any]] = []
for face in faces {
    for arch in arches {
        let result = layout(face, arch)
        print(String(format: "%@ %@: size %.1f cap %.1f tracking %+.2f%@", face.family, arch.name, result.size, result.cap, result.tracking,
                     result.fitted ? " fitted" : ""))
        let round2 = { (value: CGFloat) in (Double(value) * 100).rounded() / 100 }
        records.append(["family": face.family, "postScriptName": face.postScriptName, "file": "branding/fonts/" + face.file,
                        "arch": arch.name, "centre": [Double(arch.centre.x), Double(arch.centre.y)], "baselineRadius": Double(arch.radius),
                        "sweepDegrees": Double(arch.sweep * 180 / .pi), "size": round2(result.size), "capHeight": round2(result.cap),
                        "tracking": round2(result.tracking), "fittedBelowCap34": result.fitted])
    }
}
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
if let json = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) {
    try? json.write(to: outDir.appendingPathComponent("wordmark-layout.json"), options: .atomic)
}
write(sheet(Palette(paper: 0x27313F, ink: 0xFFFFFF, quip: 0xD6DDE7, name: "white on slate")), "wordmark-sheet.png")
write(sheet(Palette(paper: 0xF4F0E7, ink: 0x354052, quip: 0x354052, name: "light paper")), "wordmark-sheet-light.png")
