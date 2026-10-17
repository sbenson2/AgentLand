import SwiftUI
import AgentLandDesign
import AgentLandDesktopCore
import AgentLandWorkspace

/// Settings → API Keys (Later), formerly AI Providers: the providers the running OpenCode speaks (its
/// `GET /provider`, models.dev's catalog) in a list, each with whether it is connected and how many models it has, and
/// a search. Add Key… saves a key in the Keychain under the provider's variable, as provider keys have always been
/// saved; Remove Key deletes it. Keys and the default model reach OpenCode when it restarts, which AgentLand does
/// on its own as soon as nothing runs on the host (`OpenCodeRestartPolicy`). Chat doesn't use these keys: it runs
/// Claude Code and Codex in the workspace, on the Claude and ChatGPT subscriptions this Mac is signed in to (owner's
/// decisions, 2026-10-12); API keys are for later.
struct ProviderSettingsPane: View {
    @EnvironmentObject private var host: HostController
    @State private var search = ""
    @State private var selection: String?
    @State private var addingKey: OpenCodeProviderRow?
    @State private var removingKey: OpenCodeProviderRow?
    @State private var keyError: String?

    var body: some View {
        let rows = OpenCodeProviderList.rows(catalog: host.providerCatalog, savedKeys: host.savedProviderKeys, search: search)
        VStack(alignment: .leading, spacing: 8) {
            if !host.managedOpenCode {
                if let error = host.errorMessage { SettingsErrorText(message: error) }
                ContentUnavailableView("AgentLand Isn’t Running OpenCode", systemImage: "key",
                                       description: Text(AIProvidersText.externalOpenCode))
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                MacSettingsFootnote(AIProvidersText.chatUsesSubscriptions)
            } else {
                Form {
                    SettingsHostError()
                    Section {
                        status
                        MacSettingsFootnote(AIProvidersText.chatUsesSubscriptions)
                    }
                    Section { DefaultModelFields() }
                }
                .formStyle(.columns)
                .padding(.bottom, 8)
                providerList(rows)
                buttons(rows)
                MacSettingsFootnote(AIProvidersText.restartRule(hostReportsIdle: host.hostReportsIdle))
            }
        }
        .onAppear { host.refreshProviders() }
        .sheet(item: $addingKey) { row in
            // Every saved key under the variable, whatever the search shows: each one Save deletes.
            let replacing = OpenCodeProviderList.sharingKey(providerID: row.id, variable: row.keyVariable,
                                                            catalog: host.providerCatalog, savedKeys: host.savedProviderKeys)
            ProviderKeySheet(row: row, replacing: replacing.map(\.name)) { key in
                guard let variable = row.keyVariable else { return }
                try host.saveProviderKey(key, providerID: row.id, variable: variable, replacing: Set(replacing.map(\.id)))
                keyError = nil
            }
        }
        .confirmationDialog("Remove the key for “\(removingKey?.name ?? "")”?", isPresented: removeShown, titleVisibility: .visible,
                            presenting: removingKey) { row in
            Button("Remove Key", role: .destructive) {
                do { try host.removeProviderKey(providerID: row.id); keyError = nil }
                catch { keyError = redact(error.localizedDescription) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("AgentLand deletes it from your Keychain. OpenCode stops using it when it restarts.")
        }
        // A key that couldn't be removed needs the person: the system's alert.
        .alert("Couldn’t Remove the Key", isPresented: Binding(get: { keyError != nil }, set: { if !$0 { keyError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(keyError ?? "")
        }
    }

    /// What runs, why the previous version runs when it does, what waits for a restart, and the last
    /// restart AgentLand made on its own. While a start gets OpenCode, its progress; when none is available,
    /// why, with Try Again.
    @ViewBuilder private var status: some View {
        if let install = host.openCodeInstall {
            LabeledContent("OpenCode:") { OpenCodeInstallRow(progress: install) }
        } else if let unavailable = host.openCodeUnavailable {
            LabeledContent("OpenCode:") {
                HStack(alignment: .firstTextBaseline) {
                    Text(AIProvidersText.unavailable)
                    Button("Try Again") { host.retryOpenCode() }
                        .controlSize(.small)
                        .disabled(host.isWorking)
                        .accessibilityHint("Gets OpenCode again and starts it.")
                }
            }
            MacSettingsFootnote(unavailable.message).textSelection(.enabled)
        } else {
            LabeledContent("OpenCode:") {
                HStack(alignment: .firstTextBaseline) {
                    Text(AIProvidersText.running(host.openCodeReport))
                    Button("Refresh") { host.refreshProviders() }
                        .controlSize(.small)
                        .disabled(host.status != .running || host.providerIsWorking)
                        .accessibilityHint("Reads OpenCode’s providers again.")
                }
            }
        }
        ForEach(AIProvidersText.notes(report: host.openCodeReport, pending: host.openCodeSettingsPending,
                                      hostReportsIdle: host.hostReportsIdle, activity: host.openCodeActivity), id: \.self) { note in
            MacSettingsFootnote(note).textSelection(.enabled)
        }
    }

    /// The search, then In Use and Available in one bordered list.
    @ViewBuilder private func providerList(_ rows: (inUse: [OpenCodeProviderRow], available: [OpenCodeProviderRow])) -> some View {
        MacSearchField(text: $search, prompt: "Provider, ID or variable", identifier: "providersSearch")
        if rows.inUse.isEmpty && rows.available.isEmpty {
            MacSettingsListBox {
                if !search.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    ContentUnavailableView("No Providers", systemImage: "key",
                                           description: Text(host.providerCatalogMessage.map { "OpenCode’s providers could not be read: \($0)" }
                                                             ?? AIProvidersText.notListed))
                }
            }
            .frame(height: MacSettingsMetrics.listHeight)
        } else {
            list(rows)
        }
    }

    private func list(_ rows: (inUse: [OpenCodeProviderRow], available: [OpenCodeProviderRow])) -> some View {
        List(selection: $selection) {
            if !rows.inUse.isEmpty {
                Section("In Use") {
                    ForEach(rows.inUse) { row in ProviderRowView(row: row).tag(row.id) }
                }
            }
            if !rows.available.isEmpty {
                Section("Available") {
                    ForEach(rows.available) { row in ProviderRowView(row: row).tag(row.id) }
                }
            }
        }
        .listStyle(.bordered)
        .alternatingRowBackgrounds()
        .contextMenu(forSelectionType: String.self) { ids in
            if let row = row(ids.first, in: rows) {
                if row.keyVariable != nil {
                    Button(row.savedKeyVariable == nil ? "Add Key…" : "Replace Key…") { addingKey = row }
                }
                if row.savedKeyVariable != nil {
                    Button("Remove Key", role: .destructive) { removingKey = row }
                }
            }
        } primaryAction: { ids in
            if let row = row(ids.first, in: rows), row.keyVariable != nil { addingKey = row }
        }
        .frame(height: MacSettingsMetrics.listHeight)
        .accessibilityIdentifier("providersList")
    }

    /// Add Key… (Replace Key… for a saved one) and Remove Key, for the selected provider.
    private func buttons(_ rows: (inUse: [OpenCodeProviderRow], available: [OpenCodeProviderRow])) -> some View {
        let selected = row(selection, in: rows)
        return HStack(spacing: 8) {
            Spacer()
            Button("Remove Key") { removingKey = selected }
                .disabled(selected?.savedKeyVariable == nil)
                .accessibilityLabel(selected.map { "Remove Key for \($0.name)" } ?? "Remove Key")
            Button(selected?.savedKeyVariable == nil ? "Add Key…" : "Replace Key…") { addingKey = selected }
                .disabled(selected?.keyVariable == nil)
                .accessibilityLabel(selected.map { "\($0.savedKeyVariable == nil ? "Add Key" : "Replace Key") for \($0.name)" } ?? "Add Key")
        }
    }

    private func row(_ id: String?, in rows: (inUse: [OpenCodeProviderRow], available: [OpenCodeProviderRow])) -> OpenCodeProviderRow? {
        guard let id else { return nil }
        return rows.inUse.first { $0.id == id } ?? rows.available.first { $0.id == id }
    }

    private var removeShown: Binding<Bool> {
        Binding(get: { removingKey != nil }, set: { if !$0 { removingKey = nil } })
    }
}

/// Getting OpenCode through the host: "Getting OpenCode 1.18.32…", with a bar while the host knows the
/// download's size.
struct OpenCodeInstallRow: View {
    let progress: OpenCodeInstallProgress

    var body: some View {
        VStack(alignment: .leading, spacing: AgentLandSpacing.xxSmall) {
            Text(progress.title)
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                    .accessibilityLabel(progress.title)
                    .accessibilityValue("\(Int((fraction * 100).rounded(.down))) percent")
            }
        }
    }
}

/// One provider: its name, connected or not, its model count and whether a key is saved here. A connected provider
/// lists the models OpenCode's chats offer from it.
private struct ProviderRowView: View {
    let row: OpenCodeProviderRow

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                Text(AIProvidersText.detail(row))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            if row.connected == true, let models = row.models, !models.isEmpty {
                DisclosureGroup("Chat models") {
                    ForEach(models) { model in
                        Text(model.name)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .font(.footnote)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The default model of OpenCode's chats: a connected provider and one of its models, or OpenCode's own
/// choice. It is saved with the preferences the single-provider settings always used.
private struct DefaultModelFields: View {
    @EnvironmentObject private var host: HostController

    var body: some View {
        let connected = host.providerCatalog.filter { $0.isConnected && !$0.models.isEmpty }
        let current = host.defaultModel
        Picker("Default provider:", selection: providerSelection(connected)) {
            Text("OpenCode’s choice").tag("")
            ForEach(connected) { provider in Text(provider.name).tag(provider.id) }
            if let current, !connected.contains(where: { $0.id == current.providerID }) {
                Text(current.providerID).tag(current.providerID)
            }
        }
        .macSettingsGroupStart()
        if let current {
            if let provider = connected.first(where: { $0.id == current.providerID }) {
                Picker("Default model:", selection: modelSelection(provider)) {
                    ForEach(provider.models) { model in Text(model.name).tag(model.id) }
                    if !provider.models.contains(where: { $0.id == current.modelID }) {
                        Text(current.modelID).tag(current.modelID)
                    }
                }
            } else {
                LabeledContent("Default model:", value: current.modelID)
            }
        }
        MacSettingsFootnote("New chats start with this model; each chat can pick another. Only connected providers are listed.")
    }

    private func providerSelection(_ connected: [OpenCodeProviderOption]) -> Binding<String> {
        Binding(get: { host.defaultModel?.providerID ?? "" }, set: { id in
            guard id != (host.defaultModel?.providerID ?? "") else { return }
            guard let provider = connected.first(where: { $0.id == id }) else {
                host.setDefaultModel(providerID: nil, modelID: nil)
                return
            }
            let model = provider.defaultModelID.flatMap { preferred in provider.models.first { $0.id == preferred } } ?? provider.models.first
            host.setDefaultModel(providerID: provider.id, modelID: model?.id)
        })
    }

    private func modelSelection(_ provider: OpenCodeProviderOption) -> Binding<String> {
        Binding(get: { host.defaultModel?.modelID ?? "" }, set: { host.setDefaultModel(providerID: provider.id, modelID: $0) })
    }
}

/// Add Key…: a native sheet with a secure field for the key, saved only by Save Key. It names the variable OpenCode
/// reads it from, what else the provider needs, and every provider whose saved key it replaces; Save asks before
/// it deletes theirs.
private struct ProviderKeySheet: View {
    let row: OpenCodeProviderRow
    /// Every other provider whose saved key uses the same variable, which this key replaces.
    let replacing: [String]
    let save: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var error: String?
    @State private var confirmingReplace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(row.savedKeyVariable == nil ? "Add" : "Replace") the Key for \(row.name)")
                .font(.headline)
            ForEach(AIProvidersText.keyNotes(row, replacing: replacing), id: \.self) { note in
                Text(note)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Form {
                SecureField("Key:", text: $key, prompt: Text("Paste the key"))
                    .accessibilityLabel("Key for \(row.name)")
            }
            .formStyle(.columns)
            if let error { SettingsErrorText(message: error) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save Key") {
                    if replacing.isEmpty { saveKey() } else { confirmingReplace = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .confirmationDialog(AIProvidersText.replaceTitle(replacing), isPresented: $confirmingReplace, titleVisibility: .visible) {
            Button(AIProvidersText.replaceButton(replacing), role: .destructive) { saveKey() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(AIProvidersText.replaceMessage(row, replacing: replacing))
        }
    }

    private func saveKey() {
        do {
            try save(key)
            key = ""
            dismiss()
        } catch {
            self.error = redact(error.localizedDescription)
        }
    }
}

/// The pane's words, apart from the views so the tests read them.
enum AIProvidersText {
    /// When key and model changes reach OpenCode: on their own only when AgentLand learns when the host
    /// is idle (`HostController.hostReportsIdle`; nil while it has not asked yet).
    static func restartRule(hostReportsIdle: Bool?) -> String {
        "Keys stay in your Keychain; saving one doesn’t check it. " + (hostReportsIdle == false
            ? "OpenCode picks up key and model changes when AgentLand next starts the host."
            : "OpenCode picks up key and model changes when it restarts, which AgentLand does as soon as no chat, terminal or device is active on this Mac’s host.")
    }
    static let externalOpenCode = "Keys here are for the OpenCode that AgentLand runs. Turn on “Manage OpenCode automatically” in Advanced to use them."
    /// Chat runs Claude Code and Codex on the subscriptions (owner's decisions, 2026-10-12).
    static let chatUsesSubscriptions = "Chat runs Claude Code and Codex with your Claude and ChatGPT subscriptions, not these keys. API keys are for later."
    static let notListed = "Connect to see every provider OpenCode supports. Keys saved here are listed below."

    /// What runs.
    static func running(_ report: OpenCodeRuntimeReport?) -> String {
        guard let report else { return "OpenCode isn’t running." }
        switch report.source {
        case .managed: return "OpenCode \(report.version), installed and updated by the host"
        case .previous: return "OpenCode \(report.version), the host’s previous version"
        }
    }

    /// The row while no OpenCode is available; the reason follows it.
    static let unavailable = "OpenCode isn’t available."

    /// Why the previous version runs, what waits for a restart, and the last restart AgentLand made.
    static func notes(report: OpenCodeRuntimeReport?, pending: Bool, hostReportsIdle: Bool?, activity: String?) -> [String] {
        var notes: [String] = []
        if let reason = report?.fallbackReason { notes.append(reason) }
        if pending {
            notes.append(hostReportsIdle == false
                ? "Your changes apply when AgentLand next starts the host. AgentLand can’t tell when this host is idle, so it doesn’t restart the host on its own. Disconnect and Connect to apply them now."
                : "Your changes wait for OpenCode to restart, which AgentLand does as soon as no chat, terminal or device is active.")
        }
        if let activity { notes.append(activity) }
        return notes
    }

    /// A row's second line.
    static func detail(_ row: OpenCodeProviderRow) -> String {
        var parts: [String] = []
        switch row.connected {
        case true?: parts.append("Connected")
        case false?: parts.append("Not connected")
        case nil: parts.append("Not listed by OpenCode now")
        }
        if let count = row.modelCount { parts.append(count == 1 ? "1 model" : "\(count) models") }
        if let variable = row.savedKeyVariable { parts.append("Key saved as \(variable)") }
        return parts.joined(separator: " · ")
    }

    /// What Add Key… says: the variable, what AgentLand does not set, and whose keys it replaces.
    static func keyNotes(_ row: OpenCodeProviderRow, replacing: [String]) -> [String] {
        let variable = row.keyVariable ?? "its variable"
        var notes = ["AgentLand keeps the key in your Keychain and gives it to OpenCode as \(variable). Saving it doesn’t check it; \(row.name) does when a chat uses it."]
        if !row.otherVariables.isEmpty {
            notes.append("\(row.name) also reads \(row.otherVariables.joined(separator: ", ")), which AgentLand doesn’t set.")
        }
        if let note = replacesNote(variable: variable, replacing: replacing) { notes.append(note) }
        return notes
    }

    /// Every provider whose saved key a key under `variable` deletes, named; nil when there is none.
    static func replacesNote(variable: String, replacing: [String]) -> String? {
        guard !replacing.isEmpty else { return nil }
        return "\(list(replacing)) use\(replacing.count == 1 ? "s" : "") \(variable) too. OpenCode reads one \(variable), so saving this key deletes the \(keys(replacing)) saved for \(list(replacing))."
    }

    /// Save Key's confirmation when the key replaces others.
    static func replaceTitle(_ replacing: [String]) -> String {
        "Replace the \(keys(replacing)) saved for \(list(replacing))?"
    }

    static func replaceMessage(_ row: OpenCodeProviderRow, replacing: [String]) -> String {
        "OpenCode reads one \(row.keyVariable ?? "value for this variable"). AgentLand deletes the \(keys(replacing)) saved for \(list(replacing)) from your Keychain and saves this one for \(row.name)."
    }

    static func replaceButton(_ replacing: [String]) -> String {
        replacing.count == 1 ? "Replace Key" : "Replace Keys"
    }

    private static func keys(_ names: [String]) -> String { names.count == 1 ? "key" : "keys" }

    /// "A", "A and B", "A, B and C".
    static func list(_ names: [String]) -> String {
        guard let last = names.last, names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}
