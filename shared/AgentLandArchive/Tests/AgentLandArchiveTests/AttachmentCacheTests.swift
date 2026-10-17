import Foundation
import XCTest
import AgentLandCore
@testable import AgentLandArchive

/// A host sending attachment bytes by name, recording what it was asked. A
/// name it does not have answers as a file kept by name only.
final class AttachmentHost: AttachmentFetching, @unchecked Sendable {
    private let lock = NSLock()
    private let files: [String: Data]
    private let delay: Duration
    private var log: [(chatID: String, messageID: String, name: String, sha256: String?)] = []

    init(_ files: [String: Data], delay: Duration = .zero) { self.files = files; self.delay = delay }

    var requests: [(chatID: String, messageID: String, name: String, sha256: String?)] { lock.withLock { log } }

    func archiveAttachment(chatID: String, messageID: String, name: String, sha256: String?) async throws -> Data {
        lock.withLock { log.append((chatID, messageID, name, sha256)) }
        if delay > .zero { try await Task.sleep(for: delay) }
        guard let data = files[name] else {
            throw ClientError.server(code: "attachment_not_archived", message: "This attachment's bytes were not archived")
        }
        return data
    }
}

/// A clock the eviction tests move by hand.
final class StepClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_790_000_000)
    func now() -> Date { lock.withLock { current } }
    func step() { lock.withLock { current = current.addingTimeInterval(60) } }
}

final class AttachmentCacheTests: XCTestCase {
    private let sha = String(repeating: "ab", count: 32)

    func testFetchesOnceThenOpensFromThisDevice() async throws {
        let folder = try TemporaryFolder()
        let cache = try AttachmentCache(location: folder.location("attachments"))
        let host = AttachmentHost(["screen shot.png": Data("picture".utf8)])
        let picture = AttachmentRecord(name: "screen shot.png", mime: "image/png", size: 7, sha256: sha)
        let url = try await cache.file(for: picture, chatID: "ses_1", messageID: "m1", fetcher: host)
        XCTAssertEqual(url.lastPathComponent, "screen shot.png", "The file keeps its name for Quick Look and Share")
        XCTAssertEqual(try Data(contentsOf: url), Data("picture".utf8))
        XCTAssertEqual(host.requests.count, 1)
        XCTAssertEqual(host.requests.first?.sha256, sha)
        XCTAssertEqual(host.requests.first?.messageID, "m1")

        // Again: from this device, even offline.
        let again = try await cache.file(for: picture, chatID: "ses_1", messageID: "m1", fetcher: nil)
        XCTAssertEqual(again, url)
        XCTAssertEqual(host.requests.count, 1)

        // Not saved, and no host to ask.
        do {
            _ = try await cache.file(for: AttachmentRecord(name: "other.txt", mime: "text/plain"), chatID: "ses_1", messageID: "m1", fetcher: nil)
            XCTFail("an unsaved file offline must throw")
        } catch let error as AttachmentCacheError {
            XCTAssertEqual(error, .notSaved)
        }
        // The host kept only the name.
        do {
            _ = try await cache.file(for: AttachmentRecord(name: "gone.pdf", mime: "application/pdf"), chatID: "ses_1", messageID: "m1", fetcher: host)
            XCTFail("a name-only file must throw")
        } catch let error as AttachmentCacheError {
            XCTAssertEqual(error, .notArchived)
        }

        // A relaunch finds the saved file; deleting the chat drops it.
        let reopened = try AttachmentCache(location: folder.location("attachments"))
        let used = await reopened.usedBytes
        XCTAssertEqual(used, 7)
        let saved = await reopened.contains(picture, chatID: "ses_1", messageID: "m1")
        XCTAssertTrue(saved)
        let offline = try await reopened.file(for: picture, chatID: "ses_1", messageID: "m1", fetcher: nil)
        XCTAssertEqual(offline, url)
        await reopened.remove(chatID: "ses_2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Another chat's delete keeps it")
        await reopened.remove(chatID: "ses_1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let afterDelete = await reopened.usedBytes
        XCTAssertEqual(afterDelete, 0)
    }

    func testTwoOpensAtOnceAskTheHostOnce() async throws {
        let folder = try TemporaryFolder()
        let cache = try AttachmentCache(location: folder.location("attachments"))
        let host = AttachmentHost(["notes.txt": Data("notes".utf8)], delay: .milliseconds(50))
        let notes = AttachmentRecord(name: "notes.txt", mime: "text/plain")
        async let first = cache.file(for: notes, chatID: "ses_1", messageID: "m1", fetcher: host)
        async let second = cache.file(for: notes, chatID: "ses_1", messageID: "m1", fetcher: host)
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, b)
        XCTAssertEqual(host.requests.count, 1)
        // The same name in another message is another file.
        _ = try await cache.file(for: notes, chatID: "ses_1", messageID: "m2", fetcher: host)
        XCTAssertEqual(host.requests.count, 2)
    }

    func testLeastRecentlyUsedFilesLeaveFirst() async throws {
        let folder = try TemporaryFolder()
        let clock = StepClock()
        let cache = try AttachmentCache(location: folder.location("attachments"), capacity: 10, now: { clock.now() })
        let host = AttachmentHost(["a.txt": Data("aaaa".utf8), "b.txt": Data("bbbb".utf8), "c.txt": Data("cccc".utf8)])
        func open(_ name: String) async throws -> URL {
            clock.step()
            return try await cache.file(for: AttachmentRecord(name: name, mime: "text/plain"), chatID: "ses_1", messageID: "m1", fetcher: host)
        }
        let a = try await open("a.txt")
        let b = try await open("b.txt")
        _ = try await open("a.txt")
        let c = try await open("c.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path), "Used more recently than b")
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.path))
        let used = await cache.usedBytes
        XCTAssertEqual(used, 8)
        XCTAssertEqual(host.requests.map(\.name), ["a.txt", "b.txt", "c.txt"])
    }

    func testFileNamesStayInTheirFolder() {
        XCTAssertEqual(AttachmentCache.fileName("report.pdf"), "report.pdf")
        XCTAssertEqual(AttachmentCache.fileName("../../etc/passwd"), "-..-etc-passwd")
        XCTAssertEqual(AttachmentCache.fileName(".hidden"), "hidden")
        XCTAssertEqual(AttachmentCache.fileName("a:b\nc\\d.txt"), "a-b-c-d.txt")
        XCTAssertEqual(AttachmentCache.fileName(" "), "Attachment")
        let long = AttachmentCache.fileName(String(repeating: "x", count: 200) + ".pdf")
        XCTAssertEqual(long.count, 120)
        XCTAssertTrue(long.hasSuffix(".pdf"))
    }
}

@MainActor
final class ArchivedAttachmentTests: XCTestCase {
    private let sha = String(repeating: "cd", count: 32)

    private func capabilities(blobs: Bool) -> CapabilitiesResponse {
        CapabilitiesResponse(interactions: true, terminal: true,
                             archive: ArchiveCapabilities(features: ["sync", "search"] + (blobs ? ["blobs"] : [])))
    }

    /// A chat whose message has a kept file, a file kept by name only (a size
    /// without a SHA-256) and one from a copy made before sizes were synced.
    private func store() async throws -> ArchiveStore {
        let store = try ArchiveStore.inMemory()
        let parts = [
            ConversationPart(id: "f1", kind: .attachment, ord: 0, attachment: AttachmentRecord(name: "shot.png", mime: "image/png", size: 7, sha256: sha)),
            ConversationPart(id: "f2", kind: .attachment, ord: 1, attachment: AttachmentRecord(name: "name only.pdf", mime: "application/pdf", size: 900)),
            ConversationPart(id: "f3", kind: .attachment, ord: 2, attachment: AttachmentRecord(name: "old.txt", mime: "text/plain"))
        ]
        try await store.apply(Fixture.page([Fixture.chat("ses_1"), Fixture.message("u1", chat: "ses_1", ord: 1, text: "see attached", extraParts: parts)],
                                           cursor: "e1.2"))
        return store
    }

    func testAttachmentsOpenFromTheHostWhenItListsBlobs() async throws {
        let store = try await store()
        let folder = try TemporaryFolder()
        let cache = try AttachmentCache(location: folder.location("attachments"))
        let host = ArchiveHost { request in
            guard request.url?.path == "/v1/archive/blob" else { return (404, #"{"error":{"code":"not_found","message":"no"}}"#) }
            return (200, "picture")
        }
        let environment = ArchiveEnvironment(client: host.client, capabilities: capabilities(blobs: true), reachable: true, hostName: "Studio Mac")
        let model = ArchivedChatModel(chatID: "ses_1", store: store, environment: environment, attachments: cache)
        await model.load()
        let attachments = try XCTUnwrap(model.messages.first?.message.parts.compactMap(\.attachment))
        XCTAssertEqual(attachments.map { model.canOpen($0) }, [true, false, true], "A size without a SHA-256 means the Mac kept the name only")

        await model.open(attachments[0], messageID: "u1")
        let opened = try XCTUnwrap(model.openedAttachment)
        XCTAssertEqual(try Data(contentsOf: opened), Data("picture".utf8))
        XCTAssertNil(model.attachmentNotice)
        XCTAssertNil(model.openingAttachment)
        let sent = try XCTUnwrap(host.requests(to: "/v1/archive/blob").first)
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: sent.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query, ["chatId": "ses_1", "messageId": "u1", "name": "shot.png", "sha256": sha])

        // Opening it again reads this device's copy.
        model.openedAttachment = nil
        await model.open(attachments[0], messageID: "u1")
        XCTAssertNotNil(model.openedAttachment)
        XCTAssertEqual(host.requests(to: "/v1/archive/blob").count, 1)

        // A name-only file is not offered; nothing is asked for it.
        await model.open(attachments[1], messageID: "u1")
        XCTAssertEqual(host.requests(to: "/v1/archive/blob").count, 1)

        // Without a cache the app shows names only.
        let namesOnly = ArchivedChatModel(chatID: "ses_1", store: store, environment: environment)
        XCTAssertFalse(namesOnly.canOpen(attachments[0]))
    }

    func testAttachmentsExplainWhyTheyDidNotOpen() async throws {
        let store = try await store()
        let folder = try TemporaryFolder()
        let cache = try AttachmentCache(location: folder.location("attachments"))
        let host = ArchiveHost { _ in (404, #"{"error":{"code":"attachment_not_archived","message":"This attachment's bytes were not archived"}}"#) }
        let old = AttachmentRecord(name: "old.txt", mime: "text/plain")

        // A host that does not list blobs is never asked.
        let older = ArchivedChatModel(chatID: "ses_1", store: store,
                                      environment: ArchiveEnvironment(client: host.client, capabilities: capabilities(blobs: false), reachable: true, hostName: "Studio Mac"),
                                      attachments: cache)
        await older.open(old, messageID: "u1")
        XCTAssertNil(older.openedAttachment)
        XCTAssertEqual(older.attachmentNotice, "Studio Mac can’t send files from the archive. Update AgentLand on your Mac to open them.")
        XCTAssertTrue(host.requests(to: "/v1/archive/blob").isEmpty)

        // Offline, and not saved on this device.
        let offline = ArchivedChatModel(chatID: "ses_1", store: store,
                                        environment: ArchiveEnvironment(client: host.client, capabilities: capabilities(blobs: true), reachable: false, hostName: "Studio Mac"),
                                        attachments: cache)
        await offline.open(old, messageID: "u1")
        XCTAssertEqual(offline.attachmentNotice, "“old.txt” didn’t open. This file isn’t saved on this device. Connect to your Mac to open it.")

        // The host kept the name only.
        let online = ArchivedChatModel(chatID: "ses_1", store: store,
                                       environment: ArchiveEnvironment(client: host.client, capabilities: capabilities(blobs: true), reachable: true, hostName: "Studio Mac"),
                                       attachments: cache)
        await online.open(old, messageID: "u1")
        XCTAssertEqual(online.attachmentNotice, "“old.txt” didn’t open. Your Mac kept only this file’s name, not its contents.")
        online.dismissAttachmentNotice()
        XCTAssertNil(online.attachmentNotice)
    }
}
