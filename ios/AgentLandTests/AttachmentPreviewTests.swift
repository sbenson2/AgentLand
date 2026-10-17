import XCTest
import SwiftUI
import UIKit
@testable import AgentLandArchive

@MainActor @Observable private final class PreviewTarget {
    var url: URL?
}

private struct PreviewHost: View {
    @Bindable var target: PreviewTarget
    var body: some View { Color.clear.attachmentPreview($target.url) }
}

/// An archived chat's attachment opens in the system's file preview through UIKit's document interaction
/// controller, which loads Quick Look only when a preview opens (linking Quick Look made every launch
/// load it first).
@MainActor final class AttachmentPreviewTests: XCTestCase {
    private func temporaryFile() throws -> URL {
        let file = FileManager.default.temporaryDirectory.appending(path: "attachment-\(UUID().uuidString).txt")
        try Data("An attachment from the archive\n".utf8).write(to: file)
        return file
    }

    private func window(showing controller: UIViewController) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return window
    }

    private func eventually(_ what: String, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), what)
    }

    func testSettingTheAttachmentPresentsThePreview() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let target = PreviewTarget()
        let host = UIHostingController(rootView: PreviewHost(target: target))
        let window = try window(showing: host)
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(host.presentedViewController, "Nothing is previewed without an attachment")

        target.url = file
        await eventually("The preview opens") { host.presentedViewController.map { !$0.isBeingPresented } ?? false }
        host.presentedViewController?.dismiss(animated: false)
    }

    func testClosingThePreviewClearsTheAttachment() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let host = UIViewController()
        let window = try window(showing: host)
        defer { window.isHidden = true }
        let coordinator = AttachmentPreviewPresenter.Coordinator()
        coordinator.host = host
        var closed = 0
        coordinator.closed = { closed += 1 }

        coordinator.show(file)
        coordinator.show(file)
        // Shown and settled: a preview still animating in ignores its dismissal.
        await eventually("The preview opens") { host.presentedViewController.map { !$0.isBeingPresented } ?? false }
        let interaction = try XCTUnwrap(coordinator.interaction)
        interaction.dismissPreview(animated: false)
        await eventually("Closing the preview clears the attachment once") { closed == 1 }
        XCTAssertNil(coordinator.interaction)
        await eventually("The preview is gone") { host.presentedViewController == nil }
    }
}
