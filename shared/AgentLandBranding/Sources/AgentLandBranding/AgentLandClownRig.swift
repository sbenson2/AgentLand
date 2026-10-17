import CoreGraphics
import Foundation
import ImageIO
import Synchronization

/// The circus clock's clown geometry: the orbit around the tent and the ride frames' timing, shared by
/// every design, the work-surface choreography and the tests.
enum AgentLandClownMotion {
    /// Playback rate of the packaged ride frames; eighteen frames make one juggling beat.
    static let frameDuration: TimeInterval = 1.0 / 60.0
    static let framesPerBeat = 18
    static var beat: TimeInterval { frameDuration * Double(framesPerBeat) }
    /// The ride loop: one pedal turn, 72 frames (1.2 s), in which the 13-pixel tyre rolls once round.
    static var rideLoop: TimeInterval { frameDuration * 72 }
    /// The tyre's radius in scene points (13 sprite pixels at 0.75 points each).
    static let wheelRadius: CGFloat = 13 * 0.75
    /// How fast the wheel carries the clown, in scene points per second: one tyre circumference per ride loop.
    static var wheelSpeed: CGFloat { 2 * .pi * wheelRadius / CGFloat(rideLoop) }
    /// One trip around the tent lasts 67 beats (20.1 s). An odd number of beats lets a performance's juggling
    /// clock, whole ride loops from the circus clock, still take every phase of the lap.
    static var orbitPeriod: TimeInterval { 67 * beat }
    static var orbitSpeed: Double { 2 * Double.pi / orbitPeriod }

    /// The ring is a circle seen from above at an angle: its width is the circle's radius, its depth
    /// foreshortened. The radius is the tyre's radius times the ride loops in a lap, so the clown moves at
    /// the wheel's own speed and the tyre never slips.
    static let orbitCenter = CGPoint(x: 168, y: 208)
    static var orbitRadii: CGSize { CGSize(width: wheelRadius * CGFloat(orbitPeriod / rideLoop), height: 104) }

    static func orbitPosition(angle: Double) -> CGPoint {
        CGPoint(x: orbitCenter.x + cos(angle) * orbitRadii.width, y: orbitCenter.y + sin(angle) * orbitRadii.height)
    }

    /// The ring's velocity at `angle`, in scene points per second.
    static func orbitVelocity(angle: Double) -> CGPoint {
        CGPoint(x: -orbitRadii.width * sin(angle) * orbitSpeed, y: orbitRadii.height * cos(angle) * orbitSpeed)
    }

    /// Behind the tent on the far half of the orbit.
    static func isBehind(angle: Double) -> Bool { sin(angle) < 0 }

    /// Riding toward image left on the near half.
    static func isFacingLeft(angle: Double) -> Bool { sin(angle) > 0 }

    /// The orbit started at angle 0 at clock time 0 (the tests' and evidence's reference lap).
    static func orbitPosition(at elapsed: TimeInterval) -> CGPoint { orbitPosition(angle: elapsed * orbitSpeed) }
    static func isBehind(at elapsed: TimeInterval) -> Bool { isBehind(angle: elapsed * orbitSpeed) }
    static func isFacingLeft(at elapsed: TimeInterval) -> Bool { isFacingLeft(angle: elapsed * orbitSpeed) }

    /// The first design's juggling, for single-clown sheets on the reference lap (AgentLandDesign's palette sheet).
    static var juggling: AgentLandJuggling? { AgentLandClownArtwork.designs.first?.juggling }

    /// The ride frame shown at `elapsed` on the circus clock.
    static func frameIndex(at elapsed: TimeInterval, frameCount: Int = 72) -> Int {
        guard frameCount > 0, elapsed > 0 else { return 0 }
        return Int(elapsed / frameDuration) % frameCount
    }

    /// Frames either side of a reversal over which the pedalling slows to a stop and picks up the other way:
    /// half a hold. Reversals fall in the middle of holds, so every frame shown meanwhile still closes the hand
    /// on its ball.
    static let reversalEasing = Int((AgentLandJuggling.dwellBeats * Double(framesPerBeat) / 2).rounded())

    /// The pedalling's frame count at clock frame `frame` when it reverses at each of `reversals` (clock
    /// frames, ascending, at least two easings apart): it counts up, then down after the first, up after the
    /// next. Within `reversalEasing` frames of a reversal it slows to a stop and back, a parabola that meets
    /// the straight count's value and speed at both ends, so the wheel turns round without a jolt.
    static func pedalPosition(_ frame: Double, reversals: [Int]) -> Double {
        let easing = Double(reversalEasing)
        var base = 0.0, sign = 1.0
        for reversal in reversals.map(Double.init) {
            if frame <= reversal - easing { break }
            if frame < reversal + easing {
                let offset = frame - reversal
                return base + sign * reversal - sign * (offset * offset + easing * easing) / (2 * easing)
            }
            base += 2 * sign * reversal
            sign = -sign
        }
        return base + sign * frame
    }

    /// The ride frame count shown at clock frame `frame`: `pedalPosition` to the nearest frame, which never
    /// falls on a half.
    static func pedalFrame(_ frame: Int, reversals: [Int]) -> Int {
        Int(pedalPosition(Double(frame), reversals: reversals).rounded())
    }
}

/// The riders' indexed five-tone palette (branding/clown-ride.json "palette"): index 1 is the outline and
/// deepest tone (line art, the tyre), 2 the dark fill (suits, hats, the far leg, the saddle and post, the far
/// crank), 3 the mid tone (shading, the near leg's shading, spokes), 4 the light tone (shading on white,
/// highlights, the hub, the near crank) and 5 white (face, gloves, collar). The same indices are drawn in the
/// day tones on the light paper and in the night tones on slate and the dark paper.
enum AgentLandClownRamp: Sendable, CaseIterable {
    case day, night

    /// The ramp for a backdrop's sRGB colour: night on a dark backdrop (slate, the dark paper), day on a light
    /// one (the paper). The split is mid-grey lightness (relative luminance 0.18, L* 50).
    static func forBackdrop(linearRed red: Double, green: Double, blue: Double) -> Self {
        0.2126 * red + 0.7152 * green + 0.0722 * blue < 0.18 ? .night : .day
    }
}

/// One clown design's packaged ride (branding/clown-ride/<name>/, ClownRide-<name>.png): 72 PixelLab
/// frames in the palette's indices with the unicycle drawn in, a ring drawn in the backdrop colour around each
/// frame, and the juggling built on the palms measured on its gloves.
struct AgentLandClownDesign: Sendable {
    let name: String
    /// Each frame's palette indices, row by row from the top: 0 is transparent, 1-5 the tones, darkest first.
    let indices: [[UInt8]]
    /// The frames drawn in the day tones and in the night tones, one per 1/60 s.
    let dayFrames: [CGImage]
    let nightFrames: [CGImage]
    /// The backdrop-coloured ring: every transparent pixel within two pixels of the silhouette, so the rider
    /// reads as a cut-out wherever it crosses the tent.
    let outlines: [CGImage]
    /// The day and night tones (sRGB, 0-255), index 1 first, as packaged with the rig.
    let tones: [AgentLandClownRamp: [[UInt8]]]
    let juggling: AgentLandJuggling

    func frames(_ ramp: AgentLandClownRamp) -> [CGImage] { ramp == .day ? dayFrames : nightFrames }
    var frameCount: Int { indices.count }
    var loopDuration: TimeInterval { AgentLandClownMotion.frameDuration * Double(max(1, frameCount)) }
}

/// The designs are horizontal strips of square frames (see branding/README.md), each pixel transparent or one of
/// the palette's day tones; the rig lists both ramps.
enum AgentLandClownArtwork {
    static let frameSide = 96
    /// Every ride is one 1.2 s loop of 72 frames. The choreography moves each performance's juggling by
    /// whole ride loops to line it up with the orbit.
    static let framesPerRide = 72
    static let toneCount = 5
    /// The six rubber-hose designs, in the order branding/clown-ride.json lists them.
    static let designNames = ["whiteface", "auguste", "tramp", "harlequin", "ringmaster", "strongman"]
    /// Whoever reads this first decodes every ride, and every other reader waits for that decode (seconds in a
    /// debug build). `prepareArtwork()` reads it off the main thread; the views read `prepared`, which never waits.
    static let designs: [AgentLandClownDesign] = {
        let made = designNames.compactMap(load)
        preparation.withLock { $0 = (made, Date()) }
        return made
    }()

    /// The designs and the moment their decode finished, once it has; nil until then. It never waits for the
    /// decode, so the main thread reads it every frame: a main-thread read of `designs` while
    /// `prepareArtwork()`'s decode ran held the main thread until the decode was done (batch 5's stall).
    static var prepared: (designs: [AgentLandClownDesign], at: Date)? { preparation.withLock { $0 } }
    private static let preparation = Mutex<(designs: [AgentLandClownDesign], at: Date)?>(nil)
    /// The first design's day and night tones, read from its rig alone. The tent and the covers recolour
    /// with them, so they must never wait for every ride's 72 frames (and their rings) to decode: doing that
    /// on the main thread held the opening cover blank for about 25 s in debug builds.
    static let rampTones: [AgentLandClownRamp: [[UInt8]]] = {
        guard let name = designNames.first,
              let source = AgentLandBrandingResources.json("ClownRide-\(name)", as: RigSource.self) else { return [:] }
        let day = source.tones.day.compactMap(rgb), night = source.tones.night.compactMap(rgb)
        guard day.count == toneCount, night.count == toneCount else { return [:] }
        return [.day: day, .night: night]
    }()

    /// The first design's ride, for single-clown sheets (AgentLandDesign's palette sheet).
    static func frames(_ ramp: AgentLandClownRamp) -> [CGImage] { designs.first?.frames(ramp) ?? [] }
    static var outlines: [CGImage] { designs.first?.outlines ?? [] }

    private struct RigSource: Decodable {
        struct Tones: Decodable { let day: [String]; let night: [String] }
        let frameDuration: Double; let framesPerBeat: Int; let ground: Double
        let rightPalm: [[Double]]; let leftPalm: [[Double]]
        let tones: Tones
    }

    /// "#RRGGBB" as three bytes.
    static func rgb(_ hex: String) -> [UInt8]? {
        guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return [UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]
    }

    private static func load(_ name: String) -> AgentLandClownDesign? {
        guard let source = AgentLandBrandingResources.json("ClownRide-\(name)", as: RigSource.self),
              source.rightPalm.count == framesPerRide, source.leftPalm.count == framesPerRide,
              source.rightPalm.allSatisfy({ $0.count == 2 }), source.leftPalm.allSatisfy({ $0.count == 2 }),
              abs(source.frameDuration - AgentLandClownMotion.frameDuration) < 1e-9,
              source.framesPerBeat == AgentLandClownMotion.framesPerBeat else { return nil }
        let day = source.tones.day.compactMap(rgb), night = source.tones.night.compactMap(rgb)
        guard day.count == toneCount, night.count == toneCount else { return nil }
        let strip = AgentLandBrandingResources.strip("ClownRide-\(name)", side: frameSide)
        guard strip.count == source.rightPalm.count else { return nil }
        var indices: [[UInt8]] = [], dayFrames: [CGImage] = [], nightFrames: [CGImage] = [], outlines: [CGImage] = []
        for cropped in strip {
            guard let pixels = rgbaBytes(cropped), let frame = self.indices(pixels, day: day),
                  let dayImage = image(from: paint(frame, day)), let nightImage = image(from: paint(frame, night)),
                  let ring = image(from: ring(around: frame)) else { return nil }
            indices.append(frame)
            dayFrames.append(dayImage)
            nightFrames.append(nightImage)
            outlines.append(ring)
        }
        let rig = AgentLandJuggling.Rig(rightPalm: source.rightPalm.map { CGPoint(x: $0[0], y: $0[1]) },
                                        leftPalm: source.leftPalm.map { CGPoint(x: $0[0], y: $0[1]) },
                                        framesPerBeat: source.framesPerBeat, frameDuration: source.frameDuration,
                                        ground: source.ground)
        return AgentLandClownDesign(name: name, indices: indices, dayFrames: dayFrames, nightFrames: nightFrames,
                                    outlines: outlines, tones: [.day: day, .night: night],
                                    juggling: AgentLandJuggling(rig: rig))
    }

    /// Each opaque pixel's tone: the day tone its colour matches (the nearest, so a decoder's rounding cannot
    /// lose a pixel). Nil when a pixel is far from every tone: the strip is not an indexed sheet.
    static func indices(_ pixels: [UInt8], day: [[UInt8]]) -> [UInt8]? {
        // Plain loops over the buffers: the decode runs in debug builds too, where a closure per pixel costs
        // seconds.
        let count = frameSide * frameSide
        guard pixels.count >= count * 4 else { return nil }
        let tones = day.flatMap { $0.prefix(3).map(Int.init) }
        guard tones.count == day.count * 3 else { return nil }
        var indices = [UInt8](repeating: 0, count: count)
        let complete = pixels.withUnsafeBufferPointer { source in
            tones.withUnsafeBufferPointer { tone in
                indices.withUnsafeMutableBufferPointer { result -> Bool in
                    for index in 0..<count where source[index * 4 + 3] >= 128 {
                        let red = Int(source[index * 4]), green = Int(source[index * 4 + 1]), blue = Int(source[index * 4 + 2])
                        var best = -1, bestDistance = Int.max, offset = 0
                        while offset < day.count {
                            let distance = abs(tone[offset * 3] - red) + abs(tone[offset * 3 + 1] - green)
                                + abs(tone[offset * 3 + 2] - blue)
                            if distance < bestDistance { best = offset; bestDistance = distance }
                            offset += 1
                        }
                        guard best >= 0, bestDistance <= 12 else { return false }
                        result[index] = UInt8(best + 1)
                    }
                    return true
                }
            }
        }
        return complete ? indices : nil
    }

    /// The indices drawn opaque in a ramp's tones, premultiplied RGBA.
    private static func paint(_ indices: [UInt8], _ tones: [[UInt8]]) -> [UInt8] {
        let flat = tones.flatMap { $0.prefix(3) }
        var bytes = [UInt8](repeating: 0, count: indices.count * 4)
        indices.withUnsafeBufferPointer { source in
            flat.withUnsafeBufferPointer { tone in
                bytes.withUnsafeMutableBufferPointer { result in
                    for index in 0..<source.count where source[index] > 0 {
                        let base = (Int(source[index]) - 1) * 3
                        result[index * 4] = tone[base]; result[index * 4 + 1] = tone[base + 1]
                        result[index * 4 + 2] = tone[base + 2]; result[index * 4 + 3] = 255
                    }
                }
            }
        }
        return bytes
    }

    /// A white template of every transparent pixel within two pixels of the silhouette (in the 5 × 5 square
    /// around it): a pass along the rows, then one down the columns, so the decode stays quick in debug builds.
    private static func ring(around indices: [UInt8]) -> [UInt8] {
        let side = frameSide
        var across = [UInt8](repeating: 0, count: indices.count), near = across
        var bytes = [UInt8](repeating: 0, count: indices.count * 4)
        indices.withUnsafeBufferPointer { source in
            across.withUnsafeMutableBufferPointer { across in
                near.withUnsafeMutableBufferPointer { near in
                    bytes.withUnsafeMutableBufferPointer { result in
                        // Opaque within two pixels along the row…
                        for y in 0..<side {
                            for x in 0..<side {
                                var xx = max(0, x - 2)
                                while xx <= min(side - 1, x + 2) {
                                    if source[y * side + xx] > 0 { across[y * side + x] = 1; break }
                                    xx += 1
                                }
                            }
                        }
                        // …in a row within two pixels up or down.
                        for y in 0..<side {
                            for x in 0..<side {
                                var yy = max(0, y - 2)
                                while yy <= min(side - 1, y + 2) {
                                    if across[yy * side + x] > 0 { near[y * side + x] = 1; break }
                                    yy += 1
                                }
                            }
                        }
                        for index in 0..<source.count where source[index] == 0 && near[index] > 0 {
                            result[index * 4] = 255; result[index * 4 + 1] = 255
                            result[index * 4 + 2] = 255; result[index * 4 + 3] = 255
                        }
                    }
                }
            }
        }
        return bytes
    }

    /// Redraws a frame into tightly packed premultiplied sRGB RGBA, so reads are format-independent and the
    /// stored day tones come back as written.
    static func rgbaBytes(_ image: CGImage) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? bytes : nil
    }

    private static func image(from bytes: [UInt8], side: Int = frameSide) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: side * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
