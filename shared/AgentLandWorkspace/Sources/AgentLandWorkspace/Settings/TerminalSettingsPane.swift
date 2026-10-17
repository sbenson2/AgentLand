import SwiftUI
import AgentLandDesign

/// iPhone and iPad Settings → Terminal (`TerminalSettings`): the terminal's own text size, the cursor's shape, the key
/// bar, and the bell as a haptic where the device has haptics. Saved on this device; open terminals change at once.
public struct TerminalSettingsPane: View {
    @AppStorage(TerminalSettings.fontSizeKey) private var fontSize = TerminalSettings.automaticFontSize
    @AppStorage(TerminalSettings.cursorKey) private var cursor = TerminalSettings.Cursor.block
    @AppStorage(TerminalSettings.keyBarKey) private var showsKeyBar = TerminalSettings.keyBarDefault
    @AppStorage(TerminalSettings.bellHapticKey) private var bellVibrates = TerminalSettings.bellHapticDefault
    let offersHaptics: Bool

    public init(offersHaptics: Bool) { self.offersHaptics = offersHaptics }

    public var body: some View {
        AgentLandForm {
            Section {
                SettingsToggleRow("Match text size", isOn: Binding(get: { fontSize <= 0 }, set: { follows in
                    fontSize = follows ? TerminalSettings.automaticFontSize : TerminalSettings.firstChosenFontSize
                }))
                .accessibilityIdentifier("terminalMatchTextSize")
                if fontSize > 0 {
                    Stepper(value: $fontSize, in: TerminalSettings.fontSizes, step: 1) {
                        LabeledContent("Size", value: "\(Int(fontSize)) pt").monospacedDigit()
                    }
                    .accessibilityValue("\(Int(fontSize)) points")
                    .accessibilityIdentifier("terminalFontSize")
                    Text("user@mac ~ % ls")
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundStyle(AgentLandColor.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .agentLandRowHeight()
                        .accessibilityLabel("Sample at \(Int(fontSize)) points")
                }
            } header: {
                Text("Text")
            } footer: {
                Text(fontSize > 0
                     ? "Terminals keep this size whatever AgentLand’s text size. Programs get as many rows and columns as fit."
                     : "Terminals follow your text size, keeping enough columns for their program.")
            }
            Section {
                Picker("Shape", selection: $cursor) {
                    ForEach(TerminalSettings.Cursor.allCases) { shape in Label(shape.title, systemImage: shape.symbol).tag(shape) }
                }
                .accessibilityIdentifier("terminalCursor")
            } header: {
                Text("Cursor")
            } footer: {
                Text("A program can change the cursor while it runs.")
            }
            Section {
                SettingsToggleRow("Key bar", detail: "Esc, Tab, Ctrl, the arrows and Hide keyboard, above the keyboard.",
                                  isOn: $showsKeyBar)
                    .accessibilityIdentifier("terminalKeyBarSetting")
            } header: {
                Text("Keyboard")
            } footer: {
                if !showsKeyBar { Text("Without it, hide the keyboard from the terminal’s menu at the top of the screen.") }
            }
            if offersHaptics {
                Section("Bell") {
                    SettingsToggleRow("Vibrate on bell", detail: "When a program rings the bell, at most once a second.",
                                      isOn: $bellVibrates)
                        .accessibilityIdentifier("terminalBellHaptic")
                }
            }
        }
        .settingsForm()
    }
}
