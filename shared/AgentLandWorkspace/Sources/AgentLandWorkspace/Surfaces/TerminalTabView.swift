import SwiftUI
import SwiftTerm
import AgentLandCore
import AgentLandDesign
#if os(iOS)
import UIKit

// The Mac's renderer, link, mount and representable are in MacTerminalRenderer.swift.

public final class AgentTerminalView: TerminalView {
    private(set) var forwardingProtocolReply = false
    /// True while this view sends wheel reports for a touch drag: the person's input, not a parser reply.
    private(set) var sendingWheelReport = false
    /// True while this view draws output whose queries a renderer already answered: their replies would
    /// reach the shell long after the program that asked stopped waiting, and be read as typing.
    private var replayingAnsweredOutput = false
    var onPaste: ((Data) -> Void)?
    var onLayoutReady: (() -> Void)?
    private var didReportLayout = false
    /// The view that shows this renderer: the newest one to ask for it.
    weak var owner: TerminalMountView?
    /// AgentLand's key bar, made with the renderer; it is the keyboard's accessory while Settings → Terminal shows it.
    var keyBar: TerminalKeyBar?

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

    /// Whether this terminal's tab takes input now (selected, unlocked, uncovered), from its session. The
    /// model changes before the views update, so this is already false while UIKit acts on a dismissal.
    var takesInput: @MainActor () -> Bool = { true }

    /// UIKit gives the keyboard back on its own: when a presentation that hid it ends (the task
    /// switcher's popover) and when interaction comes back on. A terminal that is not taking input
    /// (another task chosen, a cover over it) refuses. Restored there and put away again while the
    /// popover's dismissal still animated, the keyboard left the key bar (and the keyboard) over Home
    /// with nothing to type into (B-8).
    public override var canBecomeFirstResponder: Bool {
        super.canBecomeFirstResponder && isUserInteractionEnabled && !isHidden && takesInput()
    }

    /// UIKit's restore asks the responder that had the keyboard to take it again, even one that still
    /// holds it. Refusing (and letting go) there is what keeps the restore from showing anything.
    public override func becomeFirstResponder() -> Bool {
        guard canBecomeFirstResponder else {
            if isFirstResponder { _ = super.resignFirstResponder() }
            return false
        }
        return super.becomeFirstResponder()
    }

    /// Scrolls back to the rows the terminal displays. A renderer mounted into a new view can come
    /// back at another scroll position, which would hide the live rows until the next output.
    func showDisplayedRows() {
        scrollTo(row: getTerminal().getTopVisibleRow(), notifyAccessibility: false)
    }

    /// ⌘-combinations belong to the app's commands (new tab, close, select a tab …), whatever keyboard
    /// protocol the program asked for: the kitty protocol would otherwise hold them for the program.
    /// ⌘C, ⌘V and ⌘A stay with the terminal (copy, paste, select all).
    static func passesUp(_ press: UIPress) -> Bool {
        guard let key = press.key, key.modifierFlags.contains(.command) else { return false }
        switch key.keyCode {
        case .keyboardLeftGUI, .keyboardRightGUI, .keyboardLeftShift, .keyboardRightShift, .keyboardLeftAlt,
             .keyboardRightAlt, .keyboardLeftControl, .keyboardRightControl, .keyboardCapsLock:
            // The modifier keys themselves: the terminal tracks ⌘ for links.
            return false
        default:
            return !["c", "v", "a"].contains(key.charactersIgnoringModifiers.lowercased())
        }
    }

    private func split(_ presses: Set<UIPress>) -> (mine: Set<UIPress>, up: Set<UIPress>) {
        var mine = Set<UIPress>(), up = Set<UIPress>()
        for press in presses { if Self.passesUp(press) { up.insert(press) } else { mine.insert(press) } }
        return (mine, up)
    }

    /// SwiftTerm reads key presses here, and with the kitty protocol it holds ⌘-combinations for the
    /// program. Those go up the responder chain first. (Their release reaches SwiftTerm, which
    /// reports releases only for keys it reported pressing, then passes it up too.)
    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let (mine, up) = split(presses)
        if !mine.isEmpty { super.pressesBegan(mine, with: event) }
        if !up.isEmpty { next?.pressesBegan(up, with: event) }
    }
    public override func layoutSubviews() {
        super.layoutSubviews()
        guard !didReportLayout, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        didReportLayout = true
        DispatchQueue.main.async { [weak self] in self?.onLayoutReady?() }
    }
    public override func mouseModeChanged(source: Terminal) {}
    public override func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        // SwiftTerm's default cursor uses an endless UIView animation. A steady
        // cursor keeps the phone readable and lets UIKit reach an idle frame.
        let steady: CursorStyle
        switch newStyle {
        case .blinkBlock: steady = .steadyBlock
        case .blinkUnderline: steady = .steadyUnderline
        case .blinkBar: steady = .steadyBar
        default: steady = newStyle
        }
        super.cursorStyleChanged(source: source, newStyle: steady)
    }
    public override func send(source: Terminal, data: ArraySlice<UInt8>) {
        guard !sendingWheelReport else {
            super.send(source: source, data: data)
            return
        }
        guard !replayingAnsweredOutput else { return }
        forwardingProtocolReply = true
        defer { forwardingProtocolReply = false }
        super.send(source: source, data: data)
    }

    // MARK: Wheel scrolling

    private var wheel = TerminalWheelScroll()
    private var wheelPan: UIPanGestureRecognizer?
    private let wheelPanDelegate = TerminalWheelPanDelegate()
    private var coastLink: CADisplayLink?
    private var coastSpeed: CGFloat = 0
    private var coastPoint: CGPoint = .zero

    /// The program in front reads the mouse wheel: it turned on mouse reporting (OpenCode, tmux with
    /// the mouse on, htop). Then a vertical drag sends it wheel reports at the touched cell. Otherwise
    /// the drag scrolls this renderer's history, and a program on the alternate screen without mouse
    /// reporting gets nothing: touch scrolling never sends keys.
    var programReadsWheel: Bool {
        allowMouseReporting && getTerminal().mouseMode != .off && !selectionActive
    }

    /// Adds the drag that turns the wheel. The history's own scrolling waits for it to decline, which
    /// it does at once unless the program reads the wheel. A trackpad or mouse on iPad scrolls the same way.
    func installWheelScrolling() {
        guard wheelPan == nil else { return }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(wheelPanMoved(_:)))
        pan.maximumNumberOfTouches = 1
        pan.allowedScrollTypesMask = .all
        wheelPanDelegate.view = self
        pan.delegate = wheelPanDelegate
        addGestureRecognizer(pan)
        panGestureRecognizer.require(toFail: pan)
        wheelPan = pan
    }

    @objc private func wheelPanMoved(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            stopCoasting()
            wheel.reset()
        case .changed:
            let travel = pan.translation(in: self).y
            pan.setTranslation(.zero, in: self)
            turnWheel(travel: travel, at: pan.location(in: self))
        case .ended:
            startCoasting(speed: pan.velocity(in: self).y, at: pan.location(in: self))
        default:
            stopCoasting()
        }
    }

    /// Sends the wheel steps for `travel` points of drag at `point` (in this view), through the
    /// program's own mouse encoding (SGR, UTF-8, URXVT or X10) and the guarded input queue.
    private func turnWheel(travel: CGFloat, at point: CGPoint) {
        let terminal = getTerminal()
        guard programReadsWheel, terminal.rows > 0, terminal.cols > 0 else { return }
        let grid = getOptimalFrameSize().size
        let rowHeight = grid.height / CGFloat(terminal.rows)
        let columnWidth = grid.width / CGFloat(terminal.cols)
        guard columnWidth > 0, let step = wheel.steps(forTravel: travel, rowHeight: rowHeight) else { return }
        let visibleY = point.y - contentOffset.y
        let column = min(max(Int(point.x / columnWidth), 0), terminal.cols - 1)
        let row = min(max(Int(visibleY / rowHeight), 0), terminal.rows - 1)
        let flags = terminal.encodeButton(button: step.direction == .up ? 4 : 5, release: false, shift: false, meta: false, control: false)
        sendingWheelReport = true
        defer { sendingWheelReport = false }
        for _ in 0..<step.count {
            terminal.sendEvent(buttonFlags: flags, x: column, y: row, pixelX: max(Int(point.x), 0), pixelY: max(Int(visibleY), 0))
        }
    }

    /// A flick keeps the wheel turning and slows like a scroll view; a touch or leaving the window stops it.
    private func startCoasting(speed: CGFloat, at point: CGPoint) {
        stopCoasting()
        guard abs(speed) >= TerminalWheelScroll.minimumCoastSpeed, programReadsWheel, window != nil else { return }
        coastSpeed = speed
        coastPoint = point
        let link = CADisplayLink(target: TerminalCoastTarget(self), selector: #selector(TerminalCoastTarget.step(_:)))
        link.add(to: .main, forMode: .common)
        coastLink = link
    }

    fileprivate func coast(_ link: CADisplayLink) {
        let elapsed = link.targetTimestamp - link.timestamp
        guard programReadsWheel, window != nil, let speed = TerminalWheelScroll.coast(coastSpeed, elapsed: elapsed) else {
            stopCoasting()
            return
        }
        coastSpeed = speed
        turnWheel(travel: speed * CGFloat(elapsed), at: coastPoint)
    }

    func stopCoasting() {
        coastLink?.invalidate()
        coastLink = nil
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        stopCoasting()
        super.touchesBegan(touches, with: event)
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopCoasting() }
    }
    @objc public override func paste(_ sender: Any?) {
        // Only a user's Paste action reads the clipboard. Keep the text and
        // bracketed-paste markers in one bounded, ordered input operation.
        guard let text = UIPasteboard.general.string else { return }
        var data = Data(text.utf8)
        if getTerminal().bracketedPasteMode {
            data = Data("\u{001B}[200~".utf8) + data + Data("\u{001B}[201~".utf8)
        }
        onPaste?(data)
    }
}

/// Lets the wheel drag begin only while the program reads the wheel and the drag is mostly vertical.
@MainActor private final class TerminalWheelPanDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var view: AgentTerminalView?

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let view, let pan = gesture as? UIPanGestureRecognizer, view.programReadsWheel else { return false }
        let velocity = pan.velocity(in: view)
        return abs(velocity.y) >= abs(velocity.x)
    }
}

/// The coast's display-link target, which holds the view weakly (a display link retains its target).
/// The link runs on the main run loop.
@MainActor private final class TerminalCoastTarget: NSObject {
    weak var view: AgentTerminalView?
    init(_ view: AgentTerminalView) { self.view = view }

    @objc func step(_ link: CADisplayLink) {
        guard let view else { link.invalidate(); return }
        view.coast(link)
    }
}

/// AgentLand's row above the software keyboard. It replaces SwiftTerm's default
/// accessory: keys a phone keyboard lacks go through the same guarded input
/// queue as typing, and the last key hides the keyboard on this terminal.
///
/// Every key is at least 44 × 44 pt, on the system's glass. Key labels and symbols use the body text style and
/// follow the text size up to Extra Extra Extra Large (`maximumContentSizeCategory`), like the system keyboard's;
/// past that a long press shows the Large Content Viewer. A latched Ctrl is a toggle button in prominent glass, in
/// the app's accent with UIKit's own label color on it (native-iOS batch 12, TE-2 and TE-3).
final class TerminalKeyBar: UIInputView, UIInputViewAudioFeedback {
    /// The bar's height: 44 pt keys with 5 pt above and below.
    static let height: CGFloat = 54
    static let keySide: CGFloat = 44
    /// Key labels follow the text size up to this one, then the Large Content Viewer takes over.
    static let largestTextSize: UIContentSizeCategory = .extraExtraExtraLarge

    weak var terminalView: AgentTerminalView?
    var send: ((Data) -> Void)?
    private let controlKey = UIButton(type: .system)
    private var keyButtons: [UIButton] = []
    // Read once more in deinit to unregister; NotificationCenter removal is thread-safe.
    nonisolated(unsafe) private var resetObserver: NSObjectProtocol?
    var enableInputClicksWhenVisible: Bool { true }

    init(terminalView: AgentTerminalView) {
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: Self.height), inputViewStyle: .keyboard)
        self.terminalView = terminalView
        allowsSelfSizing = false
        autoresizingMask = .flexibleWidth
        accessibilityIdentifier = "terminalKeyBar"
        maximumContentSizeCategory = Self.largestTextSize
        build()
        addInteraction(UILargeContentViewerInteraction())
        resetObserver = NotificationCenter.default.addObserver(forName: .terminalViewControlModifierReset, object: terminalView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controlKey.isSelected = false }
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (bar: TerminalKeyBar, _: UITraitCollection) in
            bar.keyButtons.forEach { $0.setNeedsUpdateConfiguration() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let resetObserver { NotificationCenter.default.removeObserver(resetObserver) } }

    private func build() {
        let keys = UIStackView()
        keys.axis = .horizontal
        keys.spacing = 4
        keys.alignment = .fill
        keys.addArrangedSubview(key("esc", label: "Escape", id: "terminalKeyEscape") { [weak self] in self?.emit([0x1b]) })
        keys.addArrangedSubview(key("tab", label: "Tab", id: "terminalKeyTab") { [weak self] in self?.emit([0x09]) })
        style(controlKey, title: "ctrl", label: "Control", width: 48)
        controlKey.accessibilityLabel = "Control"
        controlKey.accessibilityIdentifier = "terminalKeyControl"
        // A toggle button: UIKit turns its selection on and off with each tap, and VoiceOver hears it selected.
        controlKey.changesSelectionAsPrimaryAction = true
        controlKey.addAction(UIAction { [weak self] _ in self?.toggleControl() }, for: .primaryActionTriggered)
        keys.addArrangedSubview(controlKey)
        for (symbol, label, id, normal, application) in [
            ("arrow.left", "Left arrow", "terminalKeyLeft", "\u{1b}[D", "\u{1b}OD"),
            ("arrow.up", "Up arrow", "terminalKeyUp", "\u{1b}[A", "\u{1b}OA"),
            ("arrow.down", "Down arrow", "terminalKeyDown", "\u{1b}[B", "\u{1b}OB"),
            ("arrow.right", "Right arrow", "terminalKeyRight", "\u{1b}[C", "\u{1b}OC")
        ] {
            keys.addArrangedSubview(key(symbol: symbol, label: label, id: id) { [weak self] in
                let app = self?.terminalView?.getTerminal().applicationCursor == true
                self?.emit(Array((app ? application : normal).utf8))
            })
        }
        let scroller = UIScrollView()
        scroller.showsHorizontalScrollIndicator = false
        scroller.alwaysBounceHorizontal = false
        scroller.translatesAutoresizingMaskIntoConstraints = false
        keys.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(keys)
        let hide = key(symbol: "keyboard.chevron.compact.down", label: "Hide keyboard", id: "terminalHideKeyboard") { [weak self] in
            _ = self?.terminalView?.resignFirstResponder()
        }
        hide.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroller)
        addSubview(hide)
        let inset = (Self.height - Self.keySide) / 2
        NSLayoutConstraint.activate([
            scroller.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 6),
            scroller.trailingAnchor.constraint(equalTo: hide.leadingAnchor, constant: -8),
            scroller.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            scroller.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            keys.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            keys.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            keys.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            keys.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            keys.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor),
            hide.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -6),
            hide.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            hide.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
        ])
    }

    private func emit(_ bytes: [UInt8]) {
        UIDevice.current.playInputClick()
        send?(Data(bytes))
    }

    /// The key's selection turns over by itself (`changesSelectionAsPrimaryAction`); the terminal's modifier turns
    /// with it, and when the next key uses the modifier up, the reset notification clears the selection.
    private func toggleControl() {
        guard let terminalView else { return }
        UIDevice.current.playInputClick()
        terminalView.controlModifier.toggle()
    }

    private func key(_ title: String? = nil, symbol: String? = nil, label: String, id: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        style(button, title: title, symbol: symbol, label: label, width: Self.keySide)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = id
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    /// The body text style at the key's text size (capped by the bar's `maximumContentSizeCategory`), in the
    /// monospaced design for the lettered keys.
    private static func labelFont(_ traits: UITraitCollection) -> UIFont {
        let body = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body, compatibleWith: traits)
        return UIFont(descriptor: body.withDesign(.monospaced) ?? body, size: 0)
    }

    private func style(_ button: UIButton, title: String? = nil, symbol: String? = nil, label: String, width: CGFloat) {
        var configuration = UIButton.Configuration.glass()
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)
        button.configuration = configuration
        button.configurationUpdateHandler = { button in
            var updated = button.isSelected ? UIButton.Configuration.prominentGlass() : .glass()
            updated.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)
            if let title {
                updated.attributedTitle = AttributedString(title, attributes: AttributeContainer([.font: Self.labelFont(button.traitCollection)]))
            }
            if let symbol {
                updated.image = UIImage(systemName: symbol)
                updated.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body)
            }
            // UIKit draws the key and its press/disabled state. A latched Ctrl is prominent glass in the window's tint
            // (the app's accent) with the configuration's own label color; the other keys' labels are `label`.
            if !button.isSelected { updated.baseForegroundColor = .label }
            button.configuration = updated
        }
        button.showsLargeContentViewer = true
        button.largeContentTitle = title == nil ? label : title
        button.largeContentImage = symbol.flatMap { UIImage(systemName: $0) }
        button.scalesLargeContentImage = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: width).isActive = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.keySide).isActive = true
        keyButtons.append(button)
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
    /// Settings → Terminal as last applied to the renderer: nil until the first apply.
    var lastCursor: TerminalSettings.Cursor?
    var lastShowsKeyBar: Bool?
    /// A bell from the program plays a haptic (Settings → Terminal), at most once a second.
    var bellVibrates = TerminalSettings.bellHapticDefault
    var bellThrottle = TerminalBellThrottle()
    /// Plays the bell's haptic; tests count it.
    var playBell: () -> Void = { UINotificationFeedbackGenerator().notificationOccurred(.warning) }

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
        lastCursor = nil
        lastShowsKeyBar = nil
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { resize(newRows, newCols) }
    /// Hears the window title the program sets (OSC 0 or 2), raw; the session cleans it and names the tab.
    var titleChanged: (String) -> Void = { _ in }
    func setTerminalTitle(source: TerminalView, title: String) { titleChanged(title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let touchPan = source.gestureRecognizers?.contains { gesture in
            guard let pan = gesture as? UIPanGestureRecognizer else { return false }
            switch pan.state {
            case .began, .changed, .ended, .cancelled: return true
            default: return false
            }
        } ?? false
        let view = source as? AgentTerminalView
        let protocolReply = view?.forwardingProtocolReply == true
        let wheelReport = view?.sendingWheelReport == true
        guard TerminalTouchInputPolicy.shouldForward(isTouchPan: touchPan, isProtocolReply: protocolReply, isWheelReport: wheelReport) else { return }
        if protocolReply {
            let reply = Data(data)
            // feed runs inside updateUIView. Mutating SwiftUI's operation queue there can discard
            // the appended reply before its drain.
            DispatchQueue.main.async { [weak self] in self?.sendProtocolReply(reply) }
        } else { send(Data(data)) }
    }
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    /// SwiftTerm's own bell vibrates every time; AgentLand's only with Settings → Terminal's Vibrate on Bell, and
    /// at most once a second.
    func bell(source: TerminalView) {
        guard bellVibrates, bellThrottle.allows(at: Date()) else { return }
        playBell()
    }
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
/// back or applies its state to it. A renderer with the keyboard moves only after SwiftUI's update:
/// moving it hides the keyboard, and that layout change inside `makeUIView` runs SwiftUI's update
/// again from within this one, which then makes views it does not keep.
final class TerminalMountView: UIView {
    private weak var renderer: AgentTerminalView?
    private var needsScrollSync = false
    private var takeScheduled = false
    /// Room kept free at the bottom for the terminal's notice, so it never covers the newest rows (B-13).
    var noticeInset: CGFloat = 0 {
        didSet { if noticeInset != oldValue { setNeedsLayout() } }
    }
    /// Told how much of this view the key bar covers, for what sits at the bottom over it (the notice).
    var keyBarCoverChanged: ((CGFloat) -> Void)?
    private var reportedKeyBarCover: CGFloat = 0

    /// The renderer while this view owns it.
    var mounted: AgentTerminalView? { renderer?.owner === self ? renderer : nil }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        backgroundColor = .clear
        for name in [UIResponder.keyboardDidShowNotification, UIResponder.keyboardDidChangeFrameNotification,
                     UIResponder.keyboardDidHideNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardSettled(_:)), name: name, object: nil)
        }
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
        if view.isFirstResponder { scheduleTake() } else { take(view) }
    }

    private func take(_ view: AgentTerminalView) {
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(view)
        needsScrollSync = true
        setNeedsLayout()
    }

    /// Moves the renderer here after SwiftUI's update; it keeps the keyboard it had.
    private func scheduleTake() {
        guard !takeScheduled else { return }
        takeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.takeScheduled = false
            guard let view = self.mounted, view.superview !== self else { return }
            let hadKeyboard = view.isFirstResponder
            self.take(view)
            if hadKeyboard, self.window != nil, view.isUserInteractionEnabled, !view.isHidden { _ = view.becomeFirstResponder() }
        }
    }

    func unmount() {
        guard let view = renderer else { return }
        renderer = nil
        if view.owner === self { view.owner = nil }
        guard view.superview === self else { return }
        if view.isFirstResponder { _ = view.resignFirstResponder() }
        view.removeFromSuperview()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { setNeedsLayout() }
    }

    /// How much of this view the renderer's key bar covers. The keyboard safe area follows the system's
    /// keyboard frame; in landscape the keys are narrower than the screen and that frame starts below the
    /// key bar, so this view reached under the bar and the prompt line was hidden behind it (B-16). In
    /// portrait, and with a hardware keyboard, the frame includes the bar and nothing is covered.
    private func keyBarOverlap(_ view: AgentTerminalView) -> CGFloat {
        guard let bar = view.inputAccessoryView, bar.window != nil, !bar.isHidden,
              let space = window?.windowScene?.screen.coordinateSpace else { return 0 }
        let barFrame = bar.convert(bar.bounds, to: space)
        let ownFrame = convert(bounds, to: space)
        guard barFrame.intersects(ownFrame), barFrame.maxY >= ownFrame.maxY - 1 else { return 0 }
        return min(max(0, ownFrame.maxY - barFrame.minY), bounds.height / 2)
    }

    /// The key bar settles after the keyboard's frame changes; lay out again once it has.
    @objc private func keyboardSettled(_ note: Notification) { setNeedsLayout() }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let view = mounted, view.superview === self else { return }
        let cover = keyBarOverlap(view)
        if cover != reportedKeyBarCover {
            reportedKeyBarCover = cover
            let changed = keyBarCoverChanged
            DispatchQueue.main.async { changed?(cover) }
        }
        var frame = bounds
        frame.size.height = max(0, bounds.height - cover - noticeInset)
        if view.frame != frame { view.frame = frame }
        guard needsScrollSync, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        needsScrollSync = false
        // After this layout pass the renderer shows the rows its terminal displays.
        DispatchQueue.main.async { [weak view] in
            guard let view, view.window != nil else { return }
            view.showDisplayedRows()
        }
    }
}

/// Shows a terminal session's retained SwiftTerm view and applies the view state to it: activity,
/// visibility, colors, font, keyboard and paste requests, and the next output packet.
struct TerminalRenderer: UIViewRepresentable {
    let session: TerminalSession
    let rendererID: UUID
    let packet: TerminalPacket?
    let active: Bool
    let colorScheme: ColorScheme
    var increasedContrast = false
    let fontSize: CGFloat
    /// Settings → Terminal: the cursor's shape, the key bar and the bell.
    var cursor: TerminalSettings.Cursor = .block
    var showsKeyBar = TerminalSettings.keyBarDefault
    var bellVibrates = TerminalSettings.bellHapticDefault
    /// The terminal's notice is shown at the bottom: the rows stop above it.
    var noticeInset: CGFloat = 0
    let focusRequest: Int
    let showKeyboard: Bool
    let pasteRequest: Int
    /// False while another tab is selected. SwiftUI's opacity and hit-testing gates do not reach
    /// UIKit's accessibility hit-testing, so a retained terminal would otherwise sit over the selected
    /// tab for VoiceOver and UI automation. A hidden view still parses, feeds and lays out.
    var visible = true

    /// A new SwiftTerm view with AgentLand's key bar in place of SwiftTerm's default accessory row;
    /// its keys use the same guarded input path as typing.
    static func makeRenderer(link: TerminalRendererLink) -> AgentTerminalView {
        let view = AgentTerminalView(frame: .zero)
        view.terminalDelegate = link
        let keyBar = TerminalKeyBar(terminalView: view)
        keyBar.send = { [weak link] data in link?.send(data) }
        view.keyBar = keyBar
        view.inputAccessoryView = keyBar
        view.inputAssistantItem.leadingBarButtonGroups = []
        view.inputAssistantItem.trailingBarButtonGroups = []
        view.allowMouseReporting = true
        view.installWheelScrolling()
        view.linkReporting = .none
        view.getTerminal().setCursorStyle(.steadyBlock)
        view.accessibilityIdentifier = "terminalCanvas"
        view.accessibilityLabel = "Terminal"
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        return view
    }

    func makeUIView(context: Context) -> TerminalMountView {
        let mount = TerminalMountView()
        mount.mount(session.renderer(for: rendererID), claim: true)
        placeNotice(on: mount)
        apply(to: mount)
        return mount
    }

    func updateUIView(_ mount: TerminalMountView, context: Context) {
        mount.mount(session.renderer(for: rendererID), claim: false)
        placeNotice(on: mount)
        apply(to: mount)
    }

    /// The notice's room at the bottom, and where the key bar covers this view (the notice sits above it).
    private func placeNotice(on mount: TerminalMountView) {
        mount.noticeInset = noticeInset
        let session = self.session
        mount.keyBarCoverChanged = { cover in if session.keyBarCover != cover { session.keyBarCover = cover } }
    }

    static func dismantleUIView(_ mount: TerminalMountView, coordinator: ()) {
        mount.unmount()
    }

    private func apply(to mount: TerminalMountView) {
        guard let view = mount.mounted else { return }
        let link = session.rendererLink
        if link.lastFontSize != fontSize {
            link.lastFontSize = fontSize
            // A new size changes the rows and columns: SwiftTerm reflows and reports them, and the session
            // resizes the host's terminal through its ordered queue.
            applyFont(to: view)
        }
        if link.lastCursor != cursor {
            link.lastCursor = cursor
            view.getTerminal().setCursorStyle(cursor.style)
        }
        if link.lastShowsKeyBar != showsKeyBar {
            link.lastShowsKeyBar = showsKeyBar
            Self.showKeyBar(showsKeyBar, on: view)
        }
        link.bellVibrates = bellVibrates
        let appearance = AgentLandAppearance(isDark: colorScheme == .dark, increasedContrast: increasedContrast)
        if link.lastAppearance != appearance {
            link.lastAppearance = appearance
            applyColors(to: view, edge: link.lastEdge)
        }
        // Give up the keyboard before turning interaction off. Left to the interaction setter, the resign
        // ran while the task switcher's dismissal was restoring this terminal's keyboard: the restore took
        // the terminal as still focused and showed its key bar again after the resign, over Home and with
        // nothing focused (B-8). Resigned first, the restore has to ask, and an inactive terminal refuses.
        if !active && view.isFirstResponder { _ = view.resignFirstResponder() }
        view.isUserInteractionEnabled = active
        // SwiftTerm explicitly makes itself an accessibility element. Mirror the cover/input gate
        // here as well as on its SwiftUI container.
        view.isAccessibilityElement = active
        view.accessibilityElementsHidden = !active
        if view.isHidden == visible { view.isHidden = !visible }
        if focusRequest != link.lastFocusRequest {
            link.lastFocusRequest = focusRequest
            if active && showKeyboard { _ = view.becomeFirstResponder() }
            else { _ = view.resignFirstResponder() }
        }
        if pasteRequest != link.lastPasteRequest {
            link.lastPasteRequest = pasteRequest
            if active { view.paste(nil) }
        }
        guard let packet, packet.id != link.lastPacket else { return }
        link.lastPacket = packet.id
        view.feed(packet)
        let session = self.session
        let edge = Self.paintedBackground(of: view)
        if edge != link.lastEdge {
            link.lastEdge = edge
            applyColors(to: view, edge: edge, applyDefaults: false)
            DispatchQueue.main.async { session.paintedEdge = edge.flatMap(Self.color) }
        }
        DispatchQueue.main.async { session.fed(packet.id) }
    }

    /// A full-screen program's main painted background. Sample at most 81 cells so borders and
    /// status rows cannot choose the phone's chrome color. A partial card/line on a default shell
    /// does not qualify; themeable ANSI colors keep the app palette.
    static func paintedBackground(of view: TerminalView) -> Attribute.Color? {
        let terminal = view.getTerminal()
        let rows = terminal.rows, cols = terminal.cols
        guard rows > 2, cols > 2 else { return nil }
        let sampleRows = min(rows, 9), sampleCols = min(cols, 9)
        var counts: [Attribute.Color: Int] = [:]
        var positions: [Attribute.Color: CGPoint] = [:]
        var blankPositions: [Attribute.Color: CGPoint] = [:]
        for row in 0..<sampleRows {
            for col in 0..<sampleCols {
                let y = row * (rows - 1) / (sampleRows - 1)
                let x = col * (cols - 1) / (sampleCols - 1)
                if let cell = terminal.getCharData(col: x, row: y) {
                    let attribute = cell.attribute
                    let background = attribute.style.contains(.inverse) ? attribute.fg : attribute.bg
                    counts[background, default: 0] += 1
                    let point = CGPoint(x: (CGFloat(x) + 0.2) * view.bounds.width / CGFloat(cols),
                                        y: (CGFloat(y) + 0.2) * view.bounds.height / CGFloat(rows))
                    if positions[background] == nil { positions[background] = point }
                    if blankPositions[background] == nil, cell.getCharacter() == " " { blankPositions[background] = point }
                }
            }
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["AGENTLAND_TRACE_TERMINAL_COLORS"] == "1" {
            let samples = counts.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key):\($0.value)" }.joined(separator: ",")
            NSLog("AgentLandTheme nativeBG=%@ nativeFG=%@ samples=%@",
                  String(describing: view.nativeBackgroundColor.cgColor.components),
                  String(describing: view.nativeForegroundColor.cgColor.components), samples)
        }
        #endif
        guard let dominant = counts.max(by: { $0.value < $1.value }),
              dominant.value * 5 >= sampleRows * sampleCols * 3 else { return nil }
        if case .ansi256 = dominant.key, let point = blankPositions[dominant.key] ?? positions[dominant.key] {
            // SwiftTerm's installed palette can use LAB interpolation or OSC 4 overrides. Its
            // palette lookup is private; draw one clipped pixel through the public renderer rather
            // than duplicating that palette or injecting a query into the program's byte stream.
            return renderedBackground(of: view, at: point)
        }
        guard Self.color(dominant.key) != nil else { return nil }
        return dominant.key
    }

    private static func renderedBackground(of view: TerminalView, at point: CGPoint) -> Attribute.Color? {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { context in
            context.cgContext.translateBy(x: -point.x, y: -point.y)
            view.draw(CGRect(origin: point, size: CGSize(width: 1, height: 1)))
        }
        guard let cgImage = image.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return drawn ? .trueColor(red: bytes[0], green: bytes[1], blue: bytes[2]) : nil
    }

    /// True colors map exactly; the xterm cube and grays are standard. The 16 themeable ANSI colors
    /// are not guessed.
    static func color(_ value: Attribute.Color) -> UIColor? {
        func rgb(_ r: Int, _ g: Int, _ b: Int) -> UIColor { UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
        switch value {
        case let .trueColor(red, green, blue): return rgb(Int(red), Int(green), Int(blue))
        case let .ansi256(code) where code >= 232: let level = 8 + Int(code - 232) * 10; return rgb(level, level, level)
        case let .ansi256(code) where code >= 16:
            let index = Int(code) - 16, levels = [0, 95, 135, 175, 215, 255]
            return rgb(levels[index / 36], levels[(index / 6) % 6], levels[index % 6])
        default: return nil
        }
    }

    private func applyColors(to view: AgentTerminalView, edge: Attribute.Color? = nil, applyDefaults: Bool = true) {
        let traits = UITraitCollection { traits in
            traits.userInterfaceStyle = colorScheme == .dark ? .dark : .light
            traits.accessibilityContrast = increasedContrast ? .high : .normal
        }
        let background = AgentLandColor.canvas.uiColor.resolvedColor(with: traits)
        if applyDefaults {
            view.nativeBackgroundColor = background
            view.nativeForegroundColor = AgentLandColor.text.uiColor.resolvedColor(with: traits)
            view.caretColor = AgentLandColor.tint.uiColor.resolvedColor(with: traits)
        }
        // The partial row below the grid shows the view's own layer.
        let surround = edge.flatMap(Self.color) ?? background
        view.backgroundColor = surround
        view.layer.backgroundColor = surround.cgColor
    }

    /// Puts the key bar above the keyboard or takes it away. A keyboard that is up takes the change after
    /// SwiftUI's update: reloading it changes the layout, which must not happen inside `updateUIView`.
    static func showKeyBar(_ shown: Bool, on view: AgentTerminalView) {
        let accessory: UIView? = shown ? view.keyBar : nil
        guard view.inputAccessoryView !== accessory else { return }
        view.inputAccessoryView = accessory
        guard view.isFirstResponder else { return }
        DispatchQueue.main.async { [weak view] in view?.reloadInputViews() }
    }

    private func applyFont(to view: AgentTerminalView) {
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.font = font
        // Rows use a line height of 1.35 × the font size; SwiftTerm multiplies the complete native
        // font line height, so convert between the two.
        view.lineSpacing = fontSize * 1.35 / font.lineHeight
    }
}
#endif

struct TerminalTabView: View {
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(\.scenePhase) private var phase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.workspaceObscured) private var workspaceObscured
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    // Settings → Terminal.
    @AppStorage(TerminalSettings.fontSizeKey) private var chosenFontSize = TerminalSettings.automaticFontSize
    @AppStorage(TerminalSettings.cursorKey) private var cursor = TerminalSettings.Cursor.block
    @AppStorage(TerminalSettings.keyBarKey) private var showsKeyBar = TerminalSettings.keyBarDefault
    @AppStorage(TerminalSettings.bellHapticKey) private var bellVibrates = TerminalSettings.bellHapticDefault
    #endif
    /// This view's name in the session's list of views that show it.
    @State private var viewID = UUID()
    /// The notice's measured height, for the room the rows leave it at the bottom.
    @State private var noticeHeight: CGFloat = 0
    let tab: WorkspaceTab
    /// Shown on a screen of its own (`StandaloneTerminalView`: a terminal of another device outside any workspace this
    /// device knows), not as a tab: it is in front while that screen shows, and it has no tab to close.
    let standalone: Bool

    init(tab: WorkspaceTab, standalone: Bool = false) {
        self.tab = tab
        self.standalone = standalone
    }

    private var session: TerminalSession { workspace.terminalSession(for: tab) }
    /// In front: the selected tab, or a standalone terminal's screen.
    private var inFront: Bool { standalone || workspace.selectedTabID == tab.id }
    private var selected: Bool { inFront && !workspace.locked }
    /// On screen, in an active scene, and not covered by a drawer or overlay.
    private var viewActive: Bool { phase == .active && !workspaceObscured }
    private var active: Bool { selected && viewActive }
    private var inputActive: Bool { active && !workspace.presentationPending }

    var body: some View {
        let session = self.session
        #if os(iOS)
        let surround = session.paintedEdge.map { SwiftUI.Color(uiColor: $0) } ?? AgentLandColor.canvas.color
        #else
        let surround = session.paintedEdge.map { SwiftUI.Color(nsColor: $0) } ?? AgentLandColor.canvas.color
        #endif
        ZStack {
            GeometryReader { geometry in
                renderer(session, width: geometry.size.width - 8)
                    .id(session.rendererID)
                    .padding(.leading, 8)
                    .padding(.top, 4)
                    .background(surround)
                    .accessibilityIdentifier("terminalCanvas")
                    .accessibilityHidden(!inputActive)
                if workspaceUITestHooks {
                    // UI tests read which renderer this terminal shows, to prove a rebuilt view kept it.
                    // It sits beside the renderer so it is read again whenever output arrives.
                    Color.clear.frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityLabel("Terminal renderer")
                        .accessibilityValue(session.rendererSerial.map { "renderer \($0)" } ?? "none")
                        .accessibilityIdentifier("terminalRendererSerial")
                }
            }
            if let connectionIssue = session.connectionIssue {
                terminalConnectionState(connectionIssue, session: session)
                if session.terminalGone, let resumeIssue = session.resumeIssue {
                    resumeNotice(resumeIssue, session: session)
                }
            } else if let issue = session.issue {
                terminalNotice(issue, session: session)
            }
        }
        // The last row (a TUI's input line or status bar) stays above the home indicator and rounded
        // corners; the canvas fills the inset beneath it.
        .background(surround.ignoresSafeArea())
        .task(id: pollKey(session)) { await session.poll(view: viewID, viewActive: viewActive) }
        .onChange(of: viewActive, initial: true) { _, value in session.setViewActive(value, view: viewID) }
        .onDisappear { session.setViewActive(false, view: viewID) }
        .onChange(of: workspace.presentationRequest(for: tab.id), initial: true) { _, _ in
            session.reportPresentationIfReady()
        }
        // A tab's End comes from the title menu (the iPhone's task menu): its question points there (`DialogAnchor`). A
        // standalone terminal's End comes from the actions menu in its own navigation bar, which asks itself
        // (`terminalChrome`).
        .overlay(alignment: DialogAnchor.titleMenu) {
            if !standalone { DialogAnchor().modifier(endQuestion(session)) }
        }
        // A standalone terminal ended from here leaves its screen, as a tab closes.
        .onChange(of: session.endedHere) { _, ended in if ended && standalone { dismiss() } }
        .agentLandHaptic(.warning, trigger: session.issue) { _, issue in issue != nil }
        // A standalone terminal's screen names it live, as a tab's name follows the program and the host.
        .terminalChrome(standalone: standalone, title: standalone ? session.shownTitle ?? tab.title : tab.title,
                        endQuestion: endQuestion(session)) { terminalMenu }
    }

    /// End's question. A terminal of another device or the Mac says where it runs (`TerminalEndConfirmation`).
    private func endQuestion(_ session: TerminalSession) -> TerminalEndQuestion {
        let shown = workspace.tab(tab.id) ?? tab
        return TerminalEndQuestion(session: session, title: TerminalEndConfirmation.title(shown),
                                   message: TerminalEndConfirmation.message(shown.sharedFrom, hostName: workspace.hostName))
    }

    /// The terminal's actions: the keyboard (iPhone and iPad), paste, keys a phone keyboard lacks,
    /// reconnecting and ending the shell. They use the same guarded input queue as typing.
    @ViewBuilder private var terminalMenu: some View {
        #if os(iOS)
        Button("Show keyboard", systemImage: "keyboard") { perform(.keyboard) }.accessibilityIdentifier("terminalKeyboard")
        Button("Hide keyboard", systemImage: "keyboard.chevron.compact.down") { perform(.hideKeyboard) }
            .accessibilityIdentifier("terminalMenuHideKeyboard")
        #endif
        Button("Paste", systemImage: "document.on.clipboard") { perform(.paste) }
        Menu("Keys", systemImage: "command") {
            Button("Escape", systemImage: "escape") { perform(.escape) }
            Button("Tab", systemImage: "arrow.right.to.line") { perform(.tab) }
            Button("Control-C", systemImage: "stop.circle") { perform(.interrupt) }.accessibilityIdentifier("terminalInterrupt")
            Divider()
            Button("Up arrow", systemImage: "arrow.up") { perform(.up) }
            Button("Down arrow", systemImage: "arrow.down") { perform(.down) }
            Button("Left arrow", systemImage: "arrow.left") { perform(.left) }
            Button("Right arrow", systemImage: "arrow.right") { perform(.right) }
        }
        .accessibilityIdentifier("terminalKeys")
        Button("Reconnect", systemImage: "arrow.clockwise") { perform(.reconnect) }
        // A section rather than a divider: a menu separates it the same way, and the iPhone's task menu lists these
        // items in a List, where a divider would be an empty row.
        Section {
            Button("End terminal", systemImage: "xmark.octagon", role: .destructive) { perform(.end) }
        }
    }

    private func perform(_ action: TerminalAction) {
        workspace.perform(action, onTerminal: tab.id)
    }

    /// Restarts the output reads whenever what they depend on changes.
    private func pollKey(_ session: TerminalSession) -> String {
        "\(tab.id)-\(phase)-\(session.generation)-\(active)-\(workspace.tabRefreshGeneration[tab.id]?.uuidString ?? "")-\(workspace.client.map { String(describing: ObjectIdentifier($0)) } ?? "")-\(workspace.reachable)-\(workspace.connectionEpoch)"
    }

    /// The terminal's font follows the text size upward from its default, never so far that fewer
    /// columns fit than the program needs: 55 for OpenCode's compact layout, 40 for a shell on iPhone,
    /// 80 on iPad and Mac. At the default text size it is 15 pt (a shell on iPhone), 16 pt (iPad), 13 pt
    /// (Mac), or 12 or 11 pt so OpenCode gets its 55 columns on iPhone. On the Mac, ⌘− can also make it
    /// smaller than its default, down to 9 pt.
    private func terminalFontSize(width: CGFloat) -> CGFloat {
        #if os(macOS)
        let cellPerPoint = ("M" as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 100, weight: .regular)]).width / 100
        let scaled = MacCodeText.size(for: typeSize)
        let largest = width / (80 * cellPerPoint)
        return max(9, min(scaled, max(MacCodeText.baseSize, largest))).rounded(.down)
        #else
        let cellPerPoint = ("M" as NSString).size(withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 100, weight: .regular)]).width / 100
        let base: CGFloat, minimumColumns: CGFloat
        if UIDevice.current.userInterfaceIdiom != .phone {
            base = 16; minimumColumns = 80
        } else if tab.label == TerminalProgram.opencode.terminalTitle {
            // Named launches keep their host title.
            base = width / (12 * cellPerPoint) >= 55 ? 12 : 11
            minimumColumns = 55
        } else {
            base = 15; minimumColumns = 40
        }
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
        let scaled = UIFontMetrics(forTextStyle: .body).scaledValue(for: base, compatibleWith: traits)
        let largest = width / (minimumColumns * cellPerPoint)
        return max(base, min(scaled, largest)).rounded(.down)
        #endif
    }

    private func renderer(_ session: TerminalSession, width: CGFloat) -> TerminalRenderer {
        #if os(iOS)
        TerminalRenderer(session: session, rendererID: session.rendererID, packet: session.packets.first,
                         active: inputActive && session.rendererTakesInput,
                         colorScheme: colorScheme, increasedContrast: contrast == .increased,
                         fontSize: TerminalSettings.fontSize(chosen: chosenFontSize, automatic: terminalFontSize(width: width)),
                         cursor: cursor, showsKeyBar: showsKeyBar, bellVibrates: bellVibrates, noticeInset: noticeInset(session),
                         focusRequest: session.focusRequest, showKeyboard: session.showKeyboard, pasteRequest: session.pasteRequest,
                         visible: inFront)
        #else
        TerminalRenderer(session: session, rendererID: session.rendererID, packet: session.packets.first,
                         active: inputActive && session.rendererTakesInput,
                         colorScheme: colorScheme, increasedContrast: contrast == .increased,
                         fontSize: terminalFontSize(width: width),
                         focusRequest: session.focusRequest, showKeyboard: session.showKeyboard, pasteRequest: session.pasteRequest,
                         visible: inFront)
        #endif
    }

    /// Output stopped: why, and what to do about it. An ended terminal says when and why it ended, with its keyboard
    /// and key bar gone (nothing can be typed into it); a Claude Code one offers Resume, a new terminal continuing its
    /// conversation in this tab's place.
    private func terminalConnectionState(_ detail: String, session: TerminalSession) -> some View {
        ContentUnavailable(session.terminalGone ? "Terminal ended" : "Terminal disconnected",
                           systemImage: session.terminalGone ? "terminal" : "bolt.horizontal.circle",
                           description: detail, descriptionIdentifier: "terminalEndedDetail") {
            if session.terminalGone {
                if let resume = session.resumeTarget {
                    Button("Resume") { Task { await session.resume() } }
                        .buttonStyle(.agentLandPrimary)
                        .disabled(!workspace.reachable || workspace.sessionOpening || session.ending)
                        .accessibilityHint(resume == .pick ? "Opens a new Claude Code terminal where you choose a conversation of this workspace to continue."
                                                           : "Opens a new Claude Code terminal that continues this conversation.")
                        .accessibilityIdentifier("terminalResume")
                    Button(standalone ? "Close" : "Close tab", action: closeEnded)
                        .accessibilityIdentifier("terminalCloseEnded")
                } else {
                    Button(standalone ? "Close" : "Close tab", action: closeEnded)
                        .buttonStyle(.agentLandPrimary)
                        .accessibilityIdentifier("terminalCloseEnded")
                }
            } else {
                Button("Retry connection") { session.reconnect() }
                    .buttonStyle(.agentLandPrimary)
                    .accessibilityIdentifier("terminalRetryConnection")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AgentLandColor.canvas)
        .accessibilityElement(children: .contain)
    }

    /// An ended terminal's Close: its tab closes, or a standalone terminal's screen goes.
    private func closeEnded() {
        if standalone { dismiss() } else { workspace.close(tab.id) }
    }

    /// Why Resume opened nothing (ending the old terminal on the host failed or is uncertain), over the ended state at
    /// the bottom, where the terminal's notices sit.
    private func resumeNotice(_ detail: String, session: TerminalSession) -> some View {
        InlineNotice(detail, tone: .warning, onDismiss: { session.resumeIssue = nil },
                     identifiers: .init(text: "terminalResumeNotice", dismiss: "terminalDismissResumeNotice"))
            .frame(maxWidth: 560)
            .padding(.horizontal, AgentLandSpacing.small)
            .padding(.bottom, AgentLandSpacing.xSmall)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// The room the notice takes at the bottom while it shows; the rows stop above it.
    private func noticeInset(_ session: TerminalSession) -> CGFloat {
        guard session.connectionIssue == nil, session.issue != nil, noticeHeight > 0 else { return 0 }
        return noticeHeight + 2 * AgentLandSpacing.xSmall
    }

    /// A notice about input or an action; the terminal keeps running above it. Resume Typing appears
    /// only after uncertain delivery, when the host is reachable again. On iPhone it sits at the bottom,
    /// just above the key bar (or the keyboard, or the home indicator), and the rows stop above it: it asks
    /// the person to check the newest output, so it never covers it (B-13).
    private func terminalNotice(_ detail: String, session: TerminalSession) -> some View {
        let canResume = session.inputBlocked && workspace.reachable
        let notice = InlineNotice(detail, tone: .warning,
                                  actionTitle: canResume ? "Resume typing" : nil,
                                  action: canResume ? { session.resumeTyping() } : nil,
                                  onDismiss: { session.issue = nil },
                                  identifiers: .init(text: "terminalNotice", action: "terminalResumeTyping", dismiss: "terminalDismissNotice"))
        #if os(iOS)
        return notice
            .frame(maxWidth: 560)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { noticeHeight = $0 }
            .padding(.horizontal, AgentLandSpacing.small)
            .padding(.bottom, AgentLandSpacing.xSmall + session.keyBarCover)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        #else
        return notice
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(AgentLandSpacing.small)
            // The workspace's connection banner sits at the top while offline.
            .padding(.top, workspace.reachable ? 0 : 92)
        #endif
    }
}

/// The question End asks before it ends the terminal on the host, attached where End was chosen: under the title menu
/// for a tab (`DialogAnchor`), on the actions menu for a standalone terminal's screen.
private struct TerminalEndQuestion: ViewModifier {
    @Bindable var session: TerminalSession
    let title: String
    let message: String

    func body(content: Content) -> some View {
        content.confirmationDialog(title, isPresented: $session.showEndConfirmation, titleVisibility: .visible) {
            Button("End terminal", role: .destructive) { Task { await session.endTerminal() } }
        } message: { Text(message) }
    }
}

private extension View {
    /// A tab's title and actions in the workspace's switcher and title menu (`surfaceTitle`); a standalone terminal's in
    /// its own screen's navigation bar, which keeps its Back button, and whose actions menu asks End's question
    /// (`endQuestion`), pointing at the menu End was chosen from.
    @ViewBuilder func terminalChrome<Items: View>(standalone: Bool, title: String, endQuestion: TerminalEndQuestion,
                                                  @ViewBuilder menu: @escaping () -> Items) -> some View {
        if standalone {
            navigationTitle(title)
                .workspaceInlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu(content: menu) { Label("\(title) Actions", systemImage: "ellipsis.circle") }
                            .menuOrder(.fixed)
                            .accessibilityIdentifier("terminalActions")
                            .modifier(endQuestion)
                    }
                }
        } else {
            surfaceTitle(title, systemImage: "terminal", identifier: "terminalActions", menu: menu)
        }
    }
}
