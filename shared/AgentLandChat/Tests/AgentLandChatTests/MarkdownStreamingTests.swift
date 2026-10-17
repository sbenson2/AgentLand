import XCTest
@testable import AgentLandChat

/// Streaming replies parse incrementally: the result always matches a full
/// parse, and the work stays linear in the reply's length.
final class MarkdownStreamingTests: XCTestCase {
    private let documents = [
        """
        # Plan
        First paragraph with **bold** text
        that continues.

        - one
          still one
        - [x] done

        3. third
           * nested

        | Name | Value |
        |:-----|------:|
        | a | 1 |
        | b | 2 |

        > Quoted **text**
        > ```swift
        > let x = 1
        > ```

        ```swift
        func greet() {
            print("hi")
        }
        ```
        ~~~
        tilde
        ~~~
        Closing words.
        ---
        """,
        "Run:\r\n```sh\r\nmake test\r\n```\r\nDone\r\n- a\r\n\r\n- b",
        "Paragraph\n```diff\n+added\n-removed",
        "- a\n\n-\n\n- b\ntext\n| x |\n|---|\n",
        "``\n```x\nnot a fence\n```\nafter"
    ]

    func testIncrementalParsingMatchesAFullParseForEveryChunking() {
        for document in documents {
            let full = MarkdownDocument.parse(document)
            for size in [1, 2, 3, 5, 7, 13, 64, 1000] {
                let parser = MarkdownStreamParser()
                var index = document.startIndex
                while index < document.endIndex {
                    let end = document.index(index, offsetBy: size, limitedBy: document.endIndex) ?? document.endIndex
                    parser.append(String(document[index..<end]))
                    // Every intermediate state matches a full parse of the prefix.
                    XCTAssertEqual(parser.blocks, MarkdownDocument.parse(String(document[..<end])),
                                   "chunk size \(size) at offset \(document.distance(from: document.startIndex, to: end))")
                    index = end
                }
                XCTAssertEqual(parser.blocks, full, "chunk size \(size)")
            }
        }
    }

    func testResetStartsOver() {
        let parser = MarkdownStreamParser("# One")
        parser.reset("Two")
        XCTAssertEqual(parser.blocks, [.paragraph("Two")])
    }

    /// A reply of 400 paragraphs streamed a few words at a time. A full
    /// re-parse on every delta would read about 580,000 lines; the incremental
    /// parser reads each line a small, constant number of times.
    func testLongProseStaysLinear() {
        let paragraphs = (0..<400).map { "Paragraph \($0) explains one more step of the change in some detail." }
        let reply = paragraphs.joined(separator: "\n\n")
        let parser = MarkdownStreamParser()
        var appends = 0
        for word in reply.split(separator: " ", omittingEmptySubsequences: false) {
            parser.append(appends == 0 ? String(word) : " " + word)
            appends += 1
        }
        let lines = reply.split(separator: "\n", omittingEmptySubsequences: false).count
        XCTAssertEqual(parser.blocks.count, 400)
        XCTAssertLessThan(parser.parsedLineCount, appends * 8, "Each append re-reads only the last few lines")
        let quadratic = (1...appends).reduce(0) { $0 + $1 * lines / appends }
        XCTAssertLessThan(parser.parsedLineCount * 20, quadratic, "Orders of magnitude below re-parsing the whole reply per delta")
    }

    /// One code block of 3,000 lines streamed line by line.
    func testLongCodeBlockStaysLinear() {
        let body = (0..<3000).map { "let value\($0) = compute(\($0))" }
        let parser = MarkdownStreamParser("Here is the file:\n\n```swift\n")
        for line in body { parser.append(line + "\n") }
        parser.append("```\nDone.")
        XCTAssertEqual(parser.blocks, MarkdownDocument.parse("Here is the file:\n\n```swift\n" + body.joined(separator: "\n") + "\n```\nDone."))
        XCTAssertLessThan(parser.parsedLineCount, 3 * 3000 + 50, "The open fence is extended, not re-read")
    }

    /// About 100 KB of reply in 2,000 appends, as a long answer streams.
    func testStreamingIsFastInPractice() {
        let chunk = "Some streamed words with `code` and **emphasis**. "
        measure {
            let parser = MarkdownStreamParser()
            for index in 0..<2000 { parser.append(index % 25 == 24 ? chunk + "\n\n" : chunk) }
            XCTAssertEqual(parser.blocks.count, 80)
        }
    }
}
