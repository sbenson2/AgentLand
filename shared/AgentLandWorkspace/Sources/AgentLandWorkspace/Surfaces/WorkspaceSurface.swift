import SwiftUI
import AgentLandDesign

private struct WorkspaceObscuredKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Drawers cover the workspace without replacing or resizing its retained tabs.
    var workspaceObscured: Bool {
        get { self[WorkspaceObscuredKey.self] }
        set { self[WorkspaceObscuredKey.self] = newValue }
    }
}

private struct WorkspaceMenuObscuredKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Something other than the iPhone's drawer covers the workspace. The tab in front's own actions are on its pill's
    /// ••• menu in the drawer (owner, 2026-10-08), so the items a surface hands that menu stay enabled while the drawer
    /// is open, and wait for anything else that covers the workspace (a sheet, a question).
    var workspaceMenuObscured: Bool {
        get { self[WorkspaceMenuObscuredKey.self] }
        set { self[WorkspaceMenuObscuredKey.self] = newValue }
    }
}

/// True while the surface in front draws its art on the art backdrop (Home; the empty-chat landing while it shows in
/// the app's own appearance). The iPhone's shell then paints `AgentLandColor.artBackdrop` behind its header and
/// safe areas, so the paper/slate runs to the screen's edges as a painted terminal's backdrop does, instead of the
/// system background framing it.
struct ArtBackdropKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
