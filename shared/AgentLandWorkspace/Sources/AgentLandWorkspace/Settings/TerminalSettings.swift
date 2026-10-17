import Foundation
#if os(iOS)
import SwiftTerm
#endif

/// The terminal's settings on iPhone and iPad (Settings → Terminal), saved on this device as user defaults. Each
/// default keeps the terminal as it was before the setting existed; the Mac reads none of them.
public enum TerminalSettings {
    /// The terminal's text size in points, apart from the app's text size; 0 (the default) follows the text size
    /// as before (`TerminalTabView`'s automatic size).
    public static let fontSizeKey = "agentland.terminal.fontSize"
    public static let automaticFontSize = 0.0
    /// The sizes a chosen text size can take.
    public static let fontSizes: ClosedRange<Double> = 9...24
    /// The size a chosen text size starts at when the person stops following the text size.
    public static let firstChosenFontSize = 15.0
    /// The cursor's shape (`Cursor`), always steady: a blinking cursor keeps UIKit from reaching an idle frame.
    public static let cursorKey = "agentland.terminal.cursor"
    /// AgentLand's key bar above the keyboard (Esc, Tab, Ctrl, arrows, Hide keyboard); on by default.
    public static let keyBarKey = "agentland.terminal.keyBar"
    public static let keyBarDefault = true
    /// A bell (BEL) from the program plays a haptic; off by default, as before.
    public static let bellHapticKey = "agentland.terminal.bellHaptic"
    public static let bellHapticDefault = false

    /// The text size to draw at: the chosen one, kept within `fontSizes`, or the automatic one.
    public static func fontSize(chosen: Double, automatic: CGFloat) -> CGFloat {
        guard chosen > 0 else { return automatic }
        return CGFloat(min(max(chosen, fontSizes.lowerBound), fontSizes.upperBound))
    }

    public enum Cursor: String, CaseIterable, Identifiable, Sendable {
        case block, underline, bar
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .block: "Block"
            case .underline: "Underline"
            case .bar: "Bar"
            }
        }
        var symbol: String {
            switch self {
            case .block: "rectangle.fill"
            case .underline: "minus"
            case .bar: "character.cursor.ibeam"
            }
        }
        #if os(iOS)
        /// SwiftTerm's steady style of this shape.
        var style: CursorStyle {
            switch self {
            case .block: .steadyBlock
            case .underline: .steadyUnderline
            case .bar: .steadyBar
            }
        }
        #endif
    }
}

/// Bells come in bursts (a shell's tab completion, a program's error loop): the haptic plays at most once a second.
struct TerminalBellThrottle {
    static let interval: TimeInterval = 1
    private var last: Date?

    mutating func allows(at now: Date) -> Bool {
        if let last, now.timeIntervalSince(last) < Self.interval { return false }
        last = now
        return true
    }
}
