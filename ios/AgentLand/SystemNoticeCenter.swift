import UIKit
import UserNotifications
import AgentLandNotifications

/// `NotificationsModel`'s view of the system on iPhone and iPad: the notification permission and
/// the push registration.
@MainActor final class SystemNoticeCenter: NoticeSystem {
    func notificationPermission() async -> NoticePermission {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .authorized, .provisional, .ephemeral: .allowed
        case .denied: .denied
        @unknown default: .denied
        }
    }

    /// Alerts and their sound; notices set no badge.
    func requestNotificationPermission() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}

extension AppModel {
    /// The environment `NoticeCloudKit` reads its switch from: this process's, with CloudKit turned
    /// off for test runs. The unit tests' host gets `AGENTLAND_CLOUDKIT=0` from the scheme; UI tests
    /// launch the app themselves, with their `-AgentLandUITests…` flags.
    static func cloudKitEnvironment(arguments: [String] = ProcessInfo.processInfo.arguments,
                                    environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = environment
        #if DEBUG
        if arguments.contains(where: { $0.hasPrefix("-AgentLandUITests") }) || environment["XCTestConfigurationFilePath"] != nil {
            result[NoticeCloudKit.environmentSwitch] = "0"
        }
        #endif
        return result
    }

    /// Notifications with the system's permission and the owner's iCloud. The `CKContainer` is made
    /// the first time notifications are used, never at launch.
    static func makeNotifications(defaults: UserDefaults) -> NotificationsModel {
        let environment = cloudKitEnvironment()
        return NotificationsModel(defaults: defaults, system: SystemNoticeCenter(),
                                  unavailability: NoticeCloudKit.unavailability(environment: environment),
                                  makeDatabase: { NoticeCloudKit.makeDatabase(environment: environment) })
    }
}
