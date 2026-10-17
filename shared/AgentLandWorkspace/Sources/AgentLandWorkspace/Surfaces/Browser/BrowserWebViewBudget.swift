import Foundation

/// Something that keeps a live web view and can give it up, keeping where it was.
@MainActor protocol BrowserWebViewHolder: AnyObject {
    func unloadWebView()
}

/// Keeps at most `limit` web views loaded across the browser tabs: showing one makes it the most
/// recent, and the least recently shown beyond the limit unloads. An unloaded tab keeps its place
/// and history and loads again when it is shown. Each web view runs its own content process, so the
/// limit is per app, not per workspace.
@MainActor final class BrowserWebViewBudget {
    static let shared = BrowserWebViewBudget(limit: 3)

    let limit: Int
    /// Least recently shown first.
    private var order: [ObjectIdentifier] = []
    private var holders: [ObjectIdentifier: Weak] = [:]

    private struct Weak {
        weak var holder: (any BrowserWebViewHolder)?
    }

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// The holders with a live web view, least recently shown first.
    var live: [ObjectIdentifier] {
        order.filter { holders[$0]?.holder != nil }
    }

    func isLive(_ holder: any BrowserWebViewHolder) -> Bool { holders[ObjectIdentifier(holder)]?.holder != nil }

    /// `holder` shows its web view now. The least recently shown beyond the limit unload.
    func use(_ holder: any BrowserWebViewHolder) {
        let id = ObjectIdentifier(holder)
        order.removeAll { $0 == id || holders[$0]?.holder == nil }
        holders = holders.filter { $0.value.holder != nil }
        order.append(id)
        holders[id] = Weak(holder: holder)
        while order.count > limit {
            let evicted = order.removeFirst()
            // Forget it before it unloads, so an unload that looks back finds it gone.
            let unloading = holders.removeValue(forKey: evicted)?.holder
            unloading?.unloadWebView()
        }
    }

    /// `holder` gave its web view up or ended.
    func release(_ holder: any BrowserWebViewHolder) {
        let id = ObjectIdentifier(holder)
        order.removeAll { $0 == id }
        holders.removeValue(forKey: id)
    }
}
