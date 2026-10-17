import SwiftUI

/// Where lists and pages take their colors (the owner's choice, 2026-10-07: Home's paper and slate on every screen,
/// panel, sheet and row). A list hides its own background over its page, `agentLandListPage`: the canvas on a full
/// screen (the default), `surfaceRaised` in a sheet (`agentLandSheetPage()`), and nothing inside a header panel, whose
/// native glass platter is the page (`agentLandPanelPage()`). Its rows are `surface` with `separator` between
/// them (`listRowFill`, `AgentLandForm`). The Mac draws the canvas behind its lists, as before, whatever the
/// environment says, and keeps the system's rows in its forms.
public extension EnvironmentValues {
    /// The page behind lists and their surroundings on iPhone and iPad; nil where something around them paints it.
    @Entry var agentLandListPage: AgentLandColor? = .canvas
}

public extension View {
    /// The list's own background hidden over its page: `agentLandListPage` on iPhone and iPad (the navigation
    /// container's background too, so a page pushed inside a panel or a sheet keeps its tone), the canvas on the Mac.
    func listPageBackground() -> some View {
        modifier(AgentLandListPage(hidesList: true))
    }

    /// The list's own background hidden, where something around the list paints its page.
    func hidesListPageBackground() -> some View {
        scrollContentBackground(.hidden)
    }

    /// The page around a list or in its place (a field over it, a loading state or message): `agentLandListPage` on
    /// iPhone and iPad, so it continues the list's, and the canvas on the Mac.
    func groupedPageBackground() -> some View {
        modifier(AgentLandListPage(hidesList: false))
    }

    /// A row of `color` on every platform, with the separator token between rows when `separator` is true.
    @ViewBuilder func listRowFill(_ color: AgentLandColor, separator: Bool = false) -> some View {
        if separator {
            listRowBackground(Rectangle().fill(color)).listRowSeparatorTint(AgentLandColor.separator.color)
        } else {
            listRowBackground(Rectangle().fill(color))
        }
    }

    /// A row of `color`, on the Mac, with the separator token between rows when `separator` is true. On iPhone and
    /// iPad the row stays clear over its page, as a plain list's rows are (Files' lists, seamless with the page).
    @ViewBuilder func macListRowBackground(_ color: AgentLandColor, separator: Bool = false) -> some View {
        #if os(macOS)
        listRowFill(color, separator: separator)
        #else
        self
        #endif
    }

    /// `surface` behind every row of the sections or rows it is applied to, with `separator` between them, on iPhone
    /// and iPad: a grouped list's cells in paper and slate. Nothing on the Mac.
    @ViewBuilder func surfaceRows() -> some View {
        #if os(macOS)
        self
        #else
        listRowFill(.surface, separator: true)
        #endif
    }

    /// A sheet's content on iPhone and iPad: the sheet's background is `surfaceRaised`, and so is the page of the lists
    /// in it. Nothing on the Mac.
    @ViewBuilder func agentLandSheetPage() -> some View {
        #if os(macOS)
        self
        #else
        presentationBackground(AgentLandColor.surfaceRaised).environment(\.agentLandListPage, .surfaceRaised)
        #endif
    }

    /// A header panel's content: its lists and pages draw no background over the native glass platter.
    func agentLandPanelPage() -> some View {
        environment(\.agentLandListPage, nil)
    }
}

/// A grouped `Form` whose rows are `surface` with `separator` between them on iPhone and iPad (`surfaceRows()` over
/// its sections), on the page its surroundings give it (`settingsForm()` or `listPageBackground()`); a plain `Form` on
/// the Mac.
public struct AgentLandForm<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        Form { content.surfaceRows() }
    }
}

private struct AgentLandListPage: ViewModifier {
    @Environment(\.agentLandListPage) private var page
    let hidesList: Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        hidden(content).background(AgentLandColor.canvas)
        #else
        let fill = page.map(AnyShapeStyle.init) ?? AnyShapeStyle(Color.clear)
        hidden(content).background(fill).containerBackground(fill, for: .navigation)
        #endif
    }

    /// The list's own background hidden, for a list; anything else as it is.
    @ViewBuilder private func hidden(_ content: Content) -> some View {
        if hidesList { content.scrollContentBackground(.hidden) } else { content }
    }
}
