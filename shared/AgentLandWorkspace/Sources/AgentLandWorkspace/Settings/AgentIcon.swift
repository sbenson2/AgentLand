import Foundation
import CoreGraphics
import ImageIO
import Observation
import SwiftUI
import AgentLandCore
import AgentLandDesign

// Registry icons (docs/AGENT-CATALOG-PLAN.md: "Icons come through the host"): `GET /v1/agents/icon` serves
// the icon the host cached, so devices never contact the registry's CDN. Registry icons are small
// one-color SVGs (`fill="currentColor"`); iOS has no public SVG decoder, so their paths and basic shapes
// are drawn here, in the text color. A bitmap is shown as it is; anything else gets the agent's initial.

/// An agent's icon, as decoded from what the host served.
public enum AgentIcon: Sendable {
    case vector(AgentVectorIcon)
    case bitmap(AgentBitmapIcon)
    /// The host had none, or it could not be read.
    case missing

    /// Decodes an SVG, or a bitmap ImageIO reads (at most 256 pixels on a side); nil otherwise. The type the
    /// host named (`image/svg+xml`, `image/png`) decides; without one, the bytes do, as the host tells them
    /// apart: a PNG signature, else text holding `<svg` anywhere, else whatever bitmap ImageIO reads.
    static func decode(_ data: Data, contentType: String? = nil) -> AgentIcon? {
        switch contentType.flatMap(AgentIconData.mediaType) {
        case "image/svg+xml":
            return AgentVectorIcon.parse(data).map(AgentIcon.vector)
        case "image/png":
            return AgentBitmapIcon.decode(data).map(AgentIcon.bitmap)
        default:
            if !AgentBitmapIcon.hasPNGSignature(data), AgentVectorIcon.looksLikeSVG(data) {
                return AgentVectorIcon.parse(data).map(AgentIcon.vector)
            }
            return AgentBitmapIcon.decode(data).map(AgentIcon.bitmap)
        }
    }

    /// Native menus accept Image, not a Canvas. Render each bounded registry vector
    /// once while decoding it off the main actor, then reuse it as a template image.
    var menuBitmap: AgentBitmapIcon? {
        switch self {
        case let .bitmap(icon): return icon
        case .missing: return nil
        case let .vector(icon):
            let side = 60
            guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            let box = icon.viewBox
            let scale = min(CGFloat(side) / box.width, CGFloat(side) / box.height)
            context.translateBy(x: 0, y: CGFloat(side))
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: (CGFloat(side) - box.width * scale) / 2 - box.minX * scale,
                                y: (CGFloat(side) - box.height * scale) / 2 - box.minY * scale)
            context.scaleBy(x: scale, y: scale)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            for shape in icon.shapes {
                if let evenOdd = shape.evenOdd {
                    context.addPath(shape.path)
                    context.fillPath(using: evenOdd ? .evenOdd : .winding)
                }
                if let width = shape.strokeWidth {
                    context.addPath(shape.path)
                    context.setLineWidth(width)
                    context.setLineCap(shape.lineCap)
                    context.setLineJoin(shape.lineJoin)
                    context.strokePath()
                }
            }
            return context.makeImage().map(AgentBitmapIcon.init(image:))
        }
    }
}

/// A bitmap icon, scaled down to at most 256 pixels on a side when it is read.
public final class AgentBitmapIcon: @unchecked Sendable {
    let image: CGImage

    init(image: CGImage) { self.image = image }

    /// PNG's eight-byte signature, which the host checks too.
    static func hasPNGSignature(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    static func decode(_ data: Data) -> AgentBitmapIcon? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 256,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return AgentBitmapIcon(image: image)
    }
}

// MARK: Vector icons

/// An SVG icon as paths in its view box: each filled (with its fill rule) or stroked, in one color.
/// Immutable once parsed, so it crosses actors.
public final class AgentVectorIcon: @unchecked Sendable {
    struct Shape {
        let path: CGPath
        /// Filled, with the even-odd rule when true; nil when the shape is not filled.
        let evenOdd: Bool?
        /// Stroked with this width (in the view box's units), when it is.
        let strokeWidth: CGFloat?
        let lineCap: CGLineCap
        let lineJoin: CGLineJoin
    }

    let viewBox: CGRect
    let shapes: [Shape]

    init(viewBox: CGRect, shapes: [Shape]) {
        self.viewBox = viewBox
        self.shapes = shapes
    }

    /// At most this many elements and path commands are read; an icon past them is not drawn.
    static let maximumElements = 2_000
    static let maximumCommands = 40_000

    /// Holds `<svg` anywhere, in any case, as the host checks it (a prolog or comment may come first).
    static func looksLikeSVG(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return false }
        // ASCII letters | 0x20 are lower case, so "S", "V" and "G" match too.
        for index in 0...(bytes.count - 4) where bytes[index] == UInt8(ascii: "<") {
            if bytes[index + 1] | 0x20 == UInt8(ascii: "s"), bytes[index + 2] | 0x20 == UInt8(ascii: "v"),
               bytes[index + 3] | 0x20 == UInt8(ascii: "g") {
                return true
            }
        }
        return false
    }

    /// The icon's shapes, or nil when it has none this reader can draw.
    static func parse(_ data: Data) -> AgentVectorIcon? {
        let reader = SVGReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = reader
        _ = parser.parse()
        guard !reader.failed, let viewBox = reader.viewBox, viewBox.width > 0, viewBox.height > 0, !reader.shapes.isEmpty else { return nil }
        return AgentVectorIcon(viewBox: viewBox, shapes: reader.shapes)
    }
}

/// What an element passes to its children: the presentation attributes SVG inherits, and the transform.
private struct SVGStyle {
    var fill: Bool = true
    var evenOdd = false
    var stroke = false
    var strokeWidth: CGFloat = 1
    var lineCap: CGLineCap = .butt
    var lineJoin: CGLineJoin = .miter
    var hidden = false
    var transform: CGAffineTransform = .identity

    /// This element's attributes (and its `style`) over the inherited ones.
    func applying(_ attributes: [String: String]) -> SVGStyle {
        var style = self
        var values = attributes
        // `style="fill:none;stroke:currentColor"` counts like attributes, and wins over them.
        for declaration in (attributes["style"] ?? "").split(separator: ";") {
            let pair = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { values[pair[0].lowercased()] = pair[1] }
        }
        if let fill = values["fill"]?.lowercased() { style.fill = fill != "none" && fill != "transparent" }
        if let opacity = values["fill-opacity"].flatMap(Double.init), opacity <= 0 { style.fill = false }
        if let rule = values["fill-rule"]?.lowercased() { style.evenOdd = rule == "evenodd" }
        if let stroke = values["stroke"]?.lowercased() { style.stroke = stroke != "none" && stroke != "transparent" }
        if let width = values["stroke-width"].flatMap(SVGReader.length) { style.strokeWidth = max(0, width) }
        switch values["stroke-linecap"]?.lowercased() {
        case "round": style.lineCap = .round
        case "square": style.lineCap = .square
        case "butt": style.lineCap = .butt
        default: break
        }
        switch values["stroke-linejoin"]?.lowercased() {
        case "round": style.lineJoin = .round
        case "bevel": style.lineJoin = .bevel
        case "miter": style.lineJoin = .miter
        default: break
        }
        if values["display"]?.lowercased() == "none" || values["visibility"]?.lowercased() == "hidden"
            || values["opacity"].flatMap(Double.init).map({ $0 <= 0 }) == true {
            style.hidden = true
        }
        if let transform = attributes["transform"].flatMap(SVGReader.transform) { style.transform = transform.concatenating(style.transform) }
        return style
    }
}

/// Reads an SVG document's view box and drawable shapes: `path`, `rect`, `circle`, `ellipse`, `line`,
/// `polyline` and `polygon`, in groups, with their fill, stroke and transforms. Definitions, clip paths,
/// masks, text, images and scripts are skipped whole.
private final class SVGReader: NSObject, XMLParserDelegate {
    private(set) var viewBox: CGRect?
    private(set) var shapes: [AgentVectorIcon.Shape] = []
    private(set) var failed = false
    private var styles: [SVGStyle] = []
    /// The depth of a skipped subtree being passed over (0 when drawing).
    private var skipping = 0
    private var elements = 0
    private var commands = 0
    private var sawRoot = false

    private static let skipped: Set<String> = [
        "defs", "clippath", "mask", "pattern", "lineargradient", "radialgradient", "symbol", "style", "title", "desc",
        "metadata", "filter", "text", "image", "use", "foreignobject", "script", "marker", "switch", "a",
    ]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        elements += 1
        guard elements <= AgentVectorIcon.maximumElements else { return stop(parser) }
        let name = (elementName.split(separator: ":").last.map(String.init) ?? elementName).lowercased()
        if skipping > 0 || Self.skipped.contains(name) {
            skipping += 1
            return
        }
        if !sawRoot {
            guard name == "svg" else { return stop(parser) }
            sawRoot = true
            viewBox = Self.viewBox(attributes)
        }
        let style = (styles.last ?? SVGStyle()).applying(attributes)
        styles.append(style)
        guard !style.hidden, let path = shape(name, attributes) else { return }
        let transformed = CGMutablePath()
        transformed.addPath(path, transform: style.transform)
        guard style.fill || style.stroke else { return }
        // The path is drawn in the view box's units; a stroke scales with the element's transforms as its
        // path does (by the transform's area scale, exact for a uniform scale).
        let t = style.transform
        let scale = abs(t.a * t.d - t.b * t.c).squareRoot()
        shapes.append(AgentVectorIcon.Shape(path: transformed, evenOdd: style.fill ? style.evenOdd : nil,
                                            strokeWidth: style.stroke ? style.strokeWidth * scale : nil,
                                            lineCap: style.lineCap, lineJoin: style.lineJoin))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if skipping > 0 {
            skipping -= 1
            return
        }
        if !styles.isEmpty { styles.removeLast() }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { failed = true }

    private func stop(_ parser: XMLParser) {
        failed = true
        parser.abortParsing()
    }

    private func shape(_ name: String, _ attributes: [String: String]) -> CGPath? {
        func number(_ key: String) -> CGFloat { attributes[key].flatMap(Self.length) ?? 0 }
        switch name {
        case "path":
            guard let data = attributes["d"] else { return nil }
            var path = SVGPathData(data)
            let result = path.build(limit: AgentVectorIcon.maximumCommands - commands)
            commands += path.commandCount
            if path.exceeded { failed = true }
            return result
        case "rect":
            let rect = CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height"))
            guard rect.width > 0, rect.height > 0 else { return nil }
            var rx = attributes["rx"].flatMap(Self.length)
            var ry = attributes["ry"].flatMap(Self.length)
            if rx == nil { rx = ry }
            if ry == nil { ry = rx }
            let cornerWidth = min(max(0, rx ?? 0), rect.width / 2)
            let cornerHeight = min(max(0, ry ?? 0), rect.height / 2)
            return CGPath(roundedRect: rect, cornerWidth: cornerWidth, cornerHeight: cornerHeight, transform: nil)
        case "circle":
            let r = number("r")
            guard r > 0 else { return nil }
            return CGPath(ellipseIn: CGRect(x: number("cx") - r, y: number("cy") - r, width: 2 * r, height: 2 * r), transform: nil)
        case "ellipse":
            let rx = number("rx"), ry = number("ry")
            guard rx > 0, ry > 0 else { return nil }
            return CGPath(ellipseIn: CGRect(x: number("cx") - rx, y: number("cy") - ry, width: 2 * rx, height: 2 * ry), transform: nil)
        case "line":
            let path = CGMutablePath()
            path.move(to: CGPoint(x: number("x1"), y: number("y1")))
            path.addLine(to: CGPoint(x: number("x2"), y: number("y2")))
            return path
        case "polyline", "polygon":
            let values = SVGPathData.numbers(attributes["points"] ?? "")
            guard values.count >= 4 else { return nil }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: values[0], y: values[1]))
            var index = 2
            while index + 1 < values.count {
                path.addLine(to: CGPoint(x: values[index], y: values[index + 1]))
                index += 2
            }
            if name == "polygon" { path.closeSubpath() }
            return path
        default:
            return nil
        }
    }

    /// `viewBox`, else a box of `width` by `height`.
    static func viewBox(_ attributes: [String: String]) -> CGRect? {
        let values = SVGPathData.numbers(attributes["viewBox"] ?? attributes["viewbox"] ?? "")
        if values.count == 4 { return CGRect(x: values[0], y: values[1], width: values[2], height: values[3]) }
        guard let width = attributes["width"].flatMap(length), let height = attributes["height"].flatMap(length) else { return nil }
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    /// A number with an optional `px` unit.
    static func length(_ raw: String) -> CGFloat? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let number = trimmed.hasSuffix("px") ? String(trimmed.dropLast(2)) : trimmed
        return Double(number).flatMap { $0.isFinite ? CGFloat($0) : nil }
    }

    /// `matrix`, `translate`, `scale`, `rotate`, `skewX` and `skewY`, applied left to right.
    static func transform(_ raw: String) -> CGAffineTransform? {
        var result = CGAffineTransform.identity
        var rest = Substring(raw)
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let name = rest[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " ,\t\n\r")).lowercased()
            let values = SVGPathData.numbers(String(rest[rest.index(after: open)..<close]))
            let next: CGAffineTransform
            switch (name, values.count) {
            case ("matrix", 6): next = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
            case ("translate", 1): next = CGAffineTransform(translationX: values[0], y: 0)
            case ("translate", 2): next = CGAffineTransform(translationX: values[0], y: values[1])
            case ("scale", 1): next = CGAffineTransform(scaleX: values[0], y: values[0])
            case ("scale", 2): next = CGAffineTransform(scaleX: values[0], y: values[1])
            case ("rotate", 1): next = CGAffineTransform(rotationAngle: values[0] * .pi / 180)
            case ("rotate", 3):
                next = CGAffineTransform(translationX: values[1], y: values[2]).rotated(by: values[0] * .pi / 180)
                    .translatedBy(x: -values[1], y: -values[2])
            case ("skewx", 1): next = CGAffineTransform(a: 1, b: 0, c: tan(values[0] * .pi / 180), d: 1, tx: 0, ty: 0)
            case ("skewy", 1): next = CGAffineTransform(a: 1, b: tan(values[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            default: return nil
            }
            // SVG applies the list's first transform outermost.
            result = next.concatenating(result)
            rest = rest[rest.index(after: close)...]
        }
        return result
    }
}

/// SVG path data (`d`): moves, lines, cubic and quadratic curves with their smooth forms, elliptical arcs and
/// closes, absolute and relative, with the grammar's compact numbers ("-.5.5", arc flags without spaces).
struct SVGPathData {
    private let bytes: [UInt8]
    private var index = 0
    private(set) var commandCount = 0
    private(set) var exceeded = false

    init(_ data: String) { bytes = Array(data.utf8) }

    /// The path, or nil when it draws nothing. Stops at the first malformed command, keeping what came
    /// before it, as SVG renderers do; stops at `limit` commands.
    mutating func build(limit: Int) -> CGPath? {
        let path = CGMutablePath()
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var lastQuadratic: CGPoint?
        var command: UInt8 = 0
        var started = false
        while true {
            skipSeparators()
            guard index < bytes.count else { break }
            if Self.isCommand(bytes[index]) {
                command = bytes[index]
                index += 1
            } else if command == 0 || command == UInt8(ascii: "z") || command == UInt8(ascii: "Z") {
                break
            }
            commandCount += 1
            guard commandCount <= limit else { exceeded = true; break }
            let relative = command >= UInt8(ascii: "a")
            let base = relative ? current : .zero
            func point() -> CGPoint? {
                guard let x = number(), let y = number() else { return nil }
                return CGPoint(x: base.x + x, y: base.y + y)
            }
            var smoothControl: CGPoint?
            var quadraticControl: CGPoint?
            switch command {
            case UInt8(ascii: "M"), UInt8(ascii: "m"):
                guard let to = point() else { return finished(path, started) }
                path.move(to: to)
                current = to
                start = to
                started = true
                // Further pairs after a move are lines.
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "L"), UInt8(ascii: "l"):
                guard started, let to = point() else { return finished(path, started) }
                path.addLine(to: to)
                current = to
            case UInt8(ascii: "H"), UInt8(ascii: "h"):
                guard started, let x = number() else { return finished(path, started) }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
            case UInt8(ascii: "V"), UInt8(ascii: "v"):
                guard started, let y = number() else { return finished(path, started) }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
            case UInt8(ascii: "C"), UInt8(ascii: "c"):
                guard started, let c1 = point(), let c2 = point(), let to = point() else { return finished(path, started) }
                path.addCurve(to: to, control1: c1, control2: c2)
                smoothControl = c2
                current = to
            case UInt8(ascii: "S"), UInt8(ascii: "s"):
                guard started, let c2 = point(), let to = point() else { return finished(path, started) }
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                path.addCurve(to: to, control1: c1, control2: c2)
                smoothControl = c2
                current = to
            case UInt8(ascii: "Q"), UInt8(ascii: "q"):
                guard started, let c = point(), let to = point() else { return finished(path, started) }
                path.addQuadCurve(to: to, control: c)
                quadraticControl = c
                current = to
            case UInt8(ascii: "T"), UInt8(ascii: "t"):
                guard started, let to = point() else { return finished(path, started) }
                let c = lastQuadratic.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                path.addQuadCurve(to: to, control: c)
                quadraticControl = c
                current = to
            case UInt8(ascii: "A"), UInt8(ascii: "a"):
                guard started, let rx = number(), let ry = number(), let rotation = number(),
                      let large = flag(), let sweep = flag(), let to = point() else { return finished(path, started) }
                Self.addArc(to: path, from: current, to: to, radii: CGSize(width: rx, height: ry), rotation: rotation,
                            largeArc: large, sweep: sweep)
                current = to
            case UInt8(ascii: "Z"), UInt8(ascii: "z"):
                if started { path.closeSubpath() }
                current = start
            default:
                return finished(path, started)
            }
            lastControl = smoothControl
            lastQuadratic = quadraticControl
        }
        return finished(path, started)
    }

    private func finished(_ path: CGMutablePath, _ started: Bool) -> CGPath? {
        started && !path.isEmpty ? path : nil
    }

    private static func isCommand(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "M"), UInt8(ascii: "m"), UInt8(ascii: "L"), UInt8(ascii: "l"), UInt8(ascii: "H"), UInt8(ascii: "h"),
             UInt8(ascii: "V"), UInt8(ascii: "v"), UInt8(ascii: "C"), UInt8(ascii: "c"), UInt8(ascii: "S"), UInt8(ascii: "s"),
             UInt8(ascii: "Q"), UInt8(ascii: "q"), UInt8(ascii: "T"), UInt8(ascii: "t"), UInt8(ascii: "A"), UInt8(ascii: "a"),
             UInt8(ascii: "Z"), UInt8(ascii: "z"):
            true
        default:
            false
        }
    }

    private mutating func skipSeparators() {
        while index < bytes.count, bytes[index] == UInt8(ascii: " ") || bytes[index] == UInt8(ascii: ",")
            || bytes[index] == UInt8(ascii: "\n") || bytes[index] == UInt8(ascii: "\r") || bytes[index] == UInt8(ascii: "\t") {
            index += 1
        }
    }

    /// An arc flag: a single 0 or 1, which may run into the next number.
    private mutating func flag() -> Bool? {
        skipSeparators()
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case UInt8(ascii: "0"): index += 1; return false
        case UInt8(ascii: "1"): index += 1; return true
        default: return nil
        }
    }

    /// A number: an optional sign, digits with at most one point, and an optional exponent. A second point
    /// or a sign starts the next number.
    mutating func number() -> CGFloat? {
        skipSeparators()
        let begin = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
        var digits = false
        while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1; digits = true }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1; digits = true }
        }
        guard digits else {
            index = begin
            return nil
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            let mark = index
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
            var exponent = false
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1; exponent = true }
            if !exponent { index = mark }
        }
        guard let value = Double(String(decoding: bytes[begin..<index], as: UTF8.self)), value.isFinite else { return nil }
        return CGFloat(value)
    }

    /// Every number in `text` (a view box, points, a transform's arguments).
    static func numbers(_ text: String) -> [CGFloat] {
        var reader = SVGPathData(text)
        var values: [CGFloat] = []
        while let value = reader.number() { values.append(value) }
        return values
    }

    /// An elliptical arc from `from` to `to` as cubic curves (SVG 1.1, F.6.5 and F.6.6): radii scaled up when
    /// they cannot reach, a line when either is zero, nothing when the ends meet.
    static func addArc(to path: CGMutablePath, from: CGPoint, to: CGPoint, radii: CGSize, rotation: CGFloat, largeArc: Bool, sweep: Bool) {
        guard from != to else { return }
        var rx = abs(radii.width), ry = abs(radii.height)
        guard rx > 0, ry > 0 else { return path.addLine(to: to) }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (from.x - to.x) / 2, dy = (from.y - to.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let factor = (largeArc != sweep ? 1 : -1) * (denominator == 0 ? 0 : max(0, numerator / denominator).squareRoot())
        let cxPrime = factor * rx * y1 / ry
        let cyPrime = -factor * ry * x1 / rx
        let center = CGPoint(x: cosPhi * cxPrime - sinPhi * cyPrime + (from.x + to.x) / 2,
                             y: sinPhi * cxPrime + cosPhi * cyPrime + (from.y + to.y) / 2)
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat { atan2(ux * vy - uy * vx, ux * vx + uy * vy) }
        let ux = (x1 - cxPrime) / rx, uy = (y1 - cyPrime) / ry
        let vx = (-x1 - cxPrime) / rx, vy = (-y1 - cyPrime) / ry
        let theta = angle(1, 0, ux, uy)
        var delta = angle(ux, uy, vx, vy)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / CGFloat(segments)
        let k = 4 / 3 * tan(step / 4)
        func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: center.x + rx * cosPhi * x - ry * sinPhi * y, y: center.y + rx * sinPhi * x + ry * cosPhi * y)
        }
        for segment in 0..<segments {
            let a = theta + CGFloat(segment) * step
            let b = a + step
            let control1 = map(cos(a) - k * sin(a), sin(a) + k * cos(a))
            let control2 = map(cos(b) + k * sin(b), sin(b) - k * cos(b))
            let end = segment == segments - 1 ? to : map(cos(b), sin(b))
            path.addCurve(to: end, control1: control1, control2: control2)
        }
    }
}

// MARK: The store

/// The host's registry icons for its agents, read once per agent while the host is attached. An icon the
/// host has not got (404 `not_found`), or that cannot be read, shows the agent's initial for as long as the
/// host is attached. One the host could not fetch in time (503 `icon_unavailable`) is not missing: the
/// initial shows meanwhile and it is asked for again, at most every `unavailableRetry`, while a row shows it.
/// A request that did not reach the host is tried again when a row asks next.
@MainActor @Observable public final class AgentIconStore {
    public private(set) var icons: [String: AgentIcon] = [:]
    private var menuIcons: [String: AgentBitmapIcon] = [:]
    @ObservationIgnored private var requested: Set<String> = []
    /// Reads on their way. A read is the store's, not the row's that asked: Home's Chat and Terminal launchers
    /// both show Claude's icon, and the row that asked first may go away while another waits on its read.
    @ObservationIgnored private var reading: [String: Task<Void, Never>] = [:]
    /// When an icon the host could not fetch in time may be asked for again.
    @ObservationIgnored private var retryAfter: [String: Date] = [:]
    @ObservationIgnored weak var model: AgentsModel?
    /// How long an icon the host could not fetch in time waits before it is asked for again; tests shorten it.
    @ObservationIgnored public var unavailableRetry: TimeInterval = 30

    public init() {}

    public func icon(for id: String) -> AgentIcon? { icons[id] }

    func menuImage(for id: String?, fallback: String) -> Image {
        guard let id, let icon = menuIcons[id] else { return Image(systemName: fallback) }
        // A decorative image carries accessibilityHidden into UIKit's menu adapter,
        // hiding the whole menu action. Keep an accessible image in native menus.
        return Image(icon.image, scale: 3, label: Text(id)).renderingMode(.template)
    }

    /// The host answers now: icons can be read. A row reads its icon again when this turns true.
    public var canLoad: Bool { model?.canChange == true }

    /// Reads `id`'s icon for a row that shows it; while the host says it could not fetch it in time, again
    /// once each wait is over, for as long as the row shows (its task is cancelled when it goes).
    public func follow(_ id: String) async {
        await load(id)
        while !Task.isCancelled, let after = retryAfter[id], after > Date() {
            do { try await Task.sleep(for: .seconds(max(0, after.timeIntervalSinceNow))) } catch { return }
            await load(id)
        }
    }

    /// Reads `id`'s icon through the host unless it was read already or waits after the host could not fetch it
    /// in time; while a read is on its way, waits for that one.
    public func load(_ id: String) async {
        if let read = reading[id] { return await read.value }
        guard !requested.contains(id), AgentID.isValid(id), let model, model.canChange,
              let workspace = model.workspace, let stamp = workspace.requestStamp() else { return }
        if let after = retryAfter[id], after > Date() { return }
        requested.insert(id)
        // Unstructured, so cancelling the asking row's task does not cancel a read another row is waiting on.
        let read = Task { await self.read(id, workspace: workspace, stamp: stamp) }
        reading[id] = read
        await read.value
    }

    private func read(_ id: String, workspace: WorkspaceModel, stamp: HostRequestStamp) async {
        defer { reading[id] = nil }
        let icon: AgentIconData
        do {
            icon = try await stamp.client.agentIcon(id: id)
        } catch {
            guard workspace.isCurrent(stamp) else { return }
            if (error as? ClientError)?.isIconUnavailable == true {
                // Not missing: the host could not fetch it in time. The initial shows until it is asked again.
                requested.remove(id)
                retryAfter[id] = Date().addingTimeInterval(unavailableRetry)
            } else if Self.hostAnswered(error) {
                // The host answered without an icon: the initial stays.
                icons[id] = AgentIcon.missing
            } else {
                // No answer (no connection, or cancelled): tried again when a row asks next.
                requested.remove(id)
            }
            return
        }
        retryAfter[id] = nil
        let (decoded, menuIcon) = await Task.detached(priority: .utility) {
            let decoded = AgentIcon.decode(icon.data, contentType: icon.contentType)
            return (decoded, decoded?.menuBitmap)
        }.value
        guard workspace.isCurrent(stamp), requested.contains(id) else { return }
        icons[id] = decoded ?? AgentIcon.missing
        menuIcons[id] = menuIcon
    }

    /// The host answered, with a refusal or something this version cannot use: asking again gives the same.
    static func hostAnswered(_ error: Error) -> Bool {
        guard let error = error as? ClientError else { return false }
        return error != .unreachable
    }

    func reset() {
        icons = [:]
        menuIcons = [:]
        requested = []
        retryAfter = [:]
        reading = [:]
    }
}

// MARK: The view

/// An agent's icon in a rounded tile: its registry icon in the primary color, or its initial in the secondary
/// one. On iPhone and iPad the tile is the system's tertiary fill; the Mac keeps its raised surface and hairline.
/// Decorative: the row names the agent.
struct AgentIconView: View {
    let id: String
    /// Its initial shows while the host serves no icon.
    let name: String
    let icons: AgentIconStore
    /// Grows with the text, up to 56 pt: at the largest sizes the text needs the room more.
    @ScaledMetric(relativeTo: .body) private var scaledSide: CGFloat = 36
    private var side: CGFloat { min(scaledSide, 56) }

    init(agent: AgentInfo, icons: AgentIconStore) {
        self.init(id: agent.id, name: agent.name, icons: icons)
    }

    /// An agent known by its ID and name alone, such as a Chat provider's sign-in (`MacChatSignInRow`).
    init(id: String, name: String, icons: AgentIconStore) {
        self.id = id
        self.name = name
        self.icons = icons
    }

    var body: some View {
        ZStack {
            #if os(iOS)
            AgentLandRadius.shape(AgentLandRadius.chip).fill(.fill.tertiary)
            #else
            // The Mac's Settings window draws with the system's colours, as Safari's does (2026-10-16).
            AgentLandRadius.shape(AgentLandRadius.chip).fill(.fill.quaternary)
            AgentLandRadius.shape(AgentLandRadius.chip).strokeBorder(.separator, lineWidth: 0.5)
            #endif
            content.padding(side * 0.2)
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
        // Read when the row shows, and again once the host answers if it did not then; while the host could
        // not fetch it in time, again after each wait for as long as the row shows.
        .task(id: "\(id)|\(icons.canLoad)") { await icons.follow(id) }
    }

    @ViewBuilder private var content: some View {
        switch icons.icon(for: id) {
        case let .vector(icon)?:
            AgentVectorIconShape(icon: icon)
        case let .bitmap(icon)?:
            Image(decorative: icon.image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        case .missing?, nil:
            Text(String(name.prefix(1)).uppercased())
                .font(AgentLandTypeRole.body.font.weight(.semibold))
                .foregroundStyle(.secondary)
                .minimumScaleFactor(0.5)
        }
    }
}

/// An agent's registry icon on its own, in the text color, for rows that otherwise show an SF Symbol (Home's
/// action boxes): the symbol shows until the host has served the icon, and stays when it has none.
/// Decorative: the row names the agent.
struct AgentGlyph: View {
    let id: String
    let symbol: String
    let icons: AgentIconStore
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 20

    var body: some View {
        Group {
            switch icons.icon(for: id) {
            case let .vector(icon)?:
                AgentVectorIconShape(icon: icon).frame(width: side, height: side)
            case let .bitmap(icon)?:
                Image(decorative: icon.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: side, height: side)
            case .missing?, nil:
                Image(systemName: symbol).font(AgentLandTypeRole.body.font)
            }
        }
        .accessibilityHidden(true)
        .task(id: "\(id)|\(icons.canLoad)") { await icons.follow(id) }
    }
}

/// Draws a vector icon's shapes, fitted into the view, in the primary color: the system's label on iPhone and iPad,
/// the palette's text on the Mac.
struct AgentVectorIconShape: View {
    let icon: AgentVectorIcon

    var body: some View {
        Canvas { context, size in
            let box = icon.viewBox
            let scale = min(size.width / box.width, size.height / box.height)
            context.translateBy(x: (size.width - box.width * scale) / 2 - box.minX * scale,
                                y: (size.height - box.height * scale) / 2 - box.minY * scale)
            context.scaleBy(x: scale, y: scale)
            for shape in icon.shapes {
                let path = Path(shape.path)
                if let evenOdd = shape.evenOdd { context.fill(path, with: .foreground, style: FillStyle(eoFill: evenOdd)) }
                if let width = shape.strokeWidth {
                    context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: width, lineCap: shape.lineCap, lineJoin: shape.lineJoin))
                }
            }
        }
        #if os(iOS)
        .foregroundStyle(.primary)
        #else
        .foregroundStyle(AgentLandColor.text)
        #endif
    }
}
