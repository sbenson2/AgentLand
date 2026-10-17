import Foundation

/// The kinds of notice the host issues (docs/HOST-API.md, "Presence and
/// notices"). Each kind has its own alert title and, on iPhone and iPad, its
/// own query subscription. The Mac drops kinds it does not know.
public enum NoticeKind: String, CaseIterable, Codable, Sendable {
    case turnFinished = "chat.turn.finished"
    case turnFailed = "chat.turn.failed"
    case approvalNeeded = "chat.approval.needed"
    case questionNeeded = "chat.question.needed"

    /// The String Catalog key of the alert title. The subscription names it
    /// in `titleLocalizationKey`, so the iOS app's `Localizable.xcstrings`
    /// must carry it (see `NoticeAlertText`).
    public var titleLocalizationKey: String { "notice.title.\(rawValue)" }

    /// The alert title in this process's language, from the package's catalog.
    public var title: String { NoticeAlertText.localized(titleLocalizationKey) }
}
