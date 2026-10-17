import XCTest
import AgentLandCore

final class LauncherMenuTests: XCTestCase {
    /// The host lists the shell among its terminal programs. The Mac's old Home menu added its own
    /// Shell item on top of that list and title-cased the rest, showing "Shell" twice and "Opencode".
    /// The shared Home (and the Mac's workspace) lists what the host offers, once, by product name.
    func testHomeMenusListEachProgramAndAgentOnceByProductName() {
        let capabilities = CapabilitiesResponse(interactions: true, terminal: true,
                                                terminalPrograms: ["shell", "opencode", "claude", "codex"],
                                                chatProviders: ["opencode", "claude", "codex"])
        XCTAssertEqual(TerminalProgram.offered(by: capabilities).map(\.displayName), ["Shell", "OpenCode", "Claude Code", "Codex"])
        XCTAssertEqual(TerminalProgram.offered(by: capabilities).map(\.terminalTitle), ["Terminal", "OpenCode", "Claude Code", "Codex"])
        XCTAssertEqual(AgentProvider.offered(by: capabilities).map(\.displayName), ["OpenCode", "Claude Code", "Codex"])

        let plain = CapabilitiesResponse(interactions: true, terminal: false)
        XCTAssertEqual(TerminalProgram.offered(by: plain), [])
        XCTAssertEqual(AgentProvider.offered(by: plain), [.opencode])
    }
}
