import SwiftUI

/// Speaks short status messages to VoiceOver users. Components read it from the environment, so tests
/// and previews can record announcements instead of posting them.
public struct AgentLandAnnouncer: Sendable {
    public enum Priority: Sendable {
        /// Queued behind current speech.
        case normal
        /// Interrupts current speech: errors, lost connections.
        case high
    }

    private let post: @MainActor @Sendable (String, Priority) -> Void

    public init(_ post: @escaping @MainActor @Sendable (String, Priority) -> Void) {
        self.post = post
    }

    @MainActor
    public func announce(_ message: String, priority: Priority = .normal) {
        post(message, priority)
    }

    /// Posts an accessibility announcement (VoiceOver on iPhone, iPad and Mac).
    public static let voiceOver = AgentLandAnnouncer { message, priority in
        var string = AttributedString(message)
        string.accessibilitySpeechAnnouncementPriority = priority == .high ? .high : .default
        AccessibilityNotification.Announcement(string).post()
    }
}

public extension EnvironmentValues {
    @Entry var agentLandAnnouncer: AgentLandAnnouncer = .voiceOver
}
