import SwiftUI

/// Text roles, each a Dynamic Type text style, so text follows the reader's size up to the largest
/// accessibility sizes. No role has a fixed point size.
public enum AgentLandTypeRole: String, CaseIterable, Sendable {
    /// Running text: messages, replies, row titles.
    case body
    /// Body text that needs weight: a row's primary label, a notice title.
    case bodyEmphasized
    /// Supporting text next to body text (subheadline).
    case secondary
    /// Metadata: times, sizes, counts (footnote).
    case metadata
    /// Smaller metadata (caption).
    case caption
    /// The smallest metadata, used sparingly (caption2).
    case caption2
    /// Code, commands, paths and terminal-like output (subheadline, monospaced).
    case code
    /// Code in dense places such as tool output (footnote, monospaced).
    case codeSmall
    /// Screen and sheet headings (title2).
    case heading1
    /// Section headings (title3).
    case heading2
    /// Group and card headings (headline).
    case heading3
    /// The quip under the title (callout, italic).
    case quip

    public var textStyle: Font.TextStyle {
        switch self {
        case .body, .bodyEmphasized: .body
        case .secondary, .code: .subheadline
        case .metadata, .codeSmall: .footnote
        case .caption: .caption
        case .caption2: .caption2
        case .heading1: .title2
        case .heading2: .title3
        case .heading3: .headline
        case .quip: .callout
        }
    }

    /// Nil keeps the text style's own weight.
    public var weight: Font.Weight? {
        self == .bodyEmphasized ? .semibold : nil
    }

    public var design: Font.Design? {
        switch self {
        case .code, .codeSmall: .monospaced
        default: nil
        }
    }

    public var isItalic: Bool { self == .quip }

    public var font: Font {
        let font = Font.system(textStyle, design: design, weight: weight)
        return isItalic ? font.italic() : font
    }
}

public extension View {
    /// Sets the font of an AgentLand text role.
    func agentLandFont(_ role: AgentLandTypeRole) -> some View {
        font(role.font)
    }
}
