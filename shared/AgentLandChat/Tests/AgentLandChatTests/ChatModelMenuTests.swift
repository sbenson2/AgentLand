import XCTest
import AgentLandCore
@testable import AgentLandChat

/// The model menu (owner's request, 2026-10-07): the host's first five models in its order, every other model under
/// More Models by provider.
final class ChatModelMenuTests: XCTestCase {
    private func model(_ id: String, _ provider: String) -> AgentModelOption {
        AgentModelOption(id: "\(provider)/\(id)", name: id, provider: provider)
    }

    func testFiveOrFewerModelsAreAllInTheMenu() {
        let models = (1...5).map { model("m\($0)", "Anthropic") }
        let groups = ChatModelMenuGroups(models)
        XCTAssertEqual(groups.first, models)
        XCTAssertTrue(groups.more.isEmpty, "No More Models with five models")

        let three = Array(models.prefix(3))
        XCTAssertEqual(ChatModelMenuGroups(three).first, three)
        XCTAssertTrue(ChatModelMenuGroups(three).more.isEmpty)
    }

    func testTheRestGoUnderMoreModelsInTheHostsOrder() {
        let models = ["m1", "m2", "m3", "m4", "m5", "m6", "m7", "m8"].map { model($0, "OpenAI") }
        let groups = ChatModelMenuGroups(models)
        XCTAssertEqual(groups.first.map(\.name), ["m1", "m2", "m3", "m4", "m5"], "The host's first five, in its order")
        XCTAssertEqual(groups.more.map(\.provider), ["OpenAI"])
        XCTAssertEqual(groups.more.first?.models.map(\.name), ["m6", "m7", "m8"])
    }

    func testMoreModelsAreGroupedByProviderInNameOrder() {
        let models = [model("a1", "Zed"), model("a2", "Anthropic"), model("a3", "OpenAI"), model("a4", "Zed"),
                      model("a5", "Anthropic"),
                      model("z1", "Zed"), model("o1", "OpenAI"), model("x1", "Anthropic"), model("z2", "Zed"), model("o2", "OpenAI")]
        let groups = ChatModelMenuGroups(models)
        XCTAssertEqual(groups.first.map(\.name), ["a1", "a2", "a3", "a4", "a5"], "The first five whatever their provider")
        XCTAssertEqual(groups.more.map(\.provider), ["Anthropic", "OpenAI", "Zed"])
        XCTAssertEqual(groups.more.map { $0.models.map(\.name) }, [["x1"], ["o1", "o2"], ["z1", "z2"]],
                       "Each provider's models in the host's order")
    }

    func testNoModels() {
        let groups = ChatModelMenuGroups([])
        XCTAssertTrue(groups.first.isEmpty)
        XCTAssertTrue(groups.more.isEmpty)
    }

    func testEffortNamesAndSummaries() {
        XCTAssertEqual(["minimal", "low", "medium", "high", "xhigh", "max"].map(ChatEffort.name),
                       ["Minimal", "Low", "Medium", "High", "Extra High", "Max"])
        XCTAssertEqual(ChatEffort.summary("high"), "Thinks longer")
        XCTAssertEqual(ChatEffort.summary("max"), "Thinks the longest")
        XCTAssertNil(ChatEffort.summary("turbo"), "An effort AgentLand doesn't know shows its name alone")
        XCTAssertEqual(ChatEffort.name("turbo"), "Turbo")
    }

    func testPillShortName() {
        XCTAssertEqual(ChatEffort.shortName("Default (recommended)"), "Default")
        XCTAssertEqual(ChatEffort.shortName("Opus 5.5"), "Opus 5.5")
        XCTAssertEqual(ChatEffort.shortName("Sonnet (1M context)"), "Sonnet")
        XCTAssertEqual(ChatEffort.shortName("(beta)"), "(beta)", "A name that is all note stays whole")
    }
}
