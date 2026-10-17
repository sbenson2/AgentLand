import ImageIO
import XCTest
@testable import AgentLandBranding

final class ClownAnimationConsistencyTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private var candidates: [(String, URL)] {
        [("whiteface", root.appendingPathComponent("branding/candidates/clown-one-piece-20261003"))] +
        ["auguste", "tramp", "harlequin", "ringmaster", "strongman"].map {
            ($0, root.appendingPathComponent("branding/candidates/clown-gold-20261003/\($0)"))
        }
    }

    func testCandidateSourcesHaveIdentityAndPlannedMotionForAllSeventyTwoFrames() throws {
        for (name, folder) in candidates {
            let verification = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("animation-research-final-verification.json"))) as? [String: Any])
            XCTAssertEqual(verification["frames"] as? Int, 72, name)
            let rows = try XCTUnwrap(verification["rows"] as? [[String: Any]])
            XCTAssertEqual(rows.count, 72, name)
            XCTAssertEqual(verification["folder"] as? String, "animation-research-final", name)
            for row in rows {
                XCTAssertEqual(row["size"] as? [Int], [96, 96], name)
                XCTAssertEqual(row["binaryAlpha"] as? Bool, true, "\(name) \(row["frame"] ?? "")")
                XCTAssertEqual(row["colors"] as? Int, 5, name)
                let palms = try XCTUnwrap(row["palms"] as? [String: [Double]])
                XCTAssertEqual(palms["near"]?.count, 2)
                XCTAssertEqual(palms["far"]?.count, 2)
                let image = try load(folder.appendingPathComponent("animation-research-final").appendingPathComponent(row["frame"] as! String))
                let bytes = try XCTUnwrap(AgentLandClownArtwork.rgbaBytes(image))
                let components = componentSizes(bytes)
                // Approved frames contain small detached ink/glove patches.
                // They retain one main body-and-wheel silhouette; test the
                // actual pixels rather than the candidate report's old count.
                XCTAssertEqual(components.filter { $0 > 32 }.count, 1, name)
                XCTAssertGreaterThanOrEqual(Double(components.max() ?? 0) / Double(components.reduce(0, +)), 0.98, name)
                XCTAssertTrue(bytes.indices.filter { $0 % 4 == 3 }.allSatisfy { bytes[$0] == 0 || bytes[$0] == 255 }, name)
                let occupiedRows = (0..<96).filter { y in (0..<96).contains { bytes[(y * 96 + $0) * 4 + 3] == 255 } }
                XCTAssertEqual(occupiedRows.max(), 93, "\(name) \(row["frame"] ?? ""): wheel is lowest")
            }
        }
    }

    private func componentSizes(_ bytes: [UInt8]) -> [Int] {
        var remaining = Set((0..<(96 * 96)).filter { bytes[$0 * 4 + 3] == 255 })
        var sizes: [Int] = []
        while let start = remaining.popFirst() {
            var stack = [start], count = 0
            while let pixel = stack.popLast() {
                count += 1
                let x = pixel % 96, y = pixel / 96
                for dy in -1...1 { for dx in -1...1 {
                    let xx = x + dx, yy = y + dy
                    guard (0..<96).contains(xx), (0..<96).contains(yy) else { continue }
                    let next = yy * 96 + xx
                    if remaining.remove(next) != nil { stack.append(next) }
                } }
            }
            sizes.append(count)
        }
        return sizes
    }

    private func load(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
}
