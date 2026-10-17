import Foundation

// The vault (docs/HOST-API.md "Vault"): a folder of Markdown notes, Obsidian-style, that the host keeps in step with
// the archive. In phase 1 only this Mac's own session reads and changes it, and the host lists `capabilities.vault`
// for that session alone; nothing is asked of a host that does not list it. Nothing here retries: a change whose
// answer was lost is reported as not confirmed, and the caller reads the status again.

/// `capabilities.vault`: the host keeps a vault this session may read and change.
public struct VaultCapabilities: Codable, Hashable, Sendable {
    /// The only version this client reads; an entry of another version counts as absent.
    public static let supportedVersion = 1

    public let version: Int

    public init(version: Int = supportedVersion) { self.version = version }

    /// Reads the entry when it is of the supported version; nil when absent, of another version or unreadable.
    static func decodeSupported<Key: CodingKey>(from container: KeyedDecodingContainer<Key>, forKey key: Key) -> VaultCapabilities? {
        guard let entry = (try? container.decodeIfPresent(VaultCapabilities.self, forKey: key)) ?? nil,
              entry.version == supportedVersion else { return nil }
        return entry
    }
}

/// What the vault's writer does now (`state`).
public enum VaultState: String, Hashable, Sendable, CaseIterable {
    /// The vault is off: nothing is written.
    case off
    /// Notes wait to be written (`pending`), the first ones too (`backfill`).
    case writing
    /// Every note is written.
    case current
    /// The writer waits, for the `reason` the status gives, and tries again every 30 s.
    case paused
    /// A state this version does not know.
    case unknown
}

/// Why a paused vault waits (`reason`).
public enum VaultPauseReason: String, Hashable, Sendable, CaseIterable {
    /// The vault's folder is gone (an unplugged disk, a folder moved away); the host does not make it again.
    case folderMissing = "folder_missing"
    /// The system refused access to the folder (on macOS, Privacy & Security).
    case permission
    /// Under 1 GiB free on the folder's disk.
    case lowSpace = "low_space"
    /// The folder's marker names another archive: another Mac writes it. `adopt` takes it over.
    case otherArchive = "other_archive"
    /// Something else went wrong; the status's `message` says what.
    case error
    /// A reason this version does not know.
    case unknown
}

/// The first write's progress, in notes (`backfill`).
public struct VaultBackfill: Hashable, Sendable {
    public let done: Int
    public let total: Int

    public init(done: Int = 0, total: Int = 0) { self.done = done; self.total = total }

    /// The first write still has notes to write.
    public var isRunning: Bool { done < total }
}

/// `GET /v1/vault`, and the answer to every change: the vault's settings and its writer's status.
public struct VaultStatus: Decodable, Hashable, Sendable {
    /// The vault is on (the owner's switch); `state` says what the writer does.
    public let enabled: Bool
    /// Where the vault writes: `defaultFolder` until another is chosen.
    public let folder: String
    /// The folder of a vault turned on without one chosen (`~/AgentLand Vault` under `serve`).
    public let defaultFolder: String
    /// Terminals get notes (true unless the owner turned them off).
    public let terminals: Bool
    public let state: VaultState
    /// Why a paused vault waits; nil otherwise.
    public let reason: VaultPauseReason?
    /// The host's words for the pause; nil when it gave none.
    public let message: String?
    /// The chat and terminal notes written.
    public let notes: Int
    /// The files in the vault's own folders and its README, in bytes (not `Notes/`).
    public let bytes: Int64
    /// The notes waiting to be written.
    public let pending: Int
    /// The notes left alone: edited without their end marker, or another file where they would go.
    public let skipped: Int
    public let backfill: VaultBackfill
    /// The last file written since the host started; nil before.
    public let lastWriteAt: Date?
    /// The Obsidian vault the folder is in (the folder, or the nearest folder above it, holding `.obsidian`).
    public let obsidianVault: String?

    public init(enabled: Bool, folder: String = "", defaultFolder: String = "", terminals: Bool = true, state: VaultState = .unknown,
                reason: VaultPauseReason? = nil, message: String? = nil, notes: Int = 0, bytes: Int64 = 0, pending: Int = 0,
                skipped: Int = 0, backfill: VaultBackfill = VaultBackfill(), lastWriteAt: Date? = nil, obsidianVault: String? = nil) {
        self.enabled = enabled; self.folder = folder; self.defaultFolder = defaultFolder; self.terminals = terminals
        self.state = state; self.reason = reason; self.message = message; self.notes = notes; self.bytes = bytes
        self.pending = pending; self.skipped = skipped; self.backfill = backfill; self.lastWriteAt = lastWriteAt
        self.obsidianVault = obsidianVault
    }

    enum CodingKeys: String, CodingKey {
        case enabled, folder, defaultFolder, terminals, state, reason, message, notes, bytes, pending, skipped, backfill, lastWriteAt
        case obsidianVault
    }

    private enum BackfillKeys: String, CodingKey { case done, total }

    /// `enabled` is required: without it the answer is one this version cannot read. Every other field it cannot read
    /// takes its default (counts 0, terminals on, no folder), a state or reason it does not know is `.unknown`, and
    /// blank words are none.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        // Paths are kept as the host gives them (a folder's name may end in a space); words are trimmed.
        func text(_ key: CodingKeys, trimmed: Bool = false) -> String? {
            guard var value = (try? container.decodeIfPresent(String.self, forKey: key)).flatMap({ $0 }) else { return nil }
            if trimmed { value = value.trimmingCharacters(in: .whitespacesAndNewlines) }
            return value.isEmpty ? nil : value
        }
        func count(_ key: CodingKeys) -> Int { max(0, (try? container.decodeIfPresent(Int.self, forKey: key)).flatMap { $0 } ?? 0) }
        folder = text(.folder) ?? ""
        defaultFolder = text(.defaultFolder) ?? ""
        terminals = (try? container.decodeIfPresent(Bool.self, forKey: .terminals)).flatMap { $0 } ?? true
        state = text(.state).flatMap(VaultState.init(rawValue:)) ?? .unknown
        reason = text(.reason).map { VaultPauseReason(rawValue: $0) ?? .unknown }
        message = text(.message, trimmed: true)
        notes = count(.notes)
        bytes = max(0, (try? container.decodeIfPresent(Int64.self, forKey: .bytes)).flatMap { $0 } ?? 0)
        pending = count(.pending)
        skipped = count(.skipped)
        if let progress = try? container.nestedContainer(keyedBy: BackfillKeys.self, forKey: .backfill) {
            func part(_ key: BackfillKeys) -> Int { max(0, (try? progress.decodeIfPresent(Int.self, forKey: key)).flatMap { $0 } ?? 0) }
            backfill = VaultBackfill(done: part(.done), total: part(.total))
        } else {
            backfill = VaultBackfill()
        }
        lastWriteAt = text(.lastWriteAt).flatMap(ChatTime.date)
        obsidianVault = text(.obsidianVault)
    }
}

/// Why the host refused a vault change, by the code and status the contract gives it. Nothing changed.
public enum VaultRefusal: String, Sendable, CaseIterable {
    /// 400: the folder cannot hold the vault (not absolute, the disk's top folder, the home folder, inside AgentLand's
    /// state folder, a file); the host's words say which.
    case invalidFolder = "invalid_folder"
    /// 409: the host could not make the folder or write a file in it ("AgentLand cannot write in <folder>: <reason>").
    case folderUnwritable = "folder_unwritable"
    /// 409: a rebuild while the vault is off.
    case off = "vault_off"
    /// 503: the host keeps no archive, so it has no vault, or it is stopping.
    case unavailable = "vault_unavailable"
    /// 403: only this Mac's own app changes the vault.
    case localOnly = "local_only"

    /// The status the host answers this refusal with.
    public var status: Int {
        switch self {
        case .invalidFolder: 400
        case .folderUnwritable, .off: 409
        case .unavailable: 503
        case .localOnly: 403
        }
    }

    /// A known code with its own status; another status is not this refusal.
    init?(code: String, status: Int) {
        guard let refusal = VaultRefusal(rawValue: code), refusal.status == status else { return nil }
        self = refusal
    }
}

/// How a vault change ended.
public enum VaultChangeOutcome: Equatable, Sendable {
    /// The host made the change and answered the vault's status since.
    case changed(VaultStatus)
    /// The host refused, with its words; nothing changed.
    case refused(VaultRefusal, message: String)
    /// Another refusal that changed nothing (`invalid_request`), or the request provably never reached the host.
    case failed(ClientError)
    /// The connection ended before an answer, the answer was unreadable, or the host failed after it may have saved
    /// the change (500 `vault_error`): the change may have been made. The caller reads the status again rather than
    /// sending it again.
    case uncertain
}

/// Error codes of the vault routes beyond the named refusals.
public enum VaultErrorCode {
    /// 500: the vault's settings or records could not be read or saved. It may come after the settings were saved
    /// and the writer restarted, so a change it answers is not confirmed either way.
    public static let storage = "vault_error"
}

public extension ClientError {
    /// The host has no vault (503 `vault_unavailable`), as `GET /v1/vault` reports it.
    var isVaultUnavailable: Bool {
        if case let .server(code, _) = self { return code == VaultRefusal.unavailable.rawValue }
        return false
    }
}

extension APIClient {
    /// `GET /v1/vault`: the vault's settings and its writer's status. Call it only when the host lists
    /// `capabilities.vault`. A host without a vault answers 503 (`ClientError.isVaultUnavailable`).
    public func vault() async throws -> VaultStatus { try await get("/v1/vault") }

    /// `POST /v1/vault/settings`: changes what is given and nothing else. `folder` "" is the default folder; `adopt`
    /// (sent only when true, and never kept) lets the vault take over a folder another archive's marker names, once.
    /// Turning the vault on, or moving it while on, makes the folder and checks that the host can write there.
    /// Sending `enabled: true` again tries a paused vault again. Only the writer restarts, never the host.
    public func setVault(enabled: Bool? = nil, folder: String? = nil, terminals: Bool? = nil, adopt: Bool = false) async -> VaultChangeOutcome {
        let body = SettingsBody(enabled: enabled, folder: folder, terminals: terminals, adopt: adopt ? true : nil)
        // The host refuses a change without anything to change; it is never sent.
        guard enabled != nil || folder != nil || terminals != nil || adopt, let data = try? JSONEncoder().encode(body) else {
            return .failed(.invalidResponse)
        }
        return await vaultChange(path: "/v1/vault/settings", body: data)
    }

    /// `POST /v1/vault/rebuild`: the vault, which must be on, reads its change feed again from the start and compares
    /// every note with its file. It deletes nothing.
    public func rebuildVault() async -> VaultChangeOutcome {
        await vaultChange(path: "/v1/vault/rebuild", body: nil)
    }

    /// Sends one vault change; the answer is the status.
    private func vaultChange(path: String, body: Data?) async -> VaultChangeOutcome {
        var request: URLRequest
        do { request = try makeRequest(path: path, method: "POST") } catch { return .failed(.invalidResponse) }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await transport.execute(request)
            try validateWithRefusal(response, data: data, expected: 200)
            // 200 means the host made the change; an answer this version cannot read leaves the status unknown.
            guard let status = try? ProtocolDecoder.decode(VaultStatus.self, from: data) else { return .uncertain }
            return .changed(status)
        } catch let refusal as HostRefusal {
            if let reason = VaultRefusal(code: refusal.error.code, status: refusal.status) {
                return .refused(reason, message: refusal.error.message)
            }
            // A server error, `vault_error` included, may have made the change; a refusal it named did not.
            guard refusal.status < 500, case let .failed(error) = mutationOutcome(for: refusal.clientError) else { return .uncertain }
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

    private struct SettingsBody: Encodable {
        let enabled: Bool?
        let folder: String?
        let terminals: Bool?
        let adopt: Bool?
    }
}
