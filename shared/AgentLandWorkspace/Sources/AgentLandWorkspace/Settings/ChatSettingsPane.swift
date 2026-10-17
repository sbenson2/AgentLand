import SwiftUI
import AgentLandChat
import AgentLandCore
import AgentLandDesign

/// iPhone and iPad Settings → Chat: the model new chats on the attached host start with (for a host that
/// offers chats), the sign-ins Chat runs on (`PlainChatSignIns`), tool details open by default, long pastes as
/// files, and the send haptic where the device has haptics. All saved on this device; the model per host.
public struct ChatSettingsPane: View {
    @Environment(WorkspaceModel.self) private var workspace
    @AppStorage(ChatSettings.expandDetailsKey) private var expandDetails = ChatSettings.expandDetailsDefault
    @AppStorage(ChatSettings.sendHapticKey) private var sendHaptic = ChatSettings.sendHapticDefault
    @AppStorage(ChatSettings.longPasteAsFileKey) private var longPastes = ChatSettings.longPasteAsFileDefault
    @State private var models = PlainChatModels()
    /// The device can play haptics (the app knows; iPad cannot).
    let offersHaptics: Bool

    public init(offersHaptics: Bool) { self.offersHaptics = offersHaptics }

    public var body: some View {
        AgentLandForm {
            if workspace.offersPlainChats {
                Section {
                    if workspace.plainChatProviders.count > 1 {
                        Picker("Provider", selection: Binding(get: { workspace.plainChatDefaultProvider.id },
                            set: { workspace.setPlainChatDefaultProvider(AgentProvider(id: $0)) })) {
                            if !workspace.plainChatProviders.contains(where: { $0.id == workspace.plainChatDefaultProvider.id }) {
                                Label("\(workspace.plainChatDefaultProvider.chatDisplayName) (unavailable)", systemImage: "exclamationmark.bubble")
                                    .tag(workspace.plainChatDefaultProvider.id)
                            }
                            ForEach(workspace.plainChatProviders) { provider in
                                Label {
                                    Text(provider.name)
                                } icon: {
                                    workspace.agents.icons.menuImage(for: provider.id, fallback: "bubble.left.and.bubble.right")
                                }.tag(provider.id)
                            }
                        }
                        .accessibilityIdentifier("chatDefaultProvider")
                    }
                    NavigationLink {
                        PlainChatModelPage(models: models)
                    } label: {
                        LabeledContent("Default model", value: models.choiceName(workspace.plainChatDefaultModel))
                    }
                    .accessibilityIdentifier("chatDefaultModel")
                } header: {
                    Text("New chats")
                } footer: {
                    Text("New chats on \(workspace.hostName) start with this agent and model, in the workspace in use. Chats you already started keep theirs.")
                }
            }
            PlainChatSignInSection(signIns: PlainChatSignIns(workspace.capabilities?.workspaceChats))
            Section("Replies") {
                SettingsToggleRow("Expand tool details", detail: "Reasoning and tool activity show open in every reply.",
                                  isOn: $expandDetails)
                    .accessibilityIdentifier("chatExpandDetails")
            }
            Section {
                SettingsToggleRow("Long pastes as files",
                                  detail: "A paste over \(ChatLongPaste.lineLimit) lines or \(ChatLongPaste.characterLimit.formatted()) characters is attached as a text file.",
                                  isOn: $longPastes)
                    .accessibilityIdentifier("chatLongPastes")
                if offersHaptics {
                    SettingsToggleRow("Haptic on send", isOn: $sendHaptic)
                        .accessibilityIdentifier("chatSendHaptic")
                }
            } header: {
                Text("Composer")
            } footer: {
                Text("A host that takes no attachments keeps a long paste in the message.")
            }
        }
        .settingsForm()
        .task(id: "\(workspace.paneReadKey)|\(workspace.plainChatDefaultProvider.id)|\(workspace.selectedProjectID ?? "")") {
            guard workspace.offersPlainChats else { return }
            await models.load(workspace)
        }
    }
}

/// The models a host's chats can use, read from its chat options for the workspace in use (else its first): Chat's
/// chats run in the workspaces.
@MainActor @Observable final class PlainChatModels {
    private(set) var options: ChatOptionsResponse?
    private(set) var issue: String?
    private(set) var loading = false

    func load(_ workspace: WorkspaceModel) async {
        guard let stamp = workspace.requestStamp(), workspace.reachable,
              let projectID = workspace.currentProject?.id ?? workspace.projects.first(where: { !workspace.isChatsSpace($0.id) })?.id
        else { return }
        loading = true
        defer { loading = false }
        do {
            let provider = workspace.plainChatDefaultProvider
            options = nil
            let read = try await stamp.client.chatOptions(projectID: projectID, provider: provider.id)
            guard workspace.isCurrent(stamp), workspace.plainChatDefaultProvider == provider else { return }
            options = read
            issue = nil
        } catch {
            guard workspace.isCurrent(stamp), !isCancellation(error) else { return }
            issue = error.localizedDescription
        }
    }

    /// The host's default model, by name when it lists it.
    var hostDefaultName: String? {
        guard let options else { return nil }
        return options.models.first { $0.id == options.defaultModel }?.name
    }

    /// What Settings shows for `choice`: the model's name, "Mac's Default" for none, or the ID of a model the host
    /// no longer lists (a new chat then starts with the host's default).
    func choiceName(_ choice: String?) -> String {
        guard let choice else { return "Mac’s default" }
        return options?.models.first { $0.id == choice }?.name ?? choice
    }
}

/// The models to choose from, grouped by provider, with the host's default first; searchable when the list is long.
struct PlainChatModelPage: View {
    @Environment(WorkspaceModel.self) private var workspace
    let models: PlainChatModels
    @State private var query = ""

    var body: some View {
        List {
            if let options = models.options {
                Section {
                    row(title: "Mac’s default", detail: models.hostDefaultName, id: nil)
                } footer: {
                    Text("The model \(workspace.hostName) uses unless a chat chooses another.")
                        .agentLandFont(.metadata)
                        .foregroundStyle(AgentLandColor.textSecondary)
                }
                let filtered = query.isEmpty ? options.models : options.models.filter {
                    $0.name.localizedCaseInsensitiveContains(query) || $0.provider.localizedCaseInsensitiveContains(query)
                }
                ForEach(Array(Dictionary(grouping: filtered, by: \.provider).keys).sorted(), id: \.self) { provider in
                    Section(provider) {
                        ForEach(filtered.filter { $0.provider == provider }) { model in
                            row(title: model.name, detail: nil, id: model.id)
                        }
                    }
                }
                if filtered.isEmpty && !query.isEmpty {
                    ContentUnavailable.search(text: query)
                        .listRowBackground(Color.clear)
                }
            } else if let issue = models.issue {
                ContentUnavailable("Couldn’t Load Models", systemImage: "exclamationmark.triangle", description: issue,
                                   actionTitle: "Try Again") { Task { await models.load(workspace) } }
                    .listRowBackground(Color.clear)
            } else if !workspace.reachable || workspace.client == nil {
                ContentUnavailable("\(workspace.hostName) Isn’t Connected", systemImage: "wifi.exclamationmark",
                                   description: "Its models show here once it’s connected.")
                    .listRowBackground(Color.clear)
            } else {
                ProgressView("Loading Models")
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .listPageBackground()
        .searchable(text: $query, prompt: "Find a Model")
        .accessibilityIdentifier("chatDefaultModelList")
        .workspaceSettingsPage("Default Model")
        .task(id: workspace.paneReadKey) { if models.options == nil { await models.load(workspace) } }
    }

    private func row(title: String, detail: String?, id: String?) -> some View {
        SettingsChoiceRow(title, detail: detail, selected: workspace.plainChatDefaultModel == id) {
            workspace.setPlainChatDefaultModel(id)
        }
        .listRowFill(.surface)
        .accessibilityIdentifier("chatDefaultModel-\(id ?? "host")")
    }
}
