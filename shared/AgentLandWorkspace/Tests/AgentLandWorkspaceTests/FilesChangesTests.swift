import XCTest
import ImageIO
import Observation
import UniformTypeIdentifiers
import AgentLandCore
@testable import AgentLandWorkspace

/// The Files tab's changes, uploads and search against a scripted host: what goes out, what comes
/// back, and that late or unconfirmed answers never do more than they should.
@MainActor final class FilesChangesTests: XCTestCase {
    private let identity = ConnectionIdentity(host: "https://studio.local:9841", deviceID: "device-a")
    private let hostID = "https://studio.local:9841|device-a"
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
    }

    private static let allFiles = ["move", "mkdir", "upload", "trash", "delete", "search"]

    private func workspace(_ host: ScriptedHost, files: [String] = allFiles, name: String = #function) throws -> WorkspaceModel {
        let suite = "files-changes-\(name)-\(UUID())"
        suites.append(suite)
        let workspace = WorkspaceModel(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        workspace.attach(hostID: hostID, identity: identity, client: try client(host))
        workspace.projects = [Project(id: "p", name: "Project")]
        workspace.capabilities = CapabilitiesResponse(interactions: true, terminal: true, files: files)
        workspace.selectedProjectID = "p"
        return workspace
    }

    private func client(_ host: ScriptedHost) throws -> APIClient {
        APIClient(address: try ServerAddress(validating: "https://studio.local:9841"), token: "token", transport: host)
    }

    private func filesTab(_ workspace: WorkspaceModel) -> (WorkspaceTab, FilesSession) {
        let tab = WorkspaceTab(kind: .files, projectID: "p", title: "Files")
        workspace.open(tab)
        return (tab, workspace.filesSession(for: tab))
    }

    nonisolated private static func entry(_ path: String, directory: Bool = false, size: Int = 3) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return #"{"name":"\#(name)","path":"\#(path)","isDirectory":\#(directory),"size":\#(size)}"#
    }

    nonisolated private static func listing(_ entries: String...) -> String { #"{"entries":[\#(entries.joined(separator: ","))]}"# }

    nonisolated private static func refusal(_ code: String, _ message: String = "Refused", extra: String = "") -> String {
        #"{"error":{"code":"\#(code)","message":"\#(message)"\#(extra)}}"#
    }

    // MARK: Rename, move and new folders

    /// A listing that failed while the host was away is read again once the connection epoch has moved on (the
    /// view need not have been on screen when the host came back); never while the epoch is unchanged.
    func testAListingThatFailedWhileTheHostWasAwayIsReadAgainAfterItCameBack() async throws {
        let host = ScriptedHost()
        let away = Counter()
        away.increment()
        host.on("/v1/files") { _ in
            away.value > 0 ? (503, Self.refusal("host_unavailable", "Could not connect to the server."))
                : (200, Self.listing(Self.entry("hello.txt")))
        }
        let workspace = try workspace(host)
        let (_, session) = filesTab(workspace)
        await session.loadIfNeeded()
        XCTAssertNotNil(session.issue)
        await session.loadIfNeeded()
        XCTAssertEqual(host.requests("/v1/files").count, 1, "No new read while the connection has not come back")

        away.decrement()
        workspace.connectionEpoch += 1
        await session.loadIfNeeded()
        XCTAssertEqual(host.requests("/v1/files").count, 2, "The failed listing is read again after recovery")
        XCTAssertNil(session.issue)
        XCTAssertEqual(session.entries.map(\.path), ["hello.txt"])
        await session.loadIfNeeded()
        XCTAssertEqual(host.requests("/v1/files").count, 2, "A listing that worked is not read again")
    }

    func testRenameMovesTheItemInItsFolderRereadsTheFolderAndFollowsOpenEditors() async throws {
        let host = ScriptedHost()
        host.on("/v1/files") { _ in (200, Self.listing(Self.entry("docs", directory: true), Self.entry("notes.md"))) }
        host.on("/v1/files/move") { _ in (200, Self.entry("docs/guide.md")) }
        let workspace = try workspace(host)
        let editor = WorkspaceTab(kind: .editor, projectID: "p", resourceID: "docs/readme.md", title: "readme.md")
        workspace.open(editor)
        let (_, session) = filesTab(workspace)
        await session.loadIfNeeded()
        let reads = host.requests("/v1/files").count

        session.beginRename(FileEntry(name: "readme.md", path: "docs/readme.md", isDirectory: false, size: 3))
        XCTAssertEqual(session.renameText, "readme.md")
        await session.rename(FileEntry(name: "readme.md", path: "docs/readme.md", isDirectory: false, size: 3), to: " guide.md ")

        XCTAssertEqual(host.bodies("/v1/files/move").last as? [String: String], ["projectId": "p", "from": "docs/readme.md", "to": "docs/guide.md"])
        XCTAssertEqual(session.notice?.tone, .success)
        XCTAssertEqual(session.confirmedChanges, 1)
        XCTAssertEqual(host.requests("/v1/files").count, reads + 1, "A change reads the folder again")
        XCTAssertEqual(workspace.tab(editor.id)?.resourceID, "docs/guide.md", "An open editor follows its file")
        XCTAssertEqual(workspace.tab(editor.id)?.title, "guide.md")
        XCTAssertTrue(session.changing.isEmpty)

        // Names the host would refuse never go out.
        await session.rename(FileEntry(name: "a", path: "a", isDirectory: false, size: 1), to: "b/c")
        await session.rename(FileEntry(name: "a", path: "a", isDirectory: false, size: 1), to: "..")
        XCTAssertEqual(host.requests("/v1/files/move").count, 1)
        XCTAssertEqual(session.notice?.tone, .warning)
        // The same name is no change.
        await session.rename(FileEntry(name: "a", path: "a", isDirectory: false, size: 1), to: "a")
        XCTAssertEqual(host.requests("/v1/files/move").count, 1)
    }

    func testMovingIntoAFolderAndATakenNameOffersKeepBoth() async throws {
        let host = ScriptedHost()
        let calls = Counter()
        host.on("/v1/files") { _ in (200, Self.listing(Self.entry("src", directory: true), Self.entry("a.swift"))) }
        host.on("/v1/files/move") { _ in
            calls.increment() == 1
                ? (409, Self.refusal("file_exists", extra: #","suggestedName":"a 2.swift""#))
                : (200, Self.entry("src/a 2.swift"))
        }
        let workspace = try workspace(host)
        let (_, session) = filesTab(workspace)
        let file = FileEntry(name: "a.swift", path: "a.swift", isDirectory: false, size: 3)
        XCTAssertFalse(session.canMove(file, to: ""), "Not where it already is")
        let folder = FileEntry(name: "src", path: "src", isDirectory: true, size: 0)
        XCTAssertFalse(session.canMove(folder, to: "src/inner"), "Never into itself")

        await session.move(file, toFolder: "src")
        XCTAssertEqual(host.bodies("/v1/files/move").first as? [String: String], ["projectId": "p", "from": "a.swift", "to": "src/a.swift"])
        let conflict = try XCTUnwrap(session.nameConflict)
        XCTAssertEqual(conflict.name, "a.swift")
        XCTAssertEqual(conflict.suggestedName, "a 2.swift")
        XCTAssertEqual(session.confirmedChanges, 0)

        await session.keepBoth(conflict)
        XCTAssertNil(session.nameConflict)
        XCTAssertEqual(host.bodies("/v1/files/move").last as? [String: String], ["projectId": "p", "from": "a.swift", "to": "src/a 2.swift"])
        XCTAssertEqual(session.confirmedChanges, 1)
    }

    func testNewFolderGoesInTheFolderShown() async throws {
        let host = ScriptedHost()
        host.on("/v1/files") { _ in (200, Self.listing()) }
        host.on("/v1/files/mkdir") { _ in (201, Self.entry("docs/New Folder", directory: true, size: 0)) }
        let workspace = try workspace(host)
        let (_, session) = filesTab(workspace)
        session.navigate(to: "docs")
        session.beginNewFolder()
        XCTAssertTrue(session.creatingFolder)
        await session.makeFolder(named: session.newFolderName)
        XCTAssertEqual(host.bodies("/v1/files/mkdir").last as? [String: String], ["projectId": "p", "path": "docs/New Folder"])
        XCTAssertEqual(session.notice?.title, "Made “New Folder”")
        XCTAssertFalse(session.creatingFolder)
    }

    func testChangesAreRefusedOfflineAndALateAnswerForAnotherHostIsDropped() async throws {
        let host = ScriptedHost()
        let gate = Gate()
        let arrived = Gate()
        host.on("/v1/files") { _ in (200, Self.listing(Self.entry("a.txt"))) }
        host.on("/v1/files/move") { _ in
            await arrived.open()
            await gate.wait()
            return (200, Self.entry("b.txt"))
        }
        let workspace = try workspace(host)
        let (_, session) = filesTab(workspace)
        let file = FileEntry(name: "a.txt", path: "a.txt", isDirectory: false, size: 3)

        workspace.reachable = false
        await session.rename(file, to: "b.txt")
        XCTAssertTrue(host.requests("/v1/files/move").isEmpty, "Offline sends nothing")
        XCTAssertEqual(session.notice?.title, "You’re offline, so nothing was changed.")

        workspace.reachable = true
        session.notice = nil
        let rename = Task { await session.rename(file, to: "b.txt") }
        await arrive(at: arrived, "the move")
        // The host changes while the answer is on its way.
        workspace.attach(hostID: "https://other.local|device-b", identity: ConnectionIdentity(host: "https://other.local", deviceID: "device-b"),
                         client: try client(ScriptedHost()))
        await gate.open()
        await rename.value
        XCTAssertNil(session.notice, "A late answer for another host changes nothing")
        XCTAssertEqual(session.confirmedChanges, 0)
    }

    // MARK: Trash and permanent delete

    func testTrashThatIsUnavailableAsksForAPermanentDeleteThatRepeatsThePath() async throws {
        let host = ScriptedHost()
        host.on("/v1/files") { _ in (200, Self.listing(Self.entry("big/data.bin"))) }
        host.on("/v1/files/delete") { request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
            if body["permanent"] as? Bool == true { return (200, #"{"path":"big/data.bin","trashed":false}"#) }
            return (409, Self.refusal("trash_unavailable", "This item can't be moved to the Trash", extra: #","permanentDeleteAllowed":true"#))
        }
        let workspace = try workspace(host)
        let (_, session) = filesTab(workspace)
        let file = FileEntry(name: "data.bin", path: "big/data.bin", isDirectory: false, size: 9)

        session.requestDelete(file)
        XCTAssertEqual(session.pendingTrash, file, "Moving to the Trash asks first")
        XCTAssertTrue(host.requests("/v1/files/delete").isEmpty)
        await session.confirmTrash(file)
        XCTAssertEqual(host.bodies("/v1/files/delete").first as? [String: String], ["projectId": "p", "path": "big/data.bin"])
        XCTAssertEqual(session.pendingPermanentDelete, file, "Another volume asks again, for a permanent delete")
        XCTAssertEqual(session.confirmedChanges, 0)

        await session.confirmPermanentDelete(file)
        let body = try XCTUnwrap(host.bodies("/v1/files/delete").last)
        XCTAssertEqual(body["permanent"] as? Bool, true)
        XCTAssertEqual(body["confirmPath"] as? String, "big/data.bin")
        XCTAssertEqual(session.notice?.title, "Deleted “data.bin”")
        XCTAssertEqual(session.confirmedChanges, 1)
    }

    func testHostsWithoutATrashDeleteAfterTheConfirmation() async throws {
        let host = ScriptedHost()
        host.on("/v1/files") { _ in (200, Self.listing()) }
        let workspace = try workspace(host, files: ["move", "mkdir", "upload", "delete", "search"])
        let (_, session) = filesTab(workspace)
        let file = FileEntry(name: "a.txt", path: "a.txt", isDirectory: false, size: 3)
        session.requestDelete(file)
        XCTAssertNil(session.pendingTrash)
        XCTAssertEqual(session.pendingPermanentDelete, file)

        let bare = try self.workspace(ScriptedHost(), files: [], name: #function + "-bare")
        let (_, bareSession) = filesTab(bare)
        XCTAssertFalse(bareSession.canDelete)
        bareSession.requestDelete(file)
        XCTAssertNil(bareSession.pendingTrash)
        XCTAssertNil(bareSession.pendingPermanentDelete, "A host without deletes offers none")
    }

    func testAnUnconfirmedTrashIsReportedAndNotSentAgain() async throws {
        let host = ScriptedHost()
        host.on("/v1/files") { _ in (200, Self.listing(Self.entry("a.txt"))) }
        host.on("/v1/files/delete") { _ in throw URLError(.networkConnectionLost) }
        let workspace = try workspace(host)
        let (_, session) = filesTab(workspace)
        await session.loadIfNeeded()
        let reads = host.requests("/v1/files").count
        let file = FileEntry(name: "a.txt", path: "a.txt", isDirectory: false, size: 3)
        session.requestDelete(file)
        await session.confirmTrash(file)
        XCTAssertEqual(host.requests("/v1/files/delete").count, 1)
        XCTAssertEqual(session.notice?.tone, .warning)
        XCTAssertEqual(host.requests("/v1/files").count, reads + 1, "The folder is read again to show what the host has")
    }

    // MARK: Uploads

    private func temporaryFile(_ name: String, _ contents: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "files-changes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testUploadsRunTwoAtATimeIntoTheFolderShown() async throws {
        let host = ScriptedHost()
        let gate = Gate()
        let running = Counter()
        let most = Counter()
        host.on("/v1/files") { _ in (200, Self.listing()) }
        host.on("/v1/files/upload") { request in
            let now = running.increment()
            most.raise(to: now)
            await gate.wait()
            running.decrement()
            let path = ScriptedHost.query(request)["path"] ?? ""
            return (201, Self.entry(path, size: request.httpBody?.count ?? 0))
        }
        let workspace = try workspace(host)
        let (_, session) = filesTab(workspace)
        session.navigate(to: "assets")
        let files = try ["one.txt", "two.txt", "three.txt"].map { try temporaryFile($0, "contents of \($0)") }
        session.uploads.addFiles(files)
        await waitUntil("two uploads to start") { host.requests("/v1/files/upload").count == 2 }
        // Each file is prepared off the main actor, so the third may still be preparing when two have started.
        await waitUntil("the third to be prepared") { session.uploads.items.allSatisfy { $0.state != .preparing } }
        XCTAssertEqual(session.uploads.items.filter { $0.state == .waiting }.count, 1, "The third waits for a free slot")
        XCTAssertEqual(host.requests("/v1/files/upload").count, 2, "Never a third while two are sending")
        await gate.open()
        await waitUntil("all three to finish") { session.uploads.completed == 3 }
        XCTAssertEqual(most.value, 2, "Never more than two at once")
        let paths = host.requests("/v1/files/upload").compactMap { ScriptedHost.query($0)["path"] }
        XCTAssertEqual(Set(paths), ["assets/one.txt", "assets/two.txt", "assets/three.txt"])
        XCTAssertEqual(host.requests("/v1/files/upload").first?.httpBody.map { String(decoding: $0, as: UTF8.self) }?.hasPrefix("contents of"), true)
        XCTAssertEqual(session.confirmedChanges, 3)
    }

    func testATakenNameWaitsForKeepBothOrReplaceAndNothingIsSentTwiceByItself() async throws {
        let host = ScriptedHost()
        let uploads = Counter()
        host.on("/v1/files") { _ in (200, Self.listing(Self.entry("report.txt"))) }
        host.on("/v1/files/upload") { request in
            let path = ScriptedHost.query(request)["path"] ?? ""
            if path == "report.txt" && uploads.increment() == 1 {
                return (409, Self.refusal("file_exists", extra: #","suggestedName":"report 2.txt""#))
            }
            return (201, Self.entry(path))
        }
        host.on("/v1/files/delete") { _ in (200, #"{"path":"report.txt","trashed":true,"trashName":"report.txt"}"#) }
        let workspace = try workspace(host)
        let (_, session) = filesTab(workspace)

        session.uploads.addFiles([try temporaryFile("report.txt", "first")])
        await waitUntil("the taken name") { session.uploads.conflict != nil }
        let conflicted = try XCTUnwrap(session.uploads.conflict)
        XCTAssertEqual(conflicted.state, .nameTaken(suggestedName: "report 2.txt"))
        XCTAssertEqual(host.requests("/v1/files/upload").count, 1)
        session.uploads.keepBoth(conflicted.id)
        await waitUntil("Keep Both to finish") { session.uploads.completed == 1 }
        XCTAssertEqual(ScriptedHost.query(try XCTUnwrap(host.requests("/v1/files/upload").last))["path"], "report 2.txt")

        // Replace: the existing item goes to the Trash first, then the same name goes up.
        let replacing = Counter()
        host.on("/v1/files/upload") { request in
            let path = ScriptedHost.query(request)["path"] ?? ""
            return replacing.increment() == 1 ? (409, Self.refusal("file_exists", extra: #","suggestedName":"report 2.txt""#)) : (201, Self.entry(path))
        }
        session.uploads.addFiles([try temporaryFile("report.txt", "second")])
        await waitUntil("the second taken name") { session.uploads.conflict != nil }
        await session.uploads.replace(try XCTUnwrap(session.uploads.conflict).id)
        await waitUntil("Replace to finish") { session.uploads.completed == 2 }
        XCTAssertEqual(host.bodies("/v1/files/delete").last as? [String: String], ["projectId": "p", "path": "report.txt"],
                       "Replace trashes the item that was there, never permanently")
        XCTAssertEqual(ScriptedHost.query(try XCTUnwrap(host.requests("/v1/files/upload").last))["path"], "report.txt")
    }

    func testAnUnconfirmedUploadGoesAgainOnlyWhenAsked() async throws {
        let host = ScriptedHost()
        let attempts = Counter()
        host.on("/v1/files") { _ in (200, Self.listing()) }
        host.on("/v1/files/upload") { request in
            if attempts.increment() == 1 { throw URLError(.networkConnectionLost) }
            return (201, Self.entry(ScriptedHost.query(request)["path"] ?? ""))
        }
        let workspace = try workspace(host)
        let (_, session) = filesTab(workspace)
        session.uploads.addFiles([try temporaryFile("a.txt", "a")])
        await waitUntil("the lost answer") { session.uploads.items.first?.state == .notConfirmed }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(host.requests("/v1/files/upload").count, 1, "Never sent again by itself")
        session.uploads.uploadAgain(try XCTUnwrap(session.uploads.items.first).id)
        await waitUntil("the second attempt") { session.uploads.completed == 1 }
        XCTAssertEqual(host.requests("/v1/files/upload").count, 2)
    }

    func testPhotosAreReencodedWithoutTheirLocation() async throws {
        let host = ScriptedHost()
        host.on("/v1/files") { _ in (200, Self.listing()) }
        host.on("/v1/files/upload") { request in (201, Self.entry(ScriptedHost.query(request)["path"] ?? "")) }
        let workspace = try workspace(host)
        let (_, session) = filesTab(workspace)
        let photo = try Self.jpegWithLocation()
        XCTAssertNotNil(Self.gps(in: photo), "The fixture carries a location")

        session.uploads.addPhoto(data: photo, name: "IMG_0001.HEIC", type: .jpeg)
        await waitUntil("the photo to go up") { session.uploads.completed == 1 }
        let sent = try XCTUnwrap(host.requests("/v1/files/upload").last)
        XCTAssertEqual(ScriptedHost.query(sent)["path"], "IMG_0001.jpg", "Re-encoded photos go up as JPEG")
        let body = try XCTUnwrap(sent.httpBody)
        XCTAssertNil(Self.gps(in: body), "The location never leaves the device")
        XCTAssertNotNil(CGImageSourceCreateWithData(body as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
    }

    private static func jpegWithLocation() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 122.01, kCGImagePropertyGPSLongitudeRef: "W"]
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private static func gps(in data: Data) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        return properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
    }

    // MARK: Menus

    /// The title and sort menus read `hasModifiedTimes`, and a menu made again while open loses a tap on
    /// its items: a refresh that lists the same items must leave the flag's readers alone.
    func testARefreshChangesTheModifiedTimesFlagOnlyWhenTheListingDoes() async throws {
        let host = ScriptedHost()
        let dated = Counter()
        host.on("/v1/files") { _ in
            dated.value == 0 ? (200, Self.listing(Self.entry("a.txt")))
                : (200, #"{"entries":[{"name":"a.txt","path":"a.txt","isDirectory":false,"size":3,"modifiedAt":"2026-09-25T07:00:00.250Z"}]}"#)
        }
        let workspace = try workspace(host)
        let (_, session) = filesTab(workspace)
        await session.refreshVisibleTree()
        XCTAssertFalse(session.hasModifiedTimes)
        let changes = Counter()
        withObservationTracking { _ = session.hasModifiedTimes } onChange: { changes.increment() }
        await session.refreshVisibleTree()
        XCTAssertEqual(session.entries.map(\.path), ["a.txt"])
        XCTAssertEqual(changes.value, 0, "The same listing again leaves the menus alone")
        dated.increment()
        await session.refreshVisibleTree()
        XCTAssertEqual(changes.value, 1)
        XCTAssertTrue(session.hasModifiedTimes, "A listing that names times offers Date Modified")
    }

    // MARK: Search

    func testNamesSearchWalksTheFolderShown() async throws {
        let host = ScriptedHost()
        host.on("/v1/files") { request in
            switch ScriptedHost.query(request)["path"] ?? "" {
            case "src": return (200, Self.listing(Self.entry("src/lib", directory: true), Self.entry("src/Main.swift"), Self.entry("src/.env")))
            case "src/lib": return (200, Self.listing(Self.entry("src/lib/MainView.swift"), Self.entry("src/lib/Other.swift")))
            default: return (200, Self.listing(Self.entry("src", directory: true)))
            }
        }
        let workspace = try workspace(host)
        let (_, session) = filesTab(workspace)
        session.navigate(to: "src")
        session.search.text = "main"
        await session.search.run()
        XCTAssertEqual(session.search.names.map(\.path), ["src/Main.swift", "src/lib/MainView.swift"])
        XCTAssertTrue(session.search.resultsCurrent)
        XCTAssertEqual(host.requests("/v1/files").compactMap { ScriptedHost.query($0)["path"] }.filter { $0 == "" }, [],
                       "Only the folder shown and those under it are walked")
    }

    func testContentSearchDropsALateAnswerAndOpensTheEditorAtTheLine() async throws {
        let host = ScriptedHost()
        let first = Gate()
        let firstArrived = Gate()
        host.on("/v1/files") { _ in (200, Self.listing()) }
        host.on("/v1/files/search") { request in
            let query = ScriptedHost.query(request)
            if query["q"] == "old" {
                await firstArrived.open()
                await first.wait()
                return (200, #"{"results":[{"path":"stale.swift","matches":[{"line":1,"column":1,"preview":"old"}]}]}"#)
            }
            XCTAssertEqual(query["path"], "src", "Contents are searched in the folder shown")
            return (200, #"{"results":[{"path":"src/a.swift","matches":[{"line":12,"column":5,"preview":"let needle = 1"}]}],"truncatedReason":"matches"}"#)
        }
        let workspace = try workspace(host)
        let (_, session) = filesTab(workspace)
        session.navigate(to: "src")
        session.search.scope = .contents
        session.search.text = "old"
        let stale = Task { await session.search.run() }
        await arrive(at: firstArrived, "the first search")
        session.search.text = "needle"
        await session.search.run()
        await first.open()
        await stale.value
        XCTAssertEqual(session.search.contents.map(\.path), ["src/a.swift"], "The late answer for an older query is dropped")
        XCTAssertEqual(session.search.limit, .matches)

        session.openMatch(path: "src/a.swift", line: 12)
        let editor = try XCTUnwrap(workspace.currentTab)
        XCTAssertEqual(editor.kind, .editor)
        XCTAssertEqual(editor.resourceID, "src/a.swift")
        let editorSession = workspace.editorSession(for: editor)
        XCTAssertEqual(editorSession.lineRequest?.line, 12)
        XCTAssertEqual(editorSession.caretLine, 12)
        let request = try XCTUnwrap(editorSession.lineRequest)
        editorSession.lineRequestShown(request.id)
        XCTAssertNil(editorSession.lineRequest, "Shown once; a rebuilt view doesn't move the caret back")

        // One character is too little for a contents search; a host without contents search has names only.
        session.search.text = "n"
        await session.search.run()
        XCTAssertNotNil(session.search.issue)
        XCTAssertEqual(host.requests("/v1/files/search").count, 2)
        workspace.capabilities = CapabilitiesResponse(interactions: true, terminal: true, files: ["move"])
        XCTAssertEqual(session.search.effectiveScope, .names)
    }
}

/// A count shared with scripted host handlers.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    @discardableResult func increment() -> Int { lock.withLock { count += 1; return count } }
    func decrement() { lock.withLock { count -= 1 } }
    func raise(to value: Int) { lock.withLock { count = max(count, value) } }
    var value: Int { lock.withLock { count } }
}
