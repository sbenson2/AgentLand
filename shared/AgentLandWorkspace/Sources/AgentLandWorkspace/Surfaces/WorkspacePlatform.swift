import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The horizontal size class: the system's on iPhone and iPad. A Mac window is always regular: the
/// shell shows its sidebar beside the detail, like iPad.
@propertyWrapper struct WorkspaceHorizontalSizeClass: DynamicProperty {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var value
    var wrappedValue: UserInterfaceSizeClass? { value }
    #else
    var wrappedValue: UserInterfaceSizeClass? { .regular }
    #endif

    init() {}
}

/// The vertical size class: the system's on iPhone and iPad; a Mac window is always regular.
@propertyWrapper struct WorkspaceVerticalSizeClass: DynamicProperty {
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var value
    var wrappedValue: UserInterfaceSizeClass? { value }
    #else
    var wrappedValue: UserInterfaceSizeClass? { .regular }
    #endif

    init() {}
}

/// What differs between the platforms' text input and pasteboard.
enum WorkspacePlatform {
    @MainActor static var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    /// Ends text editing before a dialog or a new surface: on iPhone and iPad it hides the keyboard.
    /// The Mac has no keyboard to hide, and its focus stays where the person put it.
    @MainActor static func endEditing() {
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    /// Puts `string` on the general pasteboard.
    @MainActor static func copy(_ string: String) {
        #if os(iOS)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }

    #if os(macOS)
    /// Closes the key window, as the File menu's Close does.
    @MainActor static func closeKeyWindow() {
        NSApp.keyWindow?.performClose(nil)
    }
    #endif
}

extension View {
    /// The inline title of the iPhone and iPad navigation bar. A Mac window shows its title one way.
    func workspaceInlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// File names, paths and addresses are typed as they are: no automatic capitals on iPhone and iPad
    /// (the Mac has none).
    func workspaceNoAutocapitalization() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    /// A sheet's size on the Mac, where a sheet is only as large as its content asks; on iPhone and
    /// iPad the system sizes it.
    func workspaceSheetFrame(minWidth: CGFloat = 560, minHeight: CGFloat = 460) -> some View {
        #if os(macOS)
        frame(minWidth: minWidth, idealWidth: minWidth + 120, minHeight: minHeight, idealHeight: minHeight + 160)
        #else
        self
        #endif
    }
}

extension ToolbarItemPlacement {
    /// The trailing end of the bar: the navigation bar's on iPhone and iPad, the window toolbar's on
    /// the Mac.
    static var workspaceTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}

#if os(macOS)
/// The Mac has no Dynamic Type: its text styles keep their sizes whatever `dynamicTypeSize` says. Code
/// text (the terminal, the editor and diffs) is sized here instead, so ⌘+ and ⌘− still change it: by
/// the ratio iPhone's body text has at that size to its default (17 pt).
enum MacCodeText {
    /// The default size of code text on the Mac, as Terminal and Xcode use.
    static let baseSize: CGFloat = 13

    static func scale(for size: DynamicTypeSize) -> CGFloat {
        let body: CGFloat = switch size {
        case .xSmall: 14
        case .small: 15
        case .medium: 16
        case .large: 17
        case .xLarge: 19
        case .xxLarge: 21
        case .xxxLarge: 23
        case .accessibility1: 28
        case .accessibility2: 33
        case .accessibility3: 40
        case .accessibility4: 47
        case .accessibility5: 53
        @unknown default: 17
        }
        return body / 17
    }

    /// Code text at `base` points for the text size.
    static func size(_ base: CGFloat = baseSize, for typeSize: DynamicTypeSize) -> CGFloat {
        (base * scale(for: typeSize)).rounded()
    }

    static func font(_ base: CGFloat = baseSize, for typeSize: DynamicTypeSize) -> NSFont {
        .monospacedSystemFont(ofSize: size(base, for: typeSize), weight: .regular)
    }
}
#endif
