import SwiftUI
import AgentLandCore
import AgentLandDesign

#if os(iOS)
/// Native folder selection for the paired Mac; the system owns presentation and navigation.
struct HomeWorkspacePicker: View {
    @Environment(WorkspaceModel.self) private var model
    let choose: (String) -> Void
    let close: () -> Void
    @State private var creationLocation: CreationLocation?

    private struct CreationLocation: Identifiable {
        let folder: FolderListing
        var id: String { folder.path }
    }

    var body: some View {
        Group {
            if model.workspaces.supports(.browse) {
                NavigationStack {
                    folderPage(path: nil, name: "Home")
                        .navigationDestination(for: FolderEntry.self) { folder in
                            folderPage(path: folder.path, name: folder.name)
                        }
                }
            } else {
                WorkspacePickerView(onClose: close, choose: choose)
            }
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("homeWorkspacePicker")
        .sheet(item: $creationLocation) { location in
            NewWorkspaceSheet(created: choose, initialLocation: location.folder)
                .environment(model)
                .agentLandSheetPage()
        }
    }

    private func folderPage(path: String?, name: String) -> some View {
        HomePhoneFolderBrowser(start: path, name: name, open: choose, create: { location in
            creationLocation = CreationLocation(folder: location)
        }, close: close)
    }
}
#endif
