import Foundation
import XCTest
@testable import AgentLandBranding

final class QuipTests: XCTestCase {
    func testGrammarIsDeterministicForASeed() {
        let grammar = GrammarQuipProvider()
        let first = grammar.generate(count: 12, avoiding: [], seed: 2026)
        XCTAssertEqual(first, grammar.generate(count: 12, avoiding: [], seed: 2026), "The same seed gives the same quips")
        XCTAssertNotEqual(first, grammar.generate(count: 12, avoiding: [], seed: 2027))
        XCTAssertEqual(first.count, 12)
        XCTAssertEqual(Set(first).count, 12, "A batch has no repeats")
        let avoided = grammar.generate(count: 12, avoiding: Set(first), seed: 2026)
        XCTAssertTrue(Set(avoided).isDisjoint(with: first), "Quips to avoid are skipped")
    }

    func testGrammarHasWellOver100kCombinations() {
        let count = GrammarQuipProvider.combinationCount()
        print("Grammar combinations of 3-36 characters: \(count)")
        XCTAssertGreaterThan(count, 100_000)
        XCTAssertLessThan(count, GrammarQuipProvider.combinationCount(lengths: 3...200), "Longer derivations are excluded")
    }

    func testGrammarQuipsAreValidSingleLines() {
        let quips = GrammarQuipProvider().generate(count: 400, avoiding: [], seed: 7)
        XCTAssertEqual(quips.count, 400)
        for quip in quips {
            XCTAssertEqual(QuipValidator.clean(quip), quip, quip)
            XCTAssertTrue((3...36).contains(quip.count), quip)
            XCTAssertTrue(quip.first?.isUppercase ?? false, "Starts with a capital: \(quip)")
            XCTAssertFalse(quip.contains("#"), "Every symbol is expanded: \(quip)")
        }
    }

    func testValidatorKeepsOneCleanLine() {
        XCTAssertEqual(QuipValidator.clean("  Juggling three pull requests  "), "Juggling three pull requests")
        XCTAssertEqual(QuipValidator.clean("1. Taming the backlog"), "Taming the backlog")
        XCTAssertEqual(QuipValidator.clean("- Tests on the trapeze"), "Tests on the trapeze")
        XCTAssertEqual(QuipValidator.clean("“Builds under the big top”"), "Builds under the big top")
        XCTAssertEqual(QuipValidator.clean("\"Diffs in ring two\""), "Diffs in ring two")
        XCTAssertEqual(QuipValidator.clean("The clown's merge   is green"), "The clown's merge is green", "Apostrophes stay")
        XCTAssertNil(QuipValidator.clean("Hi"), "Too short")
        XCTAssertNil(QuipValidator.clean(String(repeating: "a", count: 37)), "Too long")
        XCTAssertNotNil(QuipValidator.clean(String(repeating: "a", count: 36)))
        XCTAssertNil(QuipValidator.clean("Two lines\nof quip"))
        XCTAssertNil(QuipValidator.clean("Juggling tests 🤹"))
        XCTAssertNil(QuipValidator.clean("Big ❤ top"))
        XCTAssertNil(QuipValidator.clean("The \"best\" build"), "Quotation marks inside")
        XCTAssertNil(QuipValidator.clean("Ship it #agents"))
        XCTAssertNil(QuipValidator.clean("See https://example.com"))
        XCTAssertNil(QuipValidator.clean("**Bold** tests"))
        XCTAssertNil(QuipValidator.clean("12345"), "Needs words")
    }

    func testFoundationModelsUnavailableFallsBackToTheGrammar() async {
        let provider = FoundationModelsQuipProvider(isAvailable: { false }, generate: { _, _ in
            XCTFail("An unavailable model is never asked")
            return []
        })
        let batch = await provider.quips(count: 8, avoiding: [], seed: 5)
        XCTAssertEqual(batch.source, .grammar)
        XCTAssertEqual(batch.quips, GrammarQuipProvider().generate(count: 8, avoiding: [], seed: 5))
    }

    func testFoundationModelsErrorsAndRefusalsFallBackToTheGrammar() async {
        struct Refused: Error {}
        let provider = FoundationModelsQuipProvider(isAvailable: { true }, generate: { _, _ in throw Refused() })
        let batch = await provider.quips(count: 8, avoiding: [], seed: 9)
        XCTAssertEqual(batch.source, .grammar)
        XCTAssertEqual(batch.quips.count, 8)
        let empty = FoundationModelsQuipProvider(isAvailable: { true }, generate: { _, _ in ["🤹🤹🤹", "no"] })
        let fallback = await empty.quips(count: 8, avoiding: [], seed: 9)
        XCTAssertEqual(fallback.source, .grammar, "Nothing valid came back")
    }

    func testFoundationModelsResultsAreValidatedAndDeduplicated() async {
        let recent = "Taming the backlog"
        let provider = FoundationModelsQuipProvider(isAvailable: { true }, generate: { theme, _ in
            XCTAssertTrue(FoundationModelsQuipProvider.themes.contains(theme))
            return ["1. Juggling builds on stilts", "Juggling builds on stilts", recent, "Line one\nline two",
                    "An emoji 🎪 act", "Clowns review the test suite", String(repeating: "x", count: 40)]
        })
        let batch = await provider.quips(count: 8, avoiding: [recent], seed: 1)
        XCTAssertEqual(batch.source, .foundationModels)
        XCTAssertEqual(batch.quips, ["Juggling builds on stilts", "Clowns review the test suite"])
    }

    func testFoundationModelsInstructionsAskForShortFamilyFriendlyLines() {
        let instructions = FoundationModelsQuipProvider.instructions
        XCTAssertTrue(instructions.contains("family-friendly"))
        XCTAssertTrue(instructions.contains("36 characters"))
        XCTAssertTrue(instructions.contains("No emoji"))
        XCTAssertGreaterThanOrEqual(FoundationModelsQuipProvider.themes.count, 8)
    }

    @MainActor
    func testStoreReadsAtLeastEightQuipsSynchronouslyAndPersists() throws {
        let (defaults, cleanup) = try suite()
        defer { cleanup() }
        let store = QuipStore(defaults: defaults, provider: GrammarQuipProvider(), arguments: [], seed: 1)
        XCTAssertGreaterThanOrEqual(store.ring.count, 8)
        XCTAssertGreaterThanOrEqual(store.upcoming, 7)
        XCTAssertFalse(store.current.isEmpty)
        let first = store.current
        store.advance()
        XCTAssertNotEqual(store.current, first)
        let reopened = QuipStore(defaults: defaults, provider: GrammarQuipProvider(), arguments: [], seed: 2)
        XCTAssertEqual(reopened.current, store.current, "The ring and position survive a relaunch")
        XCTAssertEqual(reopened.shown, [first])
    }

    @MainActor
    func testStoreNeverShowsARecentQuipAgain() throws {
        let (defaults, cleanup) = try suite()
        defer { cleanup() }
        let store = QuipStore(defaults: defaults, provider: GrammarQuipProvider(), arguments: [], seed: 3)
        var history = [store.current]
        for _ in 0..<150 {
            store.advance()
            history.append(store.current)
            XCTAssertGreaterThanOrEqual(store.ring.count, 8)
            XCTAssertLessThanOrEqual(store.ring.count, QuipStore.maximumRing)
        }
        for index in history.indices {
            let window = history[max(0, index - 50)..<index]
            XCTAssertFalse(window.contains(history[index]), "\(history[index]) came back within 50 quips")
        }
    }

    @MainActor
    func testStoreAcceptsOnlyNewValidQuips() throws {
        let (defaults, cleanup) = try suite()
        defer { cleanup() }
        let store = QuipStore(defaults: defaults, provider: GrammarQuipProvider(), arguments: [], seed: 4)
        let shown = store.current
        store.advance()
        let before = store.ring.count
        store.accept(QuipBatch(quips: [shown, "Stilts for every test suite", "Stilts for every test suite", "🎪", "x"],
                               source: .foundationModels))
        XCTAssertEqual(store.ring.count, before + 1)
        XCTAssertEqual(store.ring.last, "Stilts for every test suite")
        XCTAssertEqual(store.lastSource, .foundationModels)
        // Corrupt saved values are dropped on the next launch.
        defaults.set(["ok quip here", 7, "🎪🎪🎪"], forKey: QuipStore.ringKey)
        defaults.set("not a number", forKey: QuipStore.indexKey)
        let reopened = QuipStore(defaults: defaults, provider: GrammarQuipProvider(), arguments: [], seed: 5)
        XCTAssertGreaterThanOrEqual(reopened.ring.count, 8)
        XCTAssertFalse(reopened.current.isEmpty)
    }

    @MainActor
    func testFixedQuipArgumentPinsTheQuip() throws {
        let (defaults, cleanup) = try suite()
        defer { cleanup() }
        let store = QuipStore(defaults: defaults, provider: GrammarQuipProvider(),
                              arguments: ["AgentLand", "-AgentLandFixedQuip", "Fixture quip for tests"], seed: 6)
        XCTAssertEqual(store.current, "Fixture quip for tests")
        store.advance()
        XCTAssertEqual(store.current, "Fixture quip for tests")
        XCTAssertNil(store.prefetchIfNeeded(), "A pinned quip never generates")
        XCTAssertNil(defaults.array(forKey: QuipStore.ringKey), "Test runs leave the saved ring alone")
    }

    @MainActor
    func testPrefetchRunsOffTheMainThreadAtUtilityPriority() async throws {
        let (defaults, cleanup) = try suite()
        defer { cleanup() }
        let probe = ThreadProbe()
        let store = QuipStore(defaults: defaults, provider: probe, arguments: [], seed: 8)
        XCTAssertNotNil(store.prefetchIfNeeded(), "A ring with fewer than eight upcoming quips tops up")
        XCTAssertTrue(store.prefetching)
        XCTAssertNil(store.prefetchIfNeeded(), "One prefetch at a time")
        // Poll rather than await the task: awaiting it from the main actor would raise its priority.
        for _ in 0..<500 where store.prefetching { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.prefetching)
        let observation = await probe.observation
        XCTAssertEqual(observation?.onMainThread, false)
        XCTAssertEqual(observation?.priority, .utility)
        XCTAssertTrue(store.ring.contains("Probe quip at the big top"))
        XCTAssertEqual(store.lastSource, .foundationModels)
    }

    /// Settings → Apple Intelligence off: the grammar writes the quips and the model is never asked; a missing setting
    /// is on.
    @MainActor
    func testAppleIntelligenceOffUsesOnlyTheGrammar() async throws {
        let (defaults, cleanup) = try suite()
        defer { cleanup() }
        XCTAssertTrue(AppleIntelligence.isOn(defaults), "On by default")
        defaults.set(false, forKey: AppleIntelligence.settingKey)
        XCTAssertFalse(AppleIntelligence.isOn(defaults))
        let probe = ThreadProbe()
        let store = QuipStore(defaults: defaults, provider: probe, arguments: [], seed: 9)
        XCTAssertNotNil(store.prefetchIfNeeded())
        for _ in 0..<500 where store.prefetching { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.prefetching)
        let observation = await probe.observation
        XCTAssertNil(observation, "The model's provider is never asked")
        XCTAssertEqual(store.lastSource, .grammar)
        XCTAssertFalse(store.ring.contains("Probe quip at the big top"))
    }

    /// The switch turned off while the model writes: its late quips are dropped.
    @MainActor
    func testQuipsArrivingAfterAppleIntelligenceWentOffAreDropped() async throws {
        let (defaults, cleanup) = try suite()
        defer { cleanup() }
        let gate = QuipGate()
        let store = QuipStore(defaults: defaults, provider: gate, arguments: [], seed: 10)
        XCTAssertNotNil(store.prefetchIfNeeded())
        var waited = 0
        while !(await gate.asked), waited < 500 { waited += 1; try await Task.sleep(for: .milliseconds(10)) }
        defaults.set(false, forKey: AppleIntelligence.settingKey)
        await gate.open()
        for _ in 0..<500 where store.prefetching { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.prefetching)
        XCTAssertFalse(store.ring.contains("Late quip at the big top"))
        XCTAssertNil(store.lastSource)
    }

    private func suite() throws -> (UserDefaults, () -> Void) {
        let name = "QuipTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }
}

private actor ThreadProbe: QuipProvider {
    struct Observation { let onMainThread: Bool; let priority: TaskPriority }
    private(set) var observation: Observation?

    nonisolated func quips(count: Int, avoiding: Set<String>, seed: UInt64) async -> QuipBatch {
        let seen = Observation(onMainThread: currentThreadIsMain(), priority: Task.currentPriority)
        await record(seen)
        return QuipBatch(quips: ["Probe quip at the big top"], source: .foundationModels)
    }

    private func record(_ value: Observation) { observation = value }
}

private func currentThreadIsMain() -> Bool { Thread.isMainThread }

/// A model that answers only once the test opens it.
private actor QuipGate: QuipProvider {
    private(set) var asked = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var opened = false

    nonisolated func quips(count: Int, avoiding: Set<String>, seed: UInt64) async -> QuipBatch {
        await wait()
        return QuipBatch(quips: ["Late quip at the big top"], source: .foundationModels)
    }

    private func wait() async {
        asked = true
        guard !opened else { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func open() {
        opened = true
        waiting?.resume()
        waiting = nil
    }
}
