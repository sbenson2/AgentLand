import Foundation
import XCTest
@testable import AgentLandDesktopCore

/// OpenCode 1.18.31's `GET /provider` (`{all, default, connected}`, each provider with its models.dev `env`
/// names), as the host's `desktop/chat_options.go` and its fixture read it, and the rows of Settings → AI
/// Providers.
final class OpenCodeProviderListTests: XCTestCase {
    /// Shaped like 1.18.31's answer: models keyed by ID with more fields than read, `options` that may hold a
    /// key (never read), a custom provider without `env`, and a provider whose models do not all decode.
    static let catalog = """
    {"all": [
      {"id": "openai", "name": "OpenAI", "source": "env", "env": ["OPENAI_API_KEY"], "options": {"apiKey": "must-not-leak"},
       "models": {"gpt-test": {"id": "gpt-test", "providerID": "openai", "name": "GPT Test", "limit": {"context": 128000}},
                  "gpt-mini": {"id": "gpt-mini", "providerID": "openai", "name": "GPT Mini"}}},
      {"id": "azure", "name": "Azure", "env": ["AZURE_RESOURCE_NAME", "AZURE_API_KEY"], "models": {"a": {"id": "a", "name": "A"}}},
      {"id": "google", "name": "Google", "env": ["GOOGLE_GENERATIVE_AI_API_KEY", "GEMINI_API_KEY"],
       "models": {"g": {"id": "g", "name": "Gemini"}, "broken": {"name": 7}}},
      {"id": "amazon-bedrock", "name": "Amazon Bedrock", "env": ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_REGION"], "models": {}},
      {"id": "local", "name": "Local Server", "models": {"m": {"id": "m", "name": "Model"}}},
      {"name": "No ID"}
    ],
    "default": {"openai": "gpt-test", "google": "g"},
    "connected": ["openai", "local"]}
    """

    func testTheProviderCatalogReadsEveryProviderItsVariablesAndModels() throws {
        let providers = try OpenCodeProviderClient.parse(Data(Self.catalog.utf8))
        XCTAssertEqual(providers.map(\.id), ["amazon-bedrock", "azure", "google", "local", "openai"], "by name; one without an ID is skipped")
        let openAI = try XCTUnwrap(providers.first { $0.id == "openai" })
        XCTAssertEqual(openAI.name, "OpenAI")
        XCTAssertTrue(openAI.isConnected)
        XCTAssertEqual(openAI.models.map(\.id), ["gpt-mini", "gpt-test"])
        XCTAssertEqual(openAI.defaultModelID, "gpt-test")
        XCTAssertEqual(openAI.keyVariable, "OPENAI_API_KEY")
        XCTAssertEqual(openAI.otherVariables, [])
        let google = try XCTUnwrap(providers.first { $0.id == "google" })
        XCTAssertEqual(google.models.map(\.id), ["g"], "a model that does not decode is skipped, not the provider")
        XCTAssertEqual(google.keyVariable, "GOOGLE_GENERATIVE_AI_API_KEY", "the first key variable OpenCode reads")
        let azure = try XCTUnwrap(providers.first { $0.id == "azure" })
        XCTAssertEqual(azure.keyVariable, "AZURE_API_KEY")
        XCTAssertEqual(azure.otherVariables, ["AZURE_RESOURCE_NAME"])
        XCTAssertNil(providers.first { $0.id == "amazon-bedrock" }?.keyVariable, "no key variable AgentLand may set")
        let local = try XCTUnwrap(providers.first { $0.id == "local" })
        XCTAssertEqual(local.environmentKeys, [])
        XCTAssertNil(local.keyVariable)
        XCTAssertTrue(local.isConnected)
        XCTAssertThrowsError(try OpenCodeProviderClient.parse(Data("[]".utf8)))
    }

    func testTheRowsSplitWhatIsInUseFromTheRestAndFollowTheSearch() throws {
        let providers = try OpenCodeProviderClient.parse(Data(Self.catalog.utf8))
        // A key saved for Azure (not connected yet) and one for a provider OpenCode no longer lists.
        let saved = ["azure": "AZURE_API_KEY", "retired": "RETIRED_API_KEY"]
        let all = OpenCodeProviderList.rows(catalog: providers, savedKeys: saved, search: "")
        XCTAssertEqual(all.inUse.map(\.id), ["azure", "local", "openai", "retired"])
        XCTAssertEqual(all.available.map(\.id), ["amazon-bedrock", "google"])
        let openAI = try XCTUnwrap(all.inUse.first { $0.id == "openai" })
        XCTAssertEqual(openAI.connected, true)
        XCTAssertEqual(openAI.modelCount, 2)
        XCTAssertNil(openAI.savedKeyVariable)
        let azure = try XCTUnwrap(all.inUse.first { $0.id == "azure" })
        XCTAssertEqual(azure.connected, false)
        XCTAssertEqual(azure.savedKeyVariable, "AZURE_API_KEY")
        let retired = try XCTUnwrap(all.inUse.first { $0.id == "retired" })
        XCTAssertEqual(retired.name, "retired")
        XCTAssertNil(retired.connected, "OpenCode does not list it")
        XCTAssertNil(retired.modelCount)
        XCTAssertEqual(retired.keyVariable, "RETIRED_API_KEY", "its key can still be removed or replaced")

        XCTAssertEqual(OpenCodeProviderList.rows(catalog: providers, savedKeys: saved, search: "gem").available.map(\.id), ["google"],
                       "a variable matches")
        let byName = OpenCodeProviderList.rows(catalog: providers, savedKeys: saved, search: "  azure ")
        XCTAssertEqual(byName.inUse.map(\.id) + byName.available.map(\.id), ["azure"])
        XCTAssertEqual(OpenCodeProviderList.rows(catalog: providers, savedKeys: saved, search: "BEDROCK").available.map(\.id),
                       ["amazon-bedrock"], "the ID matches, whatever the case")
        let none = OpenCodeProviderList.rows(catalog: [], savedKeys: [:], search: "")
        XCTAssertTrue(none.inUse.isEmpty && none.available.isEmpty)
    }

    /// OpenCode reads one value per variable, so a key saved for GitHub Copilot replaces the GITHUB_TOKEN
    /// saved for GitHub Models. Whose keys go is read from every saved key, never from what a search shows.
    func testEveryProviderWhoseSavedKeyWouldBeReplacedIsNamedWhateverTheSearch() throws {
        let copilot = OpenCodeProviderOption(id: "github-copilot", name: "GitHub Copilot", environmentKeys: ["GITHUB_TOKEN"], models: [],
                                             defaultModelID: nil, isConnected: false)
        let models = OpenCodeProviderOption(id: "github-models", name: "GitHub Models", environmentKeys: ["GITHUB_TOKEN"], models: [],
                                            defaultModelID: nil, isConnected: false)
        let openAI = OpenCodeProviderOption(id: "openai", name: "OpenAI", environmentKeys: ["OPENAI_API_KEY"], models: [],
                                            defaultModelID: nil, isConnected: false)
        let catalog = [copilot, models, openAI]
        let saved = ["github-models": "GITHUB_TOKEN", "openai": "OPENAI_API_KEY"]
        // The owner searches "copilot": GitHub Models is not shown, and its key is still named.
        let shown = OpenCodeProviderList.rows(catalog: catalog, savedKeys: saved, search: "copilot")
        XCTAssertEqual(shown.inUse.map(\.id) + shown.available.map(\.id), ["github-copilot"])
        let row = try XCTUnwrap(shown.available.first)
        let replacing = OpenCodeProviderList.sharingKey(providerID: row.id, variable: row.keyVariable, catalog: catalog, savedKeys: saved)
        XCTAssertEqual(replacing.map(\.id), ["github-models"])
        XCTAssertEqual(replacing.map(\.name), ["GitHub Models"])

        // One OpenCode no longer lists goes by its ID; the provider's own key and other variables are not named.
        let more = saved.merging(["retired-github": "GITHUB_TOKEN", "github-copilot": "GITHUB_TOKEN"]) { $1 }
        XCTAssertEqual(OpenCodeProviderList.sharingKey(providerID: "github-copilot", variable: "GITHUB_TOKEN", catalog: catalog,
                                                       savedKeys: more).map(\.name), ["GitHub Models", "retired-github"])
        XCTAssertEqual(OpenCodeProviderList.sharingKey(providerID: "openai", variable: "OPENAI_API_KEY", catalog: catalog, savedKeys: more), [])
        XCTAssertEqual(OpenCodeProviderList.sharingKey(providerID: "github-copilot", variable: nil, catalog: catalog, savedKeys: more), [])
    }
}
