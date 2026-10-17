import AgentLandChat
import AgentLandCore

/// The device archive as `ChatSessionStore` reads it: a chat's newest visible
/// messages, shown before the host answers and while it is offline.
public struct ArchiveTranscriptCache: ChatTranscriptCache {
    public let store: ArchiveStore
    /// How many of the newest messages a chat opens with.
    public let limit: Int

    public init(store: ArchiveStore, limit: Int = 200) {
        self.store = store
        self.limit = limit
    }

    public func cachedTranscript(projectID: String, sessionID: String) async -> ChatSnapshot? {
        try? await store.transcript(projectID: projectID, chatID: sessionID, limit: limit)
    }
}
