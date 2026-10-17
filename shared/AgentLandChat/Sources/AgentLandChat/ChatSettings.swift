import Foundation
import SwiftUI

/// The chat's own settings, saved on this device as user defaults (iPhone and iPad Settings → Chat). Each default
/// keeps the chat as it was before the setting existed, so the Mac, which offers none of them, is unchanged.
public enum ChatSettings {
    /// Reasoning, tool calls and tool groups show open in every reply; each can still be closed.
    public static let expandDetailsKey = "agentland.chat.expandDetails"
    public static let expandDetailsDefault = false
    /// One light haptic when a message is sent (iPhone; docs/CHAT-UX-SPEC.md §2.3).
    public static let sendHapticKey = "agentland.chat.sendHaptic"
    public static let sendHapticDefault = true
    /// A long paste into the composer becomes a text file attachment (`ChatLongPaste`).
    public static let longPasteAsFileKey = "agentland.chat.longPasteAsFile"
    public static let longPasteAsFileDefault = false
}

/// Long pastes as attachments (docs/CHAT-UX-SPEC.md §5.3, off by default): a paste longer than a long message is
/// attached as a text file instead of going into the message. The spec's long message is more than 12 lines
/// (§2.1, where such a message collapses); a paste of fewer, longer lines counts from 1,000 characters.
public enum ChatLongPaste {
    public static let lineLimit = 12
    public static let characterLimit = 1_000
    /// The attachment's name.
    public static let fileName = "Pasted text.txt"

    /// Whether `text` is long enough to go as a file.
    public static func isLong(_ text: String) -> Bool {
        text.count >= characterLimit || text.split(separator: "\n", omittingEmptySubsequences: false).count > lineLimit
    }

    /// What one edit of the composer from `old` to `new` inserted in one go (a paste: typing inserts a character at
    /// a time), and the text without it; nil when the edit only removed text.
    public static func insertion(from old: String, to new: String) -> (inserted: String, remainder: String)? {
        let oldCharacters = Array(old), newCharacters = Array(new)
        guard newCharacters.count > oldCharacters.count else { return nil }
        var prefix = 0
        while prefix < oldCharacters.count, oldCharacters[prefix] == newCharacters[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < oldCharacters.count - prefix,
              oldCharacters[oldCharacters.count - 1 - suffix] == newCharacters[newCharacters.count - 1 - suffix] { suffix += 1 }
        let inserted = String(newCharacters[prefix..<(newCharacters.count - suffix)])
        // What the edit replaced (a paste over a selection) goes, as it would have.
        let remainder = String(newCharacters[..<prefix]) + String(newCharacters[(newCharacters.count - suffix)...])
        return (inserted, remainder)
    }
}

/// Whether reasoning and tool activity start open in this chat (`ChatSettings.expandDetailsKey`); the screen
/// reads the setting once and its rows read it here.
struct ChatExpandsDetailsKey: EnvironmentKey {
    static let defaultValue = ChatSettings.expandDetailsDefault
}

extension EnvironmentValues {
    var chatExpandsDetails: Bool {
        get { self[ChatExpandsDetailsKey.self] }
        set { self[ChatExpandsDetailsKey.self] = newValue }
    }
}
