import CoreTransferable
import Foundation
import UniformTypeIdentifiers
import AgentLandChat
import AgentLandCore

/// One chat as a file for the share sheet: Markdown or JSON from the host's
/// `/v1/archive/export`. When the host cannot be reached, the file is made from
/// this device's copy instead (Markdown as Copy Chat writes it, JSON with every
/// message, rewound ones marked).
public struct ArchiveChatExport: Transferable, Sendable {
    public let chat: ArchivedChat
    public let format: ArchiveExportFormat
    private let client: APIClient?
    private let store: ArchiveStore
    private let workspace: String?

    public init(chat: ArchivedChat, format: ArchiveExportFormat, client: APIClient?, store: ArchiveStore, workspace: String? = nil) {
        self.chat = chat
        self.format = format
        self.client = client
        self.store = store
        self.workspace = workspace
    }

    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .agentLandMarkdown) { export in
            SentTransferredFile(try await export.writeFile())
        }
        .exportingCondition { $0.format == .markdown }
        FileRepresentation(exportedContentType: .json) { export in
            SentTransferredFile(try await export.writeFile())
        }
        .exportingCondition { $0.format == .json }
    }

    /// Letters, digits, `-` and `_` from the title, and the format's extension.
    public var fileName: String {
        var name = ""
        var dash = false
        for character in chat.displayTitle {
            if character.isLetter || character.isNumber || character == "_" {
                name.append(character)
                dash = false
            } else if !dash, !name.isEmpty {
                name.append("-")
                dash = true
            }
            if name.count >= 60 { break }
        }
        while name.hasSuffix("-") { name.removeLast() }
        return (name.isEmpty ? "chat" : name) + (format == .markdown ? ".md" : ".json")
    }

    /// The file's bytes: the host's export, or this device's copy.
    public func data() async throws -> Data {
        if let client {
            do {
                return try await client.archiveExport(chatID: chat.id, format: format)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Offline or refused: the copy on this device still exports.
            }
        }
        return try await localData()
    }

    func localData() async throws -> Data {
        let messages = try await store.allMessages(chatID: chat.id, includeHidden: format == .json)
        switch format {
        case .markdown:
            return Data(ChatExport.markdown(title: chat.displayTitle, provider: chat.agent, model: chat.model, workspace: workspace,
                                            messages: messages.map(\.message)).utf8)
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(LocalExport(chat: chat, messages: messages))
        }
    }

    private func writeFile() async throws -> URL {
        let data = try await data()
        let folder = FileManager.default.temporaryDirectory.appending(path: "AgentLandExport-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: fileName, directoryHint: .notDirectory)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// The JSON written from this device's copy.
    private struct LocalExport: Encodable {
        let chat: ArchiveChatRecord
        let messages: [Message]

        init(chat: ArchivedChat, messages: [ArchivedMessage]) {
            self.chat = ArchiveChatRecord(id: chat.id, projectID: chat.projectID, provider: chat.provider, title: chat.title, model: chat.model,
                                          mode: chat.mode, effort: chat.effort, parentID: chat.parentID, relation: chat.relation,
                                          createdAt: ArchiveTime.text(ArchiveTime.milliseconds(chat.createdAt)),
                                          updatedAt: ArchiveTime.text(ArchiveTime.milliseconds(chat.updatedAt)))
            self.messages = messages.map { Message(message: $0.message, hidden: $0.hidden) }
        }

        struct Message: Encodable {
            let message: ConversationMessage
            let hidden: Bool
            func encode(to encoder: Encoder) throws {
                try message.encode(to: encoder)
                var container = encoder.container(keyedBy: Keys.self)
                if hidden { try container.encode(true, forKey: .hidden) }
            }
            enum Keys: String, CodingKey { case hidden }
        }
    }
}

extension UTType {
    /// Markdown (`net.daringfireball.markdown`), or plain text where the system does not know it.
    static let agentLandMarkdown = UTType("net.daringfireball.markdown") ?? .plainText
}
