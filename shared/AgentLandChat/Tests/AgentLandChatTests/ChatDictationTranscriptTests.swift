import XCTest
@testable import AgentLandChat

/// The draft while dictating: the words still settling are replaced by each new result, settled phrases are kept
/// across pauses, and what was typed before stays in front.
final class ChatDictationTranscriptTests: XCTestCase {
    func testSettlingWordsAreReplacedAndSettledPhrasesKept() {
        var transcript = ChatDictationTranscript(prefix: "")
        transcript.receive("Add a", isFinal: false)
        XCTAssertEqual(transcript.draft, "Add a")
        transcript.receive("Add a settings page", isFinal: false)
        XCTAssertEqual(transcript.draft, "Add a settings page", "A newer guess replaces the last one")
        transcript.receive("Add a settings page.", isFinal: true)
        XCTAssertEqual(transcript.draft, "Add a settings page.")
        // A pause, then more speech: the first phrase stays.
        transcript.receive("Then run", isFinal: false)
        XCTAssertEqual(transcript.draft, "Add a settings page. Then run")
        transcript.receive(" Then run the tests.", isFinal: true)
        XCTAssertEqual(transcript.draft, "Add a settings page. Then run the tests.")
    }

    func testPrefixKeepsWhatWasTyped() {
        var typed = ChatDictationTranscript(prefix: "In ChatView.swift")
        typed.receive("fix the padding", isFinal: false)
        XCTAssertEqual(typed.draft, "In ChatView.swift fix the padding")

        var spaced = ChatDictationTranscript(prefix: "Hello\n")
        spaced.receive("next line", isFinal: true)
        XCTAssertEqual(spaced.draft, "Hello\nnext line", "No space after a line break")
    }

    func testNothingHeardLeavesTheDraft() {
        var transcript = ChatDictationTranscript(prefix: "Draft")
        XCTAssertTrue(transcript.isEmpty)
        defer {
            transcript.receive("more", isFinal: false)
            XCTAssertFalse(transcript.isEmpty)
        }
        XCTAssertEqual(transcript.draft, "Draft ", "Only the separating space, so the first words don't stick to it")
        XCTAssertEqual(ChatDictationTranscript(prefix: "").draft, "")
    }

    func testJoin() {
        XCTAssertEqual(ChatDictationTranscript.join("one", "two"), "one two")
        XCTAssertEqual(ChatDictationTranscript.join("one ", " two"), "one two")
        XCTAssertEqual(ChatDictationTranscript.join("one", ", two"), "one, two", "No space before punctuation")
        XCTAssertEqual(ChatDictationTranscript.join("one", "?"), "one?")
        XCTAssertEqual(ChatDictationTranscript.join("say", "\"hi\""), "say \"hi\"", "An opening quote takes a space")
        XCTAssertEqual(ChatDictationTranscript.join("", " two"), "two")
        XCTAssertEqual(ChatDictationTranscript.join("one", ""), "one")
    }

    /// The older recognizer reports the whole run each time and may start over after a pause.
    func testRunningReportsKeepARunThatStartedOver() {
        var transcript = ChatDictationTranscript(prefix: "")
        transcript.receiveRunning("Add a", isFinal: false)
        transcript.receiveRunning("Add a settings page", isFinal: false)
        XCTAssertEqual(transcript.draft, "Add a settings page")
        transcript.receiveRunning("Then", isFinal: false)
        XCTAssertEqual(transcript.draft, "Add a settings page Then", "A run that starts over keeps the last one")
        transcript.receiveRunning("Then run the tests", isFinal: true)
        XCTAssertEqual(transcript.draft, "Add a settings page Then run the tests")

        var revised = ChatDictationTranscript(prefix: "")
        revised.receiveRunning("Fix the bug in the parser", isFinal: false)
        revised.receiveRunning("Fix the bugs", isFinal: false)
        XCTAssertEqual(revised.draft, "Fix the bugs", "A revision of the same run replaces it")
    }
}
