import SwiftUI
import AgentLandCore
import AgentLandDesign

/// What Settings says about the sign-ins Chat runs on (owner's decision, 2026-10-12: Chat uses the Claude and ChatGPT
/// subscriptions the Mac is signed in to, never API keys): each provider the host offers with its sign-in, then those
/// it found signed in otherwise, with what to do. Empty for hosts before then, which name no sign-in. Read-only. Chat's
/// are `workspaceChats`' (Claude Code and Codex in the workspaces).
public struct PlainChatSignIns: Equatable, Sendable {
    public struct Row: Identifiable, Equatable, Sendable {
        /// The provider's ID.
        public let id: String
        public let name: String
        /// The sign-in's name: "Claude subscription", "ChatGPT subscription", "Not signed in".
        public let value: String
        /// What to do, in the host's words, for a provider Chat cannot use; nil for one it can.
        public let detail: String?
        public let available: Bool
        /// Why Chat cannot use it, in the host's code (`subscription_required`, `version_unsupported`); nil for one it can.
        public let reason: String?

        /// The line under the name on the Mac (setup's Claude Code and Codex step, Settings → Agents): "Signed in with
        /// your Claude subscription" for a sign-in Chat runs on, else the sign-in's name ("API key", "Not signed in").
        public var status: String { available ? "Signed in with your \(value)" : value }

        /// What to run in Terminal to sign in with a subscription (`claude auth login`, `codex login`), for a provider
        /// signed in otherwise or not at all; nil for one Chat runs on and for a version Chat does not support, which
        /// signing in again does not fix.
        public var signInCommand: String? {
            guard !available, reason != PlainChatAuth.versionUnsupported else { return nil }
            return PlainChatSignIns.signInCommands[id]
        }
    }

    public let rows: [Row]

    public init(_ workspaceChats: WorkspaceChatsCapability?) {
        self.init(providers: workspaceChats?.providers ?? [], unavailable: workspaceChats?.unavailableProviders ?? [])
    }

    init(providers: [PlainChatProvider], unavailable: [PlainChatProvider]) {
        let offered = providers.compactMap { provider in
            provider.auth.map { Row(id: provider.id, name: provider.name, value: $0.label, detail: nil, available: true, reason: nil) }
        }
        let unavailable = unavailable.map { provider in
            Row(id: provider.id, name: provider.name, value: provider.auth?.label ?? "Not available",
                detail: provider.auth?.message, available: false, reason: provider.auth?.reason)
        }
        rows = offered + unavailable
    }

    public static let footer = "Chat uses the Claude and ChatGPT subscriptions this Mac is signed in to. API keys are for later."
    /// What the Mac's setup says when the host lists neither Claude Code nor Codex.
    public static let none = "Install Claude Code or Codex and sign in with your subscription to chat from your iPhone. Files and Terminal work without them."
    /// The commands that sign each CLI in with its subscription, as the host's messages name them. The Mac's Sign In…
    /// runs these and nothing else.
    public static let signInCommands = ["claude": "claude auth login", "codex": "codex login"]
}

/// The sign-ins as a section of a Settings form; nothing when the host names none.
struct PlainChatSignInSection: View {
    let signIns: PlainChatSignIns

    var body: some View {
        if !signIns.rows.isEmpty {
            Section {
                ForEach(signIns.rows) { row in
                    PlainChatSignInRow(row: row)
                }
            } header: {
                Text("Sign-ins")
            } footer: {
                Text(PlainChatSignIns.footer)
            }
        }
    }
}

/// A provider and its sign-in; for one Chat cannot use, what to do under it.
struct PlainChatSignInRow: View {
    let row: PlainChatSignIns.Row

    var body: some View {
        VStack(alignment: .leading, spacing: AgentLandSpacing.xxxSmall) {
            LabeledContent(row.name, value: row.value)
            if let detail = row.detail {
                // The warning colour goes on the symbol; small text in it is too faint on the system backgrounds.
                Label {
                    Text(detail).foregroundStyle(AgentLandColor.textSecondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AgentLandColor.warning)
                }
                .agentLandFont(.metadata)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chatSignIn-\(row.id)")
    }
}

#if os(macOS)
/// A Chat provider's sign-in on the Mac, in setup's Claude Code and Codex step and in Settings → Agents (owner,
/// 2026-10-17: setup shows the subscriptions the CLIs are signed in to instead of asking for API keys): the agent's
/// catalog icon (its initial until the host serves one), its name and its sign-in, with a checkmark for one Chat runs
/// on; for one it cannot use, the host's words on what to do and, when signing in fixes it, Sign In… (owner,
/// 2026-10-17: "Each agent that isn't signed in gets a Sign In… button. It opens Terminal running that CLI's own
/// sign-in") when the Mac passes `startSignIn`, then the command to run in Terminal with Copy.
public struct MacChatSignInRow: View {
    /// Where a Sign In… started from this row is.
    public enum SignIn: Equatable, Sendable {
        case idle
        /// Terminal runs the CLI's sign-in and the Mac asks the host every few seconds.
        case waiting
        /// The script could not be written or opened.
        case couldNotOpen
    }

    private let row: PlainChatSignIns.Row
    private let icons: AgentIconStore
    private let signIn: SignIn
    private let startSignIn: (() -> Void)?
    @State private var copied = false

    public init(row: PlainChatSignIns.Row, icons: AgentIconStore, signIn: SignIn = .idle, startSignIn: (() -> Void)? = nil) {
        self.row = row
        self.icons = icons
        self.signIn = signIn
        self.startSignIn = startSignIn
    }

    /// Whether a row has Sign In…: only where the Mac offers it and signing in fixes the row (not signed in, or signed
    /// in otherwise than with a subscription); a row signed in with one and a version Chat does not support have none.
    public static func offersSignIn(_ row: PlainChatSignIns.Row, offered: Bool) -> Bool {
        offered && row.signInCommand != nil
    }

    public static let waiting = "Waiting for sign-in in Terminal…"
    public static let couldNotOpen = "AgentLand couldn’t open Terminal. Run the command below in Terminal."

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentIconView(id: row.id, name: row.name, icons: icons)
            VStack(alignment: .leading, spacing: AgentLandSpacing.xxSmall) {
                VStack(alignment: .leading, spacing: AgentLandSpacing.xxxSmall) {
                    Text(row.name)
                    Text(row.status).font(.footnote).foregroundStyle(.secondary)
                    if let detail = row.detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chatSignIn-\(row.id)")
                if let command = row.signInCommand {
                    if let startSignIn, Self.offersSignIn(row, offered: true) { signInLine(startSignIn) }
                    commandLine(command)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: row.available ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(row.available ? AgentLandColor.success : AgentLandColor.warning)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
    }

    /// Sign In…, which stays enabled so a closed Terminal can be opened again, and while the Mac waits, a small
    /// progress indicator and what it waits for.
    private func signInLine(_ start: @escaping () -> Void) -> some View {
        HStack(spacing: AgentLandSpacing.xSmall) {
            Button("Sign In…", action: start)
                .minimumTapTarget()
                .accessibilityLabel("Sign in to \(row.name)")
                .accessibilityIdentifier("chatSignInButton-\(row.id)")
            switch signIn {
            case .idle:
                EmptyView()
            case .waiting:
                HStack(spacing: AgentLandSpacing.xxSmall) {
                    ProgressView().controlSize(.small)
                    Text(Self.waiting).font(.footnote).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chatSignInWaiting-\(row.id)")
            case .couldNotOpen:
                Text(Self.couldNotOpen)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("chatSignInCouldNotOpen-\(row.id)")
            }
        }
    }

    /// The command in code type, selectable, and Copy, which says Copied for a moment.
    private func commandLine(_ command: String) -> some View {
        HStack(spacing: AgentLandSpacing.xSmall) {
            Text(command)
                .agentLandFont(.code)
                .textSelection(.enabled)
                .padding(.horizontal, AgentLandSpacing.xSmall)
                .padding(.vertical, AgentLandSpacing.xxSmall)
                .background(.fill.quaternary, in: AgentLandRadius.shape(AgentLandRadius.chip))
                .accessibilityLabel("Run \(command) in Terminal")
            Button {
                WorkspacePlatform.copy(command)
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .accessibilityLabel(copied ? "Copied" : "Copy \(command)")
            .accessibilityIdentifier("chatSignInCopy-\(row.id)")
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
#endif
