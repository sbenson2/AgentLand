import SwiftUI
import AgentLandBranding
import AgentLandDesign

enum ChatInline {
    /// Inline Markdown (emphasis, code spans, links, strikethrough) for one block of text.
    static func attributed(_ text: String, role: ChatTextRole) -> AttributedString {
        var value = (try? AttributedString(markdown: text, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        ))) ?? AttributedString(text)
        let runs = value.runs.map { ($0.range, $0.inlinePresentationIntent, $0.link) }
        for (range, intent, link) in runs {
            if intent?.contains(.code) == true {
                value[range].font = role.codeFont
                value[range].backgroundColor = AgentLandColor.surface.color
            }
            if let link {
                if allowsLink(link) {
                    value[range].foregroundColor = AgentLandColor.tint.color
                    value[range].underlineStyle = .single
                } else {
                    value[range].link = nil
                }
            }
        }
        return value
    }

    /// Agent text may contain arbitrary URLs; only web and mail links stay tappable.
    static func allowsLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto"].contains(scheme)
    }

    /// The plain string VoiceOver reads for a block, without Markdown marks.
    static func plain(_ text: String) -> String {
        String(attributed(text, role: .reply).characters)
    }
}
