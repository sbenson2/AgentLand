import SwiftUI
import AgentLandCore
import AgentLandDesign
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// One file's diff in a sheet: the staged changes of a staged file, the unstaged changes of a changed
/// one (an untracked file as additions), with Stage or Unstage in its bar.
struct GitDiffSheet: View {
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let session: GitSession
    let request: GitDiffRequest
    @State private var diff: GitDiffDocument?
    @State private var issue: String?

    var body: some View {
        NavigationStack {
            Group {
                if let diff {
                    if diff.lines.isEmpty {
                        ContentUnavailable("No Differences", systemImage: "equal.circle", description: emptyDescription)
                    } else {
                        GitDiffView(document: diff)
                    }
                } else if let issue {
                    ContentUnavailable("Diff Unavailable", systemImage: "exclamationmark.triangle", description: issue,
                                       actionTitle: "Try Again") { Task { await load() } }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #if os(macOS)
            .background(AgentLandColor.canvas)
            #endif
            .navigationTitle(request.row.name)
            .navigationSubtitle(subtitle)
            .workspaceInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { GitDiffCloseButton { dismiss() } }
                ToolbarItem(placement: .primaryAction) { indexButton }
            }
        }
        .task(id: request.id) { await load() }
        .accessibilityIdentifier("gitDiffSheet")
    }

    private var subtitle: String {
        var parts = [request.row.words]
        if let diff, !diff.lines.isEmpty { parts.append("+\(diff.addedCount) −\(diff.removedCount)") }
        return parts.joined(separator: " · ")
    }

    private var emptyDescription: String {
        if request.row.isFolder { return "Stage the folder to see the files in it." }
        return "Git shows no text changes for this file. It may be binary, or its changes may be in its mode only."
    }

    @ViewBuilder private var indexButton: some View {
        switch request.row.area {
        case .staged where session.canUnstage:
            Button("Unstage") { dismiss(); Task { await session.unstage([request.row]) } }
                .accessibilityIdentifier("gitDiffUnstage")
        case .changes where session.canStage:
            Button("Stage") { dismiss(); Task { await session.stage([request.row]) } }
                .accessibilityIdentifier("gitDiffStage")
        case .conflicts where session.canStage:
            Button("Mark Resolved") { dismiss(); Task { await session.stage([request.row]) } }
        default:
            EmptyView()
        }
    }

    private func load() async {
        issue = nil
        let hostID = workspace.hostID
        do {
            let answer = try await session.loadDiff(request)
            guard !Task.isCancelled, workspace.hostID == hostID else { return }
            // Parsing a large diff stays off the main thread.
            diff = await Task.detached(priority: .userInitiated) { GitDiffDocument(answer.diff) }.value
        } catch {
            guard !Task.isCancelled, workspace.hostID == hostID else { return }
            issue = error.localizedDescription
        }
    }
}

/// A unified diff in the code style: monospaced text at the code role's size, old and new line numbers,
/// added lines on a green wash and removed lines on a red one, each also marked + or −. Long lines
/// scroll sideways; VoiceOver reads each line with what happened to it.
/// A diff sheet's way out (GI-10): the system's close button on iPhone and iPad, on the sheet's own page (the sheet's
/// `surfaceRaised`, not the canvas); Done on the Mac, as before.
struct GitDiffCloseButton: View {
    let action: () -> Void

    var body: some View {
        #if os(iOS)
        Button(role: .close, action: action).accessibilityIdentifier("gitDiffDone")
        #else
        Button("Done", action: action).accessibilityIdentifier("gitDiffDone")
        #endif
    }
}

struct GitDiffView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let document: GitDiffDocument
    @State private var viewport: CGFloat = 0

    var body: some View {
        let metrics = Metrics(document: document, font: codeFont)
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(document.lines) { line in
                    GitDiffLineView(line: line, gutter: metrics.gutter)
                        .frame(width: max(metrics.width, viewport), alignment: .leading)
                }
            }
            .padding(.vertical, AgentLandSpacing.xSmall)
        }
        // A short diff starts at the top left, not in the middle of the sheet.
        .defaultScrollAnchor(.topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewport = $0 }
        .accessibilityIdentifier("gitDiff")
    }

    #if os(iOS)
    /// The code role's font at the current text size, to measure the widest line.
    private var codeFont: UIFont {
        UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular),
                                                             compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize)))
    }
    #else
    /// The code role's font on the Mac, which its lines use too (`agentLandFont(.code)` keeps the
    /// system's size there), to measure the widest line.
    private var codeFont: NSFont {
        .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .regular)
    }
    #endif

    struct Metrics {
        let gutter: CGFloat
        let width: CGFloat

        #if os(iOS)
        typealias PlatformFont = UIFont
        #else
        typealias PlatformFont = NSFont
        #endif

        init(document: GitDiffDocument, font: PlatformFont) {
            let digit = ("0" as NSString).size(withAttributes: [.font: font]).width
            let digits = CGFloat(max(3, String(document.largestNumber).count))
            gutter = ceil(digits * digit + AgentLandSpacing.small)
            width = ceil(gutter * 2 + digit * CGFloat(document.widestLine + 2) + AgentLandSpacing.large * 2)
        }
    }
}

private struct GitDiffLineView: View {
    let line: GitDiffDocument.Line
    let gutter: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(marker)
                .foregroundStyle(markerColor)
                .frame(width: AgentLandSpacing.large)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(textColor)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .agentLandFont(.code)
        .padding(.vertical, 1)
        .background(background)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(.isStaticText)
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(AgentLandTypeRole.codeSmall.font.monospacedDigit())
            .foregroundStyle(AgentLandColor.textSecondary)
            .frame(width: gutter, alignment: .trailing)
            .padding(.trailing, AgentLandSpacing.xxSmall)
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        default: ""
        }
    }

    private var markerColor: AgentLandColor {
        line.kind == .added ? .success : line.kind == .removed ? .danger : .textSecondary
    }

    private var textColor: AgentLandColor {
        switch line.kind {
        case .added, .removed, .context: .text
        default: .textSecondary
        }
    }

    @ViewBuilder private var background: some View {
        switch line.kind {
        case .added: AgentLandColor.success.color.opacity(0.14)
        case .removed: AgentLandColor.danger.color.opacity(0.14)
        case .hunk: AgentLandColor.surface.color
        default: Color.clear
        }
    }

    private var spoken: String {
        switch line.kind {
        case .added: "Added line \(line.newNumber ?? 0): \(line.text)"
        case .removed: "Removed line \(line.oldNumber ?? 0): \(line.text)"
        case .context: "Line \(line.newNumber ?? 0): \(line.text)"
        case .hunk: "Changes near line \(GitDiffDocument.hunkStarts(line.text).1)"
        default: line.text
        }
    }
}
