#if os(iOS)
import SwiftUI
import AgentLandCore
import AgentLandDesign

/// The iPhone's Files and Git pages, pushed on the Workspace tab's own navigation stack with the system's Back
/// (native-full side build, 2026-10-16; owner, 2026-10-11: bottom tabs replace the drawer). A file's inspector and a
/// commit's or stash's page push on the same stack (`WorkspacePhoneDrawerPageView`).
struct WorkspacePhoneExplorer: View {
    @Environment(WorkspaceModel.self) private var model
    let section: WorkspacePhoneNavigation.DrawerSection
    /// Opens the workspace picker.
    let chooseWorkspace: () -> Void
    @State private var voiceOverElements = ""
    private var navigation: WorkspacePhoneNavigation { model.phoneNavigation }

    var body: some View {
        browserSection(section)
            .background(AgentLandColor.canvas)
            .overlay(alignment: .topLeading) { voiceOverList }
            .task(id: section) { await listVoiceOverElements() }
            .onAppear { navigation.drawerSection = section }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("workspaceExplorer")
    }

    /// UI tests read what VoiceOver reaches in the drawer, the section or the page it shows, once it has settled: the
    /// header's task menu that lists it for a surface is out of reach while the drawer is open.
    @ViewBuilder private var voiceOverList: some View {
        if workspaceUITestHooks {
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("VoiceOver elements in the drawer")
                .accessibilityValue(voiceOverElements)
                .accessibilityIdentifier("debugDrawerPageVoiceOverElements")
        }
    }

    private func listVoiceOverElements() async {
        guard workspaceUITestHooks else { return }
        voiceOverElements = ""
        try? await Task.sleep(for: .seconds(1.5))
        guard !Task.isCancelled else { return }
        voiceOverElements = reachableAccessibilityElements().joined(separator: "\n")
    }

    // MARK: Files and Git

    /// The workspace in use's Files or Git, under its name; with no workspace in use, the way to the workspace picker.
    @ViewBuilder private func browserSection(_ section: WorkspacePhoneNavigation.DrawerSection) -> some View {
        let project = navigation.drawerProject(model: model)
        let title = project?.name ?? section.title
        Group {
            if project == nil {
                chooseWorkspaceEmpty
                    .navigationTitle(title)
            } else if let tab = navigation.backingTab(section, model: model) {
                if section == .files {
                    // Files names its page itself: the folder shown, with the folders above it in the title menu (FI-1).
                    FilesTabView(tab: tab, placement: .drawer)
                        .environment(\.filesRowIdentifierPrefix, "drawerFile-")
                        // A file's row links to its inspector (`DrawerPage.file`) on the Workspace tab's stack.
                        .environment(\.filesInspectFile, { _ in })
                } else {
                    GitManagementTree(tab: tab)
                        .navigationTitle(title)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { navigation.prepare(section, model: model) }
                    .navigationTitle(title)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var chooseWorkspaceEmpty: some View {
        ContentUnavailable("Choose a Workspace", systemImage: "folder",
                           description: "Choose a workspace to see its files and repository.",
                           actionTitle: "Open Workspace", action: chooseWorkspace)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A page pushed over Files or Git on the Workspace tab's stack: a file's read-only inspector, or a commit's or stash's
/// changed files.
struct WorkspacePhoneDrawerPageView: View {
    @Environment(WorkspaceModel.self) private var model
    let page: WorkspacePhoneNavigation.DrawerPage

    var body: some View {
        Group {
            switch page {
            case let .file(projectID, path):
                FileInspectorView(projectID: projectID, path: path)
            case let .savedChange(tabID, hash, stash, _):
                if let tab = model.tab(tabID) {
                    GitSavedChangePage(tab: tab, hash: hash, stash: stash)
                } else {
                    ContentUnavailable("Repository Closed", systemImage: "arrow.triangle.branch",
                                       description: "Choose Git again to see this repository's history.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
        .background(AgentLandColor.canvas)
    }
}

#endif
