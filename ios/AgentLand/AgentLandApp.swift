import SwiftUI
import UIKit
import AgentLandCore
import AgentLandBranding
import AgentLandDesign
import AgentLandWorkspace

@main struct AgentLandApp: App {
    init() {
        #if DEBUG
        // XCTest can wait for a missing iOS 26 menu-animation completion event.
        // Keep deterministic UI runs on public APIs without changing release motion.
        if ProcessInfo.processInfo.arguments.contains("-AgentLandUITestsDisableAnimations") &&
            !ProcessInfo.processInfo.arguments.contains("-AgentLandUITestsAnimateHomeActions") {
            UIView.setAnimationsEnabled(false)
        }
        #endif
        // The cover's circus loader decodes its first runs off the main thread from the start.
        AgentLandCircusLoader.prepare()
    }

    @AppStorage("agentland.appearance") private var appearance = "dark"
    /// Settings → Privacy & Security → Hide content in the app switcher.
    @AppStorage(PrivacyCover.settingKey) private var hidesInAppSwitcher = PrivacyCover.settingDefault
    @State private var privacyCover = PrivacyCoverWindows()
    /// Owns the app model, so a notification tapped before the scene exists still reaches it.
    @UIApplicationDelegateAdaptor(AgentLandAppDelegate.self) private var appDelegate
    private var model: AppModel { appDelegate.model }
    @Environment(\.scenePhase) private var phase
    @State private var artworkReferenceDate = Date()
    var body: some Scene {
        WindowGroup {
            GeometryReader { window in
                ZStack {
                    Group {
                        if model.selectedHost == nil { PairingView() }
                        else { workspace.id(model.selectedHost?.id) }
                    }
                    .disabled(openingOverlayVisible)
                    // The app's short notices the native way (NO-2): a tapped notification that cannot open, or the
                    // tip's Turn On that failed, in the system's alert; a success only heard by VoiceOver. Never over
                    // the covers.
                    .noticePresentation(openingOverlayVisible ? nil
                                        : model.appNotice.map { NoticeContent(id: $0.id, $0.text, tone: $0.tone) },
                                        dismiss: { model.appNotice = nil })
                    // NavigationStack's native toolbar can outlive an ancestor's
                    // accessibility flag. Hide the retained surface itself as well.
                    .opacity(openingOverlayVisible ? 0 : 1)
                    .accessibilityElement(children: .contain)
                    .accessibilityHidden(openingOverlayVisible)
                    // In the workspace the notices sit with its own, under the navigation bar.
                    if !openingOverlayVisible && model.selectedHost == nil {
                        NoticeOverlay()
                    }
                    if openingOverlayVisible {
                        AgentLandOpeningView(
                            message: openingMessage,
                            forceReduceMotion: loadingPreviewReduceMotion
                        )
                        .accessibilityIdentifier(model.locked ? "appLockScreen" : "hostLoadingScreen")
                        // It covers at once (lock and background never show the workspace through a fade)
                        // and leaves in a fade as the workspace comes in.
                        .transition(.asymmetric(insertion: .identity, removal: .opacity))
                    }
                    if let ticket = model.presentationTicket,
                       model.presentationReady, !model.locked, !model.busy, phase == .active {
                        WorkspacePresentationCommit(ticket: ticket, completion: model.completePresentation)
                            .frame(width: 1, height: 1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .animation(openingOverlayVisible ? nil
                           : AgentLandMotion.smooth.animation(reduceMotion: UIAccessibility.isReduceMotionEnabled),
                           value: openingOverlayVisible)
                .environment(\.agentLandArtwork, AgentLandArtworkLayout(
                    windowFrame: window.frame(in: .global), referenceDate: artworkReferenceDate
                ))
            }
            // The system background (`canvas` on iPhone and iPad), or a painted terminal's. The accent is the
            // AccentColor asset and text the system's label color, so no app-wide tint or foreground style is set.
            .background((model.selectedHost == nil ? nil : model.workspace.phoneChromeAppearance?.background)
                        ?? AgentLandColor.canvas.color, ignoresSafeAreaEdges: .all)
            .environment(model)
            .environment(model.workspace)
            .preferredColorScheme(preferredColorScheme)
            .transaction { transaction in
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-AgentLandUITestsDisableAnimations") &&
                    !ProcessInfo.processInfo.arguments.contains("-AgentLandUITestsAnimateHomeActions") {
                    transaction.disablesAnimations = true
                    transaction.animation = nil
                }
                #endif
            }
            .onChange(of: phase, initial: true) { _, value in
                model.handleScenePhase(value)
                updatePrivacyCover()
            }
            .onChange(of: model.isAuthenticating) { _, _ in updatePrivacyCover() }
            .onChange(of: hidesInAppSwitcher) { _, _ in updatePrivacyCover() }
        }
        // The workspace's keyboard commands, in the iPadOS menu bar.
        .commands { WorkspaceCommands() }
    }

    /// The workspace shell with what the app owns: the connection, the pairing cover and Settings.
    private var workspace: some View {
        let retry: (() -> Void)? = model.canRetryConnection ? { model.retryNow() } : nil
        // Pairing another host (Settings → Connection → Pair another host) runs in a sheet over Settings, inside the
        // workspace: the opening view covers the window meanwhile, but the workspace is not told it is covered, which
        // would put every presentation away and take the sheet, and a failed attempt's reason, with it. A pairing
        // that succeeds selects the new host, which builds the workspace afresh.
        return WorkspaceView(connection: model.connectionStatus, retryConnection: retry, covered: false) { close in
            SettingsView(onClose: close)
        } notices: {
            NoticeStack()
        }
    }

    /// The brand cover over every window of the app while the scene is not active, when Settings asks for it.
    private func updatePrivacyCover() {
        privacyCover.show(PrivacyCover.isVisible(enabled: hidesInAppSwitcher, phase: phase, authenticating: model.isAuthenticating))
    }

    private var openingHost: Bool { model.busy || model.presentationPending }
    private var openingOverlayVisible: Bool { model.locked || openingHost || loadingPreviewEnabled }
    private var openingMessage: String {
        if model.locked { return model.authenticationMessage ?? "Unlocking…" }
        return openingHost && !model.busy ? "Opening your host…" : "Connecting…"
    }
    /// The covers (lock, opening, loading) are dark navy. Everything else, Home and the empty chat
    /// included, follows the saved appearance. A painted terminal uses a readable appearance for
    /// its matching chrome; returning Home or opening a drawer restores the saved choice.
    private var preferredColorScheme: ColorScheme? {
        if model.locked || (model.presentationPending && !model.presentationReady) || model.busy || loadingPreviewEnabled { return .dark }
        if model.selectedHost != nil, let chrome = model.workspace.phoneChromeAppearance { return chrome.colorScheme }
        return appearance == "light" ? .light : appearance == "dark" ? .dark : nil
    }

    #if DEBUG
    private var loadingPreviewEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-AgentLandLoadingPreview")
    }

    private var loadingPreviewElapsed: TimeInterval? {
        guard let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-AgentLandLoadingPreviewElapsed"),
              ProcessInfo.processInfo.arguments.indices.contains(index + 1) else { return nil }
        return TimeInterval(ProcessInfo.processInfo.arguments[index + 1])
    }

    private var loadingPreviewReduceMotion: Bool? {
        ProcessInfo.processInfo.arguments.contains("-AgentLandLoadingPreviewReduceMotion") ? true : nil
    }
    #else
    private var loadingPreviewEnabled: Bool { false }
    private var loadingPreviewElapsed: TimeInterval? { nil }
    private var loadingPreviewReduceMotion: Bool? { nil }
    #endif
}

/// Wait for the prepared workspace to pass through a display frame before
/// uncovering it. This is a rendering acknowledgement, not a timed splash delay.
private struct WorkspacePresentationCommit: UIViewRepresentable {
    let ticket: WorkspacePresentationTicket
    let completion: (WorkspacePresentationTicket) -> Void

    func makeUIView(context: Context) -> PresentationCommitView { PresentationCommitView() }
    func updateUIView(_ view: PresentationCommitView, context: Context) {
        view.prepare(ticket: ticket, completion: completion)
    }
    static func dismantleUIView(_ view: PresentationCommitView, coordinator: ()) { view.cancel() }

    final class PresentationCommitView: UIView {
        private var ticket: WorkspacePresentationTicket?
        private var completion: ((WorkspacePresentationTicket) -> Void)?
        private var displayLink: CADisplayLink?
        private var sawFrame = false

        func prepare(ticket: WorkspacePresentationTicket, completion: @escaping (WorkspacePresentationTicket) -> Void) {
            self.completion = completion
            guard self.ticket != ticket else { return }
            cancel()
            self.ticket = ticket
            sawFrame = false
            startIfVisible()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { cancel() } else { startIfVisible() }
        }

        private func startIfVisible() {
            guard window != nil, ticket != nil, displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(frameReady))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }

        @objc private func frameReady() {
            guard window != nil else { cancel(); return }
            guard sawFrame else { sawFrame = true; return }
            guard let ticket else { cancel(); return }
            cancel()
            completion?(ticket)
            completion = nil
        }

        func cancel() {
            displayLink?.invalidate()
            displayLink = nil
        }
    }
}

/// Hide content in the app switcher (Settings → Privacy & Security, off by default): while the scene is inactive
/// or in the background, the brand cover (the opening and lock covers' circus on slate, still) covers every window,
/// sheets and keyboard included, so the app switcher's snapshot and a glance at the app behind Control Center or
/// Notification Center show none of the work. It changes nothing in the app model: the lock, its Face ID prompt and
/// the opening ticket go on as before.
enum PrivacyCover {
    static let settingKey = "agentland.privacy.hideInAppSwitcher"
    static let settingDefault = false

    /// Shown while the scene is not active, except while device authentication runs: Face ID's prompt makes the
    /// scene inactive over the lock cover, whose loader keeps moving then (AGENTS.md), and nothing else shows.
    static func isVisible(enabled: Bool, phase: ScenePhase, authenticating: Bool) -> Bool {
        enabled && phase != .active && !authenticating
    }
}

/// One window per scene, above everything the app shows, made the first time the cover is needed and hidden after.
@MainActor final class PrivacyCoverWindows {
    private var windows: [ObjectIdentifier: UIWindow] = [:]

    func show(_ shown: Bool) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if shown {
            for scene in scenes {
                let window = windows[ObjectIdentifier(scene)] ?? makeWindow(scene)
                window.isHidden = false
            }
        } else {
            for window in windows.values { window.isHidden = true }
        }
        windows = windows.filter { key, _ in scenes.contains { ObjectIdentifier($0) == key } }
    }

    private func makeWindow(_ scene: UIWindowScene) -> UIWindow {
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        let cover = UIHostingController(rootView: AgentLandOpeningView(message: "AgentLand", forceReduceMotion: true))
        cover.view.backgroundColor = AgentLandColor.brand.uiColor
        window.rootViewController = cover
        window.accessibilityIdentifier = "privacyCover"
        windows[ObjectIdentifier(scene)] = window
        return window
    }
}

/// The cover over the lock, the opening and loading: the circus loader alone in the middle of the brand
/// slate (owner's request, 2026-10-04: no tent and no text); VoiceOver reads the status from it. The privacy
/// cover shows it still.
struct AgentLandOpeningView: View {
    let message: String
    let forceReduceMotion: Bool?
    var body: some View {
        AgentLandCircusLoader(forceReduceMotion: forceReduceMotion)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(message)
            .accessibilityIdentifier("openingCircus")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AgentLandColor.brand, ignoresSafeAreaEdges: .all)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
    }
}
