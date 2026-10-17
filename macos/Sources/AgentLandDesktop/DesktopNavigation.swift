import SwiftUI

/// What the windows share for this launch.
@MainActor
final class DesktopNavigation: ObservableObject {
    /// Whether this launch has already looked for paired devices to open pairing by itself (once per launch).
    var autoPairingChecked = false
}
