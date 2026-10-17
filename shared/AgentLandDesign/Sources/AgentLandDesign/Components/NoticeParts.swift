import SwiftUI

/// The raised card behind notices and banners: `surfaceRaised`, a `separator` border (which carries the
/// edge under Increase Contrast) and a soft shadow cast by the card alone, so text and border don't
/// cast their own.
struct NoticeChrome: ViewModifier {
    func body(content: Content) -> some View {
        let shape = AgentLandRadius.shape(AgentLandRadius.card)
        content
            .background {
                shape.fill(AgentLandColor.surfaceRaised)
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            }
            .overlay(shape.strokeBorder(AgentLandColor.separator, lineWidth: 1))
    }
}

/// A text button label in the tint color with the minimum tap target, for notice and banner actions.
struct NoticeButtonLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(AgentLandTypeRole.secondary.font.weight(.semibold))
            .foregroundStyle(AgentLandColor.tint)
            .padding(.horizontal, AgentLandSpacing.xSmall)
            .minimumTapTarget(.reserveSpace)
    }
}

/// The dismiss "×" with the minimum tap target.
struct DismissButtonLabel: View {
    var body: some View {
        Image(systemName: "xmark")
            .font(AgentLandTypeRole.secondary.font.weight(.semibold))
            .foregroundStyle(AgentLandColor.textSecondary)
            .minimumTapTarget(.reserveSpace)
    }
}

extension View {
    /// Sets an accessibility identifier only when there is one. An empty identifier on a container
    /// would still replace the identifiers inside it.
    @ViewBuilder func optionalAccessibilityIdentifier(_ identifier: String?) -> some View {
        if let identifier { accessibilityIdentifier(identifier) } else { self }
    }
}
