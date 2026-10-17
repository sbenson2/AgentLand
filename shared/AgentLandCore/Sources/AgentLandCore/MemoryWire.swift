import Foundation

// The owner's memory (docs/HOST-API.md "Plain chats", "Memory"): short plain-text facts the model keeps about the
// owner across plain chats, which the host sends to the model on every plain-chat turn while memory is on. Hosts
// serve the routes when `capabilities.plainChats` lists `memory`. Nothing here retries: a change whose answer was
// lost is reported as not confirmed, and the caller reads the list again.
//
// The apps keep only what a "Memory updated" card's Undo and Check need (`deleteMemory(id:)`, `memory()`), in
// OpenCode's plain chats (`--opencode-chat`). Settings' Memory pages and their edits and switch went with Chat's move
// to Claude Code and Codex in the workspace (owner, 2026-10-12: memory "dont need"); the host's routes and its
// memory file stay as they are.

/// One entry of the owner's memory (`GET /v1/memory`): a fact the model keeps about the owner across plain chats.
public struct MemoryEntry: Decodable, Hashable, Identifiable, Sendable {
    /// The longest ID the host sends, in bytes.
    public static let maximumIDBytes = PlainChatText.maximumMemoryIDBytes

    /// Opaque; `PATCH` and `DELETE` name the entry by it.
    public let id: String
    /// One line of plain text, as the host keeps it (cleaned again here, at most 2,000 characters).
    public let text: String
    public let createdAt: Date?
    /// `createdAt` until the entry is edited.
    public let updatedAt: Date?

    public init(id: String, text: String, createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id; self.text = text; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey { case id, text, createdAt, updatedAt }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        guard PlainChatText.isMemoryID(id) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Not a memory ID")
        }
        self.id = id
        text = PlainChatText.memoryText(try container.decode(String.self, forKey: .text))
        // Times this version cannot read count as unknown; they never cost the entry.
        createdAt = (try? container.decodeIfPresent(String.self, forKey: .createdAt)).flatMap { $0 }.flatMap(ChatTime.date)
        updatedAt = (try? container.decodeIfPresent(String.self, forKey: .updatedAt)).flatMap { $0 }.flatMap(ChatTime.date)
    }
}

/// The memory's limits (`limits` of `GET /v1/memory`).
public struct MemoryLimits: Decodable, Hashable, Sendable {
    /// The contract's limits: 50 entries, and 2,000 characters of text over all of them.
    public static let contract = MemoryLimits(maxEntries: 50, maxTotalChars: PlainChatText.maximumMemoryCharacters)

    public let maxEntries: Int
    /// Characters (Unicode scalar values) of text over all entries.
    public let maxTotalChars: Int

    public init(maxEntries: Int, maxTotalChars: Int) { self.maxEntries = maxEntries; self.maxTotalChars = maxTotalChars }

    enum CodingKeys: String, CodingKey { case maxEntries, maxTotalChars }
    /// A limit this version cannot read, or one that is not positive, is the contract's.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func limit(_ key: CodingKeys, _ fallback: Int) -> Int {
            (try? container.decodeIfPresent(Int.self, forKey: key)).flatMap { $0 }.flatMap { $0 > 0 ? $0 : nil } ?? fallback
        }
        maxEntries = limit(.maxEntries, Self.contract.maxEntries)
        maxTotalChars = limit(.maxTotalChars, Self.contract.maxTotalChars)
    }
}

/// `GET /v1/memory`: whether memory is on, its entries oldest first, and its limits.
public struct MemoryList: Decodable, Hashable, Sendable {
    /// At most this many entries are kept (the host keeps 50).
    public static let maximumEntries = 256

    /// While on, the host sends every entry to the model on every plain-chat turn and takes new saves.
    public let enabled: Bool
    public let entries: [MemoryEntry]
    public let limits: MemoryLimits

    public init(enabled: Bool, entries: [MemoryEntry] = [], limits: MemoryLimits = .contract) {
        self.enabled = enabled; self.entries = entries; self.limits = limits
    }

    enum CodingKeys: String, CodingKey { case enabled, entries, limits }
    /// `enabled` and the `entries` list are required: without them the answer is one this version cannot read.
    /// Entries it cannot read, and a later entry of an ID already listed, are left out; missing limits are the
    /// contract's.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        var list = try container.nestedUnkeyedContainer(forKey: .entries)
        var entries: [MemoryEntry] = []
        while !list.isAtEnd && entries.count < Self.maximumEntries {
            if let entry = try? list.decode(MemoryEntry.self) {
                if !entries.contains(where: { $0.id == entry.id }) { entries.append(entry) }
            } else if (try? list.decode(Discarded.self)) == nil {
                break
            }
        }
        self.entries = entries
        limits = (try? container.decodeIfPresent(MemoryLimits.self, forKey: .limits)).flatMap { $0 } ?? .contract
    }
}

/// Why the host refused a memory change, by the code and status the contract gives it.
public enum MemoryRefusal: String, Sendable, CaseIterable {
    /// 404: no entry has that ID (removed meanwhile, or never there). For Undo, the entry is gone already.
    case notFound = "not_found"
    /// 400: the edit would take the entries' text past `maxTotalChars`.
    case overLimit = "memory_limit"
    /// 503: the host has no memory store.
    case unavailable = "memory_unavailable"

    /// The status the host answers this refusal with.
    public var status: Int {
        switch self {
        case .notFound: 404
        case .overLimit: 400
        case .unavailable: 503
        }
    }

    /// A known code with its own status; another status is not this refusal.
    init?(code: String, status: Int) {
        guard let refusal = MemoryRefusal(rawValue: code), refusal.status == status else { return nil }
        self = refusal
    }
}

/// How a memory change ended.
public enum MemoryChangeOutcome: Equatable, Sendable {
    /// `DELETE`: the entry is gone.
    case removed
    /// The host refused, with its words; nothing changed.
    case refused(MemoryRefusal, message: String)
    /// Another refusal that changed nothing (`invalid_request`, `storage_error`), or the request provably never
    /// reached the host.
    case failed(ClientError)
    /// The connection ended before an answer, or the answer was unreadable: the change may have been made. The
    /// caller reads the list again rather than sending it again.
    case uncertain
}

/// Error codes of the memory routes beyond the named refusals.
public enum MemoryErrorCode {
    /// 500: the host could not save the change; nothing changed.
    public static let storage = "storage_error"
}

extension APIClient {
    /// `GET /v1/memory`: whether memory is on, its entries oldest first, and its limits. Call it only when
    /// `capabilities.plainChats` lists `memory`. A host without a memory store answers 503 `memory_unavailable`.
    public func memory() async throws -> MemoryList { try await get("/v1/memory") }

    /// `DELETE /v1/memory?id=`: removes entry `id`, as Undo does after a memory save. `.refused(.notFound, …)`
    /// means it is gone already.
    public func deleteMemory(id: String) async -> MemoryChangeOutcome {
        guard PlainChatText.isMemoryID(id) else { return .failed(.invalidResponse) }
        return await memoryChange(method: "DELETE", path: "/v1/memory", query: [URLQueryItem(name: "id", value: id)]) {
            (answer: RemovedAnswer) in answer.removed ? .removed : nil
        }
    }

    /// Sends one memory change. `done` reads the host's answer; nil (or an answer this version cannot read) leaves
    /// the outcome unknown.
    private func memoryChange<Answer: Decodable>(method: String, path: String, query: [URLQueryItem] = [],
                                                 done: (Answer) -> MemoryChangeOutcome?) async -> MemoryChangeOutcome {
        let request: URLRequest
        do { request = try makeRequest(path: path, method: method, query: query) } catch { return .failed(.invalidResponse) }
        do {
            let (data, response) = try await transport.execute(request)
            try validateWithRefusal(response, data: data, expected: 200)
            // 200 means the host made the change; an answer this version cannot read leaves what it keeps unknown.
            guard let answer = try? ProtocolDecoder.decode(Answer.self, from: data), let outcome = done(answer) else { return .uncertain }
            return outcome
        } catch let refusal as HostRefusal {
            if let reason = MemoryRefusal(code: refusal.error.code, status: refusal.status) {
                return .refused(reason, message: refusal.error.message)
            }
            // A server error may have made the change; a refusal it named did not, and neither did `storage_error`
            // (the host could not save the change, so nothing changed).
            let definite = refusal.status < 500 || refusal.error.code == MemoryErrorCode.storage
            guard definite, case let .failed(error) = mutationOutcome(for: refusal.clientError) else { return .uncertain }
            return .failed(error)
        } catch let error as ClientError {
            if case let .failed(error) = mutationOutcome(for: error) { return .failed(error) }
            return .uncertain
        } catch is CancellationError {
            return .uncertain
        } catch {
            return ClientError.isUndelivered(error) ? .failed(.unreachable) : .uncertain
        }
    }

    private struct RemovedAnswer: Decodable { let removed: Bool }
}
