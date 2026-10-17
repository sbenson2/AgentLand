import AgentLandCore

/// A copy of chats kept on this device (the device archive). A chat reads it
/// once, before its first network load, so it opens at once and can be read
/// offline; the host's own snapshot replaces it as soon as it arrives.
public protocol ChatTranscriptCache: Sendable {
    /// The newest messages of the chat as this device last saved them, or nil
    /// when it has none. Called off the main actor.
    func cachedTranscript(projectID: String, sessionID: String) async -> ChatSnapshot?
}
