import SwiftUI
import TipKit
import UIKit
import AgentLandDesign

/// The one-time notifications tip (NO-2, owner's decision of 2026-10-06: TipKit for this tip). The workspace shows it
/// with its own notices, under the navigation bar; without a workspace (pairing) `NoticeOverlay` floats it at the top
/// of the screen. `NotificationsModel` decides when it is offered (once, after a chat turn longer than 30 s, while
/// permission is not asked yet); TipKit draws it and keeps it closed once closed. The app's short notices (a tapped
/// notification that cannot open, the tip's outcome) are the system's alert, from `AgentLandApp`.
struct NoticeStack: View {
    @Environment(AppModel.self) private var model
    private let tip = NotificationsTip(device: UIDevice.current.model)

    var body: some View {
        if model.notifications.tipVisible {
            TipView(tip) { action in
                guard action.id == NotificationsTip.turnOn else { return }
                tip.invalidate(reason: .actionPerformed)
                model.acceptNotificationsTip()
            }
            .task {
                AppTips.configureIfNeeded()
                NotificationsTip.offered = true
                // Closed with its ×: the model's offer ends too.
                for await status in tip.statusUpdates {
                    if case .invalidated = status { model.notifications.dismissTip(); return }
                }
            }
        }
    }
}

/// The notifications tip: TipKit's own platter with its title, message, symbol, Turn On and close button.
struct NotificationsTip: Tip {
    static let turnOn = "turnOn"
    /// Set once the app offers the tip; TipKit shows it while this holds and it was never closed.
    @Parameter static var offered: Bool = false
    let device: String

    var id: String { "notificationsTip" }
    var title: Text { Text("Get notified when a reply is ready") }
    var message: Text? {
        Text("Your Mac can alert this \(device) through iCloud when an agent finishes or needs you. You can change this in Settings → Notifications.")
    }
    var image: Image? { Image(systemName: "bell.badge") }
    var actions: [Action] { [Action(id: Self.turnOn, title: "Turn On")] }
    var rules: [Rule] { [#Rule(Self.$offered) { $0 == true }] }
}

/// TipKit's set-up, made the first time a tip is offered and never at launch, so it costs the first frame nothing
/// (`testLaunchTiming`). Test runs (a `-AgentLandUITests…` argument, or the unit tests' XCTest host) start from an
/// empty tip datastore; UI-test runs show no tip unless launched with `-AgentLandUITestsShowTips`, so no tip covers a
/// control a test taps.
@MainActor
enum AppTips {
    private static var configured = false

    static func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        let process = ProcessInfo.processInfo
        let uiTestRun = process.arguments.contains { $0.hasPrefix("-AgentLandUITests") }
        if uiTestRun || process.environment["XCTestConfigurationFilePath"] != nil { try? Tips.resetDatastore() }
        if uiTestRun, !process.arguments.contains("-AgentLandUITestsShowTips") { Tips.hideAllTipsForTesting() }
        try? Tips.configure([.displayFrequency(.immediate)])
    }
}

/// The tip over a screen without a workspace, under the covers.
struct NoticeOverlay: View {
    var body: some View {
        VStack(spacing: AgentLandSpacing.xSmall) {
            NoticeStack()
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, AgentLandSpacing.small)
        .padding(.top, AgentLandSpacing.xSmall)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
