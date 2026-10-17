import SwiftUI
import AgentLandCore
import AgentLandDesign

/// Home's glass actions use native menus; Workspaces opens the native folder selection sheet.
struct HomePhoneActionArea: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.workspaceShell) private var shell
    @Environment(\.dynamicTypeSize) private var typeSize
    let active: Bool
    var wide = false
    let perform: (HomePhoneActions.Destination) -> Void

    @ScaledMetric(relativeTo: .title3) private var buttonHeight: CGFloat = 64

    private static let topBand: CGFloat = 44
    private static let bandSpacing: CGFloat = 8
    /// Preserve the approved gap between the quip and the Home buttons.
    static func clearBand(wide: Bool) -> CGFloat { wide ? 0 : topBand + bandSpacing }

    var body: some View {
        VStack(spacing: Self.bandSpacing) {
            if !wide { Color.clear.frame(height: Self.topBand).accessibilityHidden(true) }
            GlassControlGroup(spacing: 12) {
                ActionCapsuleGrid(columns: typeSize.isAccessibilitySize ? 1 : 2, spacing: 12) {
                    ForEach(HomePhoneActions.Action.allCases) { action in
                        actionButton(action)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: 192, alignment: .topLeading)
        .task(id: active) {
            // Prepare host-wide Resume choices when Home becomes active; menu content
            // cannot launch a SwiftUI task when the system presents it.
            if active { await model.sidebar.refreshResumeTerminals() }
        }
        .task(id: active ? TerminalProgram.offered(by: model.capabilities).map(\.id) : []) {
            guard active else { return }
            for program in TerminalProgram.offered(by: model.capabilities) where program != .shell {
                await model.agents.icons.load(program.id)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("homeActionArea")
    }

    private func actionButton(_ action: HomePhoneActions.Action) -> some View {
        Group {
            switch action {
            case .newChat:
                PlainChatLaunchMenu { actionLabel(action) }
            case .newTerminal:
                if model.currentProject == nil {
                    Button(action: shell.chooseNewTerminal) { actionLabel(action) }
                } else {
                    Menu { choices(for: action) } label: { actionLabel(action) }
                }
            case .resumeWorkspace:
                Menu { choices(for: action) } label: { actionLabel(action) }
            case .newWorkspace:
                Button { perform(.workspacePicker) } label: { actionLabel(action) }
            }
        }
        .buttonStyle(.plain)
        .glassControl(in: Capsule())
        .disabled(!active || isUnavailable(action))
        .accessibilityHint(action.hint)
        .accessibilityIdentifier(action.identifier)
    }

    private func actionLabel(_ action: HomePhoneActions.Action) -> some View {
        HomePhoneActionLabel(action: action, minHeight: buttonHeight)
    }

    @ViewBuilder private func choices(for action: HomePhoneActions.Action) -> some View {
        let choices = HomePhoneActions.choices(for: action, capabilities: model.capabilities,
            recent: action == .resumeWorkspace ? HomePhoneActions.recentChoices(model: model) : [])
        if choices.isEmpty {
            Text("No chats or terminals to resume")
                .accessibilityIdentifier("homeResumeEmpty")
        } else {
            ForEach(choices) { choice in
                Button { perform(choice.destination) } label: {
                    // Native menus read the second Text directly as the subtitle.
                    Text(choice.title)
                    if let detail = choice.detail, !detail.isEmpty { Text(detail) }
                    model.agents.icons.menuImage(for: choice.agentID, fallback: choice.symbol)
                }
                .accessibilityIdentifier(choice.id)
            }
        }
    }

    private func isUnavailable(_ action: HomePhoneActions.Action) -> Bool {
        switch action {
        case .newChat: model.creating || !model.offersPlainChats
        case .newTerminal: model.creating || TerminalProgram.offered(by: model.capabilities).isEmpty
        case .newWorkspace: model.projects.isEmpty && !model.workspaces.isAvailable
        case .resumeWorkspace: false
        }
    }
}

/// A button's symbol and one-line title, centred together in the button (owner's request, 2026-10-04);
/// the symbol sits in a fixed box so it stays centred on the title.
private struct HomePhoneActionLabel: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dynamicTypeSize) private var typeSize
    let action: HomePhoneActions.Action
    let minHeight: CGFloat

    var body: some View {
        HStack(spacing: AgentLandSpacing.xSmall) {
            Image(systemName: action.symbol)
                .font(AgentLandTypeRole.heading2.font)
                .agentLandIconFrame(.large)
                .accessibilityHidden(true)
            Text(action.title)
                .agentLandFont(.heading3)
                .multilineTextAlignment(.leading)
                // One word on one line beside the symbol; at accessibility sizes the grid is one column
                // wide and the title wraps instead of shrinking.
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(typeSize.isAccessibilitySize ? 1 : 0.85)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(isEnabled ? AgentLandColor.text : AgentLandColor.textSecondary)
        .padding(.horizontal, AgentLandSpacing.small)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .center)
        .contentShape(Capsule())
    }
}
