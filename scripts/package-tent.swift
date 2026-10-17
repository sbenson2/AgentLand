import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Packages Home's tent from the logo's exact PixelLab sprite (branding/tent-home.json: the source, its crop
// and the door seed and box) and its breathing loop (branding/tent-loop.json). Maps every opaque pixel onto
// the clown's five day tones exactly as scripts/package-logo.py maps the logo, so the still is the logo pixel
// for pixel. Writes tonal artwork, compatible black/white marks, the doorway, geometry and depth masks
// together. Only the darkest opening pixels become the doorway, preserving shaded curtains; depth includes
// the whole tonal silhouette. Generated motion is kept above the loop's fixed first row; the still's walls,
// curtains and doorway are copied from that row down and checked before any packaged resource is written.
// Every image is cropped to the recorded window, which must hold all of the ink.
// Run from the project root:
//   swift scripts/package-tent.swift && python3 scripts/check-tent-doorway.py <out.png>
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let branding = root.appendingPathComponent("branding")
let resources = root.appendingPathComponent("shared/AgentLandBranding/Sources/AgentLandBranding/Resources")

let paletteRecord = try JSONSerialization.jsonObject(with: Data(contentsOf: branding.appendingPathComponent("clown-ride.json"))) as! [String: Any]
let palette = paletteRecord["palette"] as! [String: Any]
let day = palette["day"] as! [String: Any]
let colours = (day["tones"] as! [String]).map { hex -> [UInt8] in
    let value = UInt32(hex.dropFirst(), radix: 16)!
    return [UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]
}

struct TentRecord: Decodable {
    struct Source: Decodable { let file: String }
    struct Crop: Decodable { let x: Int, y: Int, side: Int }
    struct Cleanup: Decodable {
        struct Doorway: Decodable {
            struct Box: Decodable { let minX: Int, minY: Int, maxX: Int, maxY: Int }
            let seed: [Int]
            let box: Box
        }
        let doorway: Doorway
    }
    let source: Source
    let crop: Crop
    let cleanup: Cleanup
}
guard let tentData = try? Data(contentsOf: branding.appendingPathComponent("tent-home.json")),
      let tentRecord = try? JSONDecoder().decode(TentRecord.self, from: tentData) else {
    fatalError("Run from the project root: branding/tent-home.json is missing or unreadable.")
}
let crop = tentRecord.crop

/// The source's pixels as palette indices 1-5 (0 is transparent), and its side. Alpha below 128 is transparent;
/// every other pixel takes the nearest day tone by the logo packager's weighted distance (0.3, 0.59, 0.11).
func loadTones(_ url: URL) -> (tones: [UInt8], side: Int) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width == image.height else {
        fatalError("Run from the project root with the square PixelLab export \(url.lastPathComponent).")
    }
    let side = image.width
    var bytes = [UInt8](repeating: 0, count: side * side * 4)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    }
    var tones = [UInt8](repeating: 0, count: side * side)
    for index in 0..<(side * side) {
        let alpha = Int(bytes[index * 4 + 3])
        guard alpha >= 128 else { continue }
        let rgb = (0..<3).map { min(255, (Int(bytes[index * 4 + $0]) * 255 + alpha / 2) / alpha) }
        let weights = [0.3, 0.59, 0.11]
        func distance(_ tone: Int) -> Double {
            (0..<3).reduce(0) { $0 + weights[$1] * pow(Double(rgb[$1] - Int(colours[tone][$1])), 2) }
        }
        tones[index] = UInt8(colours.indices.min { distance($0) < distance($1) }! + 1)
    }
    return (tones, side)
}

let (sourceTones, sourceSide) = loadTones(branding.appendingPathComponent(tentRecord.source.file))
guard crop.x >= 0, crop.y >= 0, crop.side > 0, crop.x + crop.side <= sourceSide, crop.y + crop.side <= sourceSide else {
    fatalError("tent-home.json's crop must lie inside the \(sourceSide)x\(sourceSide) source.")
}

// Doorway, in source pixels: flood a 3x3 solid core in the darkest tone, then grow one darkest-tone pixel to
// recover its edge. The seed and box are recorded with the export. Darker curtain shading in tones 2 and 3
// stays artwork rather than being mistaken for the opening.
let seedRecord = tentRecord.cleanup.doorway.seed, boxRecord = tentRecord.cleanup.doorway.box
let doorSeed = (x: seedRecord[0], y: seedRecord[1])
func inDoorBox(_ x: Int, _ y: Int) -> Bool { (boxRecord.minX...boxRecord.maxX).contains(x) && (boxRecord.minY...boxRecord.maxY).contains(y) }
func inSource(_ x: Int, _ y: Int) -> Bool { (0..<sourceSide).contains(x) && (0..<sourceSide).contains(y) }
func solid(_ x: Int, _ y: Int) -> Bool {
    inDoorBox(x, y) && (-1...1).allSatisfy { dy in (-1...1).allSatisfy { dx in
        inSource(x + dx, y + dy) && sourceTones[(y + dy) * sourceSide + x + dx] == 1
    } }
}
var core = [Bool](repeating: false, count: sourceSide * sourceSide)
var walk = [doorSeed]
while let (x, y) = walk.popLast() {
    guard inSource(x, y), !core[y * sourceSide + x], solid(x, y) else { continue }
    core[y * sourceSide + x] = true
    walk += [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
}
guard core.contains(true) else { fatalError("The doorway seed is not inside a solid opening.") }
let sourceDoorway = (0..<(sourceSide * sourceSide)).map { index -> Bool in
    let x = index % sourceSide, y = index / sourceSide
    guard sourceTones[index] == 1, inDoorBox(x, y) else { return false }
    return (-1...1).contains { dy in (-1...1).contains { dx in
        inSource(x + dx, y + dy) && core[(y + dy) * sourceSide + x + dx]
    } }
}

// Everything below works on the cropped window, the packaged images' size.
let side = crop.side
/// The recorded window of a source-sized array; stops if any of the source's ink lies outside it.
func cropped<T: Equatable>(_ values: [T], empty: T, name: String) -> [T] {
    let outside = values.indices.filter { index in
        let x = index % sourceSide, y = index / sourceSide
        return values[index] != empty && !((crop.x..<crop.x + side).contains(x) && (crop.y..<crop.y + side).contains(y))
    }
    guard outside.isEmpty else {
        fatalError("\(name) has \(outside.count) pixels outside the crop window, first at \(outside[0] % sourceSide),\(outside[0] / sourceSide); nothing was written.")
    }
    return (0..<(side * side)).map { values[(crop.y + $0 / side) * sourceSide + crop.x + $0 % side] }
}
let stillTones = cropped(sourceTones, empty: 0, name: tentRecord.source.file)
let doorway = cropped(sourceDoorway, empty: false, name: "The doorway")
let ink = stillTones.map { (1...3).contains($0) }
let silhouette = stillTones.map { $0 > 0 }

/// Depth: flood the transparent outside from the canvas edge (4-connected); everything unreached is tent.
func depth(of ink: [Bool]) -> [Bool] {
    var outside = [Bool](repeating: false, count: side * side)
    var stack = (0..<side).flatMap { [($0, 0), ($0, side - 1), (0, $0), (side - 1, $0)] }
    while let (x, y) = stack.popLast() {
        guard (0..<side).contains(x), (0..<side).contains(y) else { continue }
        let index = y * side + x
        guard !outside[index], !ink[index] else { continue }
        outside[index] = true
        stack += [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
    }
    return outside.map { !$0 }
}

func pngImage(_ masks: [[Bool]], white: Bool) -> CGImage {
    let width = side * masks.count
    var rgba = [UInt8](repeating: 0, count: width * side * 4)
    for (frame, mask) in masks.enumerated() {
        for index in 0..<(side * side) where mask[index] {
            let offset = ((index / side) * width + frame * side + index % side) * 4
            let value: UInt8 = white ? 255 : 0
            rgba[offset] = value; rgba[offset + 1] = value; rgba[offset + 2] = value; rgba[offset + 3] = 255
        }
    }
    let provider = CGDataProvider(data: Data(rgba) as CFData)!
    return CGImage(width: width, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

/// One mask, or a strip of masks side by side, as a black (or white) and transparent PNG.
func write(_ masks: [[Bool]], white: Bool, to destination: URL) {
    guard let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Cannot write \(destination.path).")
    }
    CGImageDestinationAddImage(output, pngImage(masks, white: white), nil)
    guard CGImageDestinationFinalize(output) else { fatalError("Cannot write \(destination.path).") }
}

func write(_ mask: [Bool], white: Bool, to destination: URL) { write([mask], white: white, to: destination) }

let mark = (0..<(side * side)).map { ink[$0] && !doorway[$0] }
let stillDepth = depth(of: silhouette)

func writeTones(_ frames: [[UInt8]], to destination: URL) {
    let width = side * frames.count
    var bytes = [UInt8](repeating: 0, count: width * side * 4)
    for (frame, tones) in frames.enumerated() {
        for index in tones.indices where tones[index] > 0 && !doorway[index] {
            let offset = (index / side * width + frame * side + index % side) * 4
            let colour = colours[Int(tones[index]) - 1]
            bytes[offset] = colour[0]; bytes[offset + 1] = colour[1]; bytes[offset + 2] = colour[2]; bytes[offset + 3] = 255
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let image = CGImage(width: width, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(output, image, nil)
    guard CGImageDestinationFinalize(output) else { fatalError("Cannot write tonal tent") }
}

// The breathing loop (tent-loop.json): every frame cleaned the same way, checked against the still.
struct LoopRecord: Decodable {
    struct Cleanup: Decodable { struct Fixed: Decodable { let firstRow: Int }; let fixedRegion: Fixed }
    struct Playback: Decodable { let frameDuration: Double; let order: [Int] }
    let cleanup: Cleanup
    let playback: Playback
}
guard let loopData = try? Data(contentsOf: branding.appendingPathComponent("tent-loop.json")),
      let loop = try? JSONDecoder().decode(LoopRecord.self, from: loopData) else {
    fatalError("branding/tent-loop.json is missing or unreadable.")
}
let order = loop.playback.order
guard order.count >= 8, Set(order).count == order.count, Set(order) == Set(0..<order.count) else {
    fatalError("tent-loop.json's playback order must name every frame of the loop once.")
}
// The fixed first row is recorded in source pixels; in the packaged images it is that row of the crop.
let fixedFirstRow = loop.cleanup.fixedRegion.firstRow - crop.y
guard (1..<side).contains(fixedFirstRow) else { fatalError("tent-loop.json's fixed first row must fall inside the crop.") }
let fixedRows = fixedFirstRow..<side
// The still's depth at least two pixels inside its outline: a roof that breathes by a pixel never uncovers
// it, but a gap in a frame's outline lets the outside flood a whole panel, and the rider would show there.
// Only the tent's body counts: the pennant, joined to it by a thin pole, snaps to new places every frame.
let deepPixels = (0..<(side * side)).map { index -> Bool in
    let x = index % side, y = index / side
    return (-2...2).allSatisfy { dy in (-2...2).allSatisfy { dx in
        let nx = x + dx, ny = y + dy
        return (0..<side).contains(nx) && (0..<side).contains(ny) && stillDepth[ny * side + nx]
    } }
}
/// The largest 4-connected region of `mask`.
func largestRegion(of mask: [Bool]) -> [Bool] {
    var label = [Int](repeating: -1, count: mask.count), sizes: [Int] = []
    for start in mask.indices where mask[start] && label[start] < 0 {
        var stack = [start], size = 0
        label[start] = sizes.count
        while let index = stack.popLast() {
            size += 1
            let x = index % side, y = index / side
            for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
            where (0..<side).contains(nx) && (0..<side).contains(ny) && mask[ny * side + nx] && label[ny * side + nx] < 0 {
                label[ny * side + nx] = sizes.count
                stack.append(ny * side + nx)
            }
        }
        sizes.append(size)
    }
    guard let largest = sizes.indices.max(by: { sizes[$0] < sizes[$1] }) else { return mask }
    return label.map { $0 == largest }
}
let deepInside = largestRegion(of: deepPixels)
var loopMarks: [[Bool]] = [], loopDepths: [[Bool]] = [], loopTones: [[UInt8]] = [], open: [String] = []
for frame in order {
    let name = String(format: "frame-%02d.png", frame)
    let (frameSource, frameSide) = loadTones(branding.appendingPathComponent("tent-loop").appendingPathComponent(name))
    guard frameSide == sourceSide else { fatalError("\(name) must be \(sourceSide)x\(sourceSide), like the still.") }
    var tones = cropped(frameSource, empty: 0, name: name)
    // The generation supplies roof motion; the same still supplies all structural lower pixels.
    // This is deterministic packaging, so the doorway and curtains cannot drift between frames.
    for y in fixedRows { for x in 0..<side { tones[y * side + x] = stillTones[y * side + x] } }
    let frameInk = tones.map { (1...3).contains($0) }
    let frameDepth = depth(of: tones.map { $0 > 0 })
    let uncovered = (0..<(side * side)).filter { deepInside[$0] && !frameDepth[$0] }
    if let first = uncovered.first {
        open.append("\(name): \(uncovered.count) pixels from \(first % side),\(first / side)")
    }
    loopMarks.append((0..<(side * side)).map { frameInk[$0] && !doorway[$0] })
    loopDepths.append(frameDepth)
    loopTones.append(tones)
}
guard open.isEmpty else {
    fatalError("A frame's outline is open, so its depth mask would not hide the rider; nothing was written: \(open.joined(separator: "; "))")
}
guard let stillFrame = order.firstIndex(of: 0), loopTones[stillFrame] == stillTones else {
    fatalError("The loop's frame 00 must be the still, pixel for pixel.")
}

write(mark, white: false, to: branding.appendingPathComponent("tent-mono.png"))
write(mark, white: false, to: resources.appendingPathComponent("TentMark.png"))
write(mark, white: true, to: branding.appendingPathComponent("tent-mono-white.png"))
write(doorway, white: false, to: branding.appendingPathComponent("tent-doorway.png"))
write(doorway, white: false, to: resources.appendingPathComponent("TentDoorway.png"))
write(stillDepth, white: false, to: branding.appendingPathComponent("tent-depth-mask.png"))
write(stillDepth, white: false, to: resources.appendingPathComponent("TentDepthMask.png"))
write(loopMarks, white: false, to: resources.appendingPathComponent("TentLoop.png"))
write(loopDepths, white: false, to: resources.appendingPathComponent("TentLoopDepth.png"))
writeTones([stillTones], to: resources.appendingPathComponent("TentTone.png"))
writeTones(loopTones, to: resources.appendingPathComponent("TentToneLoop.png"))
let loopJSON: [String: Any] = ["frameDuration": loop.playback.frameDuration, "frames": order.count, "stillFrame": stillFrame]
try JSONSerialization.data(withJSONObject: loopJSON, options: [.prettyPrinted, .sortedKeys])
    .write(to: resources.appendingPathComponent("TentLoop.json"), options: .atomic)
let opening = doorway.indices.filter { doorway[$0] }
let geometry: [String: Any] = ["side": side, "minX": opening.map { $0 % side }.min()!, "maxX": opening.map { $0 % side }.max()!,
                             "minY": opening.map { $0 / side }.min()!, "maxY": opening.map { $0 / side }.max()!, "pixels": opening.count,
                             "fixedFirstRow": fixedFirstRow]
try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys])
    .write(to: resources.appendingPathComponent("TentGeometry.json"), options: .atomic)
print("Packaged the tent from \(tentRecord.source.file) (\(sourceSide) px), cropped to \(side) px at \(crop.x),\(crop.y): \(mark.filter { $0 }.count) mark pixels, \(opening.count) doorway pixels, \(stillDepth.filter { $0 }.count) depth pixels.")
print("Packaged the loop: \(order.count) frames of \(loop.playback.frameDuration) s from frame \(order[0]); the still is loop frame \(stillFrame); rows \(fixedFirstRow)-\(side - 1) are the still's in every frame; mark pixels \(loopMarks.map { $0.filter { $0 }.count }), depth pixels \(loopDepths.map { $0.filter { $0 }.count }).")
