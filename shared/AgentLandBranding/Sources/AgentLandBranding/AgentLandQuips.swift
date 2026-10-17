import Combine
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Where a batch of quips came from.
public enum QuipSource: String, Sendable {
    case foundationModels, grammar, fixed
}

public struct QuipBatch: Sendable {
    public let quips: [String]
    public let source: QuipSource
    public init(quips: [String], source: QuipSource) {
        self.quips = quips
        self.source = source
    }
}

/// Makes one-line, family-friendly circus quips about AI agents at work.
public protocol QuipProvider: Sendable {
    /// Up to `count` validated quips that are not in `avoiding`.
    func quips(count: Int, avoiding: Set<String>, seed: UInt64) async -> QuipBatch
}

/// The rules every quip meets before it is shown: one line of 3–36 characters, no emoji, no quotation
/// marks, markup or links. A leading list marker or wrapping quotation marks are removed first.
public enum QuipValidator {
    public static let lengths = 3...36

    public static func clean(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains(where: \.isNewline) else { return nil }
        // Drop a list marker such as "1." "2)" "-" "•" "*".
        if let marker = text.range(of: #"^(\d{1,2}[.)]|[-•*])\s+"#, options: .regularExpression) {
            text.removeSubrange(marker)
        }
        let wrappers: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’"), ("«", "»")]
        if text.count >= 2, wrappers.contains(where: { text.first == $0.0 && text.last == $0.1 }) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard lengths.contains(text.count) else { return nil }
        let clutter: Set<Character> = ["\"", "“", "”", "«", "»", "`", "#", "@", "*", "_", "|", "<", ">", "{", "}", "[", "]", "\\"]
        guard !text.contains(where: { clutter.contains($0) }) else { return nil }
        guard !text.lowercased().contains("http"), !text.lowercased().contains("www.") else { return nil }
        guard !text.unicodeScalars.contains(where: isEmoji) else { return nil }
        guard text.contains(where: \.isLetter) else { return nil }
        return text
    }

    private static func isEmoji(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        if properties.isEmojiPresentation { return true }
        // Text-default emoji (for example ☺ or ❤) still count; digits, # and * are plain text.
        if properties.isEmoji && scalar.value > 0x238C { return true }
        return scalar.value == 0xFE0F || scalar.value == 0x200D
    }
}

// MARK: - Grammar

/// An in-house Tracery-style expander: `#symbol#` picks one of the symbol's options with a seeded
/// generator, and `#symbol.cap#` capitalizes the first letter. Its vocabulary gives well over 100,000
/// valid quips (see `combinationCount`).
public struct GrammarQuipProvider: QuipProvider {
    public static let rules: [String: [String]] = [
        "origin": [
            "#gerund.cap# #count# #plural#",
            "Now #gerund# #count# #plural#",
            "#performer# #verbs# #plural#",
            "#performer# #verbs# #count# #plural#",
            "#performer# #verbs# the #singular#",
            "#gerund.cap# #plural# #place#",
            "#gerund.cap# the #singular# #place#",
            "#count.cap# #plural# #place#",
            "#count.cap# #plural# on the #apparatus#",
            "#plural.cap#, #fresh# and #steady#",
            "#performer# on the #apparatus#",
            "#singular.cap# on the #apparatus#",
            "Tonight: #plural# #place#",
            "Step right up: #fresh# #plural#",
        ],
        "plural": [
            "tests", "builds", "diffs", "commits", "branches", "merges", "prompts", "pull requests", "code reviews",
            "bug fixes", "refactors", "terminals", "tasks", "to-dos", "unit tests", "patches", "releases", "drafts",
            "deploys", "logs", "scripts", "tickets", "docs", "lint fixes", "migrations", "snapshots", "test suites",
            "hotfixes", "benchmarks", "pipelines", "changelogs", "type checks",
        ],
        "singular": [
            "test suite", "build", "diff", "branch", "merge", "prompt", "pull request", "code review", "bug fix",
            "refactor", "terminal", "release", "deploy", "changelog", "patch", "lint pass", "spec", "checklist",
            "backlog", "hotfix", "migration", "benchmark", "pipeline", "type check",
        ],
        "count": ["two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "a dozen", "twenty"],
        "gerund": [
            "juggling", "balancing", "taming", "spinning", "tossing", "catching", "stacking", "launching", "twirling",
            "flipping", "herding", "polishing", "sorting", "untangling", "reviewing", "testing", "shipping", "fixing",
            "patching", "merging", "tidying", "rehearsing",
        ],
        "verbs": [
            "juggles", "balances", "tames", "spins", "tosses", "catches", "stacks", "launches", "twirls", "flips",
            "herds", "polishes", "sorts", "untangles", "reviews", "tests", "ships", "fixes", "patches", "merges",
            "tidies", "rehearses",
        ],
        "performer": [
            "The clown", "The ringmaster", "An acrobat", "The strongman", "The juggler", "Your agent", "An agent",
            "The night crew", "A trapeze artist", "The stilt walker", "The magician", "The lion tamer",
            "The bandleader", "A tumbler", "The unicyclist", "The tightrope walker",
        ],
        "apparatus": [
            "trapeze", "high wire", "tightrope", "unicycle", "trampoline", "flying rings", "stilts", "seesaw",
            "balance beam", "cannon", "carousel", "bandstand", "spotlight", "center ring", "big top", "calliope",
        ],
        "place": [
            "in ring one", "in ring two", "in ring three", "under the big top", "in the spotlight", "on the high wire",
            "on stilts", "on a unicycle", "backstage", "center stage", "in the sawdust", "on the trapeze",
            "at the ticket booth", "by the calliope",
        ],
        "fresh": ["fresh", "tidy", "tested", "shiny", "clean", "bright", "merry", "nimble"],
        "steady": ["green", "fast", "sturdy", "careful", "calm", "steady", "brave", "bold"],
    ]

    public init() {}

    public func quips(count: Int, avoiding: Set<String>, seed: UInt64) async -> QuipBatch {
        QuipBatch(quips: generate(count: count, avoiding: avoiding, seed: seed), source: .grammar)
    }

    /// Up to `count` distinct valid quips not in `avoiding`, the same for the same seed.
    public func generate(count: Int, avoiding: Set<String>, seed: UInt64) -> [String] {
        var generator = AgentLandSeededGenerator(seed: seed)
        var made: [String] = []
        for _ in 0..<(count * 40) where made.count < count {
            guard let quip = QuipValidator.clean(Self.expand("#origin#", using: &generator)),
                  !avoiding.contains(quip), !made.contains(quip) else { continue }
            made.append(quip)
        }
        return made
    }

    public static func expand(_ template: String, using generator: inout AgentLandSeededGenerator) -> String {
        var output = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "#") {
            output += rest[..<open]
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "#") else { output += rest[open...]; return output }
            let reference = rest[afterOpen..<close].split(separator: ".", maxSplits: 1)
            let name = String(reference.first ?? "")
            let capitalized = reference.count > 1 && reference[1] == "cap"
            var value = expand(rules[name]?.randomElement(using: &generator) ?? "", using: &generator)
            if capitalized, let first = value.first { value = first.uppercased() + value.dropFirst() }
            output += value
            rest = rest[rest.index(after: close)...]
        }
        return output + rest
    }

    /// How many distinct derivations of `#origin#` fit `lengths` characters, counted by length
    /// (dynamic programming over each rule's length distribution), without listing them.
    public static func combinationCount(lengths: ClosedRange<Int> = QuipValidator.lengths) -> Int {
        var memo: [String: [Int: Int]] = [:]
        func distribution(ofTemplate template: String) -> [Int: Int] {
            var result: [Int: Int] = [0: 1]
            var rest = Substring(template)
            func append(_ part: [Int: Int]) {
                var next: [Int: Int] = [:]
                for (a, countA) in result { for (b, countB) in part where a + b <= lengths.upperBound {
                    next[a + b, default: 0] += countA * countB
                } }
                result = next
            }
            while let open = rest.firstIndex(of: "#") {
                append([rest[..<open].count: 1])
                let afterOpen = rest.index(after: open)
                guard let close = rest[afterOpen...].firstIndex(of: "#") else { break }
                let name = String(rest[afterOpen..<close].split(separator: ".").first ?? "")
                append(distribution(ofSymbol: name))
                rest = rest[rest.index(after: close)...]
            }
            append([rest.count: 1])
            return result
        }
        func distribution(ofSymbol name: String) -> [Int: Int] {
            if let known = memo[name] { return known }
            var total: [Int: Int] = [:]
            for option in rules[name] ?? [] {
                for (length, count) in distribution(ofTemplate: option) { total[length, default: 0] += count }
            }
            memo[name] = total
            return total
        }
        return distribution(ofSymbol: "origin").filter { lengths.contains($0.key) }.values.reduce(0, +)
    }
}

// MARK: - Apple Foundation Models

#if canImport(FoundationModels)
@Generable
struct GeneratedQuips {
    @Guide(description: "Eight different captions, each one line of at most 36 characters", .count(8))
    var captions: [String]
}
#endif

/// Quips from Apple's on-device language model (`SystemLanguageModel.default`), in batches of eight
/// around a random theme. When Apple Intelligence is off or unavailable, or on any error or guardrail
/// refusal, the grammar makes the batch instead. Every quip is validated either way.
public struct FoundationModelsQuipProvider: QuipProvider {
    public typealias Generator = @Sendable (_ theme: String, _ seed: UInt64) async throws -> [String]

    public static let instructions = """
        You write captions for a circus-themed app in which AI coding agents do the work. Each caption is one \
        playful, family-friendly line of at most 36 characters about agents at work as circus performers: \
        juggling tests, balancing builds, taming bugs. No emoji, no quotation marks, no hashtags, no names \
        of real people or brands.
        """
    public static let themes = [
        "the trapeze", "the tightrope", "juggling", "the ringmaster", "popcorn", "the unicycle", "the big top",
        "the clown car", "the calliope", "cotton candy", "acrobats", "stilts", "confetti", "the spotlight",
        "the marching band", "the ticket booth", "the sawdust ring", "the human cannonball", "the strongman",
        "the magician", "the carousel", "the flying rings", "the parade", "the grand finale",
    ]

    private let fallback: GrammarQuipProvider
    private let isAvailable: @Sendable () -> Bool
    private let generate: Generator

    public init(fallback: GrammarQuipProvider = GrammarQuipProvider(),
                isAvailable: @escaping @Sendable () -> Bool = { FoundationModelsQuipProvider.systemModelIsAvailable() },
                generate: Generator? = nil) {
        self.fallback = fallback
        self.isAvailable = isAvailable
        self.generate = generate ?? { theme, seed in try await FoundationModelsQuipProvider.generateWithSystemModel(theme: theme, seed: seed) }
    }

    public static func systemModelIsAvailable() -> Bool { AppleIntelligence.availability == .available }

    public func quips(count: Int, avoiding: Set<String>, seed: UInt64) async -> QuipBatch {
        guard isAvailable() else {
            return await fallback.quips(count: count, avoiding: avoiding, seed: seed)
        }
        var generator = AgentLandSeededGenerator(seed: seed)
        let theme = Self.themes.randomElement(using: &generator) ?? "the big top"
        do {
            var made: [String] = []
            for raw in try await generate(theme, generator.next()) {
                guard let quip = QuipValidator.clean(raw), !avoiding.contains(quip), !made.contains(quip) else { continue }
                made.append(quip)
                if made.count == count { break }
            }
            guard !made.isEmpty else { return await fallback.quips(count: count, avoiding: avoiding, seed: seed) }
            return QuipBatch(quips: made, source: .foundationModels)
        } catch {
            // Unavailable model assets, guardrail refusals, rate limits and cancellations all fall back.
            return await fallback.quips(count: count, avoiding: avoiding, seed: seed)
        }
    }

    static func generateWithSystemModel(theme: String, seed: UInt64) async throws -> [String] {
        #if canImport(FoundationModels)
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(sampling: .random(top: 40, seed: seed), temperature: 1, maximumResponseTokens: 320)
        let response = try await session.respond(to: "Theme: \(theme). Write eight different captions.",
                                                 generating: GeneratedQuips.self, options: options)
        return response.content.captions
        #else
        throw CancellationError()
        #endif
    }
}

// MARK: - Store

/// A saved ring of at least eight quips, read synchronously so Home never waits for one. Showing Home
/// or tapping the title moves to the next quip; new ones are generated off the main thread, at utility
/// priority, after Home has been visible for a moment: by the provider (Apple's on-device model) while
/// Settings → Apple Intelligence is on (`AppleIntelligence`), else by the grammar alone. Quips shown
/// recently (the last 50) are not reused. `-AgentLandFixedQuip "<text>"` pins one quip for deterministic UI tests.
@MainActor
public final class QuipStore: ObservableObject {
    public static let shared = QuipStore()
    public static let fixedQuipArgument = "-AgentLandFixedQuip"
    public static let minimumRing = 8
    public static let maximumRing = 32
    public static let rememberedShown = 50
    static let ringKey = "agentland.quips.ring"
    static let indexKey = "agentland.quips.index"
    static let shownKey = "agentland.quips.shown"

    @Published public private(set) var current: String
    /// Quips before the current one were shown; the ones after it are upcoming.
    public private(set) var ring: [String]
    /// The most recently shown quips, oldest first; none of them is shown again while remembered.
    public private(set) var shown: [String]
    public private(set) var lastSource: QuipSource?
    public private(set) var prefetching = false
    private var index: Int
    private var generator: AgentLandSeededGenerator
    private let defaults: UserDefaults
    private let provider: any QuipProvider
    private let fixed: String?

    public init(defaults: UserDefaults = .standard, provider: any QuipProvider = FoundationModelsQuipProvider(),
                arguments: [String] = ProcessInfo.processInfo.arguments, seed: UInt64 = .random(in: .min ... .max)) {
        self.defaults = defaults
        self.provider = provider
        var generator = AgentLandSeededGenerator(seed: seed)
        let fixed = Self.fixedQuip(in: arguments)
        // Saved values are checked like fresh ones; anything unreadable is dropped.
        let saved = (defaults.array(forKey: Self.ringKey) as? [String] ?? []).compactMap(QuipValidator.clean)
        var ring: [String] = []
        for quip in saved where !ring.contains(quip) { ring.append(quip) }
        let shown = Array((defaults.array(forKey: Self.shownKey) as? [String] ?? []).compactMap(QuipValidator.clean)
            .suffix(Self.rememberedShown))
        let index = min(max(0, defaults.object(forKey: Self.indexKey) as? Int ?? 0), max(0, ring.count - 1))
        if ring.count - index < Self.minimumRing {
            ring += GrammarQuipProvider().generate(count: Self.minimumRing - (ring.count - index),
                                                   avoiding: Set(ring + shown), seed: generator.next())
        }
        self.generator = generator
        self.fixed = fixed
        self.ring = ring
        self.shown = shown
        self.index = index
        current = fixed ?? ring[index]
        if fixed == nil { persist() }
    }

    static func fixedQuip(in arguments: [String]) -> String? {
        guard let flag = arguments.firstIndex(of: fixedQuipArgument), arguments.indices.contains(flag + 1) else { return nil }
        let text = arguments[flag + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Quips after the current one that have not been shown yet.
    public var upcoming: Int { max(0, ring.count - index - 1) }

    /// Shows the next quip. At the end of the ring the grammar adds one at once, so the ring never wraps
    /// around to a quip that was just shown.
    public func advance() {
        guard fixed == nil, !ring.isEmpty else { return }
        remember(ring[index])
        if upcoming == 0 {
            ring += GrammarQuipProvider().generate(count: 1, avoiding: Set(ring + shown), seed: generator.next())
        }
        index = upcoming > 0 ? index + 1 : 0
        trim()
        current = ring[index]
        persist()
    }

    /// Adds new quips after validating them and skipping any in the ring or shown recently.
    public func accept(_ batch: QuipBatch) {
        guard fixed == nil else { return }
        lastSource = batch.source
        let recent = Set(shown)
        for raw in batch.quips {
            guard let quip = QuipValidator.clean(raw), !recent.contains(quip), !ring.contains(quip) else { continue }
            ring.append(quip)
        }
        trim()
        persist()
    }

    /// Keeps the ring bounded by dropping quips that were already shown, oldest first.
    private func trim() {
        while ring.count > Self.maximumRing && index > 0 {
            ring.removeFirst()
            index -= 1
        }
    }

    /// Starts generating a batch when fewer than eight unseen quips remain. The work runs in a detached
    /// task at utility priority, so neither the main thread nor the opening ever waits for it.
    @discardableResult
    public func prefetchIfNeeded() -> Task<Void, Never>? {
        guard fixed == nil, !prefetching, upcoming < Self.minimumRing else { return nil }
        prefetching = true
        let avoiding = Set(ring + shown)
        // Apple Intelligence off: the grammar alone, and no model is asked.
        let provider: any QuipProvider = AppleIntelligence.isOn(defaults) ? self.provider : GrammarQuipProvider()
        let seed = UInt64.random(in: .min ... .max)
        return Task.detached(priority: .utility) { [weak self] in
            let batch = await provider.quips(count: 8, avoiding: avoiding, seed: seed)
            await self?.finishPrefetch(batch)
        }
    }

    private func finishPrefetch(_ batch: QuipBatch) {
        prefetching = false
        // The model's quips that arrive after Apple Intelligence was turned off are dropped.
        guard batch.source != .foundationModels || AppleIntelligence.isOn(defaults) else { return }
        accept(batch)
    }

    private func remember(_ quip: String) {
        shown.removeAll { $0 == quip }
        shown.append(quip)
        if shown.count > Self.rememberedShown { shown.removeFirst(shown.count - Self.rememberedShown) }
    }

    private func persist() {
        defaults.set(ring, forKey: Self.ringKey)
        defaults.set(index, forKey: Self.indexKey)
        defaults.set(shown, forKey: Self.shownKey)
    }
}
