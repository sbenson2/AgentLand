import CloudKit
import UIKit
import UserNotifications
import AgentLandNotifications

/// The UIKit side of push. It owns the app model so that a notice tapped while the app was not
/// running reaches the model: the notification center's delegate must be set before launching
/// finishes, before SwiftUI builds the scene. Everything it receives goes to the model.
final class AgentLandAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Signing in or out of iCloud, or switching accounts, changes whose subscriptions apply.
        NotificationCenter.default.addObserver(self, selector: #selector(accountChanged), name: .CKAccountChanged, object: nil)
        #if DEBUG && targetEnvironment(simulator)
        model.pairFromLaunchArgument()
        #endif
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // CloudKit delivers the account's subscriptions to a registered device; the token itself is not needed.
        model.notifications.registrationSucceeded()
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        model.notifications.registrationFailed(error)
    }

    @objc private func accountChanged() {
        Task { @MainActor in await model.notifications.accountChanged() }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// A notice arriving while AgentLand is in front shows unless it is about the chat on screen.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let link = NoticeDeepLink(remoteNotification: notification.request.content.userInfo)
        return await MainActor.run { model.presentationOptions(for: link) }
    }

    /// A tapped notice opens what it names, once the app is unlocked and the opening cover cleared.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let link = NoticeDeepLink(remoteNotification: response.notification.request.content.userInfo) else { return }
        await MainActor.run { model.openNotice(link) }
    }
}
