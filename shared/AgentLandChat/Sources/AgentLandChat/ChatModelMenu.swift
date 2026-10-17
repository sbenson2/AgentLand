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

extension ChatSessionStore {
    /// "Sonnet 4.5 · High": the chosen model, with the effort when its provider takes one.
    var modelMenuSummary: String {
        let name = selectedModel?.name ?? (options == nil ? "Default model" : "Choose model")
        guard !effortChoices.isEmpty, let effort = selectedEffort else { return name }
        return "\(name) · \(effort.capitalized)"
    }
}

/// What the model chip's menu holds, also the Options menu's and the title menu's Model submenu: the first five
/// models (the chosen one checked, its context size under its name), More Models as a submenu with every other model,
/// then the chosen model's efforts. No search: a long list is the submenu's.
struct ChatModelMenuContent: View {
    let store: ChatSessionStore
    /// Runs after a model or effort is chosen (the iPhone task menu closes itself with it).
    var chosen: (() -> Void)? = nil

    var body: some View {
        let models = store.options?.models ?? []
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
        if !store.effortChoices.isEmpty {
            Section("Effort") {
                // The picker's own label stays empty: the section names it, once.
                Picker(selection: Binding(get: { store.selectedEffort }, set: { if let effort = $0 { store.selectEffort(effort); chosen?() } })) {
                    ForEach(store.effortChoices, id: \.self) { Label($0.capitalized, systemImage: "brain").tag(Optional($0)) }
                } label: { EmptyView() }
                .pickerStyle(.inline)
                .accessibilityIdentifier("chatEffortPicker")
            }
        }
    }

    /// One group of models; the system checks the chosen one when it is in the group.
    private func modelPicker(_ models: [AgentModelOption]) -> some View {
        let ids = Set(models.map(\.id))
        let selection = Binding<String?>(get: { ids.contains(store.selectedModelID) ? store.selectedModelID : nil },
                                         set: { if let id = $0 { store.selectModel(id); chosen?() } })
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
}
