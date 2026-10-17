import Foundation
import Observation
import SwiftUI
import SwiftTerm
import AgentLandCore
import AgentLandDesign

/// Output for the replay renderer, in order. A new generation starts a fresh terminal.
public struct TerminalReplayFeed: Equatable, Sendable {
    public var generation = 0
    public var chunks: [Data] = []
}

/// A terminal log shown a window at a time (2 MiB by default), newest first.
/// Ranges come from `TerminalLogCache`: this device when saved, otherwise the
/// host. Terminal mode replays the raw bytes; Text mode shows the host's
/// ANSI-free text (`format=text`).
@MainActor @Observable
public final class TerminalLogViewerModel {
    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        case terminal, text
        public var id: String { rawValue }
        public var label: String { self == .terminal ? "Terminal" : "Text" }
        var format: ArchiveTerminalLogFormat { self == .terminal ? .raw : .text }
    }

    public enum Phase: Equatable, Sendable {
        case loading
        case ready
        case failed(String)
    }

    public let log: ArchivedTerminalLog
    public private(set) var mode: Mode = .terminal
    public private(set) var phase: Phase = .loading
    /// Raw offsets of the window shown.
    public private(set) var windowStart: Int64 = 0
    public private(set) var windowEnd: Int64 = 0
    /// The log's size as the host last reported it.
    public private(set) var size: Int64
    public private(set) var status: String
    /// The host said the terminal ended and the window reaches its end.
    public private(set) var reachedEnd = false
    public private(set) var feed = TerminalReplayFeed()
    public private(set) var text = ""
    /// A range after the first could not be loaded.
    public private(set) var notice: String?
    public private(set) var loading = false

    public let windowLength: Int64
    private let cache: TerminalLogCache
    @ObservationIgnored private var fetcher: (any TerminalLogFetching)?
    @ObservationIgnored private var token = UUID()

    public init(log: ArchivedTerminalLog, cache: TerminalLogCache, fetcher: (any TerminalLogFetching)?, windowLength: Int64 = 2 << 20) {
        self.log = log
        self.cache = cache
        self.fetcher = fetcher
        size = log.bytes
        status = log.status
        let chunk = Int64(cache.chunkLength)
        self.windowLength = max(chunk, (windowLength / chunk) * chunk)
    }

    public var isRunning: Bool { status == "running" }
    public var canShowEarlier: Bool { windowStart > 0 }
    public var canShowLater: Bool { windowEnd < size }
    public var lines: [Substring] { text.split(separator: "\n", omittingEmptySubsequences: false) }

    /// A new client, or none while offline (saved ranges still load).
    public func update(fetcher: (any TerminalLogFetching)?) { self.fetcher = fetcher }

    /// Opens the newest window.
    public func load() async { await loadWindow(from: align(size - windowLength)) }

    public func setMode(_ mode: Mode) async {
        guard mode != self.mode else { return }
        self.mode = mode
        await loadWindow(from: windowStart)
    }

    public func showEarlier() async { await loadWindow(from: align(windowStart - windowLength)) }
    public func showLater() async { await loadWindow(from: align(windowEnd)) }
    public func showLatest() async { await loadWindow(from: align(size - windowLength)) }

    /// Reads what a running terminal wrote after the window, without starting over.
    public func refresh() async {
        let token = UUID()
        self.token = token
        loading = true
        await append(until: windowEnd + windowLength, token: token)
        if token == self.token { loading = false }
    }

    private func align(_ offset: Int64) -> Int64 {
        let chunk = Int64(cache.chunkLength)
        return max(0, offset) / chunk * chunk
    }

    private func loadWindow(from start: Int64) async {
        let token = UUID()
        self.token = token
        loading = true
        phase = .loading
        notice = nil
        feed = TerminalReplayFeed(generation: feed.generation + 1)
        text = ""
        windowStart = start
        windowEnd = start
        reachedEnd = false
        await append(until: start + windowLength, token: token)
        if token == self.token { loading = false }
    }

    private func append(until limit: Int64, token: UUID) async {
        var offset = windowEnd
        do {
            while offset < limit {
                let chunk = try await cache.chunk(of: log, at: offset, format: mode.format, fetcher: fetcher)
                guard token == self.token else { return }
                size = max(size, chunk.size)
                if !chunk.status.isEmpty { status = chunk.status }
                if !chunk.data.isEmpty {
                    switch mode {
                    case .terminal: feed.chunks.append(chunk.data)
                    case .text: text += String(decoding: chunk.data, as: UTF8.self)
                    }
                }
                reachedEnd = chunk.eof
                // A running log's end: nothing more yet.
                guard chunk.next > offset else { break }
                offset = chunk.next
                windowEnd = offset
                if chunk.eof || offset >= chunk.size { break }
            }
            phase = .ready
        } catch {
            guard token == self.token else { return }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if windowEnd > windowStart || !feed.chunks.isEmpty || !text.isEmpty {
                phase = .ready
                notice = message
            } else {
                phase = .failed(message)
            }
        }
    }
}

/// A read-only terminal log: a replay in a terminal that never takes the
/// keyboard, or plain text. Notes say when output was not recorded, when
/// earlier or later output is outside the window, and when it still runs.
public struct TerminalLogViewer: View {
    @State private var model: TerminalLogViewerModel
    private let reachable: Bool

    public init(model: TerminalLogViewerModel, reachable: Bool = true) {
        _model = State(initialValue: model)
        self.reachable = reachable
    }

    public init(log: ArchivedTerminalLog, cache: TerminalLogCache, fetcher: (any TerminalLogFetching)?, reachable: Bool = true) {
        self.init(model: TerminalLogViewerModel(log: log, cache: cache, fetcher: fetcher), reachable: reachable)
    }

    public var body: some View {
        VStack(spacing: 0) {
            notes
            content
        }
        .background(AgentLandColor.canvas)
        .navigationTitle(model.log.displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show As", selection: Binding(get: { model.mode }, set: { mode in Task { await model.setMode(mode) } })) {
                    ForEach(TerminalLogViewerModel.Mode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier("terminalLogMode")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Show Earlier Output", systemImage: "arrow.up.to.line") { Task { await model.showEarlier() } }
                        .disabled(!model.canShowEarlier)
                    Button("Show Later Output", systemImage: "arrow.down.to.line") { Task { await model.showLater() } }
                        .disabled(!model.canShowLater)
                    Button("Show Latest Output", systemImage: "arrow.down.to.line.compact") { Task { await model.showLatest() } }
                    if model.isRunning {
                        Button("Load New Output", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                            .disabled(!reachable)
                    }
                } label: {
                    Label("Output", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("terminalLogMenu")
            }
        }
        .task { await model.load() }
    }

    @ViewBuilder private var notes: some View {
        let log = model.log
        VStack(alignment: .leading, spacing: AgentLandSpacing.xSmall) {
            TerminalLogSummary(log: log, status: model.status, size: model.size)
            if log.gapBytes > 0 {
                Label("\(Self.bytes(log.gapBytes)) of output wasn’t recorded because your Mac was low on disk space.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(AgentLandColor.warning)
                    .accessibilityIdentifier("terminalLogGap")
            }
            if model.canShowEarlier {
                noteButton("\(Self.bytes(model.windowStart)) of earlier output isn’t shown.", action: "Show Earlier") {
                    Task { await model.showEarlier() }
                }
            }
            if model.isRunning {
                noteButton("Still running. Output recorded after this point isn’t shown yet.", action: "Load New Output") {
                    Task { await model.refresh() }
                }
                .disabled(!reachable)
            } else if model.canShowLater, model.phase == .ready {
                noteButton("\(Self.bytes(model.size - model.windowEnd)) of later output isn’t shown.", action: "Show Later") {
                    Task { await model.showLater() }
                }
            }
            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.circle")
                    .foregroundStyle(AgentLandColor.danger)
            }
        }
        .agentLandFont(.metadata)
        .foregroundStyle(AgentLandColor.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AgentLandSpacing.medium)
        .padding(.vertical, AgentLandSpacing.xSmall)
        .accessibilityElement(children: .contain)
    }

    private func noteButton(_ text: String, action: String, perform: @escaping () -> Void) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AgentLandSpacing.xSmall) {
                Text(text)
                Button(action: perform) { Text(action).minimumTapTarget() }.buttonStyle(.borderless)
            }
            VStack(alignment: .leading, spacing: AgentLandSpacing.xxSmall) {
                Text(text)
                Button(action: perform) { Text(action).minimumTapTarget() }.buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading where model.feed.chunks.isEmpty && model.text.isEmpty:
            ProgressView("Loading output…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailable("Output Unavailable", systemImage: "terminal", description: message)
        default:
            switch model.mode {
            case .terminal:
                if model.feed.chunks.isEmpty && model.phase == .ready {
                    ContentUnavailable("No Output", systemImage: "terminal", description: "Nothing was recorded in this part of the log.")
                } else {
                    TerminalReplayView(feed: model.feed)
                        .id(model.feed.generation)
                        .padding(.leading, AgentLandSpacing.xSmall)
                        .accessibilityIdentifier("terminalLogReplay")
                }
            case .text:
                TerminalLogText(lines: model.lines)
            }
        }
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(count, 0), countStyle: .file)
    }
}

/// Program, start, how it ended and its size.
struct TerminalLogSummary: View {
    let log: ArchivedTerminalLog
    let status: String
    let size: Int64

    var body: some View {
        let ended: String = switch (status, log.exitCode) {
        case ("running", _): "Running"
        case let (_, code?): "Exited with code \(code)"
        default: "Ended"
        }
        Text("\(log.programName) · \(log.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(ended) · \(TerminalLogViewer.bytes(size))")
            .accessibilityIdentifier("terminalLogSummary")
    }
}

/// The text form, one row per line, selectable.
struct TerminalLogText: View {
    let lines: [Substring]

    var body: some View {
        ScrollView([.vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line.isEmpty ? " " : String(line))
                        .agentLandFont(.code)
                        .foregroundStyle(AgentLandColor.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .textSelection(.enabled)
            .padding(AgentLandSpacing.medium)
        }
        .defaultScrollAnchor(.bottom)
        .accessibilityIdentifier("terminalLogText")
    }
}

// MARK: Replay renderer

#if os(iOS)
/// SwiftTerm's view that never becomes first responder: no keyboard, no key bar.
final class ReadOnlyTerminalView: TerminalView {
    override var canBecomeFirstResponder: Bool { false }
    override var canBecomeFocused: Bool { false }
}

struct TerminalReplayView: UIViewRepresentable {
    let feed: TerminalReplayFeed
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> TerminalReplayCoordinator { TerminalReplayCoordinator() }

    func makeUIView(context: Context) -> ReadOnlyTerminalView {
        let view = ReadOnlyTerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.inputAccessoryView = nil
        view.allowMouseReporting = false
        view.font = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
        applyColors(view)
        return view
    }

    func updateUIView(_ view: ReadOnlyTerminalView, context: Context) {
        applyColors(view)
        context.coordinator.render(feed, into: view)
    }

    private func applyColors(_ view: ReadOnlyTerminalView) {
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        view.nativeBackgroundColor = AgentLandColor.canvas.uiColor.resolvedColor(with: traits)
        view.nativeForegroundColor = AgentLandColor.text.uiColor.resolvedColor(with: traits)
        view.backgroundColor = view.nativeBackgroundColor
    }
}
#elseif os(macOS)
/// SwiftTerm's view behind a container that keeps clicks from giving it
/// keyboard focus; selection still works.
final class ReadOnlyTerminalContainer: NSView {
    let terminal = TerminalView(frame: .zero)

    override init(frame: NSRect) {
        super.init(frame: frame)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor), terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminal.topAnchor.constraint(equalTo: topAnchor), terminal.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { false }
    /// Clicks land on the container, never on the terminal.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) { terminal.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { terminal.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { terminal.mouseUp(with: event) }
    override func scrollWheel(with event: NSEvent) { terminal.scrollWheel(with: event) }
}

struct TerminalReplayView: NSViewRepresentable {
    let feed: TerminalReplayFeed

    func makeCoordinator() -> TerminalReplayCoordinator { TerminalReplayCoordinator() }

    func makeNSView(context: Context) -> ReadOnlyTerminalContainer {
        let container = ReadOnlyTerminalContainer(frame: .zero)
        let view = container.terminal
        view.terminalDelegate = context.coordinator
        view.allowMouseReporting = false
        view.font = NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
        view.nativeBackgroundColor = AgentLandColor.canvas.nsColor
        view.nativeForegroundColor = AgentLandColor.text.nsColor
        return container
    }

    func updateNSView(_ container: ReadOnlyTerminalContainer, context: Context) {
        context.coordinator.render(feed, into: container.terminal)
    }
}
#endif

/// Feeds new chunks a slice at a time on the main thread, and ignores every
/// reply the terminal would send: a replay has no program to answer.
@MainActor
final class TerminalReplayCoordinator: NSObject, TerminalViewDelegate {
    private var generation = -1
    private var fed = 0
    private var pending: [Data] = []
    private var feeding = false
    private weak var view: TerminalView?

    func render(_ feed: TerminalReplayFeed, into view: TerminalView) {
        self.view = view
        if feed.generation != generation {
            generation = feed.generation
            fed = 0
            pending = []
        }
        guard feed.chunks.count > fed else { return }
        pending.append(contentsOf: feed.chunks[fed...])
        fed = feed.chunks.count
        guard !feeding else { return }
        feeding = true
        let generation = generation
        // Not inside updateUIView: slices go out on later main-queue turns.
        Task { @MainActor [weak self] in
            while let self, self.generation == generation, !self.pending.isEmpty {
                let data = self.pending.removeFirst()
                var start = data.startIndex
                while start < data.endIndex {
                    let end = data.index(start, offsetBy: 64 << 10, limitedBy: data.endIndex) ?? data.endIndex
                    self.view?.feed(byteArray: Array(data[start..<end])[...])
                    start = end
                    await Task.yield()
                    guard self.generation == generation else { return }
                }
            }
            self?.feeding = false
        }
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    nonisolated func bell(source: TerminalView) {}
    nonisolated func clipboardCopy(source: TerminalView, content: Data) {}
    nonisolated func clipboardRead(source: TerminalView) -> Data? { nil }
    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
