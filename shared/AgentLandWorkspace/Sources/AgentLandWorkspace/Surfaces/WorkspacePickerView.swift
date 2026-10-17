import SwiftUI
import AgentLandCore
import AgentLandDesign

/// Opening a workspace: every folder the host offers.
struct WorkspacePickerView: View {
    @Environment(WorkspaceModel.self) private var model
    let onClose: () -> Void
    let choose: (String) -> Void
    var body: some View {
        let projects = model.phoneNavigation.visibleProjects(model)
        NavigationStack {
            // A grouped list of the host's folders, each a row button with the workspace in use checked (WS-10).
            List {
                ForEach(projects) { project in
                    let current = project.id == model.selectedProjectID
                    Button { choose(project.id) } label: {
                        HStack(spacing: AgentLandSpacing.small) {
                            Label {
                                Text(project.name).agentLandFont(.body).foregroundStyle(AgentLandColor.text)
                                    .multilineTextAlignment(.leading)
                            } icon: {
                                Image(systemName: "folder").accessibilityHidden(true)
                            }
                            Spacer(minLength: 0)
                            if current {
                                Image(systemName: "checkmark").font(AgentLandTypeRole.body.font.weight(.semibold))
                                    .foregroundStyle(.tint).accessibilityHidden(true)
                            }
                        }
                        #if os(macOS)
                        .agentLandRowHeight()
                        .contentShape(Rectangle())
                        #endif
                    }
                    #if os(macOS)
                    .buttonStyle(.plain)
                    .workspaceRowHover()
                    #endif
                    .listRowFill(.surface, separator: true)
                    .accessibilityAddTraits(current ? .isSelected : [])
                    .accessibilityIdentifier("pickerProject-\(project.id)")
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .hidesListPageBackground()
            .overlay {
                if projects.isEmpty {
                    ContentUnavailable("No workspaces", systemImage: "folder.badge.questionmark",
                                       description: "Choose a folder in the AgentLand desktop app to make it available here.")
                }
            }
            .groupedPageBackground()
            .navigationTitle("Open Workspace")
            .workspaceInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done", action: onClose) }
            }
        }
    }
}
