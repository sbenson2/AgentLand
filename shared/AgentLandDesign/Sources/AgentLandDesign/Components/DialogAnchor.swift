import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Where a confirmation dialog points. On iPhone and iPad (iOS 26) a confirmation dialog is a popover whose arrow
/// points at the view the modifier is attached to, so each dialog is attached to the row or control it acts on, as
/// Apple's apps do: Mail's Delete points at its button, and a list row's swipe or menu action asks beside that row
/// (owner, 2026-10-08: dialogs on a whole list or surface floated over its middle, over other rows). A row's dialog
/// presents only for that row's item, so a `ForEach` never presents it once per row.
///
/// A question asked from the title menu (the iPhone's task menu, the iPad's actions menu, gone by the time it shows)
/// or a keyboard command has no row: it is attached to this point-sized anchor where that menu sits, laid over the
/// surface with `titleMenu` alignment. On the Mac a dialog is a sheet on its window wherever it is attached.
public struct DialogAnchor: View {
    public init() {}

    public var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
    }

    /// Where a surface's title menu sits over its content: centred under the iPhone's header task button, at the
    /// trailing end under the iPad's actions menu.
    @MainActor public static var titleMenu: Alignment {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone ? .top : .topTrailing
        #else
        .top
        #endif
    }
}
