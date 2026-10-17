import Foundation

/// The titles devices send when they make a chat or a terminal (`POST /v1/sessions`, `/v1/terminals`,
/// `/v1/chat/fork`, `/v1/chat/continue`). The host refuses a title longer than 200 bytes
/// of UTF-8 (desktop/host.go, terminal.go, chat_fork.go, archive_continue.go), and an agent's
/// name of 100 characters is up to 400 bytes outside Latin scripts, so every title is cut to fit, never in
/// the middle of a character. A device's name for a chat (`POST /v1/chat/title`) has its own limit, below.
public enum HostTitle {
    /// The longest title the host takes, in bytes of UTF-8.
    public static let maximumBytes = 200

    /// The host takes `title` as it is.
    public static func fits(_ title: String) -> Bool { title.utf8.count <= maximumBytes }

    /// `title` whole when it fits; otherwise its longest start that fits and ends at a character (grapheme
    /// cluster) boundary, so no letter, accent or emoji is split.
    public static func clipped(_ title: String) -> String {
        guard !fits(title) else { return title }
        var bytes = 0
        var end = title.startIndex
        for index in title.indices {
            bytes += title[index].utf8.count
            guard bytes <= maximumBytes else { break }
            end = title.index(after: index)
        }
        return String(title[..<end])
    }
}

// A device names a chat: `POST /v1/chat/title` (docs/HOST-API.md, chat titles), offered by hosts that
// list `title` in `chatFeatures`. Callers send it only to those hosts. Nothing here retries.

/// The chat's title as the host holds it after a naming: who named it and the newest message it describes.
public struct ChatTitleAnswer: Decodable, Hashable, Sendable {
    public var title: String
    public var titleSource: ChatTitleSource?
    public var titleBasis: String?

    public init(title: String, titleSource: ChatTitleSource? = nil, titleBasis: String? = nil) {
        self.title = title; self.titleSource = titleSource; self.titleBasis = titleBasis
    }

    enum CodingKeys: String, CodingKey { case title, titleSource, titleBasis }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        (titleSource, titleBasis) = ChatTitleSource.decodeNaming(from: container, source: .titleSource, basis: .titleBasis)
    }
}

/// How a naming ended.
public enum ChatTitleOutcome: Equatable, Sendable {
    /// The host took the name (cleaned) and told every stream.
    case named(ChatTitleAnswer)
    /// The chat already has a title for a newer message than `basedOn` (409 `title_stale`): the host's
    /// current title, source and basis, when its answer carries them.
    case stale(ChatTitleAnswer?)
    /// Refused (400 `invalid_request`, 404 for an unknown chat, 502 `provider_unavailable`), or provably
    /// never sent.
    case failed(ClientError)
    /// The connection ended before an answer, or the answer was unreadable.
    case uncertain
}

extension APIClient {
    /// `POST /v1/chat/title`: names chat `sessionID` of `projectID` with `title`, which describes the chat
    /// up to message `basedOn`. The host cleans the title (1–60 characters after that).
    public func nameChat(projectID: String, sessionID: String, title: String, basedOn: String) async -> ChatTitleOutcome {
        do {
            var request = try makeRequest(path: "/v1/chat/title", method: "POST")
            request.httpBody = try JSONEncoder().encode(TitleBody(projectID: projectID, sessionID: sessionID, title: title, basedOn: basedOn))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await transport.execute(request)
            if response.statusCode == 409, let stale = try? ProtocolDecoder.decode(StaleRefusal.self, from: data), stale.error.code == "title_stale" {
                return .stale(stale.answer)
            }
            try validate(response, data: data, expected: 200)
            do { return .named(try ProtocolDecoder.decode(ChatTitleAnswer.self, from: data)) } catch { return .uncertain }
        } catch let error as ClientError {
            switch mutationOutcome(for: error) {
            case .uncertain, .accepted: return .uncertain
            case let .failed(error): return .failed(error)
            }
        } catch is CancellationError {
            return .uncertain
        } catch {
            return ClientError.isUndelivered(error) ? .failed(.unreachable) : .uncertain
        }
    }

    private struct TitleBody: Encodable {
        let projectID: String; let sessionID: String; let title: String; let basedOn: String
        enum CodingKeys: String, CodingKey { case projectID = "projectId", sessionID = "sessionId", title, basedOn }
    }

    /// A `title_stale` refusal. Its current title, source and basis sit inside `error`, like other
    /// refusals' extra members; a host that puts them beside `error` is read too.
    private struct StaleRefusal: Decodable {
        struct Detail: Decodable {
            let code: String
            let title: String?
            let titleSource: String?
            let titleBasis: String?
        }
        let error: Detail
        let title: String?
        let titleSource: String?
        let titleBasis: String?

        var answer: ChatTitleAnswer? {
            if let title = error.title { return Self.answer(title, error.titleSource, error.titleBasis) }
            if let title { return Self.answer(title, titleSource, titleBasis) }
            return nil
        }

        private static func answer(_ title: String, _ source: String?, _ basis: String?) -> ChatTitleAnswer {
            ChatTitleAnswer(title: title, titleSource: source.flatMap { $0.isEmpty ? nil : ChatTitleSource(rawValue: $0) },
                            titleBasis: basis.flatMap { $0.isEmpty ? nil : $0 })
        }
    }
}
