import SwiftUI
import AgentLandCore
import AgentLandDesign
import AgentLandWorkspace

struct OnboardingContent: View {
    @EnvironmentObject private var host: HostController

    var body: some View {
        switch host.onboardingStage {
        case .folder: folder
        case .preparing: preparing
        case .agents: OnboardingAgentsStep()
        case .ready: ready
        }
    }

    private var folder: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose your default workspace folder").font(.title3.weight(.semibold))
            Text("AgentLand opens this folder in the workspace explorer on your paired devices. Paired devices can edit its files and run commands on this Mac.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Choose default folder…") { host.chooseWorkspaceAndSetUp() }.buttonStyle(.borderedProminent)
        }
    }

    /// The local service and OpenCode: the progress (with a bar while getting OpenCode, when its size is known).
    /// Setup goes on once the host runs, with or without OpenCode: Settings and the menu say why it isn't there.
    private var preparing: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preparing your workspace").font(.title3.weight(.semibold))
            if let progress = host.setupProgress { Text(progress).font(.callout).foregroundStyle(.secondary) }
            if host.isWorking {
                if let fraction = host.openCodeInstall?.fraction {
                    ProgressView(value: fraction)
                        .accessibilityLabel(host.openCodeInstall?.title ?? "Getting OpenCode…")
                        .accessibilityValue("\(Int((fraction * 100).rounded(.down))) percent")
                } else {
                    ProgressView()
                }
                Button("Stop", role: .destructive) { host.stop() }
            } else {
                Text("Setup stopped before the workspace was ready.").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Retry") { host.retrySetup() }
                    Button("Choose another folder…") { host.chooseWorkspaceAndSetUp() }
                }
            }
        }
    }

    /// The last step shows the pairing QR code itself (QR-only pairing, 2026-10-16), kept fresh while it shows;
    /// once a device has paired, setup finishes by itself.
    private var ready: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pair your iPhone").font(.title3.weight(.semibold))
            Text(workspaceStatus).font(.callout).foregroundStyle(.secondary)
            PairingPanel(instruction: "Open AgentLand on your iPhone and tap Scan QR Code.",
                         onPaired: { host.finishOnboarding() })
                .padding(.vertical, AgentLandSpacing.small)
            HStack {
                Button(host.status == .stopped ? "Connect" : "Disconnect", role: host.status == .stopped ? nil : .destructive) {
                    if host.status == .stopped { host.start() } else { host.stop() }
                }
                .disabled(host.isWorking)
                Spacer()
                Button(host.status == .running ? "Pair Later" : "Finish") { host.finishOnboarding() }
            }
        }
    }

    private var workspaceStatus: String {
        let name = host.projectName.isEmpty ? "Workspace" : host.projectName
        return switch host.status {
        case .stopped: "\(name) is ready to connect."
        case .starting: "Connecting \(name)…"
        case .running: "\(name) is connected."
        }
    }
}

/// Setup's third step: Claude Code and Codex as this Mac is signed in to them (owner, 2026-10-17: "on the mac app i have
/// signed in via the cli agents to my subscription, rather than ask for api keys the mac onboarding app needs to see
/// this"). Chat runs them on their Claude and ChatGPT subscriptions (`capabilities.workspaceChats`), so the step shows
/// the rows Settings → Agents shows (`MacChatSignInRow`), whatever OpenCode does, and asks for no API key. An agent
/// that isn't signed in has Sign In…, which opens its CLI's own sign-in in Terminal and watches for it
/// (`ChatSignInWatch`, owner 2026-10-17). The step has the host check the sign-ins when the workspace has none yet,
/// saying Checking… meanwhile; Check Again has it check them again at once (`checkChatSignIns`; the host's own check
/// runs every minute, and the workspace follows its pulse when they change). Continue goes on to pairing.
struct OnboardingAgentsStep: View {
    @EnvironmentObject private var host: HostController
    @Environment(WorkspaceModel.self) private var workspace
    /// A watch the window passes in (renders); else the step's own.
    @Environment(ChatSignInWatch.self) private var passedWatch: ChatSignInWatch?
    @State private var ownWatch = ChatSignInWatch()
    @State private var reading = false
    /// This step has read the capabilities once (or the workspace had them): until then, nothing known means checking.
    @State private var readOnce = false

    var body: some View {
        let content = OnboardingAgents.content(workspace.capabilities, reading: reading || !readOnce)
        VStack(alignment: .leading, spacing: 10) {
            Text(OnboardingAgents.title).font(.title3.weight(.semibold))
            Text(OnboardingAgents.intro)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                switch content {
                case .checking:
                    checkingLine
                case .unreadable:
                    Label(OnboardingAgents.unreadable, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                case .none:
                    Text(PlainChatSignIns.none)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("onboardingAgentsNone")
                case let .signIns(signIns):
                    VStack(alignment: .leading, spacing: AgentLandSpacing.xSmall) {
                        ForEach(signIns.rows) { row in
                            MacChatSignInRow(row: row, icons: workspace.agents.icons, signIn: watch.state(row.id)) {
                                watch.signIn(row) { [workspace] in await OnboardingAgents.check(workspace) }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, AgentLandSpacing.xSmall)
            HStack(spacing: AgentLandSpacing.small) {
                Button("Check Again") { Task { await check() } }
                    .disabled(reading || workspace.client == nil)
                    .accessibilityIdentifier("onboardingCheckAgain")
                if reading, content != .checking { checkingLine }
                Spacer()
                Button("Continue") { host.continueToPairing() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboardingContinue")
            }
            .controlSize(.large)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboardingAgents")
        // The host's session: a new one (a restart) is read afresh when the workspace has nothing from it yet.
        .task(id: workspace.client.map { ObjectIdentifier($0) }) {
            if workspace.capabilities == nil { await check() } else { readOnce = true }
        }
        .onDisappear { watch.stop() }
    }

    private var watch: ChatSignInWatch { passedWatch ?? ownWatch }

    private var checkingLine: some View {
        HStack(spacing: AgentLandSpacing.xSmall) {
            ProgressView().controlSize(.small)
            Text(OnboardingAgents.checking).font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func check() async {
        guard !reading else { return }
        reading = true
        await workspace.checkChatSignIns()
        reading = false
        readOnce = true
    }
}

/// What setup's Claude Code and Codex step shows and says.
enum OnboardingAgents {
    enum Content: Equatable {
        /// Nothing known yet, and a read is on its way.
        case checking
        /// The host's capabilities could not be read.
        case unreadable
        /// The host lists neither Claude Code nor Codex (neither installed, or a host from before Chat ran them).
        case none
        case signIns(PlainChatSignIns)
    }

    static func content(_ capabilities: CapabilitiesResponse?, reading: Bool) -> Content {
        guard let capabilities else { return reading ? .checking : .unreadable }
        let signIns = PlainChatSignIns(capabilities.workspaceChats)
        return signIns.rows.isEmpty ? .none : .signIns(signIns)
    }

    /// Has the host check the sign-ins now and answers those it then lists.
    @MainActor
    static func check(_ workspace: WorkspaceModel) async -> PlainChatSignIns {
        await workspace.checkChatSignIns()
        return PlainChatSignIns(workspace.capabilities?.workspaceChats)
    }

    static let title = "Claude Code and Codex"
    static let intro = "Chat on your iPhone runs Claude Code and Codex on this Mac, signed in with your Claude and ChatGPT subscriptions. No API keys needed."
    static let checking = "Checking…"
    static let unreadable = "AgentLand couldn’t check how Claude Code and Codex are signed in. Check again, or continue and see them later in Settings → Agents."
}
