import XCTest
import SwiftUI
import AgentLandCore
import AgentLandDesign
@testable import AgentLandWorkspace

/// Serves one screen of terminal output, then holds every later read open like the host's long-poll.
private final class TerminalHost: APITransport, @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [String] = []
    private var inputs: [Data] = []
    private var sizes: [(rows: Int, cols: Int)] = []
    let screen: String
    init(screen: String) { self.screen = screen }

    /// The cursor of every output read, in order.
    var cursors: [String] { lock.withLock { reads } }
    var received: [Data] { lock.withLock { inputs } }
    /// Every resize the host was asked for, in order.
    var resizes: [(rows: Int, cols: Int)] { lock.withLock { sizes } }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        switch url.path {
        case "/v1/terminal/output":
            let cursor = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value ?? ""
            lock.withLock { reads.append(cursor) }
            guard cursor == "0" else {
                try await Task.sleep(for: .seconds(60))
                throw CancellationError()
            }
            let data = Data(screen.utf8)
            let body = #"{"data":"\#(data.base64EncodedString())","cursor":\#(data.count),"reset":false,"status":"running","exitCode":null}"#
            return (Data(body.utf8), ok)
        case "/v1/terminal/input":
            if let body = request.httpBody, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let encoded = object["data"] as? String, let data = Data(base64Encoded: encoded) {
                lock.withLock { inputs.append(data) }
            }
            return (Data(#"{"accepted":true}"#.utf8), ok)
        case "/v1/terminal/resize":
            if let body = request.httpBody, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let rows = object["rows"] as? Int, let cols = object["cols"] as? Int {
                lock.withLock { sizes.append((rows, cols)) }
            }
            return (Data(#"{"accepted":true}"#.utf8), ok)
        default:
            return (Data(#"{"accepted":true}"#.utf8), ok)
        }
    }
}

@MainActor final class TerminalRendererTests: XCTestCase {
    func testParserCursorQueryUsesProtocolReplyRouteWhenInteractionIsDisabled() async {
        var userSends: [Data] = []
        var protocolReplies: [Data] = []
        let delivered = expectation(description: "Parser reply leaves the render update before enqueueing")
        let link = TerminalRendererLink(send: { userSends.append($0) },
                                        sendProtocolReply: { protocolReplies.append($0); delivered.fulfill() },
                                        resize: { _, _ in })
        let view = AgentTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        view.terminalDelegate = link
        view.isUserInteractionEnabled = false

        view.feed(byteArray: Array("\u{1b}[6n".utf8)[...])

        XCTAssertTrue(userSends.isEmpty)
        XCTAssertTrue(protocolReplies.isEmpty, "A parser reply must not mutate the queue synchronously inside updateUIView")
        await fulfillment(of: [delivered], timeout: 1)
        guard let reply = protocolReplies.first else {
            return XCTFail("The terminal did not emit a cursor-position reply")
        }
        XCTAssertEqual(reply.first, 0x1b)
        XCTAssertEqual(reply.last, 0x52)
    }

    /// A relaunch reads the terminal's history again. Its queries were answered when first drawn, so the
    /// renderer draws them without replying; the shell would read late replies as typing (B-9).
    func testReplayedHistoryIsDrawnWithoutAnsweringItsQueriesAgain() async {
        var userSends: [Data] = []
        var protocolReplies: [Data] = []
        let link = TerminalRendererLink(send: { userSends.append($0) },
                                        sendProtocolReply: { protocolReplies.append($0) },
                                        resize: { _, _ in })
        let view = AgentTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        view.terminalDelegate = link
        let history = Data("ready \u{1b}[6n\u{1b}[c done".utf8)

        view.feed(TerminalPacket(data: history, answeredPrefix: history.count))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(userSends.isEmpty)
        XCTAssertTrue(protocolReplies.isEmpty, "Replayed queries are not answered again")

        let delivered = expectation(description: "A new query is answered")
        link.sendProtocolReply = { protocolReplies.append($0); delivered.fulfill() }
        view.feed(TerminalPacket(data: Data("\u{1b}[6n".utf8)))
        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertEqual(protocolReplies.first?.last, 0x52)
    }

    /// UIKit restores the keyboard to the responder a presentation hid it from, even after the terminal
    /// stopped taking input. A terminal that takes no input refuses the keyboard, so nothing restores it
    /// over Home (B-8); taking input again, it accepts it.
    func testATerminalThatTakesNoInputRefusesTheKeyboard() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let view = AgentTerminalView(frame: window.bounds)
        window.addSubview(view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        view.isUserInteractionEnabled = false
        XCTAssertFalse(view.canBecomeFirstResponder)
        XCTAssertFalse(view.becomeFirstResponder(), "A terminal behind another task or a cover gets no keyboard")

        view.isUserInteractionEnabled = true
        view.isHidden = true
        XCTAssertFalse(view.canBecomeFirstResponder, "A hidden retained terminal gets no keyboard")

        view.isHidden = false
        XCTAssertTrue(view.canBecomeFirstResponder)

        // Another task was chosen: the model says so before the views update. UIKit's restore then asks the
        // terminal, which still holds the keyboard, to take it again; it refuses and lets go.
        var takesInput = true
        view.takesInput = { takesInput }
        XCTAssertTrue(view.becomeFirstResponder())
        takesInput = false
        XCTAssertFalse(view.canBecomeFirstResponder)
        XCTAssertFalse(view.becomeFirstResponder(), "A terminal whose tab is not taking input refuses the keyboard")
        XCTAssertFalse(view.isFirstResponder, "and gives up the keyboard it still held")
    }

    /// Focus reports follow the terminal in front, not the keyboard. Told the focus went when Return put the
    /// keyboard away, Claude Code ignored the tap on the bar above its prompt, and it ignores clicks for a moment
    /// after it hears the focus come back, so the keyboard coming with that tap can't report it either.
    func testFocusReportsFollowTheTerminalInFrontNotTheKeyboard() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let view = AgentTerminalView(frame: window.bounds)
        window.addSubview(view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var reports: [Data] = []
        let link = TerminalRendererLink(send: { reports.append($0) }, sendProtocolReply: { reports.append($0) }, resize: { _, _ in })
        view.terminalDelegate = link
        let focusIn = Data("\u{1b}[I".utf8), focusOut = Data("\u{1b}[O".utf8)

        view.showInFront(true)
        view.feed(byteArray: Array("\u{1b}[?1004h".utf8)[...])
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reports, [focusIn], "A program that asks hears that the terminal in front has the focus")

        reports.removeAll()
        XCTAssertTrue(view.becomeFirstResponder())
        XCTAssertTrue(view.resignFirstResponder())
        view.feed(byteArray: Array("\u{1b}[?1004h".utf8)[...])
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reports, [focusIn], "The keyboard coming and going reports nothing, and the focus stays with the terminal")

        reports.removeAll()
        view.showInFront(false)
        view.showInFront(false)
        view.showInFront(true)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reports, [focusOut, focusIn], "Another task in front, then this one again, each reported once")
    }

    /// Only a tap on the text entry brings the keyboard (owner, 2026-10-27): the cursor's row and the rows on either
    /// side of it, where Claude Code's and Codex's input boxes sit, below however much history.
    func testOnlyTheCursorsRowsAreTheTextEntry() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let view = AgentTerminalView(frame: window.bounds)
        window.addSubview(view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let terminal = view.getTerminal()
        view.feed(byteArray: Array((String(repeating: "line\r\n", count: terminal.rows * 2) + "\u{1b}[6;1H").utf8)[...])
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(terminal.getTopVisibleRow(), 0, "The screen sits below its history")
        XCTAssertEqual(terminal.getCursorLocation().y, 5)

        let rowHeight = view.getOptimalFrameSize().height / CGFloat(terminal.rows)
        func screenRow(_ row: Int) -> CGPoint {
            CGPoint(x: 10, y: (CGFloat(terminal.getTopVisibleRow() + row) + 0.5) * rowHeight)
        }
        XCTAssertTrue(view.isTextEntry(screenRow(5)), "The cursor's row")
        XCTAssertTrue(view.isTextEntry(screenRow(4)) && view.isTextEntry(screenRow(6)), "An input box's edges")
        for row in [0, 3, 7, terminal.rows - 1] {
            XCTAssertFalse(view.isTextEntry(screenRow(row)), "Row \(row) is output, not the text entry")
        }
    }

    /// A full-screen program's bars (Claude Code's input box, status line and mode line) hide while its history scrolls
    /// back (owner, 2026-10-27): the host's rows grow by them and the renderer hangs that much below its foot, masked.
    /// They come back at the program's bottom, and when the program leaves the alternate screen.
    func testFullScreenBarsHideWhileScrollingBackAndComeBackAtTheBottom() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let mount = TerminalMountView(frame: window.bounds)
        window.addSubview(mount)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var sizes: [Int] = []
        let link = TerminalRendererLink(send: { _ in }, sendProtocolReply: { _ in }, resize: { rows, _ in sizes.append(rows) })
        let view = AgentTerminalView(frame: .zero)
        view.terminalDelegate = link
        mount.mount(view, claim: true)
        mount.layoutIfNeeded()
        let terminal = view.getTerminal()
        let rows = terminal.rows
        // The alternate screen and the mouse, the cursor in an input box whose top edge is seven rows from the foot.
        view.feed(TerminalPacket(data: Data("\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h\u{1b}[\(rows - 5);3H".utf8)))

        view.hideBars()
        XCTAssertEqual(view.hiddenBarRows, 7, "From the row above the cursor to the foot")
        XCTAssertEqual(terminal.rows, rows + 7, "The terminal grows by the bars")
        XCTAssertEqual(sizes.last, rows + 7, "and tells the host at once, before any wheel step")
        XCTAssertEqual(view.layer.mask?.frame.height ?? 0, CGFloat(rows) * view.rowHeight, accuracy: 0.5,
                       "Only the rows that were in sight show")

        view.wheelTurned(.up, steps: 5)
        view.wheelTurned(.down, steps: 4)
        XCTAssertEqual(view.hiddenBarRows, 7, "Above the bottom they stay hidden")
        view.wheelTurned(.down, steps: 3)
        XCTAssertEqual(view.hiddenBarRows, 0, "Back at the bottom they come back")
        XCTAssertEqual(terminal.rows, rows)
        XCTAssertEqual(sizes.last, rows)
        XCTAssertNil(view.layer.mask)

        // Claude Code marks its scrolled-up history: the mark, not the steps, says when it is at its bottom.
        view.hideBars()
        view.wheelTurned(.up, steps: 3)
        view.feed(TerminalPacket(data: Data("\u{1b}7\u{1b}[4;1HJump to bottom (click)\u{1b}8".utf8)))
        view.wheelTurned(.down, steps: 3)
        XCTAssertEqual(view.hiddenBarRows, 7, "Still marked as scrolled up, past where the steps say the bottom is")
        view.feed(TerminalPacket(data: Data("\u{1b}7\u{1b}[4;1H\u{1b}[2K\u{1b}8".utf8)))
        XCTAssertEqual(view.hiddenBarRows, 0, "The mark gone, the program is at its bottom")

        view.hideBars()
        XCTAssertEqual(view.hiddenBarRows, 7)
        view.feed(TerminalPacket(data: Data("\u{1b}[?1049l".utf8)))
        XCTAssertEqual(view.hiddenBarRows, 0, "Leaving the alternate screen brings them back")
        view.hideBars()
        XCTAssertEqual(view.hiddenBarRows, 0, "A shell's screen has no bars to hide")
    }

    /// The terminal's notice ("Check output before typing again") sits at the bottom, and the rows stop
    /// above it, so it never covers the newest output it asks the person to check (B-13).
    func testTheRowsStopAboveTheNoticeAtTheBottom() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let mount = TerminalMountView(frame: window.bounds)
        window.addSubview(mount)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let view = AgentTerminalView(frame: .zero)
        mount.mount(view, claim: true)
        mount.layoutIfNeeded()
        XCTAssertEqual(view.frame.height, 480, accuracy: 0.5, "Without a notice the rows fill the view")

        mount.noticeInset = 96
        mount.layoutIfNeeded()
        XCTAssertEqual(view.frame.minY, 0, accuracy: 0.5)
        XCTAssertEqual(view.frame.maxY, 384, accuracy: 0.5, "The rows end where the notice begins")

        mount.noticeInset = 0
        mount.layoutIfNeeded()
        XCTAssertEqual(view.frame.height, 480, accuracy: 0.5, "Once it goes the rows take the room back")
    }

    /// The rows stop above the keyboard, the key bar on it included, and the notice above that. The renderer takes that
    /// height as the keyboard starts to move, animated with the keyboard's duration, so its rows (and the host's)
    /// change once per move, at its start (owner, 2026-10-23: "the old way looked nicer it was just to slow in
    /// tranitions").
    func testTheRowsFollowTheKeyboardAndChangeOncePerMove() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        let mount = TerminalMountView(frame: window.bounds)
        window.addSubview(mount)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var resizes: [Int] = []
        let link = TerminalRendererLink(send: { _ in }, sendProtocolReply: { _ in }, resize: { rows, _ in resizes.append(rows) })
        let view = AgentTerminalView(frame: .zero)
        view.terminalDelegate = link
        mount.mount(view, claim: true)
        mount.layoutIfNeeded()
        view.layoutIfNeeded()
        let height = window.bounds.height, foot = height - window.safeAreaInsets.bottom
        XCTAssertEqual(view.frame.maxY, foot, accuracy: 0.5, "Without a keyboard the rows end above the home indicator")
        func keyboard(top: CGFloat, duration: Double) {
            NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: CGRect(x: 0, y: top, width: window.bounds.width, height: 355),
                UIResponder.keyboardAnimationDurationUserInfoKey: duration,
                UIResponder.keyboardAnimationCurveUserInfoKey: 7])
        }
        func heightAnimation() -> CAAnimation? {
            view.layer.animationKeys()?.compactMap { view.layer.animation(forKey: $0) }
                .first { ($0 as? CABasicAnimation)?.keyPath == "bounds.size" }
        }

        resizes = []
        keyboard(top: height - 355, duration: 0.25)
        XCTAssertEqual(view.frame.minY, 0, accuracy: 0.5)
        XCTAssertEqual(view.frame.maxY, height - 355, accuracy: 0.5, "The renderer takes the height it rests at at once")
        XCTAssertNotNil(heightAnimation(), "and gets there with the keyboard")
        XCTAssertEqual(resizes.count, 1, "Its rows change as the keyboard starts to rise")
        try await Task.sleep(for: .milliseconds(400))
        mount.layoutIfNeeded()
        XCTAssertEqual(view.frame.maxY, height - 355, accuracy: 0.5, "Nothing moves once the keyboard has arrived")
        XCTAssertEqual(resizes.count, 1, "and the rows changed once")

        mount.noticeInset = 96
        mount.layoutIfNeeded()
        XCTAssertEqual(view.frame.maxY, height - 355 - 96, accuracy: 0.5, "The notice sits on the keyboard, the rows above it")

        resizes = []
        keyboard(top: height, duration: 0.25)
        XCTAssertEqual(view.frame.maxY, foot - 96, accuracy: 0.5, "A going keyboard gives the rows back at once")
        XCTAssertNotNil(heightAnimation(), "at the keyboard's pace")
        XCTAssertEqual(resizes.count, 1)
        try await Task.sleep(for: .milliseconds(400))
        mount.layoutIfNeeded()
        XCTAssertEqual(view.frame.maxY, foot - 96, accuracy: 0.5)
        XCTAssertEqual(resizes.count, 1)
        withExtendedLifetime(link) {}
    }

    func testDirectTerminalDelegateInputUsesUserRoute() {
        var userSends: [Data] = []
        var protocolReplies: [Data] = []
        let link = TerminalRendererLink(send: { userSends.append($0) },
                                        sendProtocolReply: { protocolReplies.append($0) },
                                        resize: { _, _ in })
        let view = AgentTerminalView(frame: .zero)

        link.send(source: view, data: Array("x".utf8)[...])

        XCTAssertEqual(userSends, [Data("x".utf8)])
        XCTAssertTrue(protocolReplies.isEmpty)
    }

    func testBackdropFollowsTheMainFullScreenColorInsteadOfItsBorder() {
        let view = AgentTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        view.layoutIfNeeded()
        XCTAssertNil(TerminalRenderer.paintedBackground(of: view), "A plain shell keeps the paper margins")
        view.feed(byteArray: Array("\u{1b}[48;2;30;40;50m\u{1b}[2J\u{1b}[H".utf8)[...])
        XCTAssertEqual(TerminalRenderer.paintedBackground(of: view), .trueColor(red: 30, green: 40, blue: 50),
                       "A full-screen program's own background extends into the margins")
        let rows = view.getTerminal().rows
        var border = "\u{1b}[48;2;0;0;0m\u{1b}[1;1H\u{1b}[2K\u{1b}[\(rows);1H\u{1b}[2K"
        for row in 2..<rows { border += "\u{1b}[\(row);1H " }
        view.feed(byteArray: Array(border.utf8)[...])
        XCTAssertEqual(TerminalRenderer.paintedBackground(of: view), .trueColor(red: 30, green: 40, blue: 50),
                       "OpenCode-style black borders must not replace the program's main background")
        view.feed(byteArray: Array("\u{1b}[0m\u{1b}[2J\u{1b}[H\u{1b}[48;2;30;40;50mStatus\u{1b}[0m".utf8)[...])
        XCTAssertNil(TerminalRenderer.paintedBackground(of: view), "A colored status line does not replace the app palette")
        // Erase operations deliberately ignore reverse-video style. Paint spaces to exercise it.
        var reversed = "\u{1b}[38;2;30;40;50m\u{1b}[48;2;0;0;0m\u{1b}[7m\u{1b}[2J"
        for row in 1...rows {
            reversed += "\u{1b}[\(row);1H" + String(repeating: " ", count: view.getTerminal().cols - 1)
        }
        view.feed(byteArray: Array(reversed.utf8)[...])
        XCTAssertEqual(TerminalRenderer.paintedBackground(of: view), .trueColor(red: 30, green: 40, blue: 50),
                       "Reverse video paints the foreground color as the background")
        view.feed(byteArray: Array("\u{1b}[0m\u{1b}]4;232;rgb:2e/38/45\u{7}\u{1b}[48;5;232m\u{1b}[2J\u{1b}[H".utf8)[...])
        XCTAssertEqual(TerminalRenderer.paintedBackground(of: view), .trueColor(red: 46, green: 56, blue: 69),
                       "Indexed backgrounds follow the palette actually installed in the renderer")
        XCTAssertNil(TerminalRenderer.color(.ansi256(code: 4)), "Themeable ANSI colors are not guessed")
        XCTAssertNotNil(TerminalRenderer.color(.ansi256(code: 236)))
    }

    func testPhoneChromeFollowsOnlyTheSelectedPaintedTerminal() throws {
        let suite = "terminal-chrome-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("light", forKey: "agentland.appearance")
        let workspace = WorkspaceModel(defaults: defaults)
        XCTAssertNil(workspace.phoneChromeAppearance, "Home uses the saved app palette")
        let first = WorkspaceTab(kind: .terminal, projectID: "p", resourceID: "first", title: "First")
        workspace.open(first)
        let session = workspace.terminalSession(for: first)
        XCTAssertNil(workspace.phoneChromeAppearance, "An ordinary shell uses the app palette")
        session.paintedEdge = UIColor(red: 30 / 255, green: 40 / 255, blue: 50 / 255, alpha: 1)
        XCTAssertEqual(workspace.phoneChromeAppearance?.colorScheme, .dark)
        let second = WorkspaceTab(kind: .terminal, projectID: "p", resourceID: "second", title: "Second")
        workspace.open(second)
        workspace.terminalSession(for: second).paintedEdge = .white
        XCTAssertEqual(workspace.phoneChromeAppearance?.colorScheme, .light)
        workspace.selectedTabID = first.id
        XCTAssertEqual(workspace.phoneChromeAppearance?.colorScheme, .dark, "Switching tasks restores that terminal's backdrop")
        session.paintedEdge = nil
        XCTAssertNil(workspace.phoneChromeAppearance, "Removing a painted screen restores the app palette")
        session.paintedEdge = .black
        workspace.phoneNavigation.showHome(model: workspace)
        XCTAssertNil(workspace.phoneChromeAppearance)
        XCTAssertEqual(defaults.string(forKey: "agentland.appearance"), "light", "Matching terminal chrome never overwrites the saved choice")
        XCTAssertNil(WorkspacePhoneChromeAppearance(paintedBackground: .clear))
        XCTAssertNotNil(WorkspacePhoneChromeAppearance(paintedBackground: UIColor(red: 2, green: -1, blue: 0, alpha: 1)),
                        "Extended color components must not crash background matching")
        workspace.close(first.id)
        workspace.close(second.id)
    }

    func testPaintedTerminalBackgroundExtendsAcrossPhoneSafeAreas() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let suite = "terminal-chrome-render-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = TerminalHost(screen: "\u{1b}[48;2;30;40;50m\u{1b}[2J\u{1b}[H")
        let workspace = WorkspaceModel(defaults: defaults)
        workspace.attach(hostID: "terminal-host", identity: ConnectionIdentity(host: "https://terminal.example", deviceID: "d"),
                         client: APIClient(address: try ServerAddress(validating: "https://terminal.example"), token: "t", transport: host))
        let tab = WorkspaceTab(kind: .terminal, projectID: "p", resourceID: "chrome", title: "Terminal")
        workspace.open(tab)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 700)
        window.rootViewController = UIHostingController(rootView: WorkspaceView(connection: .online, retryConnection: nil, covered: false,
            settings: { _ in EmptyView() }, notices: { EmptyView() })
            .environment(workspace).environment(\.scenePhase, .active).preferredColorScheme(.dark))
        window.makeKeyAndVisible()
        defer { workspace.close(tab.id); window.isHidden = true; window.rootViewController = nil }
        let session = workspace.terminalSession(for: tab)
        await workspace.refreshProjects()
        await settle { workspace.presentationReady && session.paintedEdge != nil }
        workspace.completePresentation(try XCTUnwrap(workspace.presentationTicket))
        try await Task.sleep(for: .milliseconds(200))
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        // Outside text, glass controls and system glyphs: top safe area, footer and terminal margin.
        for y in [4, height / 2, height - 4] {
            let offset = (y * width + 4) * 4
            for (channel, expected) in [30, 40, 50].enumerated() {
                XCTAssertEqual(Int(pixels[offset + channel]), expected, accuracy: 2, "Phone chrome and terminal margins share the painted background")
            }
        }
    }

    func testKeyBarKeysUseTheGuardedInputPathAndFollowCursorMode() throws {
        let view = AgentTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let bar = TerminalKeyBar(terminalView: view)
        var sent: [Data] = []
        bar.send = { sent.append($0) }
        func key(_ id: String) throws -> UIButton {
            func search(_ view: UIView) -> UIButton? {
                if let button = view as? UIButton, button.accessibilityIdentifier == id { return button }
                return view.subviews.lazy.compactMap(search).first
            }
            return try XCTUnwrap(search(bar), id)
        }
        try key("terminalKeyEscape").sendActions(for: .touchUpInside)
        try key("terminalKeyTab").sendActions(for: .touchUpInside)
        try key("terminalKeyUp").sendActions(for: .touchUpInside)
        view.feed(byteArray: Array("\u{1b}[?1h".utf8)[...])
        try key("terminalKeyUp").sendActions(for: .touchUpInside)
        XCTAssertEqual(sent, [Data([0x1b]), Data([0x09]), Data("\u{1b}[A".utf8), Data("\u{1b}OA".utf8)])
        // Ctrl is a toggle button (VoiceOver hears it selected) whose action turns the terminal's modifier with it.
        XCTAssertTrue(try key("terminalKeyControl").changesSelectionAsPrimaryAction)
        try key("terminalKeyControl").sendActions(for: .primaryActionTriggered)
        XCTAssertTrue(view.controlModifier, "Ctrl applies to the next typed key")
        XCTAssertEqual(bar.maximumContentSizeCategory, .extraExtraExtraLarge, "key labels follow the text size up to a cap")
        XCTAssertNotNil(try? key("terminalHideKeyboard"))
    }

    // MARK: Settings → Terminal

    /// The terminal's own text size, cursor and key bar reach the retained renderer; a new size reflows the grid and
    /// resizes the host's terminal through the session's queue.
    func testTerminalSettingsReachTheRendererAndANewSizeResizesTheHostsTerminal() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let suite = "terminal-settings-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(20.0, forKey: TerminalSettings.fontSizeKey)
        defaults.set(TerminalSettings.Cursor.bar.rawValue, forKey: TerminalSettings.cursorKey)
        defaults.set(false, forKey: TerminalSettings.keyBarKey)
        let host = TerminalHost(screen: "hello\r\n")
        let workspace = WorkspaceModel(defaults: defaults)
        workspace.attach(hostID: "terminal-host", identity: ConnectionIdentity(host: "https://terminal.example", deviceID: "d"),
                         client: APIClient(address: try ServerAddress(validating: "https://terminal.example"), token: "t", transport: host))
        let tab = WorkspaceTab(kind: .terminal, projectID: "p", resourceID: "pty-settings", title: "Terminal")
        workspace.open(tab)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 700)
        window.rootViewController = UIHostingController(rootView: TerminalTabView(tab: tab)
            .environment(workspace)
            .environment(\.scenePhase, .active)
            .defaultAppStorage(defaults))
        window.makeKeyAndVisible()
        defer { workspace.close(tab.id); window.isHidden = true; window.rootViewController = nil }
        let session = workspace.terminalSession(for: tab)
        await settle { session.currentRenderer?.font.pointSize == 20 }
        let renderer = try XCTUnwrap(session.currentRenderer)
        XCTAssertEqual(renderer.font.pointSize, 20, "the chosen size, whatever the text size")
        XCTAssertEqual(renderer.getTerminal().options.cursorStyle, .steadyBar)
        XCTAssertNil(renderer.inputAccessoryView, "no key bar")
        XCTAssertNotNil(renderer.keyBar, "kept for when it is shown again")
        let large = renderer.getTerminal().cols
        await settle { host.resizes.last?.cols == large }
        XCTAssertEqual(host.resizes.last?.cols, large, "the host's terminal has the grid's size")

        defaults.set(12.0, forKey: TerminalSettings.fontSizeKey)
        defaults.set(TerminalSettings.Cursor.underline.rawValue, forKey: TerminalSettings.cursorKey)
        defaults.set(true, forKey: TerminalSettings.keyBarKey)
        await settle { renderer.font.pointSize == 12 }
        XCTAssertEqual(renderer.font.pointSize, 12)
        XCTAssertGreaterThan(renderer.getTerminal().cols, large, "a smaller size fits more columns")
        await settle { host.resizes.last?.cols == renderer.getTerminal().cols }
        XCTAssertEqual(host.resizes.last?.cols, renderer.getTerminal().cols, "and the host's terminal follows")
        XCTAssertEqual(renderer.getTerminal().options.cursorStyle, .steadyUnderline)
        XCTAssertTrue(renderer.inputAccessoryView === renderer.keyBar, "the key bar is back")
        XCTAssertTrue(contains(window, renderer))
    }

    /// Vibrate on Bell: off, a bell plays nothing (SwiftTerm's own vibration is replaced); on, at most once a second.
    func testTheBellVibratesOnlyWhenAskedAndAtMostOnceASecond() {
        var played = 0
        let link = TerminalRendererLink(send: { _ in }, sendProtocolReply: { _ in }, resize: { _, _ in })
        link.playBell = { played += 1 }
        let view = AgentTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        view.terminalDelegate = link
        view.feed(byteArray: Array("\u{7}".utf8)[...])
        XCTAssertEqual(played, 0, "off by default")
        link.bellVibrates = true
        view.feed(byteArray: Array("\u{7}\u{7}\u{7}".utf8)[...])
        XCTAssertEqual(played, 1, "a burst plays once")
    }

    // MARK: Surviving a rebuilt view

    private func mount(_ workspace: WorkspaceModel, tab: WorkspaceTab, in scene: UIWindowScene) -> UIWindow {
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 700)
        window.rootViewController = UIHostingController(rootView: TerminalTabView(tab: tab)
            .environment(workspace)
            .environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        return window
    }

    private func settle(_ seconds: Double = 5, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func screenText(_ view: AgentTerminalView) -> String {
        let terminal = view.getTerminal()
        return (0..<terminal.rows).map { row in
            (0..<terminal.cols).compactMap { terminal.getCharData(col: $0, row: row)?.getCharacter() }.map(String.init).joined()
        }.joined(separator: "\n")
    }

    private func contains(_ view: UIView, _ target: UIView) -> Bool {
        view === target || view.subviews.contains { contains($0, target) }
    }

    /// The surface view is torn down and built again, as a split view's detail column does. The same
    /// session serves the new view, the same SwiftTerm renderer (with its screen) is mounted in it,
    /// and the host is not asked to replay the output.
    func testRebuiltTerminalViewKeepsItsSessionAndRenderer() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let suite = "terminal-rebuild-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = TerminalHost(screen: "hello-from-host\r\n")
        let workspace = WorkspaceModel(defaults: defaults)
        let client = APIClient(address: try ServerAddress(validating: "https://terminal.example"), token: "t", transport: host)
        workspace.attach(hostID: "terminal-host", identity: ConnectionIdentity(host: "https://terminal.example", deviceID: "d"), client: client)
        let tab = WorkspaceTab(kind: .terminal, projectID: "p", resourceID: "pty-1", title: "Terminal")
        workspace.open(tab)

        let first = mount(workspace, tab: tab, in: scene)
        let session = workspace.terminalSession(for: tab)
        await settle { session.currentRenderer.map { screenText($0).contains("hello-from-host") } == true && session.packets.isEmpty }
        let renderer = try XCTUnwrap(session.currentRenderer)
        XCTAssertTrue(screenText(renderer).contains("hello-from-host"), "The first view drew the host's output")
        XCTAssertTrue(contains(first, renderer))
        // The opening ends once the host metadata answered and the terminal laid out and drew its first output.
        await workspace.refreshProjects()
        await settle { workspace.presentationReady }
        workspace.completePresentation(try XCTUnwrap(workspace.presentationTicket))
        XCTAssertFalse(workspace.presentationPending)

        // Tear the surface down completely, then build a new one.
        first.rootViewController = nil
        first.isHidden = true
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(renderer.window, "The torn-down view let go of the renderer")
        let second = mount(workspace, tab: tab, in: scene)
        await settle { session.currentRenderer?.window === second }

        XCTAssertTrue(workspace.terminalSession(for: tab) === session, "The rebuilt view found the same session")
        XCTAssertTrue(session.currentRenderer === renderer, "The rebuilt view mounted the same renderer")
        XCTAssertEqual(session.renderersMade, 1)
        XCTAssertTrue(contains(second, renderer))
        XCTAssertTrue(screenText(renderer).contains("hello-from-host"), "The renderer kept its screen")
        XCTAssertEqual(host.cursors.filter { $0 == "0" }.count, 1, "The rebuilt view resumed from the cursor instead of replaying")

        // Input still reaches the host through the session's queue.
        session.enqueue(Data("ls\r".utf8))
        await settle { !host.received.isEmpty }
        XCTAssertEqual(host.received, [Data("ls\r".utf8)])

        // Closing the tab ends the session and releases the renderer; the host's process is untouched.
        workspace.close(tab.id)
        XCTAssertNil(session.currentRenderer)
        XCTAssertNil(renderer.superview)
        second.isHidden = true
    }
}
