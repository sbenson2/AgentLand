import Foundation

/// The switches iPhone and iPad Settings show: each turns its kinds'
/// subscriptions on or off together.
public enum NoticeGroup: String, CaseIterable, Codable, Sendable, Identifiable {
    /// A reply finished or failed.
    case replies
    /// An agent needs an approval or an answer.
    case approvals

    public var id: String { rawValue }

    public var kinds: [NoticeKind] {
        switch self {
        case .replies: [.turnFinished, .turnFailed]
        case .approvals: [.approvalNeeded, .questionNeeded]
        }
    }

    public init(kind: NoticeKind) {
        self = Self.allCases.first { $0.kinds.contains(kind) } ?? .replies
    }

    /// The groups with at least one of `kinds`. A group whose subscriptions
    /// are only partly on counts as on; the next save completes it.
    public static func groups(of kinds: some Sequence<NoticeKind>) -> Set<NoticeGroup> {
        Set(kinds.map(NoticeGroup.init(kind:)))
    }

    /// Every kind of `groups`, in `NoticeKind.allCases` order.
    public static func kinds(of groups: some Sequence<NoticeGroup>) -> [NoticeKind] {
        let groups = Set(groups)
        return NoticeKind.allCases.filter { groups.contains(NoticeGroup(kind: $0)) }
    }
}
