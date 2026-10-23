import CoreGraphics
import CoreText
import QuartzCore
import XCTest
#if os(macOS)
import AppKit
#endif
@testable import AgentLandBranding

final class WordmarkTests: XCTestCase {
    private typealias G = AgentLandWordmarkGeometry

    private func artwork() throws -> WordmarkArtwork {
        try XCTUnwrap(WordmarkArtwork.shared, "The title needs the packaged PixelLab rubber-hose font")
    }

    /// The original style on the night ramp, the stage the existing motion tests build from.
    private func stage(_ style: AgentLandWordmarkStyle = .classic) throws -> WordmarkStage {
        WordmarkStage(set: try XCTUnwrap(WordmarkFontSet.shared), style: style, ramp: .night)
    }

    func testFontRegistersForThisProcessWithItsPostScriptName() throws {
        XCTAssertTrue(AgentLandWordmarkFont.isRegistered)
        let font = try XCTUnwrap(AgentLandWordmarkFont.font(size: 20))
        XCTAssertEqual(CTFontCopyPostScriptName(font) as String, "AgentLandRubberHose")
        XCTAssertEqual(CTFontCopyFamilyName(font) as String, "AgentLand Rubber Hose")
        let url = try XCTUnwrap(AgentLandWordmarkFont.fontURL)
        let descriptors = try XCTUnwrap(CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])
        XCTAssertEqual(CTFontDescriptorCopyAttribute(descriptors[0], kCTFontNameAttribute) as? String, "AgentLandRubberHose")
        XCTAssertTrue(AgentLandWordmarkFont.licenseText.contains("SIL OPEN FONT LICENSE Version 1.1"))
        XCTAssertTrue(AgentLandWordmarkFont.licenseText.contains("The Holtwood Project Authors"))
    }

    func testLettersSitOnTheFlatArch() throws {
        let artwork = try artwork()
        XCTAssertEqual(String(artwork.glyphs.map(\.character)), "AGENTLAND")
        XCTAssertEqual(artwork.capHeight, 48, accuracy: 0.001, "Cap height from the H outline")
        XCTAssertEqual(G.radius, 680)
        XCTAssertEqual(Double(G.sweep) * 180 / .pi, 42, accuracy: 1e-9)
        let probe = try XCTUnwrap(AgentLandWordmarkFont.font(size: artwork.fontSize))
        XCTAssertEqual(CTFontGetCapHeight(probe), artwork.capHeight, accuracy: G.artUnit,
                       "The packaged pixel font supplies the title's cap height")
        XCTAssertTrue((0.5...12).contains(artwork.tracking), "Letters evenly spaced, never touching: \(artwork.tracking)")
        XCTAssertEqual(Double(artwork.glyphs.first!.angle) * 180 / .pi, -21, accuracy: 0.001)
        XCTAssertEqual(Double(artwork.glyphs.last!.angle) * 180 / .pi, 21, accuracy: 0.001)
        for (earlier, later) in zip(artwork.glyphs, artwork.glyphs.dropFirst()) {
            XCTAssertLessThan(earlier.angle, later.angle, "Letters run left to right along the arch")
        }
        for glyph in artwork.glyphs {
            XCTAssertEqual(hypot(glyph.arcPoint.x - G.centre.x, glyph.arcPoint.y - G.centre.y), G.radius, accuracy: 0.001,
                           "\(glyph.character) sits on the baseline circle")
            XCTAssertEqual(glyph.arcPoint.x - G.centre.x, G.radius * sin(glyph.angle), accuracy: 0.001)
            // Each letter's pixels lie on the tent's grid, which is anchored at the tent's origin (42, 54).
            let column = (glyph.frame.minX - 42) / G.artUnit, row = (glyph.frame.minY - 54) / G.artUnit
            XCTAssertEqual(column, column.rounded(), accuracy: 1e-9)
            XCTAssertEqual(row, row.rounded(), accuracy: 1e-9)
            // Turned to the circle's normal, the letter lies outside the baseline circle, cap height deep.
            var farthest: CGFloat = 0
            for y in 0..<glyph.height { for x in 0..<glyph.width where glyph.isOn(x, y) {
                let centre = CGPoint(x: glyph.frame.minX + (CGFloat(x) + 0.5) * G.artUnit,
                                     y: glyph.frame.minY + (CGFloat(y) + 0.5) * G.artUnit)
                let distance = hypot(centre.x - G.centre.x, centre.y - G.centre.y)
                XCTAssertGreaterThan(distance, G.radius - G.artUnit * 1.5, "\(glyph.character) pixel inside the arch")
                farthest = max(farthest, distance)
            } }
            var scalar = UniChar(glyph.character.asciiValue!), sourceGlyph = CGGlyph(0), sourceBounds = CGRect.zero
            XCTAssertTrue(CTFontGetGlyphsForCharacters(probe, &scalar, &sourceGlyph, 1))
            CTFontGetBoundingRectsForGlyphs(probe, .horizontal, &sourceGlyph, &sourceBounds, 1)
            XCTAssertEqual(farthest, G.radius + sourceBounds.maxY, accuracy: G.artUnit * 1.5,
                           "\(glyph.character) preserves the PixelLab face's intentionally varied letter height")
        }
        // Symmetric about the tent's centre line.
        XCTAssertEqual(artwork.glyphs.first!.arcPoint.x + artwork.glyphs.last!.arcPoint.x, 2 * G.centre.x, accuracy: 0.001)
        print("Title: font size \(artwork.fontSize), tracking \(artwork.tracking), canvas \(artwork.canvas)")
    }

    /// Bigger and wider than round 1's 160° arch (310 x 155 units, cap 34), and flatter: wider than it is tall.
    func testCanvasHoldsEveryLetterAndBulbAboveTheSceneBand() throws {
        let artwork = try artwork()
        let canvas = artwork.canvas
        XCTAssertEqual(canvas, G.canvas)
        for glyph in artwork.glyphs { XCTAssertTrue(canvas.contains(glyph.frame), "\(glyph.character) fits the canvas") }
        for index in artwork.bulbs.indices { XCTAssertTrue(canvas.contains(artwork.bulbFrame(index))) }
        XCTAssertEqual(canvas.midX, 168, accuracy: G.artUnit, "The title is centred on the tent")
        // It may overlap only the scene's motion-free top band.
        XCTAssertLessThanOrEqual(canvas.maxY, 40)
        XCTAssertLessThan(canvas.maxY, 20, "A shallow arch leaves more height for the launcher")
        XCTAssertGreaterThan(canvas.width, 460, "Wider")
        XCTAssertGreaterThan(canvas.width / canvas.height, 4.5, "Flat")
    }

    /// The letters and bulbs never meet a clown or a ball: every design with its real silhouette and fill,
    /// on the ring (the reference lap sampled at 30 Hz over the 50.4 s juggling loop, which every
    /// performance keeps; see ChoreographyTests), and on its way out of the doorway and back in.
    func testTitleClearsTheClownAndBallsByEightUnits() throws {
        let artwork = try artwork()
        let designs = AgentLandClownArtwork.designs
        XCTAssertEqual(designs.count, 6)
        let title = artwork.glyphs.map(\.frame) + artwork.bulbs.indices.map(artwork.bulbFrame)
        var clearance = CGFloat.infinity
        let pixel: CGFloat = 0.75
        let ballBounds = AgentLandJugglingBall.ring.map(opaqueBounds).reduce(CGRect.null) { $0.union($1) }
        func ball(_ point: CGPoint) -> CGRect {
            CGRect(x: point.x + (ballBounds.minX - 8) * pixel, y: point.y + (ballBounds.minY - 8) * pixel,
                   width: ballBounds.width * pixel, height: ballBounds.height * pixel)
        }
        for design in designs {
            // The sprite and its ring (two pixels outside), in sprite pixels.
            let silhouettes = zip(design.dayFrames, design.outlines).map { opaqueBounds($0).union(opaqueBounds($1)) }
            func measure(centre: CGPoint, facingLeft: Bool, time: Double, balls: [AgentLandJuggling.LocalBall],
                         ground: [AgentLandJuggling.GroundBall]) {
                let flip: CGFloat = facingLeft ? -1 : 1
                let box = silhouettes[AgentLandClownMotion.frameIndex(at: time, frameCount: design.frameCount)]
                let xs = [box.minX, box.maxX].map { centre.x + flip * ($0 - 48) * pixel }
                var moving = [CGRect(x: xs.min()!, y: centre.y + (box.minY - 48) * pixel, width: abs(xs[1] - xs[0]), height: box.height * pixel)]
                moving += balls.map { ball(CGPoint(x: centre.x + flip * ($0.point.x - 48) * pixel, y: centre.y + ($0.point.y - 48) * pixel)) }
                moving += ground.map { ball($0.point) }
                for shape in title { for other in moving { clearance = min(clearance, distance(shape, other)) } }
            }
            for step in 0..<Int((120.0 * 30).rounded()) {
                let time = Double(step) / 30
                let ground = design.juggling.groundBalls(at: time) { landing in
                    AgentLandJuggling.Placement(center: AgentLandClownMotion.orbitPosition(at: landing),
                                                facingLeft: AgentLandClownMotion.isFacingLeft(at: landing),
                                                behind: AgentLandClownMotion.isBehind(at: landing))
                }
                measure(centre: AgentLandClownMotion.orbitPosition(at: time), facingLeft: AgentLandClownMotion.isFacingLeft(at: time),
                        time: time, balls: design.juggling.balls(at: time), ground: ground)
            }
            // Out of the doorway to the ring and back in, with every ride frame.
            let C = AgentLandCircusChoreography.self
            let join = C.fadeDuration + C.rideDuration, turn = join + AgentLandClownMotion.orbitPeriod
            let door = C.Appearance(design: 0, emerge: 0, join: join, stop: join + 1, turn: turn,
                                    back: turn + C.rideDuration, gone: turn + C.rideDuration + 0.4, offset: 0)
            for time in Array(stride(from: 0.0, to: join, by: 1.0 / 30)) + Array(stride(from: turn, to: door.gone, by: 1.0 / 30)) {
                for frame in 0..<design.frameCount {
                    let state = C.state(of: door, at: time)
                    measure(centre: state.center, facingLeft: state.facingLeft, time: (Double(frame) + 0.5) * 0.1, balls: [], ground: [])
                }
            }
        }
        print("Wordmark clearance from the clowns and balls: \(clearance) scene units")
        XCTAssertGreaterThanOrEqual(clearance, 8)
    }

    @MainActor
    func testRestingImageDrawsEveryLetterPixelOnTheGrid() throws {
        let artwork = try artwork()
        let image = try XCTUnwrap(AgentLandWordmark.restingImage(color: CGColor(gray: 1, alpha: 1), scale: 3))
        XCTAssertEqual(image.width, artwork.canvasWidth * 3)
        XCTAssertEqual(image.height, artwork.canvasHeight * 3)
        let lit = alpha(image).filter { $0 }.count
        XCTAssertEqual(lit, artwork.glyphs.reduce(0) { $0 + $1.pixels.filter { $0 }.count } * 9)
        let withBulbs = try XCTUnwrap(AgentLandWordmark.restingImage(color: CGColor(gray: 1, alpha: 1), scale: 1, showsBulbs: true))
        XCTAssertGreaterThan(alpha(withBulbs).filter { $0 }.count, lit / 9)
    }

    func testEntrancesTakeBetween0_9And1_4Seconds() throws {
        let artwork = try artwork()
        for kind in AgentLandWordmarkEntrance.allCases {
            let tracks = WordmarkChoreography.entrance(kind, stage: try stage(), seed: 7)
            XCTAssertFalse(tracks.isEmpty)
            let length = tracks.map(\.end).max() ?? 0
            XCTAssertTrue((0.9...1.4).contains(length), "\(kind) lasts \(length) s")
            let touched = Set(tracks.compactMap { track -> Int? in
                switch track.target { case .letter(let index), .letterMask(let index): index; case .bulb: nil }
            })
            XCTAssertEqual(touched, Set(artwork.glyphs.indices), "\(kind) brings in every letter")
        }
    }

    func testAnimationsTouchOnlyTransformOpacityAndContents() throws {
        let stage = try stage()
        let tracks = AgentLandWordmarkEntrance.allCases.flatMap { WordmarkChoreography.entrance($0, stage: stage, seed: 3) }
            + AgentLandWordmarkFlourish.allCases.flatMap { WordmarkChoreography.flourish($0, stage: stage, seed: 3, beatDelay: 0.1) }
        for track in tracks {
            XCTAssertTrue(WordmarkTrack.allowedKeyPaths.contains(track.keyPath), track.keyPath)
            XCTAssertFalse(track.keyPath.contains("position"), "Position keyframes identify the clown's orbit")
            let expectedTimes = track.discrete ? track.values.count + 1 : track.values.count
            XCTAssertEqual(track.keyTimes.count, expectedTimes, "\(track.keyPath) key times")
            XCTAssertEqual(track.keyTimes, track.keyTimes.sorted(), "\(track.keyPath) key times run forward")
            XCTAssertEqual(track.keyTimes.first, 0); XCTAssertEqual(track.keyTimes.last, 1)
            // Every track ends where the resting pose is, so removing it never jumps.
            switch track.keyPath {
            case "opacity": XCTAssertEqual(track.numbers.last, isBulb(track.target) ? 0 : 1, "Letters rest lit, bulbs dark")
            case "transform.scale", "transform.scale.x", "transform.scale.y": XCTAssertEqual(track.numbers.last, 1)
            case "contents": break
            default: XCTAssertEqual(track.numbers.last ?? 0, 0, accuracy: 1e-9, track.keyPath)
            }
        }
    }

    func testFlashingStaysGentle() throws {
        let artwork = try artwork()
        let blink = WordmarkChoreography.flourish(.marqueeBlink, stage: try stage(), seed: 1, beatDelay: 0)
        for track in blink {
            let values = track.numbers
            let dips = values.indices.dropFirst().dropLast().filter { values[$0] < values[$0 - 1] && values[$0] < values[$0 + 1] }
            XCTAssertLessThanOrEqual(dips.count, 2, "At most two dips")
            XCTAssertGreaterThanOrEqual(values.min() ?? 0, 0.3, "Dips never go dark")
            XCTAssertLessThanOrEqual(Double(dips.count) / track.duration, 2, "At most 2 Hz")
        }
        for track in WordmarkChoreography.flourish(.bulbChase, stage: try stage(), seed: 1, beatDelay: 0) {
            let flashes = zip(track.numbers, track.numbers.dropFirst()).filter { $0 == 0 && $1 == 1 }.count
            XCTAssertLessThanOrEqual(Double(flashes) / track.duration, 2, "Each bulb lights at most twice a second")
        }
    }

    func testJuggleHopLandsOnTheClownsBeat() throws {
        let artwork = try artwork()
        let tracks = WordmarkChoreography.flourish(.juggleHop, stage: try stage(), seed: 11, beatDelay: 0.17)
        XCTAssertEqual(tracks.count, 1, "One letter hops")
        let hop = try XCTUnwrap(tracks.first)
        XCTAssertEqual(hop.delay, 0.17, "It waits for the next beat")
        XCTAssertEqual(AgentLandClownMotion.frameDuration * Double(AgentLandClownMotion.framesPerBeat), 0.3, accuracy: 1e-9, "The clown's beat is eighteen ride frames")
        XCTAssertEqual(hop.duration, 4 * 0.3, accuracy: 1e-9)
        let landings = zip(hop.numbers, hop.keyTimes).filter { abs($0.0) < 1e-9 }.map { $0.1 * hop.duration }
        XCTAssertEqual(landings.count, 5)
        for (index, time) in landings.enumerated() { XCTAssertEqual(time, Double(index) * 0.3, accuracy: 1e-9) }
    }

    func testPickerNeverRepeatsAndSkipsThePreviousLaunchsLastEntrance() throws {
        let suite = "WordmarkTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(AgentLandWordmarkPicker.savedEntrance(in: defaults))
        defaults.set(42, forKey: AgentLandWordmarkPicker.lastEntranceKey)
        XCTAssertNil(AgentLandWordmarkPicker.savedEntrance(in: defaults), "Unreadable values count as none")

        for seed in UInt64(0)..<40 {
            var picker = AgentLandWordmarkPicker(seed: seed, lastEntrance: .pixelAssemble)
            var entrances: [AgentLandWordmarkEntrance] = [], flourishes: [AgentLandWordmarkFlourish] = []
            for _ in 0..<200 {
                entrances.append(picker.nextEntrance(saving: defaults))
                flourishes.append(picker.nextFlourish())
            }
            XCTAssertNotEqual(entrances.first, .pixelAssemble, "A launch never opens with the last launch's entrance")
            XCTAssertFalse(zip(entrances, entrances.dropFirst()).contains { $0 == $1 })
            XCTAssertFalse(zip(flourishes, flourishes.dropFirst()).contains { $0 == $1 })
            XCTAssertEqual(Set(entrances), Set(AgentLandWordmarkEntrance.allCases))
            XCTAssertEqual(Set(flourishes), Set(AgentLandWordmarkFlourish.allCases))
            XCTAssertEqual(AgentLandWordmarkPicker.savedEntrance(in: defaults), entrances.last, "The last entrance is saved")
        }
        var first = AgentLandWordmarkPicker(seed: 99), second = AgentLandWordmarkPicker(seed: 99)
        XCTAssertEqual((0..<20).map { _ in first.nextEntrance() }, (0..<20).map { _ in second.nextEntrance() }, "Seedable")
        let delays = (0..<100).map { _ in first.idleDelay() }
        XCTAssertTrue(delays.allSatisfy { (20...30).contains($0) }, "Idle flourishes come every 20–30 s")
    }

    func testPickerChoosesANewFaceAndLookEachTime() throws {
        let suite = "WordmarkTests-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let faces = AgentLandWordmarkFaces.all.map(\.id)
        defaults.set("gone", forKey: AgentLandWordmarkPicker.lastFaceKey); defaults.set("bevel", forKey: AgentLandWordmarkPicker.lastLookKey)
        XCTAssertNil(AgentLandWordmarkPicker.savedStyle(in: defaults, faces: faces), "A removed face counts as none")
        defaults.set(7, forKey: AgentLandWordmarkPicker.lastFaceKey)
        XCTAssertNil(AgentLandWordmarkPicker.savedStyle(in: defaults, faces: faces), "Unreadable counts as none")
        var picker = AgentLandWordmarkPicker(seed: 5, lastStyle: AgentLandWordmarkStyle(face: "chango", look: .extrude))
        var styles: [AgentLandWordmarkStyle] = []
        for _ in 0..<300 { styles.append(picker.nextStyle(faces: faces, saving: defaults)) }
        XCTAssertNotEqual(styles[0].face, "chango"); XCTAssertNotEqual(styles[0].look, .extrude)
        for (a, b) in zip(styles, styles.dropFirst()) { XCTAssertNotEqual(a.face, b.face); XCTAssertNotEqual(a.look, b.look) }
        XCTAssertEqual(Set(styles.map(\.face)), Set(faces)); XCTAssertEqual(Set(styles.map(\.look)), Set(AgentLandWordmarkLook.allCases))
        XCTAssertEqual(AgentLandWordmarkPicker.savedStyle(in: defaults, faces: faces), styles.last)
        XCTAssertEqual(picker.nextStyle(faces: ["rubberHose"]).face, "rubberHose", "One face left: it repeats")
    }

    func testNewEntrancesAreThere() {
        XCTAssertEqual(AgentLandWordmarkEntrance.allCases.count, 12)
        let added: [AgentLandWordmarkEntrance] = [.tossUp, .spinIn, .slotShuffle, .inkFill, .stamp, .stretchSnap]
        XCTAssertTrue(added.allSatisfy(AgentLandWordmarkEntrance.allCases.contains))
    }

    func testSlotShuffleLandsOnTheStageFace() throws {
        let set = try XCTUnwrap(WordmarkFontSet.shared)
        let stage = WordmarkStage(set: set, style: AgentLandWordmarkStyle(face: "chango", look: .dropShadow), ramp: .night)
        let contents = WordmarkChoreography.entrance(.slotShuffle, stage: stage, seed: 4).filter { $0.keyPath == "contents" }
        XCTAssertEqual(contents.count, 2 * set.boxes.count, "Each letter's image and mask shuffle")
        for track in contents {
            guard case let .image(last) = track.values.last else { return XCTFail("Image frames") }
            let images = track.values.compactMap { if case let .image(image) = $0 { image } else { nil } }
            XCTAssertEqual(images.count, 9)
            XCTAssertFalse(zip(images, images.dropFirst()).contains { $0 === $1 }, "Never the same face twice running")
            switch track.target {
            case .letter(let slot): XCTAssertTrue(last === set.face(stage.style, slot: slot, ramp: .night), "Lands on the stage face")
            case .letterMask(let slot): XCTAssertTrue(last === set.mask(stage.style, slot: slot))
            case .bulb: XCTFail("No bulbs")
            }
        }
    }

    func testInkFillGrowsFromTheBottom() throws {
        let set = try XCTUnwrap(WordmarkFontSet.shared), style = AgentLandWordmarkStyle(face: "coiny", look: .candyStripe)
        for slot in set.boxes.indices {
            let box = set.boxes[slot], frames = set.revealMasks(style, slot: slot, count: 8, order: .rowsFromBottom)
            XCTAssertEqual(frames.count, 9)
            let cells = frames.map { opaqueCells($0, box) }, whole = opaqueCells(try XCTUnwrap(set.mask(style, slot: slot)), box)
            XCTAssertTrue(cells[0].isEmpty, "Starts empty")
            XCTAssertEqual(cells[8], whole, "Ends whole")
            for (earlier, later) in zip(cells, cells.dropFirst()) { XCTAssertTrue(earlier.isSubset(of: later), "Only grows") }
            let lowest = whole.map { $0 / 100_000 }.max()!
            for frame in cells.dropFirst() { XCTAssertEqual(frame.map { $0 / 100_000 }.max(), lowest, "From the bottom row up") }
        }
        let ink = WordmarkChoreography.entrance(.inkFill, stage: WordmarkStage(set: set, style: style, ramp: .night), seed: 1)
        XCTAssertTrue(ink.allSatisfy { if case .letterMask = $0.target { $0.keyPath == "contents" } else { false } })
    }

    func testNewFlourishesAreThere() {
        XCTAssertEqual(AgentLandWordmarkFlourish.allCases.count, 13)
        let added: [AgentLandWordmarkFlourish] = [.fontFlip, .fontDissolve, .jellyWobble, .dominoTip, .sparkleTwinkle,
                                                  .spotlightSweep, .leapfrog, .dripAndReform]
        XCTAssertTrue(added.allSatisfy(AgentLandWordmarkFlourish.allCases.contains))
        XCTAssertTrue(added.allSatisfy { !WordmarkChoreography.flourish($0, stage: (try? stage(AgentLandWordmarkStyle(face: "bungee", look: .extrude)))!,
                                                                        seed: 5, beatDelay: 0).isEmpty }, "Each one moves something")
    }

    func testMorphsEndOnTheStageFace() throws {
        let stage = try stage(AgentLandWordmarkStyle(face: "titanOne", look: .doubleOutline))
        for kind in [AgentLandWordmarkFlourish.fontFlip, .fontDissolve] {
            let contents = WordmarkChoreography.flourish(kind, stage: stage, seed: 9, beatDelay: 0).filter { $0.keyPath == "contents" }
            XCTAssertEqual(contents.count, 2 * stage.set.boxes.count, "\(kind): every letter's image and mask")
            for track in contents {
                guard case let .image(first) = track.values.first, case let .image(last) = track.values.last else { return XCTFail("Images") }
                XCTAssertTrue(first === last, "\(kind) ends where it started")
                if case let .letter(slot) = track.target { XCTAssertTrue(first === stage.set.face(stage.style, slot: slot, ramp: .night)) }
                if case let .letterMask(slot) = track.target { XCTAssertTrue(first === stage.set.mask(stage.style, slot: slot)) }
                XCTAssertTrue(track.values.contains { if case let .image(image) = $0 { image !== first } else { false } }, "\(kind) shows another face")
            }
        }
    }

    func testSparklesLightEachPixelOnce() throws {
        let stage = try stage(AgentLandWordmarkStyle(face: "shrikhand", look: .bevel))
        let points = stage.set.sparkles(stage.style, seed: 3, count: 14)
        XCTAssertEqual(points.count, 14)
        XCTAssertEqual(Set(points.map { "\($0.slot):\($0.column):\($0.row)" }).count, 14, "Each pixel once")
        for point in points {
            let tones = stage.set.tones(stage.style, slot: point.slot, ramp: .night), box = stage.set.boxes[point.slot]
            XCTAssertGreaterThan(tones[(point.row - box.row) * box.width + point.column - box.column], 1, "On the letter, inside its outline")
        }
        let sparkle = WordmarkChoreography.flourish(.sparkleTwinkle, stage: stage, seed: 3, beatDelay: 0)
        XCTAssertTrue(sparkle.allSatisfy { $0.keyPath == "contents" })
        XCTAssertLessThanOrEqual(sparkle.map(\.end).max() ?? 0, 2.4 + 1e-9)
    }

    func testNoNewFlourishBlinks() throws {
        let stage = try stage(AgentLandWordmarkStyle(face: "coiny", look: .candyStripe))
        for kind in AgentLandWordmarkFlourish.allCases where kind != .marqueeBlink {
            for track in WordmarkChoreography.flourish(kind, stage: stage, seed: 2, beatDelay: 0) where track.keyPath == "opacity" {
                XCTAssertTrue(isBulb(track.target), "\(kind) never dims a letter")
            }
        }
    }

    func testLeapfroggersSwapAndComeBack() throws {
        let stage = try stage()
        let tracks = WordmarkChoreography.flourish(.leapfrog, stage: stage, seed: 6, beatDelay: 0.2)
        let movers = Set(tracks.compactMap { if case let .letter(slot) = $0.target { slot } else { nil } })
        XCTAssertEqual(movers.count, 2)
        let a = movers.min()!, b = movers.max()!
        XCTAssertEqual(b, a + 1, "Neighbours")
        for track in tracks {
            XCTAssertEqual(track.delay, 0.2); XCTAssertEqual(track.duration, 2.0, accuracy: 1e-9)
            XCTAssertEqual(track.numbers.last ?? 1, 0, accuracy: 1e-9, "Back home")
        }
        let x = try XCTUnwrap(tracks.first { $0.target == .letter(a) && $0.keyPath == "transform.translation.x" })
        // Between the hops the track holds its last key: the value in force at 1.0 s.
        let held = Array(zip(x.keyTimes, x.numbers)).last { $0.0 <= 0.5 }?.1
        XCTAssertEqual(held ?? 0, stage.set.pivots[b].x - stage.set.pivots[a].x, accuracy: 0.5, "In its neighbour's place mid-way")
    }

    #if os(macOS)
    @MainActor
    func testATapDuringAMorphLeavesTheStageFaceInTheModel() throws {
        let suite = "WordmarkTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 304, height: 152), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let host = WordmarkHostView(frame: NSRect(x: 0, y: 0, width: 304, height: 152), defaults: defaults)
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        let controller = host.controller, set = try XCTUnwrap(WordmarkFontSet.shared)
        controller.update(color: CGColor(gray: 1, alpha: 1), motionAllowed: true, referenceDate: Date(), flourishRequests: 0, ramp: .night)
        controller.playFlourish(.fontFlip)
        controller.playFlourish(.fontDissolve)
        XCTAssertTrue(controller.letters.indices.allSatisfy {
            (controller.letters[$0].contents.map { $0 as! CGImage }) === set.face(controller.style, slot: $0, ramp: .night)
        }, "The model keeps the load's face under any morph")
        XCTAssertTrue(controller.masks.indices.allSatisfy {
            (controller.masks[$0].contents.map { $0 as! CGImage }) === set.mask(controller.style, slot: $0)
        })
    }
    #endif

    func testMotionGateMatchesTheCircus() {
        XCTAssertTrue(AgentLandWordmarkMotionGate.allowsMotion(active: true, reduceMotion: false, sceneActive: true, arguments: []))
        XCTAssertFalse(AgentLandWordmarkMotionGate.allowsMotion(active: true, reduceMotion: true, sceneActive: true, arguments: []))
        XCTAssertFalse(AgentLandWordmarkMotionGate.allowsMotion(active: false, reduceMotion: false, sceneActive: true, arguments: []))
        XCTAssertFalse(AgentLandWordmarkMotionGate.allowsMotion(active: true, reduceMotion: false, sceneActive: false, arguments: []))
        XCTAssertFalse(AgentLandWordmarkMotionGate.allowsMotion(active: true, reduceMotion: false, sceneActive: true,
                                                                arguments: ["-AgentLandUITestsDisableAnimations"]))
    }

    #if os(macOS)
    /// Hosted in a real window, as in the app: Core Animation drops animations of layers outside one.
    @MainActor
    func testTitleRestsStillWithoutMotionAndAnimatesOnlyAllowedKeyPaths() throws {
        let suite = "WordmarkTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 304, height: 152), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let host = WordmarkHostView(frame: NSRect(x: 0, y: 0, width: 304, height: 152), defaults: defaults)
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.layer?.isGeometryFlipped, true, "Letters use the same top-left geometry as on iOS")
        let controller = host.controller
        let white = CGColor(gray: 1, alpha: 1)
        // Reduce Motion, hidden, covered or inactive: the resting pose, with no animation anywhere.
        controller.update(color: white, motionAllowed: false, referenceDate: Date(), flourishRequests: 0)
        XCTAssertEqual(controller.letters.count, 9)
        XCTAssertTrue(controller.animatableLayers.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        XCTAssertTrue(controller.letters.allSatisfy { $0.opacity == 1 && CATransform3DIsIdentity($0.transform) })
        XCTAssertTrue(controller.bulbs.allSatisfy { $0.opacity == 0 })
        XCTAssertTrue(controller.letters.allSatisfy { $0.backgroundColor == white }, "Tinted like the tent")
        XCTAssertTrue(controller.masks.allSatisfy { $0.magnificationFilter == .nearest }, "Pixels stay crisp")
        controller.update(color: white, motionAllowed: false, referenceDate: Date(), flourishRequests: 1)
        XCTAssertTrue(controller.animatableLayers.allSatisfy { ($0.animationKeys() ?? []).isEmpty }, "A tap without motion stays still")

        // Revealed: an entrance on the render server.
        controller.update(color: white, motionAllowed: true, referenceDate: Date(), flourishRequests: 1)
        let animations = controller.animatableLayers.flatMap { layer in
            (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) as? CAKeyframeAnimation }
        }
        XCTAssertFalse(animations.isEmpty)
        for animation in animations {
            XCTAssertTrue(WordmarkTrack.allowedKeyPaths.contains(animation.keyPath ?? ""), animation.keyPath ?? "")
        }
        XCTAssertNotNil(AgentLandWordmarkPicker.savedEntrance(in: defaults), "The entrance is remembered for the next launch")

        // A tap plays a flourish on top.
        controller.update(color: white, motionAllowed: true, referenceDate: Date(), flourishRequests: 2)
        XCTAssertTrue(controller.animatableLayers.contains { ($0.animationKeys() ?? []).contains { $0.hasPrefix("wordmarkFlourish") } })

        controller.update(color: white, motionAllowed: false, referenceDate: Date(), flourishRequests: 2)
        XCTAssertTrue(controller.animatableLayers.allSatisfy { ($0.animationKeys() ?? []).isEmpty }, "Covered again: still")
        XCTAssertTrue(controller.letters.allSatisfy { $0.opacity == 1 && CATransform3DIsIdentity($0.transform) })
    }

    /// The iPhone's Home stays alive under the pages pushed over it: shown again, its title picks up where it was, with
    /// no new face, look or entrance (owner, 2026-10-22: Home "reappearing very slow on returning home"). Elsewhere each
    /// reveal is a new entrance.
    @MainActor
    func testTitleShownAgainWithoutReplayKeepsItsStyleAndPlaysNoEntrance() throws {
        let suite = "WordmarkTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 304, height: 152), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let host = WordmarkHostView(frame: NSRect(x: 0, y: 0, width: 304, height: 152), defaults: defaults)
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        let controller = host.controller
        let white = CGColor(gray: 1, alpha: 1)
        func entranceRunning() -> Bool {
            controller.animatableLayers.contains { ($0.animationKeys() ?? []).contains { $0.hasPrefix("wordmarkEntrance") } }
        }

        controller.update(color: white, motionAllowed: false, referenceDate: Date(), flourishRequests: 0, replaysEntrance: false)
        controller.update(color: white, motionAllowed: true, referenceDate: Date(), flourishRequests: 0, replaysEntrance: false)
        XCTAssertTrue(entranceRunning(), "The first reveal plays an entrance")
        let style = controller.style

        controller.update(color: white, motionAllowed: false, referenceDate: Date(), flourishRequests: 0, replaysEntrance: false)
        controller.update(color: white, motionAllowed: true, referenceDate: Date(), flourishRequests: 0, replaysEntrance: false)
        XCTAssertFalse(entranceRunning(), "Shown again: no new entrance")
        XCTAssertEqual(controller.style, style, "Shown again: the same face and look")
        XCTAssertTrue(controller.letters.allSatisfy { $0.opacity == 1 && CATransform3DIsIdentity($0.transform) },
                      "The letters rest on the arch")
        controller.update(color: white, motionAllowed: true, referenceDate: Date(), flourishRequests: 1, replaysEntrance: false)
        XCTAssertTrue(controller.animatableLayers.contains { ($0.animationKeys() ?? []).contains { $0.hasPrefix("wordmarkFlourish") } },
                      "A tap still plays a flourish")

        controller.update(color: white, motionAllowed: false, referenceDate: Date(), flourishRequests: 1)
        controller.update(color: white, motionAllowed: true, referenceDate: Date(), flourishRequests: 1)
        XCTAssertTrue(entranceRunning(), "Where reveals replay (the default), shown again is a new entrance")
    }

    @MainActor
    func testTitleWearsItsStyleThroughRestRampChangesAndEntrances() throws {
        let suite = "WordmarkTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 304, height: 152), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let host = WordmarkHostView(frame: NSRect(x: 0, y: 0, width: 304, height: 152), defaults: defaults)
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        let controller = host.controller, white = CGColor(gray: 1, alpha: 1), set = try XCTUnwrap(WordmarkFontSet.shared)
        func image(_ layer: CALayer) -> CGImage? { layer.contents.map { $0 as! CGImage } }

        controller.update(color: white, motionAllowed: false, referenceDate: Date(), flourishRequests: 0, ramp: .night)
        let first = controller.style
        XCTAssertTrue(controller.letters.indices.allSatisfy { image(controller.letters[$0]) === set.face(first, slot: $0, ramp: .night) },
                      "Still, the letters wear the picked face and look")
        XCTAssertEqual(AgentLandWordmarkPicker.savedStyle(in: defaults, faces: set.faces.map(\.id)), first)
        controller.update(color: white, motionAllowed: false, referenceDate: Date(), flourishRequests: 0, ramp: .day)
        XCTAssertEqual(controller.style, first, "A ramp change keeps the face and look")
        XCTAssertTrue(controller.letters.indices.allSatisfy { image(controller.letters[$0]) === set.face(first, slot: $0, ramp: .day) })
        controller.update(color: white, motionAllowed: true, referenceDate: Date(), flourishRequests: 0, ramp: .day)
        let second = controller.style
        XCTAssertNotEqual(second.face, first.face, "Each entrance brings a new face"); XCTAssertNotEqual(second.look, first.look)
        controller.playEntrance(.pixelAssemble)
        controller.update(color: white, motionAllowed: false, referenceDate: Date(), flourishRequests: 0, ramp: .day)
        XCTAssertTrue(controller.masks.indices.allSatisfy { image(controller.masks[$0]) === set.mask(second, slot: $0) },
                      "Covered mid-entrance: the style's own masks")
        XCTAssertEqual(controller.letters.map(\.frame.size), set.boxes.map { $0.frame.size }, "Slot boxes never change")
    }
    #endif

    // MARK: Helpers

    private func isBulb(_ target: WordmarkTrack.Target) -> Bool {
        if case .bulb = target { return true }
        return false
    }

    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = max(0, max(a.minX - b.maxX, b.minX - a.maxX)), dy = max(0, max(a.minY - b.maxY, b.minY - a.maxY))
        return hypot(dx, dy)
    }

    /// Opaque bounds of a 96-pixel sprite frame, in sprite pixels.
    private func opaqueBounds(_ image: CGImage) -> CGRect {
        let lit = alpha(image)
        let xs = lit.indices.filter { lit[$0] }.map { $0 % image.width }, ys = lit.indices.filter { lit[$0] }.map { $0 / image.width }
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()! + 1, height: ys.max()! - ys.min()! + 1)
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
