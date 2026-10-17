import SwiftUI
import AgentLandBranding
import AgentLandDesign
import AgentLandCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Text roles for chat content. Every size is a Dynamic Type text style.
public enum ChatTextRole: Sendable {
    /// Reply prose: body, primary color.
    case reply
    /// Reasoning, quotes and other supporting text: callout, secondary color.
    case supporting

    var font: Font { self == .reply ? .body : .callout }
    var codeFont: Font { self == .reply ? .callout.monospaced() : .footnote.monospaced() }
    var color: Color { self == .reply ? AgentLandColor.text.color : AgentLandColor.textSecondary.color }
}

enum ChatMetrics {
    /// Touch targets: 44 pt on touch, 28 pt with a pointer (Mac).
    #if os(macOS)
    static let target: CGFloat = 28
    #else
    static let target: CGFloat = 44
    #endif
}

public enum ChatClipboard {
    @MainActor public static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// Copies `text`; the symbol turns into a checkmark for 1.5 s. No toast.
public struct ChatCopyButton: View {
    let text: String
    let label: String
    let announcement: String
    let identifier: String?
    let iconOnly: Bool
    @State private var copied = false

    public init(_ text: String, label: String = "Copy", announcement: String = "Copied", identifier: String? = nil, iconOnly: Bool = false) {
        self.text = text; self.label = label; self.announcement = announcement; self.identifier = identifier; self.iconOnly = iconOnly
    }

    public var body: some View {
        Button {
            ChatClipboard.copy(text)
            // The symbol's own replace transition (`contentTransition` below).
            withAnimation { copied = true }
            AccessibilityNotification.Announcement(announcement).post()
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation { copied = false }
            }
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(ChatCompactLabelStyle(iconOnly: iconOnly))
                .contentTransition(.symbolEffect(.replace))
                .font(.footnote.weight(.medium))
                .foregroundStyle(AgentLandColor.textSecondary.color)
                .padding(.horizontal, iconOnly ? 0 : 8)
                .frame(minWidth: ChatMetrics.target, minHeight: ChatMetrics.target)
                .contentShape(Rectangle())
        }
        .chatBorderlessButton()
        .accessibilityLabel(copied ? "Copied" : label)
        .chatIdentifier(identifier)
        .help(label)
    }
}

extension View {
    /// Icon and text buttons in the chat's content: the system's borderless button on iOS and iPad (CH-09), with its
    /// own pressed state; the Mac keeps its plain buttons.
    @ViewBuilder func chatBorderlessButton() -> some View {
        #if os(iOS)
        self.buttonStyle(.borderless)
        #else
        self.buttonStyle(.plain)
        #endif
    }

    /// Sets an accessibility identifier only when there is one; an empty
    /// identifier would still replace the ones inside.
    @ViewBuilder func chatIdentifier(_ identifier: String?) -> some View {
        if let identifier { self.accessibilityIdentifier(identifier) } else { self }
    }
}

/// Icon and title, or icon only with the title kept for accessibility.
struct ChatCompactLabelStyle: LabelStyle {
    let iconOnly: Bool
    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            configuration.icon
        } else {
            HStack(spacing: 4) { configuration.icon; configuration.title }
        }
    }
}

extension View {
    /// Liquid Glass for floating controls only: the composer, Jump to Latest and the docked pill. On iOS and iPad the
    /// system's glass alone, which itself answers Reduce Transparency and Increase Contrast (CH-02); the Mac keeps
    /// its hairline, and an opaque theme surface under Reduce Transparency.
    @ViewBuilder
    func chatFloatingSurface<S: InsettableShape>(_ shape: S, reduceTransparency: Bool, increasedContrast: Bool,
                                                 interactive: Bool = false) -> some View {
        #if os(iOS)
        self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        #else
        let border = increasedContrast ? AgentLandColor.text.color.opacity(0.7) : AgentLandColor.separator.color.opacity(0.8)
        if reduceTransparency {
            self.background(AgentLandColor.surfaceRaised.color, in: shape)
                .overlay(shape.strokeBorder(border, lineWidth: increasedContrast ? 1.5 : 0.75))
        } else {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
                .overlay(shape.strokeBorder(border.opacity(increasedContrast ? 1 : 0.5), lineWidth: increasedContrast ? 1.5 : 0.5))
        }
        #endif
    }

    /// Solid cards for content: messages, tool cards, approvals, code. On iOS and iPad the fill alone, paper or slate,
    /// with a border only under Increase Contrast (CH-04); the Mac keeps its hairline, in `tint` where one is given.
    func chatCard(cornerRadius: CGFloat = 14, fill: Color = AgentLandColor.surface.color, increasedContrast: Bool, tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if os(iOS)
        return self.background(fill, in: shape)
            .overlay { if increasedContrast { shape.strokeBorder(AgentLandColor.text.color.opacity(0.8), lineWidth: 1.5) } }
        #else
        return self.background(fill, in: shape)
            .overlay(shape.strokeBorder((tint ?? (increasedContrast ? AgentLandColor.text.color : AgentLandColor.separator.color)).opacity(increasedContrast ? 0.8 : 0.6),
                                        lineWidth: increasedContrast ? 1.5 : 0.75))
        #endif
    }
}

/// Buttons on approval and question cards: on iOS and iPad the system's bordered buttons in a large capsule, the
/// default action prominent in the accent (CH-06: content, so no Liquid Glass); explicit colors on the Mac, where
/// the app sets a theme-wide tint that would otherwise paint a filled button's label in its own fill color.
struct ChatCardButtonStyle: PrimitiveButtonStyle {
    /// The default action (Allow Once, Send Answers): prominent. Never Deny.
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        #if os(iOS)
        if prominent {
            // `onTint` on the accent: dark mode's light accent keeps its contrast.
            Button(configuration).buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
                .foregroundStyle(AgentLandColor.onTint.color)
                .minimumTapTarget(.reserveSpace)
        } else {
            Button(configuration).buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
                .minimumTapTarget(.reserveSpace)
        }
        #else
        Button(configuration).buttonStyle(MacChatCardButtonStyle(prominent: prominent))
        #endif
    }
}

private struct MacChatCardButtonStyle: ButtonStyle {
    let prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        ChatCardButtonBody(configuration: configuration, prominent: prominent)
    }
}

private struct ChatCardButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        configuration.label
            .font(prominent ? .body.weight(.semibold) : .body)
            .multilineTextAlignment(.center)
            .foregroundStyle(prominent ? AgentLandColor.onTint.color : AgentLandColor.text.color)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(minHeight: ChatMetrics.target)
            .background(prominent ? AgentLandColor.tint.color : AgentLandColor.surface.color, in: Capsule())
            .overlay {
                if !prominent || contrast == .increased {
                    Capsule().strokeBorder(AgentLandColor.separator.color, lineWidth: contrast == .increased ? 1.5 : 0.75)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.5)
            .contentShape(Capsule())
    }
}

/// A plain button that keeps its colors when disabled: the label draws the
/// disabled state itself, with colors that stay readable.
struct ChatUndimmedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// A short relative or clock time for transcript captions.
enum ChatTimeFormat {
    static func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
    static func clock(_ value: String?) -> String? { ChatTime.date(value).map(clock) }
}
