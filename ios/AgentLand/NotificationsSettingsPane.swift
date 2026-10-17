import SwiftUI
import UIKit
import AgentLandDesign
import AgentLandNotifications
import AgentLandWorkspace

/// Settings → Notifications: this device's permission, the three groups the iCloud account subscribes to and
/// their sound (for every device on it), the iCloud account, and where chat titles are set.
struct NotificationsSettingsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    private let device = UIDevice.current.model

    private var notifications: NotificationsModel { model.notifications }

    var body: some View {
        AgentLandForm {
            Section {
                permissionRows
            } header: {
                Text("This \(device)")
            } footer: {
                Text(permissionNote)
            }
            Section("Notify me about") { groupRows }
            Section {
                Toggle("Sound", isOn: Binding(get: { notifications.displayedSound },
                                              set: { on in Task { await notifications.setSound(on) } }))
                .disabled(!canChangeGroups)
                .accessibilityIdentifier("notificationsSound")
            } header: {
                Text("Alerts")
            } footer: {
                // One text, as a form's footer is. Quiet hours: the owner chose iOS Focus (2026-10-05) over building them.
                Text("These choices, the sound included, are kept in your iCloud account, so they apply to every iPhone and iPad signed in with the same Apple ID. To silence AgentLand on a schedule, use a Focus: Settings → Focus in the Settings app.")
                    .accessibilityIdentifier("notificationsFocus")
            }
            Section {
                LabeledContent("Account", value: accountValue)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("notificationsAccount")
                if notifications.account == .checkFailed || notifications.account == .status(.couldNotDetermine) {
                    Button { Task { await notifications.refresh() } } label: { ActionRowLabel("Check Again") }
                        .accessibilityIdentifier("notificationsCheckAgain")
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text(accountNote + " Your Mac decides whether alerts show chat titles: in AgentLand on the Mac, Settings → Notifications → Include chat titles. Alerts never show message text.")
                    .accessibilityIdentifier("notificationsTitles")
            }
            // A read that failed is a state, in place with Try Again; a save that failed is the alert below.
            if let problem = notifications.problem, case .readFailed = problem {
                SettingsStatusSection("Couldn’t read your choices", systemImage: "exclamationmark.icloud",
                                      message: problem.message(device: device), identifier: "notificationsProblem",
                                      actionTitle: "Try Again", actionIdentifier: "notificationsRetry") {
                    Task { await notifications.refresh() }
                }
            }
        }
        .settingsForm()
        .alert("Couldn’t Save to iCloud", isPresented: saveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notifications.problem?.message(device: device) ?? "")
        }
        .task { await notifications.refresh() }
        .onChange(of: scenePhase) { _, phase in
            // Coming back from the system's Settings may have changed the permission or the account.
            if phase == .active { Task { await notifications.refresh() } }
        }
    }

    /// A change that didn't reach iCloud: the system's alert, which OK puts away. (Notifications turned off for
    /// AgentLand show in place, in the rows above.)
    private var saveFailed: Binding<Bool> {
        Binding(get: { if case .saveFailed? = notifications.problem { true } else { false } },
                set: { if !$0 { notifications.clearProblem() } })
    }

    // MARK: This device

    @ViewBuilder private var permissionRows: some View {
        LabeledContent("Notifications", value: permissionValue)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("notificationsPermission")
        switch notifications.permission {
        case .notDetermined? where notifications.cloudKitAvailable:
            // Without CloudKit nothing could reach this device: no button that cannot work (the iCloud row says why).
            Button { Task { await notifications.requestPermission() } } label: { ActionRowLabel("Allow Notifications") }
                .disabled(notifications.working)
                .accessibilityIdentifier("notificationsAllow")
        case .denied?:
            Button {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
            } label: { ActionRowLabel("Open Settings") }
            .accessibilityIdentifier("notificationsOpenSettings")
        case .allowed?, .notDetermined?, nil:
            EmptyView()
        }
        if let error = notifications.registrationError {
            Text("This \(device) couldn’t register for notifications: \(error)")
                .agentLandFont(.metadata)
                .foregroundStyle(AgentLandColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, AgentLandSpacing.small)
        }
    }

    private var permissionValue: String {
        switch notifications.permission {
        case nil: "Checking…"
        case .notDetermined?: "Not set up"
        case .denied?: "Off"
        case .allowed?: "Allowed"
        }
    }

    private var permissionNote: String {
        switch notifications.permission {
        case .denied?: "Notifications are off for AgentLand in the Settings app. Turn them on there to get alerts on this \(device)."
        case .allowed?: "Alerts from your Mac can show on this \(device)."
        case .notDetermined?, nil: "AgentLand asks for permission only when you turn notifications on here."
        }
    }

    // MARK: Groups

    @ViewBuilder private var groupRows: some View {
        ForEach(NoticeGroup.allCases) { group in
            SettingsToggleRow(group.title, detail: group.detail,
                              isOn: Binding(get: { notifications.displayedGroups.contains(group) },
                                            set: { on in Task { await notifications.setGroup(group, enabled: on) } }))
            .disabled(!canChangeGroups)
            .accessibilityIdentifier("notificationsGroup-\(group.rawValue)")
        }
        if notifications.working {
            LabeledContent("Saving to iCloud…") { ProgressView() }
                .accessibilityElement(children: .combine)
        }
    }

    /// Off while saving, and when iCloud cannot take the change.
    private var canChangeGroups: Bool {
        guard notifications.cloudKitAvailable, !notifications.working else { return false }
        switch notifications.account {
        case .status(let status): return status == .available
        case .unknown, .checkFailed: return true
        case .checking, .unavailable: return false
        }
    }

    // MARK: iCloud

    private var accountValue: String {
        switch notifications.account {
        case .unavailable(.turnedOff): "Off for this run"
        case .unavailable(.notSignedForICloud): "Not available in this build"
        case .unknown: "Not checked"
        case .checking: "Checking…"
        case .status(.available): "Available"
        case .status(.noAccount): "Not signed in"
        case .status(.restricted): "Restricted"
        case .status(.temporarilyUnavailable): "Temporarily unavailable"
        case .status(.couldNotDetermine), .checkFailed: "Couldn’t check"
        }
    }

    private var accountNote: String {
        switch notifications.account {
        case .status(.noAccount):
            "Sign in to iCloud in the Settings app with the Apple ID your Mac uses. Until then no notices reach this \(device)."
        case .status(.restricted):
            "Screen Time or a device management profile restricts iCloud on this \(device), so notices from your Mac can’t reach it."
        case .status(.temporarilyUnavailable):
            "iCloud needs your attention: open the Settings app and finish signing in, then come back."
        case .status(.couldNotDetermine), .checkFailed:
            "AgentLand couldn’t reach iCloud. Check the connection and try again."
        case .unavailable(.turnedOff):
            "CloudKit is turned off for this run (AGENTLAND_CLOUDKIT=0)."
        case .unavailable(.notSignedForICloud):
            "This build isn’t signed for iCloud, so notices can’t reach it."
        case .status(.available), .unknown, .checking:
            "Your Mac sends notices through your iCloud account, with no AgentLand server. Use the same Apple ID on this \(device) and on the Mac."
        }
    }

}

extension NoticeGroup {
    var title: String {
        switch self {
        case .replies: "Replies"
        case .approvals: "Approvals and questions"
        }
    }

    var detail: String {
        switch self {
        case .replies: "A reply is ready, or it failed"
        case .approvals: "An agent needs your approval or an answer"
        }
    }
}

extension NoticeSetupProblem {
    func message(device: String) -> String {
        switch self {
        case .permissionDenied:
            "Notifications are off for AgentLand on this \(device). Turn them on in the Settings app."
        case .unavailable(.turnedOff):
            "CloudKit is turned off for this run."
        case .unavailable(.notSignedForICloud):
            "This build isn’t signed for iCloud."
        case .account(.noAccount):
            "Sign in to iCloud on this \(device) with the Apple ID your Mac uses."
        case .account(.restricted):
            "iCloud is restricted on this \(device), so notices from your Mac can’t reach it."
        case .account(.temporarilyUnavailable):
            "iCloud is temporarily unavailable. Finish signing in to iCloud in the Settings app, then try again."
        case .account, .accountCheckFailed:
            "AgentLand couldn’t check your iCloud account. Try again when you’re online."
        case let .readFailed(detail):
            "Couldn’t read your notification choices from iCloud. \(detail)"
        case let .saveFailed(failure, detail):
            switch failure {
            case .retry: "Couldn’t reach iCloud. Try again in a moment."
            case .quotaExceeded: "Your iCloud storage is full."
            case .account: "iCloud isn’t available on this \(device) right now. \(detail)"
            case .zoneMissing, .alreadySaved, .rejected: "iCloud didn’t accept the change. \(detail)"
            }
        }
    }
}
