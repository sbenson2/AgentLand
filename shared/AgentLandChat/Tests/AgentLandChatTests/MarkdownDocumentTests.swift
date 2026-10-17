import XCTest
@testable import AgentLandChat

final class MarkdownDocumentTests: XCTestCase {
    func testHeadingsParagraphsRulesAndQuotes() {
        let blocks = MarkdownDocument.parse("""
        # Plan ##
        First line
        second line

        ---
        > Quoted **text**
        > ```swift
        > let x = 1
        > ```
        ## C#
        """)
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Plan"),
            .paragraph("First line\nsecond line"),
            .rule,
            .quote([.paragraph("Quoted **text**"), .code(language: "swift", code: "let x = 1", closed: true)]),
            .heading(level: 2, text: "C#")
        ])
    }

    func testFencesKeepLanguageIndentationAndStreamingState() {
        let blocks = MarkdownDocument.parse("""
        Run:
        ```sh title
          make test
        ```
        ~~~~
        tilde
        ~~~~
        ```diff
        +added
        """)
        XCTAssertEqual(blocks, [
            .paragraph("Run:"),
            .code(language: "sh", code: "  make test", closed: true),
            .code(language: "", code: "tilde", closed: true),
            .code(language: "diff", code: "+added", closed: false)
        ], "A reply that is still streaming keeps its unfinished fence as code")
    }

    func testListsNestTasksNumbersAndContinuations() {
        let blocks = MarkdownDocument.parse("""
        - one
          still one
        - [x] done
        - [ ] open

        3. third
           * nested
        4) fourth
        """)
        XCTAssertEqual(blocks, [
            .list([
                MarkdownListItem(marker: .bullet, level: 0, text: "one\nstill one"),
                MarkdownListItem(marker: .task(done: true), level: 0, text: "done"),
                MarkdownListItem(marker: .task(done: false), level: 0, text: "open"),
                MarkdownListItem(marker: .number(3), level: 0, text: "third"),
                MarkdownListItem(marker: .bullet, level: 1, text: "nested"),
                MarkdownListItem(marker: .number(4), level: 0, text: "fourth")
            ])
        ])
    }

    func testNonListLookalikesStayParagraphs() {
        XCTAssertEqual(MarkdownDocument.parse("-not a bullet\n2024.1 release"), [.paragraph("-not a bullet\n2024.1 release")])
        XCTAssertEqual(MarkdownDocument.parse("* * *"), [.rule])
        XCTAssertEqual(MarkdownDocument.parse("#hashtag"), [.paragraph("#hashtag")])
    }

    func testTablesAlignEscapeAndPadRows() {
        let blocks = MarkdownDocument.parse("""
        Results:
        | Name | Count | Note |
        |:-----|------:|:----:|
        | a \\| b | 2 | ok |
        | short |
        after
        """)
        XCTAssertEqual(blocks, [
            .paragraph("Results:"),
            .table(MarkdownTable(header: ["Name", "Count", "Note"], alignments: [.leading, .trailing, .center],
                                 rows: [["a | b", "2", "ok"], ["short", "", ""]])),
            .paragraph("after")
        ])
    }

    func testPipeTextWithoutDelimiterIsNotATable() {
        XCTAssertEqual(MarkdownDocument.parse("a | b\nnot a delimiter"), [.paragraph("a | b\nnot a delimiter")])
        XCTAssertEqual(MarkdownDocument.parse("| a |\n---"), [.paragraph("| a |"), .rule])
    }

    func testWindowsLineEndingsAndCaching() {
        let source = "# Title\r\n\r\ntext"
        XCTAssertEqual(MarkdownDocument.parse(source), [.heading(level: 1, text: "Title"), .paragraph("text")])
        XCTAssertEqual(MarkdownDocument.blocks(from: source), MarkdownDocument.blocks(from: source))
    }
}
