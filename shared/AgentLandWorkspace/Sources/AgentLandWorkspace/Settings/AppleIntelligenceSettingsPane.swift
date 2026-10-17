import SwiftUI
import AgentLandBranding
import AgentLandDesign

/// App → Apple Intelligence on iPhone and iPad (owner, 2026-10-16: "the later option too as a toggle featuer (apple
/// intelligence, which also controls the quips on devcie no?)"): one switch for all this device writes with Apple's
/// on-device model, Home's quips and the names of chats and terminals (`AppleIntelligence`). Each use reads it again, so
/// a change applies at once. While the model can't run the switch keeps its choice, and a status in place says why and
/// that AgentLand uses its own quips and names meanwhile. The Mac has the same switch in Settings → General.
public struct AppleIntelligenceSettingsPane: View {
    @AppStorage(AppleIntelligence.settingKey) private var isOn = AppleIntelligence.settingDefault
    @State private var availability = AppleIntelligence.Availability.available
    @Environment(\.scenePhase) private var scenePhase
    /// "iPhone" or "iPad".
    private let device: String

    public init(device: String) { self.device = device }

    public var body: some View {
        AgentLandForm {
            Section {
                SettingsToggleRow("Use Apple Intelligence",
                                  detail: "Writes Home’s quips and names chats and terminals on this \(device).",
                                  isOn: $isOn)
                    .accessibilityIdentifier("appleIntelligenceSwitch")
            } footer: {
                Text("When it’s off, AgentLand writes its own quips and gives chats and terminals simpler names from what was typed. Apple Intelligence runs on this \(device), so nothing it reads leaves it; only the names go to your Mac.")
            }
            if let status = AppleIntelligence.unavailableText(availability, device: device) {
                SettingsStatusSection(status.title, systemImage: "exclamationmark.triangle", message: status.message,
                                      identifier: "appleIntelligenceStatus")
            }
        }
        .settingsForm()
        // Whether the model can run changes outside AgentLand (Settings, a download): read while the page shows and
        // when the app returns, off the main actor.
        .task(id: scenePhase) {
            while !Task.isCancelled {
                availability = await Task.detached(priority: .utility) { AppleIntelligence.availability }.value
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
