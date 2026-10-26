@preconcurrency import AVFoundation
@preconcurrency import Speech
import Synchronization
import SwiftUI
import AgentLandBranding
import AgentLandDesign

/// Speech-to-text for the composer, on the device with the system's SpeechAnalyzer. Words show in the draft as
/// they are spoken and settle as each phrase is finalized; a long dictation with pauses keeps every phrase (the old
/// recognizer started over after a pause). Nothing is sent until the person sends the draft.
@MainActor
public final class ChatDictation: ObservableObject {
    public enum Phase: Equatable { case idle, starting, listening, finishing }
    @Published public private(set) var phase: Phase = .idle
    @Published public var problem: String?
    /// When listening began, for the composer's running time.
    @Published public private(set) var listeningSince: Date?
    /// The microphone's level for the waveform. It is read each frame, never published, so the composer doesn't
    /// redraw with the voice.
    public let meter = ChatDictationMeter()

    private var engine: AVAudioEngine?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var recognizerEnded = false
    private var results: Task<Void, Never>?
    private var finishing: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []
    private var transcript = ChatDictationTranscript(prefix: "")
    private var update: (@MainActor (String) -> Void)?
    private var generation = 0

    public init() {}

    public var isActive: Bool { phase != .idle }

    /// Appends recognized speech after `prefix`; `update` receives the whole draft. `vocabulary` names words the
    /// person is likely to say (the agent's name), so they come out spelled right.
    public func start(prefix: String, vocabulary: [String] = [], update: @escaping @MainActor (String) -> Void) async {
        guard phase == .idle else { return }
        problem = nil
        phase = .starting
        generation += 1
        let current = generation
        transcript = ChatDictationTranscript(prefix: prefix)
        guard await Self.authorized() else {
            fail("Allow Microphone and Speech Recognition for AgentLand in Settings to dictate.")
            return
        }
        // Stopping while a permission prompt or the first model download was open cancels this start.
        guard current == generation else { return }
        let words = vocabulary + Self.vocabulary
        let analysis = await Self.analysis(vocabulary: words)
        guard current == generation else {
            if let analysis { await analysis.analyzer.cancelAndFinishNow() }
            return
        }
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers, .allowBluetoothHFP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif
            let engine = AVAudioEngine()
            let microphone = engine.inputNode.outputFormat(forBus: 0)
            guard microphone.sampleRate > 0, microphone.channelCount > 0 else {
                fail("No microphone is available.")
                return
            }
            let sink: DictationTap.Sink
            var inputs: AsyncStream<AnalyzerInput>?
            if let analysis {
                guard let converter = AVAudioConverter(from: microphone, to: analysis.format) else {
                    fail("No microphone is available.")
                    return
                }
                let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
                inputs = stream
                sink = .analyzer(converter: converter, format: analysis.format, input: input)
                self.input = input
                self.analyzer = analysis.analyzer
                results = Task { [weak self] in
                    do {
                        try await analysis.transcriber.results { text, isFinal in
                            self?.receive(text, isFinal: isFinal, generation: current)
                        }
                    } catch {
                        // A recognizer that ends by itself keeps what it heard.
                        guard let self, current == self.generation, self.phase == .listening else { return }
                        self.endedEarly()
                    }
                }
            } else {
                // Where SpeechAnalyzer has no model (the simulator, some devices and languages), the older recognizer.
                guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
                    fail("Dictation isn't available right now.")
                    return
                }
                let request = SFSpeechAudioBufferRecognitionRequest()
                request.shouldReportPartialResults = true
                request.addsPunctuation = true
                request.contextualStrings = words
                if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
                sink = .recognizer(request)
                self.request = request
                recognition = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
                    let text = result?.bestTranscription.formattedString
                    let isFinal = result?.isFinal == true
                    let failed = error != nil
                    let ended = failed || isFinal
                    Task { @MainActor in
                        guard let self, current == self.generation else { return }
                        if let text { self.receive(text, isFinal: isFinal, generation: current, running: true) }
                        guard ended else { return }
                        self.recognizerEnded = true
                        if self.phase == .listening { failed ? self.endedEarly() : self.stop() }
                    }
                }
            }
            let tap = DictationTap(sink: sink, meter: meter)
            meter.reset()
            // System callbacks here are Sendable, so not main-actor isolated: the tap runs on the audio engine's
            // realtime queue, and the isolation check trapped there on a physical iPhone (2026-10-07).
            engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: microphone) { @Sendable buffer, _ in tap.process(buffer) }
            engine.prepare()
            try engine.start()
            // Kept before the analyzer starts, so a Stop while it starts turns the microphone off.
            self.engine = engine
            self.update = update
            if let analysis, let inputs { try await analysis.analyzer.start(inputSequence: inputs) }
            guard current == generation else { return }
            observeInterruptions(engine)
            listeningSince = .now
            phase = .listening
        } catch {
            guard current == generation else { return }
            fail("Dictation couldn't start.")
        }
    }

    /// Stops listening and keeps what was heard: the words still settling are finalized first, waiting at most
    /// two seconds. Send and the Stop button use it.
    public func finish() async {
        switch phase {
        case .idle: return
        case .starting: stop(); return
        case .finishing: await finishing?.value; return
        case .listening: break
        }
        phase = .finishing
        stopAudio()
        let analyzer = self.analyzer, results = self.results
        let task = Task { @MainActor [weak self] in
            if let analyzer {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try? await analyzer.finalizeAndFinishThroughEndOfInput()
                        await results?.value
                    }
                    group.addTask { try? await Task.sleep(for: .seconds(2)) }
                    await group.next()
                    group.cancelAll()
                }
            } else {
                // The older recognizer settles its last words once its audio has ended.
                for _ in 0..<40 {
                    guard self?.recognizerEnded == false else { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }
        finishing = task
        await task.value
        stop()
    }

    /// Stops at once, keeping the draft as it is (a word still settling stays as last heard).
    public func stop() {
        generation += 1
        stopAudio()
        results?.cancel()
        results = nil
        finishing = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
        recognition?.cancel()
        recognition = nil
        recognizerEnded = false
        update = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        listeningSince = nil
        phase = .idle
    }

    /// The person changed the draft. Until the first words come, dictation goes on after the new text (tapping the
    /// microphone can commit the keyboard's autocorrection); once it has written, typing stops it, as the keyboard's
    /// own dictation does, and what was heard stays.
    public func draftEdited(_ text: String) {
        switch phase {
        case .idle: return
        case .starting: transcript = ChatDictationTranscript(prefix: text)
        case .listening where transcript.isEmpty: transcript = ChatDictationTranscript(prefix: text)
        case .listening, .finishing: stop()
        }
    }

    /// `running`: the older recognizer's report, the whole run so far.
    private func receive(_ text: String, isFinal: Bool, generation current: Int, running: Bool = false) {
        guard current == generation, let update else { return }
        if running { transcript.receiveRunning(text, isFinal: isFinal) } else { transcript.receive(text, isFinal: isFinal) }
        update(transcript.draft)
    }

    private func stopAudio() {
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        input?.finish()
        input = nil
        request?.endAudio()
        request = nil
    }

    /// The recognizer stopped by itself: what it heard stays, and when it heard nothing the person is told.
    private func endedEarly() {
        transcript.isEmpty ? fail("Dictation didn’t hear anything. Try again.") : stop()
    }

    private func fail(_ problem: String) {
        stop()
        self.problem = problem
    }

    /// A call, Siri or a microphone plugged in or out ends the dictation, keeping what was heard.
    private func observeInterruptions(_ engine: AVAudioEngine) {
        var sources: [(Notification.Name, AnyObject?)] = [(.AVAudioEngineConfigurationChange, engine)]
        #if os(iOS)
        sources.append((AVAudioSession.interruptionNotification, nil))
        #endif
        observers = sources.map { name, object in
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.finish() }
            }
        }
    }

    /// Words a coding chat often holds that general speech models tend to spell otherwise.
    private static let vocabulary = ["Claude Code", "Codex", "SwiftUI", "Xcode", "README", "JSON", "API", "repo",
                                     "commit", "refactor", "TypeScript", "JavaScript", "npm", "Git", "GitHub"]

    /// SpeechAnalyzer, ready with its on-device model, or nil where the device, the language or the simulator lacks
    /// one. The first dictation in a language downloads its model.
    private static func analysis(vocabulary: [String]) async -> Analysis? {
        guard let transcriber = await Transcriber.make() else { return nil }
        do {
            if let download = try await AssetInventory.assetInstallationRequest(supporting: [transcriber.module]) {
                try await download.downloadAndInstall()
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber.module]) else { return nil }
            // A model kept warm a while after use makes the next dictation start at once.
            let analyzer = SpeechAnalyzer(modules: [transcriber.module],
                                          options: .init(priority: .userInitiated, modelRetention: .lingering))
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            // The words only help; a model that takes none still dictates.
            try? await analyzer.setContext(context)
            try await analyzer.prepareToAnalyze(in: format)
            return Analysis(transcriber: transcriber, analyzer: analyzer, format: format)
        } catch {
            return nil
        }
    }

    private struct Analysis {
        let transcriber: Transcriber
        let analyzer: SpeechAnalyzer
        let format: AVAudioFormat
    }

    private static func authorized() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            // Sendable, like the other callbacks in `start`: TCC answers on a background queue.
            SFSpeechRecognizer.requestAuthorization { @Sendable status in continuation.resume(returning: status) }
        }
        guard speech == .authorized else { return false }
        #if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
        #endif
    }
}

/// The speech model: SpeechTranscriber, made for long, natural speech, where the device and language have it;
/// otherwise DictationTranscriber, the keyboard's dictation model, with punctuation.
private enum Transcriber: Sendable {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)

    static func make() async -> Transcriber? {
        if SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) {
            return .speech(SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                             reportingOptions: [.volatileResults, .fastResults], attributeOptions: []))
        }
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: .current) else { return nil }
        return .dictation(DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                               reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: []))
    }

    var module: any SpeechModule {
        switch self {
        case .speech(let module): module
        case .dictation(let module): module
        }
    }

    /// Hands each result's text to `receive` on the main actor, until the analyzer finishes.
    func results(_ receive: @escaping @MainActor (String, Bool) -> Void) async throws {
        switch self {
        case .speech(let module):
            for try await result in module.results { await receive(String(result.text.characters), result.isFinal) }
        case .dictation(let module):
            for try await result in module.results { await receive(String(result.text.characters), result.isFinal) }
        }
    }
}

/// The draft while dictating: what was there before, the phrases already settled, and the words still settling
/// (volatile), which each new result replaces.
struct ChatDictationTranscript: Equatable {
    let prefix: String
    private(set) var settled = ""
    private(set) var settling = ""

    init(prefix: String) {
        self.prefix = prefix.isEmpty || prefix.last?.isWhitespace == true ? prefix : prefix + " "
    }

    mutating func receive(_ text: String, isFinal: Bool) {
        if isFinal {
            settled = Self.join(settled, text)
            settling = ""
        } else {
            settling = text
        }
    }

    /// The older recognizer reports the whole run so far each time, and on some systems starts over after a pause: a
    /// report that doesn't go on from the last one settles the last one first.
    mutating func receiveRunning(_ text: String, isFinal: Bool) {
        let first = { (text: String) in text.split(whereSeparator: \.isWhitespace).first?.lowercased() }
        if !settling.isEmpty, text.count + 4 < settling.count, first(text) != first(settling) {
            settled = Self.join(settled, settling)
            settling = ""
        }
        receive(text, isFinal: isFinal)
    }

    var draft: String { prefix + Self.join(settled, settling) }

    /// Nothing heard yet.
    var isEmpty: Bool { settled.isEmpty && settling.isEmpty }

    /// Two runs of speech with one space between them, none before punctuation.
    static func join(_ first: String, _ second: String) -> String {
        let first = first.trimmingCharacters(in: .whitespaces)
        let second = second.trimmingCharacters(in: .whitespaces)
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        if let mark = second.unicodeScalars.first, CharacterSet.punctuationCharacters.contains(mark), !"(\"'“‘".unicodeScalars.contains(mark) {
            return first + second
        }
        return first + " " + second
    }
}

/// The microphone's recent levels, written on the audio thread and read by the waveform each frame.
public final class ChatDictationMeter: Sendable {
    struct Sample: Sendable { let time: TimeInterval; let level: Double }
    /// How long a bar of the waveform stands for.
    static let interval: TimeInterval = 0.05
    private let samples = Mutex<[Sample]>([])

    func record(_ levels: [Double], endingAt end: TimeInterval) {
        samples.withLock { samples in
            for (index, level) in levels.enumerated() {
                samples.append(Sample(time: end - Double(levels.count - 1 - index) * Self.interval, level: level))
            }
            if samples.count > 120 { samples.removeFirst(samples.count - 120) }
        }
    }

    func reset() { samples.withLock { $0.removeAll() } }

    var recent: [Sample] { samples.withLock { $0 } }
}

/// The input tap: measures each buffer for the waveform and hands it on, converted to SpeechAnalyzer's format or
/// as it is to the older recognizer.
private final class DictationTap: @unchecked Sendable {
    enum Sink {
        case analyzer(converter: AVAudioConverter, format: AVAudioFormat, input: AsyncStream<AnalyzerInput>.Continuation)
        case recognizer(SFSpeechAudioBufferRecognitionRequest)
    }

    private let sink: Sink
    private let meter: ChatDictationMeter

    init(sink: Sink, meter: ChatDictationMeter) {
        self.sink = sink; self.meter = meter
        if case .analyzer(let converter, _, _) = sink { converter.primeMethod = .none }
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        meter.record(Self.levels(buffer), endingAt: Date.timeIntervalSinceReferenceDate)
        switch sink {
        case .analyzer(let converter, let format, let input):
            if let converted = Self.convert(buffer, with: converter, to: format) { input.yield(AnalyzerInput(buffer: converted)) }
        case .recognizer(let request):
            request.append(buffer)
        }
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var handed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if handed {
                status.pointee = .noDataNow
                return nil
            }
            handed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && converted.frameLength > 0 ? converted : nil
    }

    /// One level from 0 to 1 per waveform bar's worth of audio (`ChatDictationMeter.interval`), from its loudness.
    private static func levels(_ buffer: AVAudioPCMBuffer) -> [Double] {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return [] }
        let frames = Int(buffer.frameLength)
        let chunk = max(1, Int(buffer.format.sampleRate * ChatDictationMeter.interval))
        return stride(from: 0, to: frames, by: chunk).map { start in
            let end = min(frames, start + chunk)
            var sum: Float = 0
            for index in start..<end { sum += channel[index] * channel[index] }
            let rms = (sum / Float(end - start)).squareRoot()
            // -50 dB is silence, 0 dB the loudest.
            let decibels = 20 * log10(max(rms, 0.000_01))
            return min(1, max(0, Double(decibels + 50) / 50))
        }
    }
}

/// The waveform while listening: the newest level enters at the trailing edge and the bars glide toward the
/// leading one at the display's own rate, whatever pace the microphone delivers its buffers at.
struct ChatDictationWaveform: View {
    let meter: ChatDictationMeter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.25 : nil)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let pitch: CGFloat = 5
                let width: CGFloat = 2.5
                // Buffers arrive about a tenth of a second late: the bars enter just past the edge.
                let lag = 0.12
                let color = AgentLandColor.text.color
                // A faint dotted line, so it reads as listening before the first word.
                var dot = size.width - pitch
                while dot > 0 {
                    let rect = CGRect(x: dot, y: (size.height - width) / 2, width: width, height: width)
                    context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.2)))
                    dot -= pitch
                }
                for sample in meter.recent {
                    let x = size.width - CGFloat((now - lag - sample.time) / ChatDictationMeter.interval) * pitch
                    guard x > -width, x < size.width else { continue }
                    let height = max(width, CGFloat(sample.level) * size.height)
                    let bar = CGRect(x: x, y: (size.height - height) / 2, width: width, height: height)
                    // The oldest bars fade out toward the leading edge.
                    let opacity = min(1, max(0.25, Double(x / (size.width * 0.3))))
                    context.fill(Path(roundedRect: bar, cornerRadius: width / 2), with: .color(color.opacity(opacity)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

public struct ChatDictationButton: View {
    @ObservedObject var dictation: ChatDictation
    let draft: () -> String
    let vocabulary: [String]
    let update: @MainActor (String) -> Void

    public init(dictation: ChatDictation, draft: @escaping () -> String, vocabulary: [String] = [],
                update: @escaping @MainActor (String) -> Void) {
        self.dictation = dictation; self.draft = draft; self.vocabulary = vocabulary; self.update = update
    }

    public var body: some View {
        Button {
            switch dictation.phase {
            case .idle: Task { await dictation.start(prefix: draft(), vocabulary: vocabulary, update: update) }
            case .starting: dictation.stop()
            case .listening: Task { await dictation.finish() }
            case .finishing: break
            }
        } label: {
            // The microphone turns into Stop at once, so a tap is answered before the microphone is ready.
            Image(systemName: dictation.isActive ? "stop.circle.fill" : "mic")
                .contentTransition(.symbolEffect(.replace))
                .animation(.smooth(duration: 0.2), value: dictation.isActive)
                .font(dictation.isActive ? .title2 : .body)
                .foregroundStyle(dictation.isActive ? AgentLandColor.danger.color : AgentLandColor.textSecondary.color)
                .frame(minWidth: ChatMetrics.target, minHeight: ChatMetrics.target)
                .contentShape(Rectangle())
        }
        .chatBorderlessButton()
        .sensoryFeedback(trigger: dictation.phase) { old, new in
            if new == .listening { return .start }
            if new == .idle && old != .idle { return .stop }
            return nil
        }
        .accessibilityLabel(dictation.isActive ? "Stop Dictation" : "Dictate")
        .accessibilityValue(dictation.phase == .listening ? "Listening" : "")
        .accessibilityIdentifier("chatDictate")
        .help(dictation.isActive ? "Stop Dictation" : "Dictate")
    }
}
