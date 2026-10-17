import SwiftUI

/// A result or a refusal to show: what `noticePresentation` takes from a screen's own notice type.
public struct NoticeContent: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let message: String?
    public let tone: InlineNotice.Tone

    public init(id: UUID, _ title: String, message: String? = nil, tone: InlineNotice.Tone) {
        self.id = id
        self.title = title
        self.message = message
        self.tone = tone
    }

    /// Whether iPhone and iPad show it in the system's alert: a warning or an error, which the person reads and puts
    /// away. A success or plain information shows nothing beyond the screen's own state.
    public var alerts: Bool { tone == .warning || tone == .error }
}

public extension View {
    /// A screen's result or refusal, the native way on iPhone and iPad (owner's decision, 2026-10-06, "Native pattern"):
    /// a warning or an error in the system's alert, with the notice's own action (Try Again, Check) when it has one and
    /// OK; a success or plain information shows nothing, since the screen's state and haptic already say it, and is only
    /// announced to VoiceOver. `dismiss` clears the screen's notice once the alert has gone, or at once for a success.
    /// The Mac keeps `InlineNotice` over the content at `alignment`, a success going by itself after `successDuration`.
    func noticePresentation(_ notice: NoticeContent?, actionTitle: String? = nil, action: (() -> Void)? = nil,
                            identifiers: InlineNotice.Identifiers = .init(), alignment: Alignment = .top,
                            successDuration: Duration = .seconds(5), dismiss: @escaping () -> Void) -> some View {
        modifier(NoticePresentation(notice: notice, actionTitle: actionTitle, action: action, identifiers: identifiers,
                                    alignment: alignment, successDuration: successDuration, dismiss: dismiss))
    }
}

private struct NoticePresentation: ViewModifier {
    let notice: NoticeContent?
    let actionTitle: String?
    let action: (() -> Void)?
    let identifiers: InlineNotice.Identifiers
    let alignment: Alignment
    let successDuration: Duration
    let dismiss: () -> Void
    @Environment(\.agentLandAnnouncer) private var announcer

    func body(content: Content) -> some View {
        #if os(iOS)
        let alerted = notice?.alerts == true ? notice : nil
        content
            .alert(alerted?.title ?? "", isPresented: Binding(get: { alerted != nil }, set: { if !$0 { dismiss() } }),
                   presenting: alerted) { _ in
                if let actionTitle, let action {
                    Button(actionTitle) { dismiss(); action() }
                }
                Button("OK", role: .cancel) {}
            } message: { notice in
                if let message = notice.message { Text(message) }
            }
            .onChange(of: notice?.id, initial: true) { _, _ in
                // A success is heard, not shown.
                guard let notice, !notice.alerts else { return }
                announcer.announce([notice.title, notice.message].compactMap { $0 }.joined(separator: " "))
                dismiss()
            }
        #else
        content.overlay(alignment: alignment) {
            if let notice {
                InlineNotice(notice.title, message: notice.message, tone: notice.tone, actionTitle: actionTitle,
                             action: action, onDismiss: dismiss, identifiers: identifiers)
                    .frame(maxWidth: 520)
                    .padding(.horizontal, AgentLandSpacing.small)
                    .padding(alignment.vertical == .bottom ? .bottom : .top, AgentLandSpacing.xSmall)
                    .transition(.opacity)
                    .task(id: notice.id) {
                        // A confirmation goes away by itself; warnings and errors wait for the person.
                        guard !notice.alerts else { return }
                        try? await Task.sleep(for: successDuration)
                        if !Task.isCancelled { dismiss() }
                    }
            }
        }
        #endif
    }
}
