import XCTest
import CoreGraphics
@testable import AgentLandWorkspace

/// Registry icons drawn from their SVG (iOS has no public SVG decoder): the path grammar's compact forms,
/// arcs, the basic shapes, fill and stroke, transforms, skipped definitions and the bounds on what is read.
/// The documents are written for these tests in the registry's style; no registry artwork is copied.
final class AgentIconTests: XCTestCase {
    private func icon(_ svg: String, file: StaticString = #filePath, line: UInt = #line) throws -> AgentVectorIcon {
        try XCTUnwrap(AgentVectorIcon.parse(Data(svg.utf8)), "The icon parses", file: file, line: line)
    }

    private func assertBox(_ rect: CGRect, _ expected: CGRect, accuracy: CGFloat = 0.01,
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rect.minX, expected.minX, accuracy: accuracy, "minX", file: file, line: line)
        XCTAssertEqual(rect.minY, expected.minY, accuracy: accuracy, "minY", file: file, line: line)
        XCTAssertEqual(rect.width, expected.width, accuracy: accuracy, "width", file: file, line: line)
        XCTAssertEqual(rect.height, expected.height, accuracy: accuracy, "height", file: file, line: line)
    }

    func testNativeMenuIconKeepsVectorOrientationAndTransparency() throws {
        let vector = try icon(#"<svg viewBox="0 0 20 20"><rect x="2" y="2" width="8" height="5"/></svg>"#)
        let image = try XCTUnwrap(AgentIcon.vector(vector).menuBitmap?.image)
        XCTAssertEqual(image.width, 60)
        XCTAssertEqual(image.height, 60)
        let data = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[y * image.bytesPerRow + x * 4 + 3] }
        XCTAssertGreaterThan(alpha(12, 12), 200, "The top-left shape remains at the top left")
        XCTAssertEqual(alpha(12, 48), 0, "The menu icon must not flip vertically")
        XCTAssertEqual(alpha(48, 12), 0, "The background stays transparent")
        XCTAssertNil(AgentIcon.missing.menuBitmap)
    }

    func testCompactNumbersRelativeCommandsAndSmoothCurvesParse() throws {
        // Signs and second points start the next number; relative commands follow the current point; pairs
        // after a move are lines; S and T reflect the previous control point.
        let parsed = try icon(#"""
        <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24">
          <path fill="currentColor" d="M2-.5.5 1 3 3h4v2H4zm10 10 2 0 0 2-2 0z"/>
          <path d="M1,20 C1,18 3,18 3,20 S5,22 5,20 Q6,18 7,20 T9,20"/>
        </svg>
        """#)
        XCTAssertEqual(parsed.viewBox, CGRect(x: 0, y: 0, width: 24, height: 24))
        XCTAssertEqual(parsed.shapes.count, 2)
        // (2,-.5) (.5,1) (3,3) (7,3) (7,5) (4,5), then from the first point moved by (10,10): (12,9.5) to (14,11.5).
        assertBox(parsed.shapes[0].path.boundingBoxOfPath, CGRect(x: 0.5, y: -0.5, width: 13.5, height: 12))
        XCTAssertEqual(parsed.shapes[0].evenOdd, false, "Filled with the nonzero rule")
        XCTAssertNil(parsed.shapes[0].strokeWidth)
        let curves = parsed.shapes[1].path.boundingBoxOfPath
        XCTAssertEqual(curves.minX, 1, accuracy: 0.01)
        XCTAssertEqual(curves.maxX, 9, accuracy: 0.01)
        XCTAssertEqual(curves.minY, 18.5, accuracy: 0.01, "The first curve rises to three quarters of its controls")
        XCTAssertEqual(curves.maxY, 21.5, accuracy: 0.01, "S reflects the previous control point, pulling its curve down")
    }

    func testArcsWithFlagsRunTogetherDrawTheirCircle() throws {
        // Two half arcs make a circle of radius 5 around (12, 12); the flags "0 1" are written "01".
        let parsed = try icon(#"""
        <svg viewBox="0 0 24 24"><path fill="currentColor" d="M7 12a5 5 0 1 1 10 0A5 5 0 01 7 12z"/></svg>
        """#)
        assertBox(parsed.shapes[0].path.boundingBoxOfPath, CGRect(x: 7, y: 7, width: 10, height: 10), accuracy: 0.05)

        // Radii too small to reach are scaled up; a zero radius is a straight line.
        let scaled = try icon(#"<svg viewBox="0 0 10 10"><path d="M0 5a1 1 0 0 0 10 0"/></svg>"#)
        assertBox(scaled.shapes[0].path.boundingBoxOfPath, CGRect(x: 0, y: 5, width: 10, height: 5), accuracy: 0.05)
        let flat = try icon(#"<svg viewBox="0 0 10 10"><path d="M0 0a0 3 0 0 1 10 10"/></svg>"#)
        assertBox(flat.shapes[0].path.boundingBoxOfPath, CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    func testShapesStrokesRulesAndTransforms() throws {
        let parsed = try icon(#"""
        <svg width="32" height="32" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
          <defs><path id="hidden" d="M0 0h100v100z"/></defs>
          <title>Not drawn</title>
          <rect x="2" y="2" width="10" height="6" rx="2"/>
          <circle cx="20" cy="20" r="4" fill="currentColor" stroke="none"/>
          <g transform="translate(10 0) scale(2)">
            <ellipse cx="2" cy="2" rx="2" ry="1"/>
            <polygon points="0,10 4,10 2,14" fill="#000" fill-rule="evenodd" style="stroke:none"/>
          </g>
          <line x1="0" y1="31" x2="31" y2="31"/>
          <path d="M0 0L5 5" style="display:none"/>
        </svg>
        """#)
        XCTAssertEqual(parsed.viewBox, CGRect(x: 0, y: 0, width: 32, height: 32), "Without a view box, the width and height")
        XCTAssertEqual(parsed.shapes.count, 5, "Definitions, titles and hidden shapes are not drawn")

        let rect = parsed.shapes[0]
        XCTAssertNil(rect.evenOdd, "fill none")
        XCTAssertEqual(rect.strokeWidth, 2, "Stroke and width come from the root")
        XCTAssertEqual(rect.lineCap, .round)
        assertBox(rect.path.boundingBoxOfPath, CGRect(x: 2, y: 2, width: 10, height: 6))

        let circle = parsed.shapes[1]
        XCTAssertEqual(circle.evenOdd, false)
        XCTAssertNil(circle.strokeWidth)

        // translate(10 0) scale(2): scaled first, then moved.
        assertBox(parsed.shapes[2].path.boundingBoxOfPath, CGRect(x: 10, y: 2, width: 8, height: 4))
        let polygon = parsed.shapes[3]
        XCTAssertEqual(polygon.evenOdd, true)
        XCTAssertNil(polygon.strokeWidth, "The style attribute wins over the inherited stroke")
        assertBox(polygon.path.boundingBoxOfPath, CGRect(x: 10, y: 20, width: 8, height: 8))

        assertBox(parsed.shapes[4].path.boundingBoxOfPath, CGRect(x: 0, y: 31, width: 31, height: 0))

        // A stroke scales with its element's transforms, as its path does.
        let scaled = try icon(#"<svg viewBox="0 0 32 32"><g transform="scale(2)"><line x1="0" y1="1" x2="10" y2="1" stroke="currentColor" stroke-width="1.5"/></g></svg>"#)
        XCTAssertEqual(try XCTUnwrap(scaled.shapes.first?.strokeWidth), 3, accuracy: 0.001)
    }

    func testDocumentsItCannotDrawGiveNoIcon() {
        XCTAssertNil(AgentVectorIcon.parse(Data("<html><body>no</body></html>".utf8)), "Not an SVG")
        XCTAssertNil(AgentVectorIcon.parse(Data(#"<svg viewBox="0 0 24 24"></svg>"#.utf8)), "Nothing drawn")
        XCTAssertNil(AgentVectorIcon.parse(Data(#"<svg viewBox="0 0 0 24"><path d="M0 0h1v1z"/></svg>"#.utf8)), "An empty view box")
        XCTAssertNil(AgentVectorIcon.parse(Data(#"<svg viewBox="0 0 24 24"><path d="M0 0h1v1z"</svg>"#.utf8)), "Malformed XML")
        XCTAssertNil(AgentVectorIcon.parse(Data(#"<svg viewBox="0 0 24 24"><path d="Q"/></svg>"#.utf8)), "Path data without numbers")
        XCTAssertNil(AgentVectorIcon.parse(Data(##"<svg viewBox="0 0 24 24"><image href="https://example.com/a.png"/><use href="#x"/></svg>"##.utf8)),
                     "Images and references are never followed")

        let many = String(repeating: "l1 1", count: AgentVectorIcon.maximumCommands + 10)
        XCTAssertNil(AgentVectorIcon.parse(Data(#"<svg viewBox="0 0 24 24"><path d="M0 0\#(many)"/></svg>"#.utf8)),
                     "An icon past the command limit is not drawn")
        let elements = String(repeating: #"<g></g>"#, count: AgentVectorIcon.maximumElements + 1)
        XCTAssertNil(AgentVectorIcon.parse(Data(#"<svg viewBox="0 0 24 24">\#(elements)<path d="M0 0h1v1z"/></svg>"#.utf8)))

        // A malformed command ends the path, keeping what came before it, as SVG renderers do.
        let partial = AgentVectorIcon.parse(Data(#"<svg viewBox="0 0 24 24"><path d="M0 0h4v4 X 9 9"/></svg>"#.utf8))
        XCTAssertEqual(partial?.shapes.first.map { $0.path.boundingBoxOfPath }, CGRect(x: 0, y: 0, width: 4, height: 4))
    }

    func testIconsDecodeFromWhatTheHostServes() throws {
        let svg = Data(#"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path d="M0 0h16v16H0z"/></svg>"#.utf8)
        guard case .vector? = AgentIcon.decode(svg) else { return XCTFail("An SVG is drawn") }

        // A small PNG is a bitmap.
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try XCTUnwrap(context.makeImage())
        let png = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        guard case let .bitmap(bitmap)? = AgentIcon.decode(png as Data) else { return XCTFail("A PNG is shown as it is") }
        XCTAssertEqual(bitmap.image.width, 4)

        XCTAssertNil(AgentIcon.decode(Data("not an image".utf8)))

        // The type the host names decides (docs/HOST-API.md "The registry": image/svg+xml or image/png).
        guard case .bitmap? = AgentIcon.decode(png as Data, contentType: "image/png") else { return XCTFail("image/png is a bitmap") }
        guard case .vector? = AgentIcon.decode(svg, contentType: "image/svg+xml; charset=utf-8") else { return XCTFail("image/svg+xml is drawn") }
        XCTAssertNil(AgentIcon.decode(svg, contentType: "image/png"), "Never read as the other kind")

        // The host recognizes <svg anywhere, so a long prolog or comment before it is still an SVG, with or
        // without the type.
        let comment = "<!-- " + String(repeating: "Generated by an editor. ", count: 80) + "-->"
        let late = Data((#"<?xml version="1.0"?>"# + comment + #"<SVG xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path d="M0 0h16v16H0z"/></SVG>"#).utf8)
        XCTAssertGreaterThan(late.count, 1_024)
        XCTAssertTrue(AgentVectorIcon.looksLikeSVG(late))
        guard case .vector? = AgentIcon.decode(late, contentType: "image/svg+xml") else { return XCTFail("Typed: drawn") }
        guard case .vector? = AgentIcon.decode(late) else { return XCTFail("Untyped: found past the first KiB") }
        XCTAssertFalse(AgentVectorIcon.looksLikeSVG(Data("<sv".utf8)))
    }
}
