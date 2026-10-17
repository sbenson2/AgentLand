import SwiftUI

public extension View {
    /// Applies Apple's style directly: Menu does not forward custom primitive styles to its label.
    /// iOS 26 supplies the renderer and interaction; the Mac retains its borderless controls.
    @ViewBuilder func agentLandControlButton() -> some View {
        #if os(iOS)
        self.menuStyle(.button)
            .buttonStyle(.glass)
            .controlSize(.large)
        #else
        self.buttonStyle(.plain)
        #endif
    }
}
