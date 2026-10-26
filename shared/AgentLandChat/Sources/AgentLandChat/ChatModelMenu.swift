import SwiftUI
import AgentLandCore

/// The model menu's lists (owner's request, 2026-10-07): the host's first five models in its own order, then every
/// other model under More Models, one group per provider. The host sends no dates, so its order decides which come
/// first.
struct ChatModelMenuGroups: Equatable {
    /// How many models the menu shows before More Models.
    static let firstCount = 5

    struct ProviderGroup: Equatable, Identifiable {
        let provider: String
        let models: [AgentModelOption]
        var id: String { provider }
    }

    /// The first five models, in the host's order.
    let first: [AgentModelOption]
    /// Every other model: one group per provider, providers by name, each group's models in the host's order. Empty
    /// with five models or fewer.
    let more: [ProviderGroup]

    init(_ models: [AgentModelOption]) {
        first = Array(models.prefix(Self.firstCount))
        let rest = Array(models.dropFirst(Self.firstCount))
        more = Set(rest.map(\.provider)).sorted().map { provider in
            ProviderGroup(provider: provider, models: rest.filter { $0.provider == provider })
        }
    }
}

/// What an effort is called, and what it does, in the pill's Thinking menu. The host sends Claude Code's and Codex's
/// own IDs.
enum ChatEffort {
    static func name(_ id: String) -> String {
        switch id {
        case "xhigh": "Extra High"
        default: id.capitalized
        }
    }

    /// A model's name without a trailing note in parentheses, for the pill; the menu keeps the whole name.
    static func shortName(_ name: String) -> String {
        guard name.hasSuffix(")"), let open = name.lastIndex(of: "(") else { return name }
        let short = name[..<open].trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? name : short
    }

    static func summary(_ id: String) -> String? {
        switch id {
        case "minimal": "Answers almost at once"
        case "low": "Quick answers"
        case "medium": "Balanced"
        case "high": "Thinks longer"
        case "xhigh": "Thinks much longer"
        case "max": "Thinks the longest"
        default: nil
        }
    }
}

extension ChatSessionStore {
    /// The chosen model's name, as the menu lists it.
    var menuModelName: String { selectedModel?.name ?? (options == nil ? "Default model" : "Choose model") }

    /// The pill's shorter name: without a trailing note in parentheses ("Default (recommended)" is "Default").
    var pillModelName: String { ChatEffort.shortName(menuModelName) }

    /// The chosen effort's name, when the provider takes one.
    var menuEffortName: String? {
        guard !effortChoices.isEmpty, let effort = selectedEffort else { return nil }
        return ChatEffort.name(effort)
    }

    /// "Sonnet 4.5 · High": the chosen model, with the effort when its provider takes one.
    var modelMenuSummary: String { menuEffortName.map { "\(menuModelName) · \($0)" } ?? menuModelName }

    /// The mode, when it isn't one that asks first: the pill shows its symbol, so Plan or Bypass can't go unnoticed.
    var flaggedMode: ChatModeChoice? {
        guard let mode = selectedModeChoice, modeChoices.count > 1, !["default", "ask"].contains(mode.id) else { return nil }
        return mode
    }
}

/// The composer pill's menu (owner, 2026-10-25: one pill that combines the model and its reasoning, as Claude's and
/// ChatGPT's apps do): the first five models (the chosen one checked, its context size under its name), More Models
/// with every other model, then Thinking and Permissions, each a submenu that shows its current choice. No search: a
/// long list is the submenu's.
struct ChatModelMenuContent: View {
    let store: ChatSessionStore

    var body: some View {
        let models = store.options?.models ?? []
        Section {
            if models.isEmpty {
                Button {} label: {
                    Label("No Models", systemImage: "cpu")
                    Text("This provider has no models set up. Choose one in AgentLand on your Mac.")
                }
                .disabled(true)
            } else {
                let groups = ChatModelMenuGroups(models)
                modelPicker(groups.first)
                if !groups.more.isEmpty {
                    Menu("More Models", systemImage: "ellipsis.circle") {
                        if groups.more.count == 1 {
                            modelPicker(groups.more[0].models)
                        } else {
                            ForEach(groups.more) { group in
                                Section(group.provider) { modelPicker(group.models) }
                            }
                        }
                    }
                    .accessibilityIdentifier("chatMoreModels")
                }
            }
        }
        Section {
            if !store.effortChoices.isEmpty { thinking }
            if store.modeChoices.count > 1 { permissions }
        }
    }

    /// One group of models; the system checks the chosen one when it is in the group.
    private func modelPicker(_ models: [AgentModelOption]) -> some View {
        let ids = Set(models.map(\.id))
        let selection = Binding<String?>(get: { ids.contains(store.selectedModelID) ? store.selectedModelID : nil },
                                         set: { if let id = $0 { store.selectModel(id) } })
        return Picker(selection: selection) {
            ForEach(models) { model in
                // A menu item's second text is its subtitle.
                VStack(alignment: .leading) {
                    Label(model.name, systemImage: "cpu")
                    if let context = model.contextWindow {
                        Text("\(context.formatted(.number.notation(.compactName))) context")
                    }
                }
                .tag(Optional(model.id))
            }
        } label: { EmptyView() }
        .pickerStyle(.inline)
    }

    /// How hard the model thinks: a submenu whose row shows the current effort. Its items are toggles, which the
    /// system checks like a picker's and which keep each item's summary as its subtitle (a picker's items drop it).
    private var thinking: some View {
        Menu {
            ForEach(store.effortChoices, id: \.self) { effort in
                Toggle(isOn: Binding(get: { store.selectedEffort == effort }, set: { if $0 { store.selectEffort(effort) } })) {
                    Text(ChatEffort.name(effort))
                    if let summary = ChatEffort.summary(effort) { Text(summary) }
                }
            }
        } label: {
            Label("Thinking", systemImage: "brain")
            Text(store.menuEffortName ?? "Default")
        }
        .accessibilityIdentifier("chatEffortPicker")
    }

    /// What the agent may do without asking, a submenu whose row shows the current mode, its items toggles like
    /// Thinking's. Bypass permissions and Full access ask first, on the pill (`chatModeConfirmation(_:origin:
    /// .composer)`); the mode changes between turns.
    private var permissions: some View {
        Menu {
            ForEach(store.modeChoices) { choice in
                Toggle(isOn: Binding(get: { store.selectedModeChoice?.id == choice.id },
                                     set: { if $0 { store.selectMode(choice.id, from: .composer) } })) {
                    Label(choice.name, systemImage: choice.symbol)
                    Text(choice.summary)
                }
                .accessibilityIdentifier(choice.id == "plan" ? "chatPlanToggle" : "chatMode-\(choice.id)")
            }
        } label: {
            Label("Permissions", systemImage: store.selectedModeChoice?.symbol ?? "hand.raised")
            Text(store.selectedModeChoice?.name ?? "Default")
        }
        .disabled(store.isWorking)
        .accessibilityIdentifier("chatModeMenu")
    }
}
