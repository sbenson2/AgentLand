import SwiftUI
import AgentLandCore
import AgentLandDesign

/// The tab in front's title-menu items, as its surface last drew them, for its pill's ••• menu in the iPhone's drawer.
struct WorkspaceSurfaceMenu {
    /// The tab the items act on; nil for the permanent Home.
    let tabID: UUID?
    /// The surface has actions of its own (Home has none).
    let hasItems: Bool
    let items: AnyView
}

#if os(iOS)
/// Ends editing in every window of the app's scenes. A popover keeps the input views of whatever had the keyboard
/// when it was presented and gives them back when it closes (`_restoreInputViewsForPresentation`), so the keyboard
/// must be gone before a header popover opens (B-8); the responder chain's resign alone missed a responder.
@MainActor func endEditingInEveryWindow() {
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
        for window in scene.windows { window.endEditing(true) }
    }
}

/// The active terminal's opaque backdrop, shared by the header, safe areas and status-bar appearance.
public struct WorkspacePhoneChromeAppearance {
    public let background: Color
    public let colorScheme: ColorScheme

    init?(paintedBackground: UIColor) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard paintedBackground.getRed(&red, green: &green, blue: &blue, alpha: &alpha), alpha == 1,
              red.isFinite, green.isFinite, blue.isFinite else { return nil }
        background = Color(uiColor: paintedBackground)
        func byte(_ component: CGFloat) -> UInt32 { UInt32((min(1, max(0, component)) * 255).rounded()) }
        let rgb = AgentLandRGB((byte(red) << 16) | (byte(green) << 8) | byte(blue))
        colorScheme = rgb.contrastRatio(with: AgentLandColor.text.dark) > rgb.contrastRatio(with: AgentLandColor.text.light) ? .dark : .light
    }
}

public extension WorkspaceModel {
    /// Home, drawers and ordinary shells follow the saved app palette. A painted terminal continues
    /// its backdrop into phone chrome without changing the saved appearance or another session.
    var phoneChromeAppearance: WorkspacePhoneChromeAppearance? {
        guard WorkspacePlatform.isPhone,
              let tab = currentTab, tab.kind == .terminal,
              let background = terminalSession(for: tab).paintedEdge else { return nil }
        return WorkspacePhoneChromeAppearance(paintedBackground: background)
    }
}

/// A session's page on iPhone (native-full side build, 2026-10-16): the system navigation bar shows its name, inline,
/// and its title menu holds the surface's own actions (`surfaceTitle`'s items: a chat's model, mode, Continue, Pin, Export
/// and Delete; a terminal's keyboard, Paste, Keys, Reconnect and End; an editor's Save, Reload, Copy and Find), then
/// Close with the existing questions: a running terminal of this device asks before it ends, an editor with unsaved
/// edits asks Close Without Saving or Keep Editing (`TaskCloseConfirmation`), a chat closes at once. The questions
/// point under the title (`DialogAnchor`). Home, and a surface whose tab is not a workspace tab (a standalone
/// terminal), are left as they are.
struct PhoneSessionTitle<Items: View>: ViewModifier {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.workspaceShell) private var shell
    @Environment(\.workspaceSurfaceTabID) private var surfaceTabID
    let title: String
    let items: () -> Items
    @State private var confirmsEnd = false

    @ViewBuilder func body(content: Content) -> some View {
        if let tab = surfaceTabID.flatMap(model.tab), tab.kind != .home {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarTitleMenu { menu(tab) }
                .overlay(alignment: DialogAnchor.titleMenu) { questions(tab) }
                .onChange(of: model.hostID) { _, _ in confirmsEnd = false }
        } else {
            content
        }
    }

    @ViewBuilder private func menu(_ tab: WorkspaceTab) -> some View {
        items()
        Section {
            // The page goes with its tab: the menu has gone first (`MenuAction.afterDismissal`).
            Button(closeTitle(tab), systemImage: "xmark") { MenuAction.afterDismissal { close(tab) } }
                .disabled(model.sessionOpening || ending(tab) || saving(tab))
                .accessibilityIdentifier("phoneCloseTab")
        }
        if workspaceUITestHooks {
            Section {
                Button("List VoiceOver elements", systemImage: "list.bullet", action: shell.debugListVoiceOverElements)
                    .accessibilityIdentifier("debugListVoiceOverElements")
                Button("Rebuild surfaces", systemImage: "arrow.triangle.2.circlepath", action: shell.debugRebuildSurfaces)
                    .accessibilityIdentifier("debugRebuildSurfaces")
            }
        }
    }

    private func questions(_ tab: WorkspaceTab) -> some View {
        DialogAnchor()
            .confirmationDialog("End “\(tab.title)”?", isPresented: $confirmsEnd, titleVisibility: .visible) {
                Button("End Terminal", role: .destructive) {
                    Task { await model.terminalSession(for: tab).endTerminal() }
                }.accessibilityIdentifier("phoneConfirmEndTerminal")
                Button("Keep Session") {}.accessibilityIdentifier("phoneKeepTerminal")
            } message: {
                Text(TerminalEndConfirmation.message(tab.sharedFrom, hostName: model.hostName))
            }
            .modifier(TaskCloseConfirmation(tab: tab, source: .header))
    }

    private func ending(_ tab: WorkspaceTab) -> Bool { tab.kind == .terminal && model.terminalSession(for: tab).ending }
    private func saving(_ tab: WorkspaceTab) -> Bool { tab.kind == .editor && model.editorSession(for: tab).saving }

    private func closeTitle(_ tab: WorkspaceTab) -> String {
        switch tab.kind {
        case .chat: "Close Chat"
        case .terminal: "Close Terminal"
        case .editor: "Close File"
        default: "Close Tab"
        }
    }

    private func close(_ tab: WorkspaceTab) {
        endEditingInEveryWindow()
        // This device's own running terminal asks before it ends (2026-10-10); a tab that follows another device's or
        // the Mac's (`sharedFrom`) closes at once and leaves it running.
        if tab.kind == .terminal {
            let session = model.terminalSession(for: tab)
            if WorkspaceModel.asksBeforeClosing(tab, running: session.status != .exited && !session.terminalGone) {
                confirmsEnd = true
                return
            }
        }
        // An editor with unsaved edits asks here (`TaskCloseConfirmation`, source `.header`).
        model.close(tab.id, source: .header)
    }
}

#endif
