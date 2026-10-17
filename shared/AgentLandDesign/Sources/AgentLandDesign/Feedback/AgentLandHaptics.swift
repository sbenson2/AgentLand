import SwiftUI

/// The three haptics AgentLand plays, through SwiftUI's `sensoryFeedback`. The system skips them where
/// the device has no haptics or the user turned them off.
public enum AgentLandHaptic: String, CaseIterable, Sendable {
    /// A choice changed: a tab, a segment, a picker value.
    case selection
    /// Something finished well: a message sent, a file saved.
    case success
    /// Something needs attention: an approval is waiting, an action was refused.
    case warning

    public var feedback: SensoryFeedback {
        switch self {
        case .selection: .selection
        case .success: .success
        case .warning: .warning
        }
    }
}

public extension View {
    /// Plays `haptic` whenever `trigger` changes.
    func agentLandHaptic<T: Equatable>(_ haptic: AgentLandHaptic, trigger: T) -> some View {
        sensoryFeedback(haptic.feedback, trigger: trigger)
    }

    /// Plays `haptic` when `trigger` changes and `condition(old, new)` holds.
    func agentLandHaptic<T: Equatable>(_ haptic: AgentLandHaptic, trigger: T,
                                       condition: @escaping (_ oldValue: T, _ newValue: T) -> Bool) -> some View {
        sensoryFeedback(haptic.feedback, trigger: trigger, condition: condition)
    }
}
