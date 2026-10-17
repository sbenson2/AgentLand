import SwiftUI
import AgentLandCore
import AgentLandDesign

/// One terminal of another device, or of the Mac, as "On <device>" shows it: the agent's icon, what runs in it, its
/// program and workspace (or folder), and what it is doing. iPhone's Workspace tab and iPad's Home share it.
struct OtherTerminalRowLabel: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let row: OtherTerminalRow

    /// At an accessibility size the status goes under the subtitle and every line wraps, so the title keeps its words.
    private var stacked: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        HStack(alignment: stacked ? .top : .center, spacing: AgentLandSpacing.small) {
            model.agents.icons.menuImage(for: row.programID, fallback: "terminal")
                .resizable().scaledToFit()
                .agentLandIconFrame(.regular)
                .rowIconStyle()
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .agentLandFont(.bodyEmphasized)
                    .foregroundStyle(AgentLandColor.text)
                    .lineLimit(stacked ? nil : 1)
                Text(row.subtitle)
                    .agentLandFont(.metadata)
                    .foregroundStyle(AgentLandColor.textSecondary)
                    .lineLimit(stacked ? nil : 1)
                if stacked { status }
            }
            if !stacked {
                Spacer(minLength: AgentLandSpacing.xSmall)
                status
            }
        }
        .frame(maxWidth: .infinity, minHeight: AgentLandTapTarget.platformMinimum, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var status: some View {
        Text(row.status)
            .agentLandFont(.metadata)
            .foregroundStyle(AgentLandColor.textSecondary)
            .multilineTextAlignment(stacked ? .leading : .trailing)
    }
}

/// "On <device>" as sections of the Workspace tab's list (iPhone): one per device, the device active most recently
/// first, its terminals as rows. A tap opens the terminal in its workspace as a tab (the shell then shows it), or on a
/// screen of its own outside any workspace (`showStandalone`). The list reads the agents' icons (`otherDeviceIcons`).
struct OtherDevicesSections: View {
    @Environment(WorkspaceModel.self) private var model
    let showStandalone: (StandaloneTerminalRoute) -> Void

    var body: some View {
        ForEach(model.others.sections) { section in
            Section {
                ForEach(section.rows) { row in
                    Button { open(row) } label: { OtherTerminalRowLabel(row: row) }
                        .accessibilityIdentifier("otherTerminal-" + row.id)
                }
            } header: {
                // One element: the words as a heading. The icon is decoration, and an identifier on the Label alone
                // would also reach the icon, whose label is the symbol's name.
                Label(section.title, systemImage: section.glyph)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(section.title)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("otherDevice-" + section.id)
            }
            .surfaceRows()
        }
    }

    private func open(_ row: OtherTerminalRow) {
        if case let .standalone(route) = model.openShared(row.terminal) { showStandalone(route) }
    }
}

/// "On <device>" as one grouped card below Home's launch capsules (iPad), built from the same rows: each device's
/// heading, then its terminals on the row tone with separators between them. A long list scrolls inside the card, so
/// Home's launcher keeps its place.
struct OtherDevicesCard: View {
    @Environment(WorkspaceModel.self) private var model
    let showStandalone: (StandaloneTerminalRoute) -> Void

    var body: some View {
        if !model.others.sections.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: AgentLandSpacing.small) {
                    ForEach(model.others.sections) { section in
                        VStack(alignment: .leading, spacing: AgentLandSpacing.xxSmall) {
                            Label(section.title, systemImage: section.glyph)
                                .agentLandFont(.metadata)
                                .foregroundStyle(AgentLandColor.textSecondary)
                                .padding(.horizontal, AgentLandSpacing.small)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(section.title)
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityIdentifier("otherDevice-" + section.id)
                            VStack(spacing: 0) {
                                ForEach(section.rows) { row in
                                    Button { open(row) } label: {
                                        OtherTerminalRowLabel(row: row)
                                            .padding(.horizontal, AgentLandSpacing.small)
                                    }
                                    .buttonStyle(OtherTerminalCardRowStyle())
                                    .accessibilityIdentifier("otherTerminal-" + row.id)
                                    if row.id != section.rows.last?.id {
                                        AgentLandColor.separator.color.frame(height: 1 / 3)
                                            .padding(.leading, AgentLandSpacing.small)
                                    }
                                }
                            }
                            .background(AgentLandColor.surface, in: AgentLandRadius.shape(AgentLandRadius.card))
                            // A pressed row's highlight keeps to the card's corners.
                            .clipShape(AgentLandRadius.shape(AgentLandRadius.card))
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            .otherDeviceIcons()
        }
    }

    private func open(_ row: OtherTerminalRow) {
        if case let .standalone(route) = model.openShared(row.terminal) { showStandalone(route) }
    }
}

/// A card row's button: the card is no List, so it draws a list row's pressed state itself, the row filled with the
/// separator token's tone while pressed, as the Workspace tab's rows are on iPhone. The Mac keeps a plain button.
private struct OtherTerminalCardRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        #if os(iOS)
        configuration.label
            .background { if configuration.isPressed { AgentLandColor.separator.color.opacity(0.6) } }
        #else
        configuration.label
        #endif
    }
}

private struct OtherDeviceIcons: ViewModifier {
    @Environment(WorkspaceModel.self) private var model

    /// The agents among the rows' programs; a plain shell has no icon of its own.
    private var programs: [String] {
        var seen = Set<String>()
        return model.others.sections.flatMap(\.rows).map(\.programID)
            .filter { $0 != TerminalProgram.shell.id && seen.insert($0).inserted }
    }

    func body(content: Content) -> some View {
        content.task(id: "\(model.agents.icons.canLoad)|\(programs.joined(separator: ","))") {
            for program in programs { await model.agents.icons.load(program) }
        }
    }
}

extension View {
    /// Reads the icons of the agents "On <device>" shows, as the launchers do.
    func otherDeviceIcons() -> some View { modifier(OtherDeviceIcons()) }

    /// Reads "On <device>" while it shows (`OtherDevicesReading`).
    func readsOtherDevices() -> some View { modifier(OtherDevicesReading()) }
}

/// Reads "On <device>" while its list shows: at once, then every 4 s, but only while the scene is active, the workspace
/// is unlocked and the host answers. The lock covers the list without unmounting it and the background keeps it, so
/// the reads stop there and start again, at once, when they are back (as the sidebar's lists, `WorkspaceSidebarLoading`);
/// `OtherDevicesModel.refresh` refuses the lock and an unreachable host itself too.
private struct OtherDevicesReading: ViewModifier {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    private var reading: Bool { scenePhase == .active && !model.locked && model.reachable }
    /// The capabilities arrive after the first read may have been asked for: a read made before them returns early, so
    /// their sharing is part of the key and the loop starts again when they come, not 4 s later.
    private var key: String { "\(reading)|\(model.capabilities?.sharesTerminals == true)" }

    func body(content: Content) -> some View {
        content.task(id: key) {
            guard reading else { return }
            while !Task.isCancelled {
                await model.others.refresh()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }
}

/// iPad's Home (`HomeView(tabID: nil)`): reads "On <device>" while Home shows (`readsOtherDevices`) and pushes a
/// standalone terminal's screen. Nothing elsewhere.
struct OtherDevicesFollow: ViewModifier {
    @Environment(WorkspaceModel.self) private var model
    let enabled: Bool
    @Binding var standalone: StandaloneTerminalRoute?

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content
                .readsOtherDevices()
                .navigationDestination(item: $standalone) { route in StandaloneTerminalView(route: route) }
        } else {
            content
        }
    }
}
