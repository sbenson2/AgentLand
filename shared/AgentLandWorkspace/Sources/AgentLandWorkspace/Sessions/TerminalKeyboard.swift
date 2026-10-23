import CoreGraphics

/// Return on the on-screen keyboard sends the Return and then puts the keyboard and its key bar away, in every
/// terminal, shells included (owner, 2026-10-23: "when sending a messing in terminal the keyboard should close"). A
/// hardware keyboard's Return keeps typing, and so does a Return the latched Control makes another key; the key bar's
/// own keys never close it, and a tap on the terminal brings the keyboard back.
enum TerminalReturnKey {
    /// The on-screen keyboard's keys show when the keyboard is at least this much taller than the key bar on it; with
    /// a hardware keyboard only the bar (and on iPad its shortcuts) is on screen.
    static let onScreenKeysHeight: CGFloat = 100

    static func closesKeyboard(text: String, keyboardHeight: CGFloat, keyBarHeight: CGFloat, hardwareKeyboard: Bool,
                               controlLatched: Bool) -> Bool {
        text == "\n" && !hardwareKeyboard && !controlLatched && keyboardHeight - keyBarHeight >= onScreenKeysHeight
    }
}
