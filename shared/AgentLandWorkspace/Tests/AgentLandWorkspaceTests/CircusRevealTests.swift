import XCTest
import AgentLandCore
@testable import AgentLandWorkspace

/// The moment the circus is revealed (`circusRevealedAt`), when the first clown comes out of the tent's door on
/// Home and the empty-chat landings: once after the opening cover or an unlock, kept across tab switches and
/// views built again, and never while the cover or the lock is up.
@MainActor final class CircusRevealTests: XCTestCase {
    private let identity = ConnectionIdentity(host: "https://studio.local:9841", deviceID: "device-a")
    private var suite = ""

    override func tearDown() async throws {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    func testTheCircusIsRevealedOnceUntilTheLockOrANewOpening() throws {
        suite = "circus-reveal-\(UUID())"
        let model = WorkspaceModel(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        model.attach(hostID: "https://studio.local:9841|device-a", identity: identity, client: nil)
        XCTAssertTrue(model.presentationPending, "Attaching puts the opening cover up")
        model.circusShown(at: Date(timeIntervalSince1970: 1))
        XCTAssertNil(model.circusRevealedAt, "Nothing is revealed under the cover")
        let ticket = try XCTUnwrap(model.presentationTicket)
        XCTAssertTrue(model.completePresentation(ticket))

        model.circusShown(at: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(model.circusRevealedAt, Date(timeIntervalSince1970: 10))
        // Another tab, Home again, a view built again: the reveal stays.
        model.projects = [Project(id: "a", name: "App")]
        model.openWorkspace("a")
        model.selectedTabID = nil
        model.circusShown(at: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(model.circusRevealedAt, Date(timeIntervalSince1970: 10), "Tab switches and rebuilt views keep the reveal")

        model.locked = true
        XCTAssertNil(model.circusRevealedAt, "The lock clears it")
        model.circusShown(at: Date(timeIntervalSince1970: 30))
        XCTAssertNil(model.circusRevealedAt, "Nothing is revealed under the lock")
        model.locked = false
        model.circusShown(at: Date(timeIntervalSince1970: 40))
        XCTAssertEqual(model.circusRevealedAt, Date(timeIntervalSince1970: 40), "Shown after the unlock: revealed again")

        model.beginPresentation()
        XCTAssertNil(model.circusRevealedAt, "A new opening clears it")
        model.circusShown(at: Date(timeIntervalSince1970: 50))
        XCTAssertNil(model.circusRevealedAt)
        XCTAssertTrue(model.completePresentation(try XCTUnwrap(model.presentationTicket)))
        model.circusShown(at: Date(timeIntervalSince1970: 60))
        XCTAssertEqual(model.circusRevealedAt, Date(timeIntervalSince1970: 60))
    }
}
