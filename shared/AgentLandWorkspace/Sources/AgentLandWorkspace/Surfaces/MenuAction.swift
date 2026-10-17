import Foundation

/// A menu item whose action changes what its menu shows runs that action once the menu has gone.
///
/// SwiftUI draws a menu's items (their titles, which show, which are enabled) and a context menu's lifted row from
/// state. When an item's action changes that state at once (a workspace's Close marks it busy, which disables the
/// menu's items and puts a spinner in its row), SwiftUI rewrites the menu while UIKit is still taking it away, and
/// UIKit, still following the touch that chose the item, can re-enter SwiftUI's update and stop the app (an
/// `AG::precondition_failure` under `UIContextMenuInteraction.updateVisibleMenu`; fix-up after native-iOS batch 11).
/// Such an item runs its action through `afterDismissal`, as the task menu's buttons run once their panel has gone.
/// Its swipe and VoiceOver actions run at once: no menu is on its way out then.
@MainActor
enum MenuAction {
    /// How long iPhone and iPad wait. No API says a SwiftUI menu has gone; a menu from a button closes in under 0.1 s
    /// (measured 2026-10-05), and a quarter second outlasts that and the touch that chose the item. The Mac's menus
    /// run their actions once they have closed, so it waits for nothing.
    static var dismissal: Duration {
        #if os(iOS)
        .milliseconds(250)
        #else
        .zero
        #endif
    }

    /// Runs `action` once a menu closing now has gone.
    static func afterDismissal(_ action: @escaping @MainActor () async -> Void) {
        afterDismissal(waiting: dismissal, action)
    }

    /// `afterDismissal` with its wait given (tests).
    static func afterDismissal(waiting wait: Duration, _ action: @escaping @MainActor () async -> Void) {
        Task { @MainActor in
            if wait > .zero { try? await Task.sleep(for: wait) }
            await action()
        }
    }
}
