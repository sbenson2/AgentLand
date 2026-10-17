import SwiftUI
import AgentLandWorkspace

/// Settings → Notifications, in its form: iCloud state, the two switches and a test.
struct NotificationSettingsSection: View {
    @ObservedObject var notifications: NotificationRelayController
    let sendTest: () -> Void

    var body: some View {
        Group { sections }
            .onAppear { notifications.refreshAccountStatus() }
    }

    @ViewBuilder private var sections: some View {
        Section {
            LabeledContent("iCloud:", value: notifications.iCloudSummary)
            if let detail = notifications.iCloudDetail { MacSettingsFootnote(detail) }
        }
        Section {
            LabeledContent("Notifications:") {
                Toggle("Send notifications to my iPhone and iPad", isOn: $notifications.sendEnabled)
                    .disabled(!notifications.canUseICloud)
            }
            .macSettingsGroupStart()
            Toggle("Include chat titles", isOn: $notifications.includeTitles)
                .disabled(!notifications.canUseICloud || !notifications.sendEnabled)
            MacSettingsFootnote("Chat titles can contain words from your chats. Message text is never sent.")
        }
        Section {
            HStack {
                Button("Send Test Notification", action: sendTest)
                    .disabled(!notifications.canUseICloud || !notifications.sendEnabled || notifications.testState == .sending)
                if notifications.testState == .sending { ProgressView().controlSize(.small) }
            }
            .macSettingsGroupStart()
            if let message = notifications.testMessage { MacSettingsFootnote(message) }
            ForEach([notifications.relayProblem, notifications.cleanupProblem].compactMap { $0 }, id: \.self) { problem in
                MacSettingsStateLine(problem)
            }
        }
    }
}
