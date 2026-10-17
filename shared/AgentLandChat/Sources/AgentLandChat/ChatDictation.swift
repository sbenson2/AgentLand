@preconcurrency import AVFoundation
@preconcurrency import Speech
import SwiftUI
import AgentLandBranding
import AgentLandDesign

/// Speech-to-text for the composer. Recognition stays on the device when the
/// system supports it; nothing is sent until the person sends the draft.
@MainActor
public final class ChatDictation: ObservableObject {
    public enum Phase: Equatable { case idle, starting, listening }
    @Published public private(set) var phase: Phase = .idle
    @Published public var problem: String?

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0

    public init() {}

    public var isActive: Bool { phase != .idle }

    /// Appends recognized speech after `prefix`; `update` receives the whole draft.
    public func start(prefix: String, update: @escaping @MainActor (String) -> Void) async {
        guard phase == .idle else { return }
        problem = nil
        phase = .starting
        generation += 1
        let current = generation
        guard await Self.authorized() else {
            finish(problem: "Allow Microphone and Speech Recognition for AgentLand in Settings to dictate.")
            return
        }
        // Stopping while the permission prompt was open cancels this start.
        guard current == generation, phase == .starting else { return }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            finish(problem: "Dictation isn't available right now.")
            return
        }
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                finish(problem: "No microphone is available.")
                return
            }
            let sink = AudioSink(request)
            // System callbacks here are Sendable, so not main-actor isolated: the tap runs on the audio engine's
            // realtime queue, and the isolation check trapped there on a physical iPhone (2026-10-07).
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in sink.append(buffer) }
            engine.prepare()
            try engine.start()
            self.engine = engine
            self.request = request
            let base = prefix.isEmpty || prefix.hasSuffix(" ") || prefix.hasSuffix("\n") ? prefix : prefix + " "
            task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let ended = error != nil || result?.isFinal == true
                Task { @MainActor in
                    guard let self, current == self.generation else { return }
                    if let text { update(base + text) }
                    if ended { self.stop() }
                }
            }
            phase = .listening
        } catch {
            finish(problem: "Dictation couldn't start.")
        }
    }

    public func stop() {
        generation += 1
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.finish()
        engine = nil
        request = nil
        task = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        phase = .idle
    }

    private func finish(problem: String) {
        stop()
        self.problem = problem
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

/// The recognition request accepts audio buffers from the capture thread.
private final class AudioSink: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest
    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }
}

public struct ChatDictationButton: View {
    @ObservedObject var dictation: ChatDictation
    let draft: () -> String
    let update: @MainActor (String) -> Void

    public init(dictation: ChatDictation, draft: @escaping () -> String, update: @escaping @MainActor (String) -> Void) {
        self.dictation = dictation; self.draft = draft; self.update = update
    }

    public var body: some View {
        Button {
            if dictation.isActive { dictation.stop() }
            else { Task { await dictation.start(prefix: draft(), update: update) } }
        } label: {
            Group {
                if dictation.phase == .starting { ProgressView().controlSize(.small) }
                else {
                    // While listening the filled mic pulses, the system's symbol effect (CH-09).
                    Image(systemName: dictation.phase == .listening ? "mic.fill" : "mic")
                        .symbolEffect(.pulse, options: .repeating, isActive: dictation.phase == .listening)
                }
            }
            .font(.body)
            .foregroundStyle(dictation.phase == .listening ? AgentLandColor.danger.color : AgentLandColor.textSecondary.color)
            .frame(minWidth: ChatMetrics.target, minHeight: ChatMetrics.target)
            .contentShape(Rectangle())
        }
        .chatBorderlessButton()
        .accessibilityLabel(dictation.isActive ? "Stop Dictation" : "Dictate")
        .accessibilityValue(dictation.phase == .listening ? "Listening" : "")
        .accessibilityIdentifier("chatDictate")
        .help(dictation.isActive ? "Stop Dictation" : "Dictate")
    }
}
