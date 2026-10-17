import XCTest

/// Every text in the chat scales with Dynamic Type: fonts are text styles,
/// never fixed point sizes.
final class ChatTypographyTests: XCTestCase {
    func testEveryFontIsATextStyle() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = package.appendingPathComponent("Sources/AgentLandChat")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10, "The chat sources are where this test expects them")
        var fixed: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let custom = line.contains(".custom(") && line.contains("size:") && !line.contains("relativeTo")
                if line.contains(".system(size:") || line.contains("UIFont.systemFont(ofSize:") || custom {
                    fixed.append("\(file.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertTrue(fixed.isEmpty, "Fixed font sizes do not scale with Dynamic Type:\n" + fixed.joined(separator: "\n"))
    }
}
