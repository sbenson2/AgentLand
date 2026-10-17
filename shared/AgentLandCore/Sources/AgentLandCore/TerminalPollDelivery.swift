import Foundation

/// Keeps a response from an earlier tab, host, or reload generation from
/// mutating the current terminal after an asynchronous request completes.
@MainActor public enum TerminalPollDelivery {
    public static func fetch<Value>(
        isCurrent: @escaping @MainActor () -> Bool,
        operation: () async throws -> Value
    ) async -> Result<Value, Error>? {
        guard !Task.isCancelled, isCurrent() else { return nil }
        do {
            let value = try await operation()
            guard !Task.isCancelled, isCurrent() else { return nil }
            return .success(value)
        } catch {
            guard !Task.isCancelled, isCurrent() else { return nil }
            return .failure(error)
        }
    }
}

/// What the renderer may send while a touch drag is under way: parser replies, and the wheel reports a
/// drag sends to a program that turned on mouse reporting. Anything else a drag would produce (keys,
/// pasteboard reads, shell input) is dropped.
public enum TerminalTouchInputPolicy {
    public static func shouldForward(isTouchPan: Bool, isProtocolReply: Bool, isWheelReport: Bool = false) -> Bool {
        !isTouchPan || isProtocolReply || isWheelReport
    }
}
