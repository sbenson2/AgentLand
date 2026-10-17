import SwiftUI
import AgentLandBranding
import AgentLandDesign

/// Renders Markdown: headings, lists, quotes, tables and code blocks with Copy.
public struct ChatMarkdownView: View {
    let source: String
    let role: ChatTextRole

    public init(_ source: String, role: ChatTextRole = .reply) {
        self.source = source
        self.role = role
    }

    public var body: some View {
        ChatMarkdownBlocks(blocks: MarkdownDocument.blocks(from: source), role: role)
    }
}

/// A VoiceOver action attached to a reply's text (Copy, Run Again, …).
struct ChatAccessibilityAction: Identifiable {
    var id: String { name }
    let name: String
    let perform: @MainActor () -> Void
}

private struct ChatAccessibilityActionsKey: EnvironmentKey {
    static let defaultValue: [ChatAccessibilityAction] = []
}

extension EnvironmentValues {
    var chatAccessibilityActions: [ChatAccessibilityAction] {
        get { self[ChatAccessibilityActionsKey.self] }
        set { self[ChatAccessibilityActionsKey.self] = newValue }
    }
}

private struct ChatTextActions: ViewModifier {
    @Environment(\.chatAccessibilityActions) private var actions
    func body(content: Content) -> some View {
        if actions.isEmpty {
            content
        } else {
            content.accessibilityActions {
                ForEach(actions) { action in Button(action.name) { action.perform() } }
            }
        }
    }
}

struct ChatMarkdownBlocks: View {
    let blocks: [MarkdownBlock]
    let role: ChatTextRole
    /// A streaming caret after the last glyph.
    var caret = false
    @ScaledMetric(relativeTo: .body) private var blockSpacing: CGFloat = 12
    @ScaledMetric(relativeTo: .body) private var lineSpacing: CGFloat = 4
    @ScaledMetric(relativeTo: .body) private var listIndent: CGFloat = 18

    var body: some View {
        // Callers choose the width: replies fill the column, user bubbles hug their text.
        VStack(alignment: .leading, spacing: blockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, last: index == blocks.count - 1)
            }
            if caret, blocks.isEmpty || !Self.caretInline(blocks.last) {
                ChatCaret(text: nil, role: role)
            }
        }
    }

    static func caretInline(_ block: MarkdownBlock?) -> Bool {
        switch block {
        case .paragraph, .heading: true
        default: false
        }
    }

    @ViewBuilder private func blockView(_ block: MarkdownBlock, last: Bool) -> some View {
        switch block {
        case let .paragraph(text):
            inline(text, font: role.font, caret: caret && last)
        case let .heading(level, text):
            inline(text, font: headingFont(level), caret: caret && last)
                .padding(.top, level <= 2 ? 4 : 2)
                .accessibilityAddTraits(.isHeader)
        case let .code(language, code, _):
            ChatCodeBlock(language: language, code: code, role: role)
        case let .quote(inner):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1).fill(AgentLandColor.separator.color).frame(width: 2)
                // A quote may contain any block, including another quote.
                AnyView(ChatMarkdownBlocks(blocks: inner, role: .supporting))
            }
            .fixedSize(horizontal: false, vertical: true)
        case let .list(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        marker(item)
                        inline(item.text, font: role.font, caret: false)
                    }
                    .padding(.leading, CGFloat(item.level) * listIndent)
                }
            }
        case let .table(table):
            ChatTableBlock(table: table, role: role)
        case .rule:
            Divider().overlay(AgentLandColor.separator.color).padding(.vertical, 4)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title3.weight(.semibold)
        case 2: .headline
        default: .subheadline.weight(.semibold)
        }
    }

    @ViewBuilder private func inline(_ text: String, font: Font, caret: Bool) -> some View {
        let attributed = ChatInline.attributed(text, role: role)
        Group {
            if caret {
                ChatCaret(text: attributed, role: role)
            } else {
                Text(attributed)
            }
        }
        .font(font)
        .foregroundStyle(role.color)
        .lineSpacing(lineSpacing)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(ChatTextActions())
    }

    @ViewBuilder private func marker(_ item: MarkdownListItem) -> some View {
        switch item.marker {
        case .bullet:
            Text(["•", "◦", "▪"][item.level % 3])
                .font(role.font)
                .foregroundStyle(AgentLandColor.textSecondary.color)
                .accessibilityHidden(true)
        case let .number(value):
            Text("\(value).")
                .font(role.font.monospacedDigit())
                .foregroundStyle(AgentLandColor.textSecondary.color)
        case let .task(done):
            Image(systemName: done ? "checkmark.square" : "square")
                .font(role.font)
                .foregroundStyle(done ? AgentLandColor.success.color : AgentLandColor.textSecondary.color)
                .accessibilityLabel(done ? "Done" : "Not done")
        }
    }
}

/// The streaming caret: a thin accent bar after the last glyph that pulses
/// gently, and stays still under Reduce Motion. VoiceOver never reads it.
struct ChatCaret: View {
    let text: AttributedString?
    let role: ChatTextRole
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let text {
            TimelineView(.periodic(from: .now, by: reduceMotion ? 3600 : 0.55)) { context in
                Text("\(Text(text))\(bar(at: context.date))")
            }
            // VoiceOver and automation read the text alone, never the bar.
            .accessibilityRepresentation { Text(text) }
        } else {
            TimelineView(.periodic(from: .now, by: reduceMotion ? 3600 : 0.55)) { context in
                bar(at: context.date).font(role.font)
            }
            .accessibilityHidden(true)
        }
    }

    private func bar(at date: Date) -> Text {
        let dim = !reduceMotion && Int(date.timeIntervalSinceReferenceDate / 0.55) % 2 == 1
        return Text("\u{258D}").foregroundStyle(AgentLandColor.tint.color.opacity(dim ? 0.3 : 1))
    }
}

struct ChatCodeBlock: View {
    let language: String
    let code: String
    let role: ChatTextRole
    @State private var expanded = false
    @Environment(\.colorSchemeContrast) private var contrast
    private static let collapseAbove = 30
    private static let collapsedLines = 15

    private var lines: [Substring] { code.split(separator: "\n", omittingEmptySubsequences: false) }
    private var collapsible: Bool { lines.count > Self.collapseAbove }
    private var shownCode: String {
        guard collapsible, !expanded else { return code }
        return lines.prefix(Self.collapsedLines).joined(separator: "\n")
    }
    private var languageName: String { language.isEmpty ? "Code" : language }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption.monospaced())
                    .foregroundStyle(AgentLandColor.textSecondary.color)
                    .lineLimit(1)
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
                ChatCopyButton(code, label: "Copy", announcement: "Code copied")
            }
            .padding(.leading, 12)
            .padding(.trailing, 2)
            Divider().overlay(AgentLandColor.separator.color)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(highlighted)
                    .font(role.codeFont)
                    .foregroundStyle(AgentLandColor.text.color)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
            }
            .overlay(alignment: .bottom) {
                if collapsible && !expanded {
                    LinearGradient(colors: [AgentLandColor.surface.color.opacity(0), AgentLandColor.surface.color], startPoint: .top, endPoint: .bottom)
                        .frame(height: 28)
                        .allowsHitTesting(false)
                }
            }
            if collapsible {
                Button {
                    expanded.toggle()
                } label: {
                    Text(expanded ? "Show Fewer Lines" : "Show \(lines.count - Self.collapsedLines) More Lines")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(AgentLandColor.tint.color)
                        .frame(maxWidth: .infinity, minHeight: ChatMetrics.target)
                        .contentShape(Rectangle())
                }
                .chatBorderlessButton()
                .overlay(alignment: .top) { Divider().overlay(AgentLandColor.separator.color) }
            }
        }
        .chatCard(cornerRadius: 12, increasedContrast: contrast == .increased)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Code, \(languageName), \(lines.count) \(lines.count == 1 ? "line" : "lines")")
    }

    /// Diffs keep their + and − marks and add tints; color is never the only cue.
    private var highlighted: AttributedString {
        let isDiff = ["diff", "patch"].contains(language.lowercased())
        guard isDiff else { return AttributedString(shownCode) }
        var result = AttributedString()
        let shown = shownCode.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in shown.enumerated() {
            var part = AttributedString(String(line) + (index < shown.count - 1 ? "\n" : ""))
            if line.hasPrefix("+"), !line.hasPrefix("+++") {
                part.foregroundColor = AgentLandColor.success.color
                part.backgroundColor = AgentLandColor.success.color.opacity(0.12)
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                part.foregroundColor = AgentLandColor.danger.color
                part.backgroundColor = AgentLandColor.danger.color.opacity(0.12)
            } else if line.hasPrefix("@@") {
                part.foregroundColor = AgentLandColor.tint.color
            }
            result += part
        }
        return result
    }
}

struct ChatTableBlock: View {
    let table: MarkdownTable
    let role: ChatTextRole
    @ScaledMetric(relativeTo: .subheadline) private var characterWidth: CGFloat = 8
    @ScaledMetric(relativeTo: .subheadline) private var maximumColumn: CGFloat = 260

    var body: some View {
        let widths = columnWidths
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { column, text in
                        cell(text, column: column, width: widths[column], header: true)
                    }
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, text in
                            cell(text, column: column, width: widths[column], header: false)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AgentLandColor.separator.color, lineWidth: 0.75))
            .padding(1)
        }
        .contextMenu {
            Button("Copy Table", systemImage: "doc.on.doc") { ChatClipboard.copy(markdown) }
        }
    }

    private func cell(_ text: String, column: Int, width: CGFloat, header: Bool) -> some View {
        Text(ChatInline.attributed(text, role: role))
            .font(header ? .subheadline.weight(.semibold) : .subheadline)
            .foregroundStyle(AgentLandColor.text.color)
            .textSelection(.enabled)
            .multilineTextAlignment(textAlignment(column))
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: frameAlignment(column))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(header ? AgentLandColor.surface.color : Color.clear)
            .overlay(alignment: .bottom) { AgentLandColor.separator.color.opacity(0.7).frame(height: 0.5) }
            .accessibilityAddTraits(header ? .isHeader : [])
    }

    /// Column width from the longest cell, bounded so long prose wraps.
    private var columnWidths: [CGFloat] {
        table.header.indices.map { column in
            let longest = ([table.header[column]] + table.rows.map { $0[column] }).map(\.count).max() ?? 0
            return min(max(CGFloat(longest) * characterWidth, 44), maximumColumn)
        }
    }

    private var markdown: String {
        func row(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }
        let separator = "|" + table.alignments.map { alignment -> String in
            switch alignment {
            case .leading: " --- "
            case .center: " :-: "
            case .trailing: " --: "
            }
        }.joined(separator: "|") + "|"
        return ([row(table.header), separator] + table.rows.map(row)).joined(separator: "\n")
    }

    private func frameAlignment(_ column: Int) -> Alignment {
        switch table.alignments[column] {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        switch table.alignments[column] {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
