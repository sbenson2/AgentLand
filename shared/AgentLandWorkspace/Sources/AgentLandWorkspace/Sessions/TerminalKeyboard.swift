import CoreGraphics

/// How a terminal's rows follow the on-screen keyboard as it rises and goes (owner, 2026-10-23: "making it smooth and
/// instant when the kepboard appears and dissapears"). The renderer's height sets its rows, and a new row count
/// reaches the host's program, which repaints a network round trip later; a height animated with the keyboard would
/// also stretch the drawn rows. So the rows change once per move, the renderer slides with the keyboard at a fixed
/// height, and the rows already shown stay in place until the slide moves them:
/// - The keyboard rising: the renderer keeps its rows and slides up with the keyboard, then takes its new height once
///   the keyboard has arrived, where SwiftTerm's resize leaves the same rows in the same places (`heldShift`).
/// - The keyboard going: the rows change at once, the renderer starts where the rows already shown stay put (the
///   history SwiftTerm brings back above them is out of sight), and slides down with the keyboard.
enum TerminalKeyboardFollow {
    /// Where the renderer's top rests, relative to the top it will have, once its rows have slid up with a rising
    /// keyboard to the new `height`: SwiftTerm's resize moves its rows by this much (negative is up), so the renderer
    /// taking the new height there changes nothing on screen. Its resize removes the rows below the cursor first,
    /// then scrolls the screen into the history; following the newest output, the last row rests on the bottom edge
    /// (a partial row at the top) once there is history, and on the first row before there is any. `lines` is every
    /// line SwiftTerm keeps (history and screen), `topRow` the first one shown, `offset` the renderer's scroll offset;
    /// the alternate screen (`keepsHistory` false: full-screen programs) keeps no history.
    static func heldShift(cellHeight: CGFloat, rows: Int, cursorRow: Int, lines: Int, topRow: Int, offset: CGFloat,
                          height: CGFloat, keepsHistory: Bool = true) -> CGFloat {
        guard cellHeight > 0, rows > 0, height > 0 else { return 0 }
        let newRows = max(1, Int(height / cellHeight))
        let removed = max(0, rows - newRows)
        let belowCursor = max(0, rows - 1 - cursorRow)
        let scrolled = max(0, removed - belowCursor)
        guard keepsHistory else {
            // The alternate screen keeps no history: the rows leaving its top are gone, the rest move up.
            return -CGFloat(scrolled) * cellHeight
        }
        let history = max(0, lines - rows)
        guard topRow >= history else {
            // Scrolled back into the history: the same lines stay in view.
            return -CGFloat(scrolled) * cellHeight
        }
        let after = max(0, CGFloat(history + scrolled) * cellHeight - (height - CGFloat(newRows) * cellHeight))
        return offset - after
    }
}

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
