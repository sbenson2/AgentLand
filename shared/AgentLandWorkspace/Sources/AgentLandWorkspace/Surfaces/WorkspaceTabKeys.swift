#if os(iOS)
import SwiftUI
import UIKit

/// Workspace keys that must win over UIKit's focused view: ⌃⇥ and ⌃⇧⇥ (Next Tab and Previous Tab), plus Escape
/// while Settings is open. Tab keys also drive the focus system, and a focused Settings field can consume Escape.
/// SwiftUI's keyboard shortcuts cannot ask for priority, so these commands live on the window's root view controller
/// and use `wantsPriorityOverSystemBehavior`. They stay hidden because the visible commands and controls describe
/// their actions. Each is installed only while its action is available.
struct WorkspaceTabKeys: UIViewRepresentable {
    let next: (@MainActor () -> Void)?
    let previous: (@MainActor () -> Void)?
    let escape: (@MainActor () -> Void)?

    func makeUIView(context: Context) -> KeysView { KeysView() }

    func updateUIView(_ view: KeysView, context: Context) {
        view.nextTab = next
        view.previousTab = previous
        view.escape = escape
        view.sync()
    }

    static func dismantleUIView(_ view: KeysView, coordinator: ()) {
        view.nextTab = nil
        view.previousTab = nil
        view.escape = nil
        view.sync()
    }

    /// The window's key commands, the actions they run, and the window they are in.
    final class KeysView: UIView {
        var nextTab: (@MainActor () -> Void)?
        var previousTab: (@MainActor () -> Void)?
        var escape: (@MainActor () -> Void)?
        private weak var controller: UIViewController?
        private let nextCommand: UIKeyCommand
        private let previousCommand: UIKeyCommand
        private let escapeCommand: UIKeyCommand
        private let responderEscapeCommand: UIKeyCommand

        private static func command(input: String, action: Selector,
                                    modifiers: UIKeyModifierFlags = []) -> UIKeyCommand {
            let command = UIKeyCommand(input: input, modifierFlags: modifiers, action: action)
            command.wantsPriorityOverSystemBehavior = true
            command.attributes = .hidden
            return command
        }

        override init(frame: CGRect) {
            nextCommand = Self.command(input: "\t", action: #selector(UIViewController.agentLandNextTab(_:)),
                                       modifiers: .control)
            previousCommand = Self.command(input: "\t", action: #selector(UIViewController.agentLandPreviousTab(_:)),
                                           modifiers: [.control, .shift])
            escapeCommand = Self.command(input: UIKeyCommand.inputEscape,
                                         action: #selector(UIViewController.agentLandCloseSettings(_:)))
            responderEscapeCommand = Self.command(
                input: UIKeyCommand.inputEscape,
                action: #selector(KeysView.agentLandCloseSettings(_:))
            )
            super.init(frame: frame)
            // Clear and out of touch, VoiceOver and the focus system's search. It stays in the visible view
            // hierarchy so it can briefly become first responder when Settings opens without a focused field.
            backgroundColor = .clear
            // UIKit removes key events from a disabled view's queue. The shell gives this view a zero-size
            // frame, so it accepts Escape as first responder without becoming a touch target.
            isUserInteractionEnabled = true
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var canBecomeFirstResponder: Bool { escape != nil }

        override var keyCommands: [UIKeyCommand]? {
            escape == nil ? nil : [responderEscapeCommand]
        }

        @objc private func agentLandCloseSettings(_ sender: Any?) {
            escape?()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            sync()
        }

        /// Adds each command to the window's root view controller while its action is there, and takes it away
        /// otherwise (and from a window this view has left).
        func sync() {
            let current = window?.rootViewController
            if let controller, controller !== current {
                controller.removeKeyCommand(nextCommand)
                controller.removeKeyCommand(previousCommand)
                controller.removeKeyCommand(escapeCommand)
            }
            controller = current
            if let window { Self.views.setObject(self, forKey: window) }
            guard let current else {
                if isFirstResponder { resignFirstResponder() }
                return
            }
            let activatesEscapeResponder = escape != nil
                && current.keyCommands?.contains(escapeCommand) != true
            for (command, wanted) in [(nextCommand, nextTab != nil), (previousCommand, previousTab != nil),
                                      (escapeCommand, escape != nil)] {
                let present = current.keyCommands?.contains(command) == true
                if wanted, !present { current.addKeyCommand(command) }
                if !wanted, present { current.removeKeyCommand(command) }
            }
            if activatesEscapeResponder {
                becomeFirstResponder()
            } else if escape == nil, isFirstResponder {
                resignFirstResponder()
            }
        }

        /// The view that holds a window's actions.
        private static let views = NSMapTable<UIWindow, KeysView>.weakToWeakObjects()

        static func view(for window: UIWindow?) -> KeysView? {
            window.flatMap { views.object(forKey: $0) }
        }
    }
}

extension UIViewController {
    /// ⌃⇥ (`WorkspaceTabKeys`): the next tab of this window's workspace.
    @objc func agentLandNextTab(_ sender: Any?) {
        WorkspaceTabKeys.KeysView.view(for: viewIfLoaded?.window)?.nextTab?()
    }

    /// ⌃⇧⇥ (`WorkspaceTabKeys`): the previous tab of this window's workspace.
    @objc func agentLandPreviousTab(_ sender: Any?) {
        WorkspaceTabKeys.KeysView.view(for: viewIfLoaded?.window)?.previousTab?()
    }

    /// Escape: closes the Settings drawer before a focused field consumes the key.
    @objc func agentLandCloseSettings(_ sender: Any?) {
        WorkspaceTabKeys.KeysView.view(for: viewIfLoaded?.window)?.escape?()
    }
}
#endif
