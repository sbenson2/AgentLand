import SwiftUI
import AgentLandCore
import AgentLandDesign

/// A terminal of another device, or of the Mac, outside any workspace this device knows, on a screen of its own
/// (pushed from "On <device>"): a strip saying its folder isn't a workspace, with Add as Workspace, above the terminal.
/// Its tab never joins the workspace's tabs; its session is the workspace model's (`standaloneTabs`) and ends when the
/// screen goes. Adding the folder opens the terminal there as a tab, and the screen goes.
struct StandaloneTerminalView: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let route: StandaloneTerminalRoute
    /// This screen's name among the views that show the terminal: a screen built again in place appears before the old
    /// one goes, so the session ends only when none shows it.
    @State private var viewID = UUID()
    @State private var adding = false
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            strip
            TerminalTabView(tab: route.tab, standalone: true)
        }
        .background(AgentLandColor.canvas)
        // "On <device>" goes on being read under this screen, so its name follows the host's list
        // (`WorkspaceModel.followSharedTerminals`) as well as its program's titles and this device's names.
        .readsOtherDevices()
        .onAppear {
            model.surfaceView(viewID, of: route.tab.id, shown: true)
            // An open session surface: the iPhone's bottom tab bar hides while it shows, and comes back when it goes.
            model.phoneNavigation.standaloneScreen(viewID, shown: true)
        }
        .onDisappear {
            model.phoneNavigation.standaloneScreen(viewID, shown: false)
            if !model.surfaceView(viewID, of: route.tab.id, shown: false) { model.endStandalone(route.tab.id) }
        }
        .alert("Couldn’t Add the Workspace", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } }),
               presenting: problem) { _ in
            Button("OK") {}
        } message: { Text($0) }
    }

    private var strip: some View {
        HStack(spacing: AgentLandSpacing.xSmall) {
            Text("\(route.displayFolder) isn't a workspace")
                .agentLandFont(.metadata)
                .foregroundStyle(AgentLandColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if adding { ProgressView().controlSize(.small) }
            Button("Add as Workspace") { Task { await add() } }
                .agentLandFont(.metadata)
                .minimumTapTarget()
                .disabled(adding || !model.workspaces.canAdd || !model.reachable)
                .accessibilityIdentifier("standaloneAddWorkspace")
        }
        .padding(.horizontal, AgentLandSpacing.medium)
        .padding(.vertical, AgentLandSpacing.xxSmall)
        .background(AgentLandColor.surface)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("standaloneTerminalStrip")
    }

    /// Adds the folder; once the host names the workspace the terminal opens there as a tab and this screen goes. A
    /// refusal says why; an answer that didn't arrive is the Workspaces screen's notice, as for any added folder.
    private func add() async {
        adding = true
        defer { adding = false }
        switch await model.addAsWorkspace(route) {
        case .open: dismiss()
        case let .problem(message): problem = message
        case .unconfirmed:
            problem = model.workspaces.notice?.message ?? "The answer didn’t arrive. Check your workspaces before trying again."
        case .dropped: break
        }
    }
}
