import SwiftUI
import AgentLandCore
import AgentLandDesign

/// The complete navigation map shown by the centered toolbar control.
enum WorkspaceNavigation {
    struct Groups {
        var standaloneChats: [WorkspaceTab]
        var workspaces: [WorkspaceGroup]
        /// Tabs restored for a workspace the host no longer lists remain reachable until the model's
        /// explicit workspace-removal path closes them.
        var unavailableTabs: [WorkspaceTab]
    }

    struct WorkspaceGroup: Identifiable {
        var project: Project
        var tabs: [WorkspaceTab]
        var id: String { project.id }
    }

    @MainActor static func groups(model: WorkspaceModel) -> Groups {
        let standaloneChats = model.tabs.filter { model.isPlainChat($0) && model.workspaceID(for: $0) == nil }
        let workspaceProjects = model.projects.filter { !model.isChatsSpace($0.id) }
        let projectIDs = Set(workspaceProjects.map(\.id))
        return Groups(
            standaloneChats: standaloneChats,
            workspaces: workspaceProjects.map { project in
                WorkspaceGroup(project: project, tabs: model.tabs.filter { model.supportsTab($0) && model.workspaceID(for: $0) == project.id })
            },
            unavailableTabs: model.tabs.filter { tab in
                model.supportsTab(tab) && !standaloneChats.contains(where: { $0.id == tab.id }) && !projectIDs.contains(model.workspaceID(for: tab) ?? tab.projectID)
            }
        )
    }
}

/// Home, standalone chats, and every folder with every tab retained for it. Selecting an existing tab only
/// changes `WorkspaceModel`'s selection, so live chat, terminal, editor and browser sessions stay intact.
struct WorkspaceNavigationPicker: View {
    @Environment(WorkspaceModel.self) private var model
    let close: () -> Void

    var body: some View {
        let groups = WorkspaceNavigation.groups(model: model)
        NavigationStack {
            List {
                Section {
                    destination("Home", systemImage: "house", selected: model.selectedTabID == nil) {
                        model.selectedTabID = nil
                    }
                    .accessibilityIdentifier("workspacePickerHome")
                }

                if !groups.standaloneChats.isEmpty {
                    Section("Chats") {
                        ForEach(groups.standaloneChats) { tab in tabRow(tab) }
                    }
                }

                ForEach(groups.workspaces) { group in
                    Section {
                        destination(group.project.name, systemImage: "folder", selected: false) {
                            model.openWorkspace(group.project.id)
                        }
                        .accessibilityIdentifier("workspacePickerProject-\(group.project.id)")
                        ForEach(group.tabs) { tab in tabRow(tab) }
                    }
                }

                if !groups.unavailableTabs.isEmpty {
                    Section("Other Tabs") {
                        ForEach(groups.unavailableTabs) { tab in tabRow(tab) }
                    }
                }
            }
            .listStyle(.sidebar)
            .listPageBackground()
            .navigationTitle("Workspaces")
            .workspaceInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: close).accessibilityIdentifier("workspacePickerClose")
                }
            }
        }
    }

    private func tabRow(_ tab: WorkspaceTab) -> some View {
        destination(tab.title, systemImage: tabIcon(tab.kind), selected: model.selectedTabID == tab.id) {
            model.requestResume(.tab(tab))
        }
        .accessibilityIdentifier("workspacePickerTab-\(tab.id.uuidString)")
    }

    private func destination(_ title: String, systemImage: String, selected: Bool,
                             action: @escaping @MainActor () -> Void) -> some View {
        Button {
            action()
            close()
        } label: {
            HStack(spacing: AgentLandSpacing.small) {
                Image(systemName: systemImage)
                    .foregroundStyle(selected ? AgentLandColor.tint : AgentLandColor.textSecondary)
                    .agentLandIconFrame(.regular)
                Text(title).foregroundStyle(AgentLandColor.text).lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(AgentLandColor.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
