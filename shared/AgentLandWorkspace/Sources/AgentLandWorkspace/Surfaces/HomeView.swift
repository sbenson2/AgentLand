import SwiftUI
import AgentLandCore
import AgentLandBranding
import AgentLandDesign

/// Home is a bounded launcher: its own safe-area height determines the title, circus, quip and actions.
/// It does not inherit the opening cover's visual anchor or turn into another workspace list.
struct HomeView: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.workspaceShell) private var shell
    @Environment(\.agentLandArtwork) private var artwork
    @Environment(\.workspaceObscured) private var workspaceObscured
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var quips = QuipStore.shared
    @State private var quipHeight: CGFloat = 40
    @State private var actionHeight: CGFloat = 168
    /// A terminal of another device outside any workspace, on its own screen (iPad's "On <device>").
    @State private var standalone: StandaloneTerminalRoute?
    let tabID: UUID?
    var tabLaunchers: AnyView? = nil
    /// This Home is the page on screen. iPhone's Chat and Terminal tabs each keep a Home alive (native-full side build,
    /// 2026-10-16); only the one in front animates its title and circus.
    var visible = true

    /// iPad's permanent Home lists the terminals open on the owner's other devices and the Mac below its launchers.
    private var showsOtherDevices: Bool {
        #if os(iOS)
        !WorkspacePlatform.isPhone && tabID == nil
        #else
        false
        #endif
    }

    private var animationActive: Bool {
        visible && model.selectedTabID == tabID && !model.locked && !model.presentationPending
            && !workspaceObscured && scenePhase == .active
    }

    private var title: String { tabID.flatMap { model.tab($0)?.title } ?? "Home" }
    private var compactsTent: Bool {
        guard WorkspacePlatform.isPhone, tabLaunchers != nil else { return false }
        if reduceMotion { return true }
        guard let reveal = model.circusRevealedAt, reveal != .distantFuture else { return false }
        return !AgentLandCircusLoading.isTightrope(revealedAt: reveal)
    }

    var body: some View {
        GeometryReader { geometry in
            let titleScale = titleScale(for: geometry.size.width)
            let titleSize = AgentLandTitleBlock.designSize(scale: titleScale)
            let actionWidth = actionWidth(for: geometry.size)
            let input = HomeLauncherLayout.Input(
                container: geometry.size,
                // This GeometryReader is already inside the navigation content's safe-area bounds. Its
                // inherited insets describe the window, so applying them again would leave a second
                // navigation-bar-sized gap above the title.
                safeArea: .init(top: 0, leading: 0, bottom: 0, trailing: 0),
                title: titleSize,
                scene: CGSize(width: AgentLandCircusLoading.stageSize.width, height: WorkspacePlatform.isPhone ? 268 : 360),
                quipHeight: quipHeight,
                actions: CGSize(width: actionWidth, height: actionHeight),
                isAccessibilitySize: typeSize.isAccessibilitySize || tabLaunchers != nil
            )
            let plan = WorkspacePlatform.isPhone ? HomeLauncherLayout.phonePlan(input, compactTent: compactsTent) : HomeLauncherLayout.plan(input)

            ZStack(alignment: .topLeading) {
                Group {
                    if plan.allowsScrolling {
                        ScrollView {
                            launcher(plan: plan, titleScale: titleScale * plan.titleScale)
                                .frame(width: geometry.size.width, height: plan.contentHeight, alignment: .top)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                    } else {
                        launcher(plan: plan, titleScale: titleScale * plan.titleScale)
                            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                    }
                }
            }
            // Paper/slate stays behind Home's art (the owner's decision, 2026-10-06); the shell continues it behind
            // the iPhone's header (`ArtBackdropKey`).
            .background(AgentLandColor.artBackdrop)
            .preference(key: ArtBackdropKey.self, value: true)
        }
        // Keep the launcher stable while a presented workspace sheet uses the keyboard.
        .ignoresSafeArea(.keyboard)
        .modifier(OtherDevicesFollow(enabled: showsOtherDevices, standalone: $standalone))
        .onChange(of: animationActive, initial: true) { _, active in if active { model.circusShown() } }
        .surfaceTitle(title, systemImage: "house", identifier: "homeTitleMenu", hasActions: false) { EmptyView() }
    }

    private func launcher(plan: HomeLauncherLayout.Plan, titleScale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            AgentLandTitleBlock(scale: titleScale, color: AgentLandColor.artInk.color,
                                quipColor: AgentLandColor.artInkSecondary.color, active: animationActive,
                                referenceDate: artwork.referenceDate, tonalArt: true)
                // A local edge lift thickens the existing animated title without changing its pixels
                // or the wordmark rendering used by iPad, Mac, covers and icons.
                .shadow(color: AgentLandColor.artInk.color.opacity(WorkspacePlatform.isPhone ? 0.45 : 0), radius: 0,
                        x: WorkspacePlatform.isPhone ? 0.6 : 0, y: 0)
                .shadow(color: AgentLandColor.artInk.color.opacity(WorkspacePlatform.isPhone ? 0.35 : 0), radius: 0,
                        x: 0, y: WorkspacePlatform.isPhone ? 0.6 : 0)
                .opacity(WorkspacePlatform.isPhone ? 0.88 : 1)
                .frame(width: plan.title.width, height: plan.title.height)
                // Squeeze the assembled artwork to the Home grid's side insets.
                // A render transform keeps the arch, letter layout and vertical budget intact.
                .scaleEffect(x: WorkspacePlatform.isPhone && !plan.usesWideLayout
                             ? min(1, plan.actions.width / max(1, plan.title.width)) : 1,
                             y: 1, anchor: .center)
                .position(x: plan.title.midX, y: plan.title.midY)

            circus(plan: plan)

            quip
                .foregroundStyle(AgentLandColor.artInkSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: plan.quip.width, alignment: .center)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { quipHeight = $0 }
                .position(x: plan.quip.midX, y: plan.quip.midY)
                .accessibilityIdentifier("homeQuip")

            VStack(spacing: AgentLandSpacing.small) {
                // A `Layout` needs its width during its own measurement. Giving the enclosing stack a
                // width only constrains it after `ActionCapsuleGrid` has selected its ideal size, which
                // makes every capsule wrap into a tall, off-screen column on a fresh Home.
                Group {
                    if let tabLaunchers {
                        tabLaunchers
                    } else if WorkspacePlatform.isPhone {
                        HomePhoneActionArea(active: animationActive, wide: plan.usesWideLayout,
                                            perform: performPhoneChoice)
                    } else {
                        launchActions
                    }
                }
                .frame(width: plan.actions.width)
                if showsOtherDevices {
                    OtherDevicesCard(showStandalone: { standalone = $0 })
                        .frame(width: plan.actions.width)
                }
                recovery
            }
            .frame(width: plan.actions.width, alignment: .center)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if height > 0 { actionHeight = height }
            }
            .position(x: plan.actions.midX, y: plan.actions.midY)
        }
    }

    private func circus(plan: HomeLauncherLayout.Plan) -> some View {
        ZStack {
            AgentLandCircusLoading(showsClown: true, animated: animationActive,
                                   markColor: AgentLandColor.artInk.color, workSurface: true,
                                   referenceDate: artwork.referenceDate,
                                   backdrop: AgentLandColor.artBackdrop.color,
                                   revealedAt: model.circusRevealedAt ?? .distantFuture, tonalArt: true,
                                   artOpacity: WorkspacePlatform.isPhone ? 0.88 : 1)
                .frame(width: AgentLandCircusLoading.stageSize.width, height: 360)
                // The iPhone crop removes the scene canvas's empty bands around the original artwork;
                // the native tent loop, rider choreography and shared clock remain the renderer.
                .frame(width: AgentLandCircusLoading.stageSize.width, height: WorkspacePlatform.isPhone ? 268 : 360)
                .scaleEffect(plan.scene.height / (WorkspacePlatform.isPhone ? 268 : 360))
        }
        .frame(width: plan.scene.width, height: plan.scene.height)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("homeCircus")
        .accessibilityHidden(!Self.exposesSceneForUITests)
        .allowsHitTesting(false)
        .position(x: plan.scene.midX, y: plan.scene.midY)
    }

    @ViewBuilder private var quip: some View {
        if WorkspacePlatform.isPhone {
            HomePhoneQuip(text: quips.current, active: animationActive, referenceDate: artwork.referenceDate)
        } else {
            Text(quips.current).agentLandFont(.quip)
        }
    }

    private func performPhoneChoice(_ destination: HomePhoneActions.Destination) {
        switch destination {
        case .standaloneChat: shell.startNewChat()
        case let .terminal(program): shell.newTerminal(program)
        case .workspacePicker: shell.openHomeWorkspacePicker()
        case .createWorkspace: shell.createWorkspace()
        case let .workspace(id): model.phoneNavigation.switchWorkspace(id, model: model)
        case let .recentChat(id): shell.openRecent(.chat(id))
        case let .recentTerminal(id): shell.openRecent(.terminal(id))
        }
    }

    @ViewBuilder private var recovery: some View {
        if let issue = model.hostIssue {
            HomeRecoveryRow(message: "Host unavailable: \(issue)", actionTitle: "Retry") {
                Task { await model.refreshProjects() }
            }
            .accessibilityIdentifier("homeHostIssue")
        } else if !model.metadataResolved && !model.reachable {
            // The opening resolved offline before the host listed anything (B-14): no workspace list is
            // known, which is not "no workspaces". The banner reconnects; the list loads once it is back.
            HomeRecoveryRow(message: "Your workspaces show once the host answers.", actionTitle: nil)
                .accessibilityIdentifier("homeHostOffline")
        } else if model.projects.isEmpty && showsNoWorkspaces {
            HomeRecoveryRow(message: model.workspaces.isAvailable ? "No workspaces yet." : "Choose a default workspace folder.",
                            actionTitle: model.workspaces.isAvailable ? "Choose Folder" : nil,
                            action: shell.openPicker)
                .accessibilityIdentifier("homeEmptyWorkspace")
        }
    }

    private var showsNoWorkspaces: Bool {
        #if os(macOS)
        model.client != nil && model.reachable && model.metadataResolved
        #else
        true
        #endif
    }

    private static var exposesSceneForUITests: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-AgentLandUITestsDisableAnimations")
        #else
        false
        #endif
    }

    private func titleScale(for width: CGFloat) -> CGFloat {
        let canvas = AgentLandTitleBlock.canvas
        if WorkspacePlatform.isPhone { return min(0.82, max(0.48, (width - 24) / canvas.width)) }
        return min(0.82, max(0.48, (width - 48) / canvas.width))
    }

    /// The action grid's width belongs to the current safe-area width; only its measured height feeds
    /// back into the vertical budget. Keeping width out of feedback avoids stale phone geometry on a
    /// rotation or a wide window.
    private func actionWidth(for container: CGSize) -> CGFloat {
        if WorkspacePlatform.isPhone { return min(480, max(0, container.width - 40)) }
        return min(480, max(0, container.width - 48))
    }

    private var capsuleColumns: Int {
        if typeSize.isAccessibilitySize { return 1 }
        return 2
    }

    private var offersArchive: Bool { model.capabilities?.supportsArchive(.sync) == true }
    private var offersGit: Bool { model.capabilities?.git.isEmpty == false }
    private var offersBrowser: Bool { model.capabilities?.preview != nil }

    private var launchActions: some View {
        ActionCapsuleGrid(columns: capsuleColumns, spacing: AgentLandSpacing.small) {
            PlainChatLaunchMenu {
                ActionCapsule("Chat", systemImage: "bubble.left.and.bubble.right", compact: true)
            }
            .agentLandControlButton()
            .disabled(!model.offersPlainChats || model.creating)
            .accessibilityIdentifier("homeNewChat")

            if model.capabilities?.terminal == true {
                Menu {
                    ForEach(TerminalProgram.offered(by: model.capabilities)) { program in
                        Button(program.displayName, systemImage: "terminal") { shell.newTerminal(program) }
                            .accessibilityIdentifier("homeTerminalProgram-\(program.id)")
                    }
                } label: {
                    ActionCapsule("New Terminal", systemImage: "terminal", showsDisclosure: true, compact: true)
                }
                .agentLandControlButton()
                .accessibilityIdentifier("homeNewTerminal")
            }

            Menu {
                Button("Files", systemImage: "folder") { shell.withWorkspace { shell.browseFiles() } }
                if offersGit {
                    Button("Git", systemImage: "arrow.triangle.branch") { shell.withWorkspace { shell.showGit() } }
                }
                if offersBrowser {
                    Button("Browser", systemImage: "globe") { shell.withWorkspace { shell.newBrowserTab() } }
                }
            } label: {
                ActionCapsule("Browse Files", systemImage: "folder", showsDisclosure: true, compact: true)
            }
            .agentLandControlButton()
            .disabled(model.projects.isEmpty)
            .accessibilityIdentifier("homeBrowseFiles")

            Menu {
                Button("Search History", systemImage: "magnifyingglass", action: shell.focusSearch)
                if offersArchive {
                    Button("Archived Chats", systemImage: "archivebox") { shell.showArchive(false) }
                    if model.capabilities?.supportsArchive(.terminalLogs) == true {
                        Button("Terminal Logs", systemImage: "clock.arrow.circlepath") { shell.showArchive(true) }
                    }
                }
            } label: {
                ActionCapsule("Resume Work", systemImage: "clock.arrow.circlepath", showsDisclosure: true, compact: true)
            }
            .agentLandControlButton()
            .accessibilityIdentifier("homeRecentWork")

            Button(action: shell.openPicker) {
                ActionCapsule("Open Workspace", systemImage: "square.grid.2x2", compact: true)
            }
            .agentLandControlButton()
            .accessibilityIdentifier("openWorkspace")

            Button(action: shell.showSettings) {
                ActionCapsule("Settings", systemImage: "gearshape", compact: true)
            }
            .agentLandControlButton()
            .accessibilityIdentifier("homeSettings")
        }
    }
}

private struct HomeRecoveryRow: View {
    let message: String
    let actionTitle: String?
    let action: () -> Void

    init(message: String, actionTitle: String?, action: @escaping () -> Void = {}) {
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        #if os(iOS)
        // The system's own box and bordered button on iPhone and iPad (HO-7).
        GroupBox { content.buttonStyle(.bordered) }
        #else
        content
            .padding(.horizontal, AgentLandSpacing.xSmall)
            .padding(.vertical, AgentLandSpacing.xxSmall)
            .background(AgentLandColor.surfaceRaised, in: AgentLandRadius.shape(AgentLandRadius.card))
        #endif
    }

    private var content: some View {
        HStack(spacing: AgentLandSpacing.xSmall) {
            Text(message)
                .agentLandFont(.metadata)
                .foregroundStyle(AgentLandColor.textSecondary)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .agentLandFont(.metadata)
                    .minimumTapTarget()
            }
        }
    }
}
