import SwiftUI
#if os(iOS)
import UIKit
#else
import QuickLook
#endif

extension View {
    /// Shows `url` in the system's file preview while it is set, and clears it when the preview closes.
    ///
    /// On iPhone and iPad the preview comes from `UIDocumentInteractionController`, which loads Quick
    /// Look only when a preview opens. Linking Quick Look instead (`quickLookPreview`) made every launch
    /// load it before any of the app's code ran (about 200 ms on the simulator).
    func attachmentPreview(_ url: Binding<URL?>) -> some View {
        #if os(iOS)
        background(AttachmentPreviewPresenter(url: url).frame(width: 0, height: 0).accessibilityHidden(true))
        #else
        quickLookPreview(url)
        #endif
    }
}

#if os(iOS)
/// Presents the preview from a view controller in the view's hierarchy (a sheet's, when the archive is
/// shown in one).
struct AttachmentPreviewPresenter: UIViewControllerRepresentable {
    @Binding var url: URL?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.host = controller
        coordinator.closed = { url = nil }
        coordinator.show(url)
    }

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: Coordinator) {
        coordinator.host = nil
    }

    /// UIKit calls the delegate on the main thread.
    @MainActor final class Coordinator: NSObject, @preconcurrency UIDocumentInteractionControllerDelegate {
        weak var host: UIViewController?
        var closed: (() -> Void)?
        /// The preview on screen, or about to be.
        private(set) var interaction: UIDocumentInteractionController?

        func show(_ url: URL?) {
            guard let url, interaction == nil else { return }
            let interaction = UIDocumentInteractionController(url: url)
            interaction.delegate = self
            self.interaction = interaction
            // After SwiftUI's update, once the host is in its window.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.interaction === interaction else { return }
                if self.host?.view.window == nil || !interaction.presentPreview(animated: true) { self.finish() }
            }
        }

        func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
            host ?? UIViewController()
        }

        func documentInteractionControllerDidEndPreview(_ controller: UIDocumentInteractionController) {
            finish()
        }

        private func finish() {
            interaction = nil
            closed?()
        }
    }
}
#endif
