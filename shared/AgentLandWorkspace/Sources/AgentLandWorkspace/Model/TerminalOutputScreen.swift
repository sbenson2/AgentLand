import Foundation
import SwiftTerm

/// A terminal's screen rendered from its output alone, with no view: the Mac app names every terminal on its host from
/// it (`HostTerminalNaming`), as devices name the terminals they show from their renderer's rows. A headless SwiftTerm
/// `Terminal` of the terminal's size is fed the output and its visible rows are read, top to bottom, escape sequences
/// applied. Whatever the output asks a terminal to answer (cursor and device reports) goes nowhere: nothing is ever
/// typed into the terminal, and it is never resized.
public nonisolated enum TerminalOutputScreen {
    /// The size used while the host knows none (a terminal restored after a restart, an agent typed in Terminal): wide
    /// and tall, so a full-screen program's rows neither wrap nor overwrite each other.
    public static let fallbackColumns = 160
    public static let fallbackRows = 50

    /// The visible rows after `output`, at `columns` × `rows` (the fallback for a size the host doesn't know, or one
    /// outside its own limits of 500 × 300).
    public static func lines(of output: Data, columns: Int?, rows: Int?) -> [String] {
        let columns = columns.flatMap { (1...500).contains($0) ? $0 : nil } ?? fallbackColumns
        let rows = rows.flatMap { (1...300).contains($0) ? $0 : nil } ?? fallbackRows
        let sink = Sink()
        let terminal = Terminal(delegate: sink, options: TerminalOptions(cols: columns, rows: rows, scrollback: 100))
        terminal.feed(byteArray: [UInt8](output))
        return (0..<rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
    }

    /// Takes the terminal's replies and drops them.
    private final class Sink: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }
}
