import SwiftUI

/// iOS uses the native prominent Liquid Glass button in the app's accent (its AccentColor asset), which the
/// environment's tint supplies. Mac keeps its established primary style.
public struct AgentLandPrimaryButtonStyle: PrimitiveButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        #if os(iOS)
        Button(configuration)
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .minimumTapTarget(.reserveSpace)
        #else
        Button(configuration).buttonStyle(MacPrimaryButtonStyle())
        #endif
    }
}

public extension PrimitiveButtonStyle where Self == AgentLandPrimaryButtonStyle {
    static var agentLandPrimary: AgentLandPrimaryButtonStyle { AgentLandPrimaryButtonStyle() }
}

private struct MacPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration)
    }
}

private struct PrimaryButtonBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.agentLandMinimumTapTarget) private var minimumTapTarget
    let configuration: ButtonStyleConfiguration

    var body: some View {
        configuration.label
            .agentLandFont(.bodyEmphasized)
            .foregroundStyle(AgentLandColor.onTint)
            .multilineTextAlignment(.center)
            .padding(.horizontal, AgentLandSpacing.medium)
            .padding(.vertical, AgentLandSpacing.xSmall)
            .frame(minWidth: minimumTapTarget, minHeight: minimumTapTarget)
            .background(AgentLandColor.tint, in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .reportsTapTarget()
    }
}

#Preview("Primary button") {
    VStack(spacing: AgentLandSpacing.medium) {
        Button("Reconnect") {}.buttonStyle(.agentLandPrimary)
        Button("Reconnect") {}.buttonStyle(.agentLandPrimary).disabled(true)
    }
    .padding()
    .background(AgentLandColor.canvas)
}
