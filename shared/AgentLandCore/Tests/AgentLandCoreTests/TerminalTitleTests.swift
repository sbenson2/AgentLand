import Foundation
import XCTest
@testable import AgentLandCore

/// The host's rules for a terminal's name (docs/HOST-API.md, "Terminals"), ported so a title seen live
/// reads as the host lists it.
final class TerminalTitleTests: XCTestCase {
    private struct Case {
        let raw: String
        let label: String?
        let expected: String?
        let line: UInt
        init(_ raw: String, label: String? = nil, _ expected: String?, line: UInt = #line) {
            self.raw = raw; self.label = label; self.expected = expected; self.line = line
        }
    }

    /// The host's table (desktop/terminal_title_test.go, TestCleanTerminalTitle), case for case; the host's
    /// "" is nil here. Its "invalid utf8 dropped" case has no Swift counterpart: a String holds only valid
    /// Unicode, and SwiftTerm reads a title that is not UTF-8 as empty.
    private static let hostTable: [Case] = {
        let long = String(repeating: "abcdefghij", count: 9) // 90 characters
        let shell = "Terminal" // the host's names shell, Shell and Terminal
        return [
            Case("Fix the login redirect", "Fix the login redirect"),
            Case("OC | Fix the login redirect", "Fix the login redirect"),
            Case("OC | Terminal scrolling on iPhone does n…", "Terminal scrolling on iPhone does n…"),
            Case("OpenCode", nil),
            Case("OC | ", nil),
            Case("✳ Terminal scrolling", "Terminal scrolling"),
            Case("✻ Reading files", "Reading files"),
            Case("✶ Writing tests", "Writing tests"),
            Case("✢ Planning", "Planning"),
            Case("· Thinking", "Thinking"),
            Case("* Compacting", "Compacting"),
            Case("⠙ Building", "Building"),
            Case("⠋⠙⠹ Deploying app", "Deploying app"),
            Case("✳ Claude Code", nil),
            Case("Claude", nil),
            Case("claude code", nil),
            Case("codex", nil),
            Case("-zsh", nil),
            Case("bash", nil),
            Case("-bash", nil),
            Case("sh", nil),
            Case("fish", nil),
            Case("login", nil),
            Case("s@robins-mac-mini:~/Developer/AgentLand", "~/Developer/AgentLand"),
            Case("wes@mini: ~/src", "~/src"),
            Case("s@mini:", nil),
            Case("s@mini: vim notes.md", "vim notes.md"),
            Case("Error: build failed", "Error: build failed"),
            Case("a@b@c: x", "a@b@c: x"),
            Case("see me@host: now", "see me@host: now"),
            Case("Fix\u{01} the\u{7f} build\u{85}now", "Fix the build now"),
            Case("  Fix \t the\n\nbuild  ", "Fix the build"),
            Case("日本語のタイトル", "日本語のタイトル"),
            Case("2 files changed", "2 files changed"),
            Case("🚀 Deploy", "Deploy"),
            Case("✳ ⠙ *", nil),
            Case("", nil),
            Case("   ", nil),
            Case(long, String(long.prefix(79)) + "…"),
            Case(String(repeating: "é", count: 85), String(repeating: "é", count: 79) + "…"),
            Case(String(repeating: "a", count: 78) + " bcd" + String(repeating: "e", count: 10), String(repeating: "a", count: 78) + "…"),
            Case(String(repeating: "x", count: 80), String(repeating: "x", count: 80)),
            Case("Shell", label: shell, nil),
            Case("shell", label: shell, nil),
            Case("terminal", label: shell, nil),
            Case("Terminal scrolling", label: shell, "Terminal scrolling"),
            Case("OC | OpenCode", nil),
        ]
    }()

    /// The same rules on this side: labels name their program, and the rules together.
    private static let table: [Case] = [
        Case("Tidy\u{00A0}\u{00A0}imports", "Tidy imports"),
        Case("\u{7}\u{1b}\u{0}", nil),
        Case("OC |  Tidy   imports ", "Tidy imports"),
        Case("OC |no space", "OC |no space"),
        Case("Fix: keep inner * and ✳", "Fix: keep inner * and ✳"),
        Case("root@build-box:/var/log", "/var/log"),
        Case("robin@studio", "robin@studio"),
        Case(String(repeating: "字", count: 79) + "尾巴", String(repeating: "字", count: 79) + "…"),
        Case("Terminal", "Terminal"),
        Case("OpenCode", label: "OpenCode", nil),
        Case("opencode", label: "OpenCode", nil),
        Case("Codex", label: "Codex", nil),
        Case("✳ Fix login", label: "Fix login", nil),
        Case("Build Server", label: "build server", nil),
        Case("vim notes.md", label: "Terminal", "vim notes.md"),
        Case(" OC | ✳ Fix the flaky test", "Fix the flaky test"),
        Case("\u{1b}OC | ⠋ s@host:~/app", "~/app"),
    ]

    func testCleanupTable() {
        for item in Self.hostTable + Self.table {
            XCTAssertEqual(TerminalTitle.clean(item.raw, label: item.label), item.expected,
                           "clean(\(item.raw.debugDescription), label: \(item.label ?? "nil"))", line: item.line)
        }
    }

    func testCleanedNamesAreAtMostEightyCharacters() {
        let long = "✳ " + String(repeating: "word ", count: 40)
        let cleaned = try? XCTUnwrap(TerminalTitle.clean(long))
        XCTAssertEqual(cleaned?.count, TerminalTitle.maximumLength)
        XCTAssertEqual(cleaned?.last, "…")
    }

    // MARK: The host's terminal list

    private func terminal(_ json: String) throws -> RemoteTerminal {
        try ProtocolDecoder.decode(RemoteTerminal.self, from: Data(json.utf8))
    }

    func testOlderHostsTerminalsDecodeWithoutNames() throws {
        let item = try terminal(#"{"id":"t1","title":"OpenCode","projectId":"p","status":"running"}"#)
        XCTAssertNil(item.programTitle)
        XCTAssertNil(item.command)
        XCTAssertEqual(item.displayTitle, "OpenCode")
    }

    func testProgramTitleThenCommandThenLabel() throws {
        let titled = try terminal(#"{"id":"t1","title":"OpenCode","projectId":"p","status":"running","programTitle":"Fix login","command":"opencode"}"#)
        XCTAssertEqual(titled.programTitle, "Fix login")
        XCTAssertEqual(titled.displayTitle, "Fix login")
        let command = try terminal(#"{"id":"t2","title":"Terminal","projectId":"p","status":"running","command":"npm run dev"}"#)
        XCTAssertEqual(command.displayTitle, "npm run dev")
        let neither = try terminal(#"{"id":"t3","title":"Codex","projectId":"p","status":"exited","exitCode":0,"programTitle":null}"#)
        XCTAssertEqual(neither.displayTitle, "Codex")
    }

    func testOnlyTheProgramsOwnNameFallsThrough() throws {
        let home = try terminal(#"{"id":"t1","title":"OpenCode","projectId":"p","status":"running","programTitle":"OpenCode","command":"vim notes.md"}"#)
        XCTAssertEqual(home.displayTitle, "vim notes.md")
        let shell = try terminal(#"{"id":"t2","title":"Terminal","projectId":"p","status":"running","command":"-zsh"}"#)
        XCTAssertEqual(shell.displayTitle, "Terminal")
        let empty = try terminal(#"{"id":"t3","title":"Claude Code","projectId":"p","status":"running","programTitle":"  ","command":""}"#)
        XCTAssertEqual(empty.displayTitle, "Claude Code")
    }

    func testUnreadableNamesNeverCostTheTerminal() throws {
        let item = try terminal(#"{"id":"t1","title":"Terminal","projectId":"p","status":"running","programTitle":42,"command":["x"]}"#)
        XCTAssertNil(item.programTitle)
        XCTAssertNil(item.command)
        XCTAssertEqual(item.displayTitle, "Terminal")
    }

    func testTerminalRoundTrips() throws {
        let item = RemoteTerminal(id: "t1", title: "OpenCode", projectID: "p", status: .running, exitCode: nil,
                                  programTitle: "Fix login", command: "opencode")
        XCTAssertEqual(try ProtocolDecoder.decode(RemoteTerminal.self, from: JSONEncoder().encode(item)), item)
    }

    // MARK: Tabs

    func testTerminalTabsKeepTheirLabelWhileTheirTitleFollowsTheProgram() throws {
        let item = RemoteTerminal(id: "t1", title: "OpenCode", projectID: "p", status: .running, exitCode: nil, programTitle: "Fix login")
        let tab = WorkspaceTab.terminal(item, projectID: "p")
        XCTAssertEqual(tab.kind, .terminal)
        XCTAssertEqual(tab.resourceID, "t1")
        XCTAssertEqual(tab.title, "Fix login")
        XCTAssertEqual(tab.creationLabel, "OpenCode")
        XCTAssertEqual(tab.label, "OpenCode")
        let restored = try JSONDecoder().decode(WorkspaceTab.self, from: JSONEncoder().encode(tab))
        XCTAssertEqual(restored, tab)
        XCTAssertEqual(restored.label, "OpenCode")
    }

    func testTabsSavedBeforeLabelsReadTheirTitleAsTheLabel() throws {
        let saved = #"{"id":"\#(UUID().uuidString)","kind":"terminal","projectID":"p","resourceID":"t1","title":"OpenCode"}"#
        let tab = try JSONDecoder().decode(WorkspaceTab.self, from: Data(saved.utf8))
        XCTAssertNil(tab.creationLabel)
        XCTAssertEqual(tab.label, "OpenCode")
    }
}
