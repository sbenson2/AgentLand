import SwiftUI
import AgentLandBranding
import AgentLandCore
import AgentLandDesign
import AgentLandDesktopCore
import AgentLandWorkspace

/// The Setup window: onboarding alone. Settings are the Settings window's (`MacSettingsView`), and pairing has its own
/// window. Neither this window nor its closing owns a server or terminal lifetime: closing it leaves `HostController`
/// and the menu bar running. Once setup is done it closes by itself.
struct SetupWindowView: View {
    static let id = "setup"
    @EnvironmentObject private var host: HostController
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings
    /// One clock for the artwork, so its motion lands on the clown's beat.
    @State private var artworkReferenceDate = Date()

    var body: some View {
        Group {
            if host.needsOnboarding {
                OnboardingWindowView()
            } else {
                ContentUnavailableView {
                    Label("AgentLand Is Set Up", systemImage: "checkmark.circle")
                } description: {
                    Text("Its server runs from the menu bar. Change how it works in Settings.")
                } actions: {
                    Button("Open Settings…") {
                        dismissWindow(id: Self.id)
                        openSettings()
                    }
                }
            }
        }
        .environment(\.agentLandArtwork, AgentLandArtworkLayout(windowFrame: .zero, referenceDate: artworkReferenceDate))
        .frame(minWidth: 760, minHeight: 560)
        .onAppear { host.refreshLifecycleStatus() }
        .onChange(of: host.needsOnboarding) { _, needed in
            if !needed { dismissWindow(id: Self.id) }
        }
    }
}

/// Setup before the workspace exists: folder first, then the automatic local setup, Claude Code and Codex
/// as this Mac is signed in to them, and pairing (`OnboardingContent`).
struct OnboardingWindowView: View {
    @EnvironmentObject private var host: HostController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AgentLandSpacing.large) {
                HStack(spacing: AgentLandSpacing.small) {
                    AgentLandMark(animated: false).frame(width: 42, height: 42)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: AgentLandSpacing.xxxSmall) {
                        Text("AgentLand").font(.largeTitle.weight(.semibold))
                        Text("This Mac").foregroundStyle(AgentLandColor.textSecondary)
                    }
                    Spacer()
                    StatusBadge(status: host.status)
                }
                if let error = host.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(AgentLandColor.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                OnboardingContent()
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(AgentLandSpacing.xLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AgentLandColor.canvas)
        .foregroundStyle(AgentLandColor.text)
    }
}
