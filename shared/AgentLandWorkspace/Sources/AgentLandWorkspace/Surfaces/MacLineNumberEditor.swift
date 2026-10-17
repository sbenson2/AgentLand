#if os(macOS)
import AppKit
import SwiftUI
import AgentLandDesign

/// The Mac's editor text: an AppKit text view with line numbers, under the same rules as the UIKit
/// one. AppKit owns the live text within a loaded-document generation: the SwiftUI binding only
/// reports what the person typed, and only a completed load or reload (a new `documentGeneration`)
/// replaces the text. Code text follows the workspace's text size (⌘+, ⌘−).
struct LineNumberEditor: NSViewRepresentable {
    @Binding var text: String
    let documentGeneration: UUID
    let active: Bool
    let colorScheme: ColorScheme
    let increasedContrast: Bool
    /// A Find request to show the find bar for; each value is shown once.
    var findRequest: Int? = nil
    /// A line to show and put the caret on once the document is in the text view.
    var lineRequest: EditorLineRequest? = nil
    var lineShown: (UUID) -> Void = { _ in }
    var caretMoved: (Int) -> Void = { _ in }
    /// The iPhone's editor uses it against UIKit's keyboard restore (B-8); the Mac keeps its own focus rules.
    var takesInput: @MainActor () -> Bool = { true }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MacEditorContainer {
        let view = MacEditorContainer()
        context.coordinator.view = view
        view.textView.delegate = context.coordinator
        view.applyFontSize(MacCodeText.size(for: context.environment.dynamicTypeSize))
        view.applyDocument(text, generation: documentGeneration, preservingSelection: false)
        view.applyTheme(colorScheme, increasedContrast: increasedContrast)
        view.setActive(active)
        return view
    }

    func updateNSView(_ view: MacEditorContainer, context: Context) {
        context.coordinator.parent = self
        view.applyFontSize(MacCodeText.size(for: context.environment.dynamicTypeSize))
        view.applyTheme(colorScheme, increasedContrast: increasedContrast)
        view.setActive(active)
        view.applyDocument(text, generation: documentGeneration, preservingSelection: true)
        if let findRequest, findRequest != context.coordinator.shownFindRequest {
            context.coordinator.shownFindRequest = findRequest
            // Outside the render transaction: the find bar takes the focus.
            DispatchQueue.main.async { view.presentFind() }
        }
        if let lineRequest, lineRequest.id != context.coordinator.shownLineRequest {
            context.coordinator.shownLineRequest = lineRequest.id
            let shown = lineShown
            // After layout, outside the render transaction; the session hears it then, so a rebuilt
            // view doesn't move the caret back.
            DispatchQueue.main.async {
                view.reveal(line: lineRequest.line)
                shown(lineRequest.id)
            }
        }
    }

    static func dismantleNSView(_ view: MacEditorContainer, coordinator: Coordinator) {
        view.endEditing()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LineNumberEditor
        weak var view: MacEditorContainer?
        var shownFindRequest: Int?
        var shownLineRequest: UUID?

        init(_ parent: LineNumberEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            view?.invalidateGutter()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Only the person's own moves count; a document being applied also moves the selection.
            guard let textView = notification.object as? NSTextView, textView.window?.firstResponder === textView else { return }
            let line = EditorLines.line(at: textView.selectedRange().location, in: textView.string)
            let moved = parent.caretMoved
            DispatchQueue.main.async { moved(line) }
        }

        /// The editor's own undo history: a new document generation starts a new one, so an undo never
        /// reaches into a document that was replaced.
        func undoManager(for view: NSTextView) -> UndoManager? { self.view?.undoHistory }
    }
}

/// The editor's AppKit text view in a scroll view, with a line-number ruler. Long lines scroll
/// sideways instead of wrapping.
final class MacEditorContainer: NSView {
    let scrollView = NSScrollView()
    let textView: NSTextView
    let undoHistory = UndoManager()
    private let ruler: LineNumberRulerView
    private var currentTheme: EditorTheme?
    private var currentDocumentGeneration: UUID?
    private var currentActiveState: Bool?
    private var currentFontSize: CGFloat = 0
    nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?

    private struct EditorTheme: Equatable {
        let colorScheme: ColorScheme
        let increasedContrast: Bool
    }

    override init(frame: NSRect) {
        // A TextKit 1 stack: the ruler reads line positions from its layout manager. The container
        // never wraps.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        textView = NSTextView(frame: .zero, textContainer: container)
        ruler = LineNumberRulerView(scrollView: scrollView, orientation: .verticalRuler)
        super.init(frame: frame)
        setAccessibilityElement(false)

        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = .zero
        textView.autoresizingMask = [.width, .height]
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.drawsBackground = true
        textView.setAccessibilityIdentifier("fileEditor")

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        ruler.textView = textView
        ruler.clientView = textView
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.autoresizingMask = [.width, .height]
        scrollView.frame = bounds
        addSubview(scrollView)

        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidateGutter() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    /// The text view fills at least what the scroll view shows, so a click under a short file's last
    /// line still reaches it.
    override func layout() {
        super.layout()
        let visible = scrollView.contentSize
        textView.minSize = visible
        let size = textView.frame.size
        if size.width < visible.width || size.height < visible.height {
            textView.setFrameSize(NSSize(width: max(size.width, visible.width), height: max(size.height, visible.height)))
        }
    }

    func applyFontSize(_ size: CGFloat) {
        guard currentFontSize != size else { return }
        currentFontSize = size
        textView.font = .monospacedSystemFont(ofSize: size, weight: .regular)
        ruler.numberFont = .monospacedDigitSystemFont(ofSize: max(9, size - 2), weight: .regular)
        invalidateGutter()
    }

    func applyTheme(_ colorScheme: ColorScheme, increasedContrast: Bool = false) {
        let theme = EditorTheme(colorScheme: colorScheme, increasedContrast: increasedContrast)
        guard currentTheme != theme else { return }
        currentTheme = theme
        let appearance = AgentLandAppearance(isDark: colorScheme == .dark, increasedContrast: increasedContrast)
        func resolved(_ token: AgentLandColor) -> NSColor {
            let rgb = token.rgb(for: appearance)
            return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        }
        textView.backgroundColor = resolved(.canvas)
        textView.textColor = resolved(.text)
        textView.insertionPointColor = resolved(.tint)
        textView.selectedTextAttributes = [.backgroundColor: resolved(.tint).withAlphaComponent(0.25)]
        ruler.backgroundColor = resolved(.canvas)
        ruler.numberColor = resolved(.textSecondary)
        ruler.ruleColor = resolved(.separator)
        invalidateGutter()
    }

    func setActive(_ active: Bool) {
        guard currentActiveState != active else { return }
        currentActiveState = active
        textView.isEditable = active
        textView.isSelectable = true
        if !active { endEditing() }
    }

    /// Gives up the focus, as when the tab is no longer the one in front.
    func endEditing() {
        if let window = textView.window, window.firstResponder === textView { window.makeFirstResponder(nil) }
    }

    @discardableResult
    func applyDocument(_ text: String, generation: UUID, preservingSelection: Bool) -> Bool {
        guard currentDocumentGeneration != generation else { return false }
        currentDocumentGeneration = generation
        let selection = textView.selectedRange()
        // AppKit owns the live document between explicit load generations. Binding echoes can arrive
        // behind rapid edits, so they never replace text for the current generation.
        textView.string = text
        undoHistory.removeAllActions()
        if preservingSelection {
            let length = (textView.string as NSString).length
            let location = min(selection.location, length)
            textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        }
        invalidateGutter()
        return true
    }

    func invalidateGutter() {
        ruler.updateThickness()
        ruler.needsDisplay = true
    }

    /// Shows the find bar for the file's text.
    func presentFind() {
        guard let window = textView.window else { return }
        window.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(item)
    }

    /// Scrolls `line` (counted from 1) into view, puts the caret at its start and marks it for a
    /// moment with the system's find indicator. A line past the end shows the last one.
    func reveal(line: Int) {
        let text = textView.string as NSString
        let start = EditorLines.location(ofLine: line, in: text)
        let range = text.length == 0 ? NSRange(location: 0, length: 0)
            : text.lineRange(for: NSRange(location: min(start, max(text.length - 1, 0)), length: 0))
        textView.setSelectedRange(NSRange(location: start, length: 0))
        textView.scrollRangeToVisible(range)
        invalidateGutter()
        if range.length > 0 { textView.showFindIndicator(for: range) }
    }
}

/// The editor's line numbers, in the scroll view's vertical ruler. Numbers use a size a step smaller
/// than the text, and the ruler widens with them.
final class LineNumberRulerView: NSRulerView {
    weak var textView: NSTextView?
    var numberColor: NSColor = .secondaryLabelColor
    var ruleColor: NSColor = .separatorColor
    var backgroundColor: NSColor = .clear
    var numberFont: NSFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    override var isFlipped: Bool { true }

    /// Wide enough for the largest line number; 40 pt at the default size.
    func updateThickness() {
        let lines = (textView?.string ?? "").utf8.reduce(1) { count, byte in byte == 10 ? count + 1 : count }
        let digits = max(3, String(lines).count)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: numberFont]).width
        let thickness = max(40, ceil(CGFloat(digits) * digitWidth + 20))
        if ruleThickness != thickness { ruleThickness = thickness }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        backgroundColor.setFill()
        rect.fill()
        ruleColor.setFill()
        NSRect(x: bounds.maxX - 0.5, y: rect.minY, width: 0.5, height: rect.height).fill()
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer,
              let clip = scrollView?.contentView else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: numberColor, .paragraphStyle: paragraph]
        let text = textView.string as NSString
        let origin = textView.textContainerOrigin
        func draw(_ number: Int, at y: CGFloat, height: CGFloat) {
            let top = convert(NSPoint(x: 0, y: y + origin.y), from: textView).y
            String(number).draw(in: NSRect(x: 4, y: top + (height - numberFont.boundingRectForFont.height) / 2,
                                           width: ruleThickness - 12, height: max(height, numberFont.boundingRectForFont.height)),
                                withAttributes: attributes)
        }
        guard text.length > 0 else {
            draw(1, at: 0, height: layout.defaultLineHeight(for: numberFont))
            return
        }
        layout.ensureLayout(for: container)
        let visible = textView.convert(clip.bounds, from: clip)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var index = text.lineRange(for: NSRange(location: characters.location, length: 0)).location
        var number = EditorLines.line(at: index, in: textView.string)
        while index < text.length && index <= NSMaxRange(characters) {
            let line = text.lineRange(for: NSRange(location: index, length: 0))
            let fragment = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: index), effectiveRange: nil)
            draw(number, at: fragment.minY, height: fragment.height)
            index = NSMaxRange(line)
            number += 1
        }
        if index >= text.length, text.character(at: text.length - 1) == 10 {
            let extra = layout.extraLineFragmentRect
            draw(number, at: extra.minY, height: extra.height)
        }
    }
}
#endif
