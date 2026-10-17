#if os(macOS)
import AppKit
import SwiftUI
import SwiftTerm
import AgentLandCore
import AgentLandDesign

/// The Mac's terminal renderer: SwiftTerm's AppKit view. Like the iPhone and iPad one, the tab's
/// `TerminalSession` retains it, and whichever view shows the tab mounts it.
///
/// It takes clicks, focus and paste only while its tab takes input (`inputEnabled`), so a terminal
/// behind the selection or under a question never gets typing.
public final class AgentTerminalView: TerminalView {
    private(set) var forwardingProtocolReply = false
    /// True while this view draws output whose queries a renderer already answered: their replies would
    /// reach the shell long after the program that asked stopped waiting, and be read as typing.
    private var replayingAnsweredOutput = false
    var onPaste: ((Data) -> Void)?
    var onLayoutReady: (() -> Void)?
    private var didReportLayout = false
    /// The view that shows this renderer: the newest one to ask for it.
    weak var owner: TerminalMountView?
    /// The tab is selected, uncovered and its window's scene active.
    var inputEnabled = false {
        didSet {
            guard !inputEnabled, let window, window.firstResponder === self else { return }
            window.makeFirstResponder(nil)
        }
    }

    /// ⌘-combinations belong to the app's commands (new tab, close, select a tab …), whatever keyboard
    /// protocol the program asked for: the kitty protocol would otherwise send them to the program.
    /// ⌘C, ⌘V and ⌘A stay with the terminal (copy, paste, select all).
    static func passesUp(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.command) else { return false }
        return !["c", "v", "a"].contains((event.charactersIgnoringModifiers ?? "").lowercased())
    }

    /// The menu bar's commands take ⌘-combinations first; one that no command takes goes up the
    /// responder chain instead of into SwiftTerm, which would send it to the program.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard Self.passesUp(event), let window, window.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        nextResponder?.keyDown(with: event)
        return true
    }

    /// No clicks (and so no focus or mouse reports) while the tab does not take input.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        inputEnabled ? super.hitTest(point) : nil
    }

    public override var canBecomeKeyView: Bool { inputEnabled && super.canBecomeKeyView }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportLayoutIfReady()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportLayoutIfReady()
    }

    private func reportLayoutIfReady() {
        guard !didReportLayout, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        didReportLayout = true
        DispatchQueue.main.async { [weak self] in self?.onLayoutReady?() }
    }

    /// Draws a packet of output. Its answered prefix is drawn without answering its queries again.
    func feed(_ packet: TerminalPacket) {
        let bytes = Array(packet.data)
        if packet.answeredPrefix > 0 {
            replayingAnsweredOutput = true
            feed(byteArray: bytes[..<packet.answeredPrefix])
            replayingAnsweredOutput = false
        }
        if packet.answeredPrefix < bytes.count { feed(byteArray: bytes[packet.answeredPrefix...]) }
    }

    public override func send(source: Terminal, data: ArraySlice<UInt8>) {
        guard !replayingAnsweredOutput else { return }
        forwardingProtocolReply = true
        defer { forwardingProtocolReply = false }
        super.send(source: source, data: data)
    }

    /// Only the person's Paste reads the pasteboard. The text and its bracketed-paste markers go in
    /// one bounded, ordered input operation, through the session's queue like typing.
    public override func paste(_ sender: Any) {
        guard inputEnabled, let text = NSPasteboard.general.string(forType: .string) else { return }
        var data = Data(text.utf8)
        if getTerminal().bracketedPasteMode {
            data = Data("\u{001B}[200~".utf8) + data + Data("\u{001B}[201~".utf8)
        }
        onPaste?(data)
    }
}

/// The renderer's delegate and what it last applied (packet, focus and paste requests, colors, font,
/// painted edges). The terminal session owns it, so a view that mounts the retained renderer again
/// neither feeds a packet twice nor replays an old focus request.
@MainActor final class TerminalRendererLink: NSObject, @preconcurrency TerminalViewDelegate {
    var send: (Data) -> Void
    var sendProtocolReply: (Data) -> Void
    var resize: (Int, Int) -> Void
    var lastPacket: UUID?
    var lastFocusRequest = 0
    var lastPasteRequest = 0
    var lastAppearance: AgentLandAppearance?
    var lastFontSize: CGFloat = 0
    var lastEdge: Attribute.Color?

    init(send: @escaping (Data) -> Void, sendProtocolReply: @escaping (Data) -> Void, resize: @escaping (Int, Int) -> Void) {
        self.send = send
        self.sendProtocolReply = sendProtocolReply
        self.resize = resize
    }

    /// A new renderer starts with nothing applied and the current requests already handled.
    func reset(focusRequest: Int, pasteRequest: Int) {
        lastPacket = nil
        lastFocusRequest = focusRequest
        lastPasteRequest = pasteRequest
        lastAppearance = nil
        lastFontSize = 0
        lastEdge = nil
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { resize(newRows, newCols) }
    /// Hears the window title the program sets (OSC 0 or 2), raw; the session cleans it and names the tab.
    /// SwiftTerm's AppKit view calls this while it feeds, inside SwiftUI's update, so the session defers it.
    var titleChanged: (String) -> Void = { _ in }
    func setTerminalTitle(source: TerminalView, title: String) { titleChanged(title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if (source as? AgentTerminalView)?.forwardingProtocolReply == true {
            let reply = Data(data)
            // feed runs inside updateNSView. Mutating SwiftUI's operation queue there can discard
            // the appended reply before its drain.
            DispatchQueue.main.async { [weak self] in self?.sendProtocolReply(reply) }
        } else {
            send(Data(data))
        }
    }
    func scrolled(source: TerminalView, position: Double) {}
    /// Web links open in the default browser; nothing else is opened.
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
    func bell(source: TerminalView) { NSSound.beep() }
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Holds the session's retained renderer while a SwiftUI view shows it. Tearing the view down
/// detaches the renderer; it is not destroyed.
///
/// When a view is built again in place, SwiftUI makes the new view before it tears down the old one
/// and may update both meanwhile. The newest view owns the renderer, and the old one never takes it
/// back or applies its state to it. A renderer with the focus moves only after SwiftUI's update, and
/// takes the focus with it.
final class TerminalMountView: NSView {
    private weak var renderer: AgentTerminalView?
    private var takeScheduled = false

    /// The renderer while this view owns it.
    var mounted: AgentTerminalView? { renderer?.owner === self ? renderer : nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows `view`. `claim` is true for a view SwiftUI just made; a renderer nobody owns (a new one)
    /// goes to the view that asks.
    func mount(_ view: AgentTerminalView, claim: Bool) {
        if claim || view.owner == nil { view.owner = self }
        guard view.owner === self else { return }
        if let previous = renderer, previous !== view, previous.superview === self { previous.removeFromSuperview() }
        renderer = view
        guard view.superview !== self else { return }
        if let window = view.window, window.firstResponder === view { scheduleTake() } else { take(view) }
    }

    private func take(_ view: AgentTerminalView) {
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

    /// Moves the renderer here after SwiftUI's update; it keeps the focus it had.
    private func scheduleTake() {
        guard !takeScheduled else { return }
        takeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.takeScheduled = false
            guard let view = self.mounted, view.superview !== self else { return }
            let hadFocus = view.window.map { $0.firstResponder === view } ?? false
            self.take(view)
            if hadFocus, let window = self.window, view.inputEnabled { window.makeFirstResponder(view) }
        }
    }

    func unmount() {
        guard let view = renderer else { return }
        renderer = nil
        if view.owner === self { view.owner = nil }
        guard view.superview === self else { return }
        if let window = view.window, window.firstResponder === view { window.makeFirstResponder(nil) }
        view.removeFromSuperview()
    }

    override func layout() {
        super.layout()
        if let view = mounted, view.superview === self, view.frame != bounds { view.frame = bounds }
    }
}

/// Shows a terminal session's retained SwiftTerm view and applies the view state to it: activity,
/// visibility, colors, font, focus and paste requests, and the next output packet.
struct TerminalRenderer: NSViewRepresentable {
    let session: TerminalSession
    let rendererID: UUID
    let packet: TerminalPacket?
    let active: Bool
    let colorScheme: ColorScheme
    var increasedContrast = false
    let fontSize: CGFloat
    let focusRequest: Int
    let showKeyboard: Bool
    let pasteRequest: Int
    /// False while another tab is selected: a hidden view still parses, feeds and lays out.
    var visible = true

    /// A new SwiftTerm view reporting to `link`.
    static func makeRenderer(link: TerminalRendererLink) -> AgentTerminalView {
        let view = AgentTerminalView(frame: .zero)
        view.terminalDelegate = link
        view.allowMouseReporting = true
        view.setAccessibilityIdentifier("terminalCanvas")
        view.setAccessibilityLabel("Terminal")
        view.setAccessibilityElement(false)
        return view
    }

    func makeNSView(context: Context) -> TerminalMountView {
        let mount = TerminalMountView()
        mount.mount(session.renderer(for: rendererID), claim: true)
        apply(to: mount)
        return mount
    }

    func updateNSView(_ mount: TerminalMountView, context: Context) {
        mount.mount(session.renderer(for: rendererID), claim: false)
        apply(to: mount)
    }

    static func dismantleNSView(_ mount: TerminalMountView, coordinator: ()) {
        mount.unmount()
    }

    private func apply(to mount: TerminalMountView) {
        guard let view = mount.mounted else { return }
        let link = session.rendererLink
        if link.lastFontSize != fontSize {
            link.lastFontSize = fontSize
            view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        let appearance = AgentLandAppearance(isDark: colorScheme == .dark, increasedContrast: increasedContrast)
        if link.lastAppearance != appearance {
            link.lastAppearance = appearance
            Self.applyColors(to: view, appearance: appearance, edge: link.lastEdge)
        }
        view.inputEnabled = active
        // SwiftTerm makes itself an accessibility element. Mirror the input gate here as well as on
        // its SwiftUI container.
        view.setAccessibilityElement(active)
        if view.isHidden == visible { view.isHidden = !visible }
        if focusRequest != link.lastFocusRequest {
            link.lastFocusRequest = focusRequest
            let focus = active && showKeyboard
            // Outside SwiftUI's update: a focus change there runs the update again from inside it.
            DispatchQueue.main.async { [weak view] in
                guard let view, let window = view.window else { return }
                if focus, view.inputEnabled { window.makeFirstResponder(view) }
                else if window.firstResponder === view { window.makeFirstResponder(nil) }
            }
        }
        if pasteRequest != link.lastPasteRequest {
            link.lastPasteRequest = pasteRequest
            if active { view.paste(view) }
        }
        guard let packet, packet.id != link.lastPacket else { return }
        link.lastPacket = packet.id
        view.feed(packet)
        let session = self.session
        let edge = Self.paintedBackground(of: view)
        if edge != link.lastEdge {
            link.lastEdge = edge
            Self.applyColors(to: view, appearance: link.lastAppearance ?? appearance, edge: edge)
            DispatchQueue.main.async { session.paintedEdge = edge.flatMap(Self.color) }
        }
        DispatchQueue.main.async { session.fed(packet.id) }
    }

    /// The background a program painted under all four corners and the left middle, or nil when any
    /// of them uses the terminal default. Status lines or dialogs that color only part of the screen
    /// never tint the margins.
    static func paintedBackground(of view: TerminalView) -> Attribute.Color? {
        let terminal = view.getTerminal()
        let rows = terminal.rows, cols = terminal.cols
        guard rows > 2, cols > 2 else { return nil }
        var found: Attribute.Color?
        for (col, row) in [(0, 0), (cols - 1, 0), (0, rows / 2), (0, rows - 1), (cols - 1, rows - 1)] {
            guard let background = terminal.getCharData(col: col, row: row)?.attribute.bg,
                  Self.color(background) != nil, found == nil || found == background else { return nil }
            found = background
        }
        return found
    }

    /// True colors map exactly; the xterm cube and grays are standard. The 16 themeable ANSI colors
    /// are not guessed.
    static func color(_ value: Attribute.Color) -> NSColor? {
        func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
            NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
        switch value {
        case let .trueColor(red, green, blue): return rgb(Int(red), Int(green), Int(blue))
        case let .ansi256(code) where code >= 232: let level = 8 + Int(code - 232) * 10; return rgb(level, level, level)
        case let .ansi256(code) where code >= 16:
            let index = Int(code) - 16, levels = [0, 95, 135, 175, 215, 255]
            return rgb(levels[index / 36], levels[(index / 6) % 6], levels[index % 6])
        default: return nil
        }
    }

    /// The paper/slate colors for `appearance`; the margins take a painted edge's color.
    private static func applyColors(to view: AgentTerminalView, appearance: AgentLandAppearance, edge: Attribute.Color?) {
        func resolved(_ token: AgentLandColor) -> NSColor {
            let rgb = token.rgb(for: appearance)
            return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        }
        let background = resolved(.canvas)
        view.nativeBackgroundColor = background
        view.nativeForegroundColor = resolved(.text)
        view.caretColor = resolved(.tint)
        view.wantsLayer = true
        view.layer?.backgroundColor = (edge.flatMap(color) ?? background).cgColor
    }
}
#endif
