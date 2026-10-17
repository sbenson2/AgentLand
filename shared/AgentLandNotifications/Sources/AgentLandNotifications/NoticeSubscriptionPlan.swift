import CloudKit
import Foundation

/// The query subscriptions iPhone and iPad save so that iOS shows the Mac's
/// notices as alerts: one per enabled kind, on record type `Notice` in the
/// `Notices` zone of the private database, firing on record creation only.
///
/// Apple's `CKQuerySubscription` documentation: "You can set the
/// subscription's zoneID property to further specialize the subscription to a
/// specific record zone in the database", and "Only public and private
/// databases support query subscriptions". Custom zones exist only in private
/// databases, so the custom `Notices` zone is supported.
///
/// Each subscription's notification info:
/// - `titleLocalizationKey`: `NoticeKind.titleLocalizationKey` ("Reply ready" …).
/// - `alertLocalizationKey` `notice.body` ("%@") with `alertLocalizationArgs`
///   `["alertBody"]`: the body the Mac composed.
/// - `soundName` "default", or with the sound off `silentSoundName`, a short
///   silent sound the iOS app bundles (`ios/AgentLand/agentland-silent.caf`).
///   Apple's `NotificationInfo` documentation: without `alertBody`,
///   `soundName` or `shouldBadge`, "CloudKit sends the push notification using
///   a lower priority and doesn't display any content", so the sound is never
///   left out; a silent one keeps the alert. A device without the file (an
///   older build) plays the default sound instead.
/// - `desiredKeys` `projectId`, `sessionId` for the deep link
///   (CloudKit allows at most three and may cut values past 100 characters;
///   the kind comes from the subscription ID and the host from the record
///   name). `NoticeDeepLink` reads them.
///
/// Subscriptions belong to the iCloud account, so what one device saves
/// applies to every device signed in to it.
public struct NoticeSubscriptionPlan: Equatable, Sendable {
    /// Raise when the subscriptions change, so apps save them again (saving
    /// a subscription with an existing ID replaces it). 2 (2026-10-06):
    /// deletes `retiredSubscriptionIDs`.
    public static let version = 2
    public static let desiredKeys: [CKRecord.FieldKey] = [NoticeRecord.Field.projectID, NoticeRecord.Field.sessionID]
    public static let soundName = "default"
    /// The sound alerts play with the sound off: silence, bundled with the iOS app.
    public static let silentSoundName = "agentland-silent.caf"
    static let subscriptionIDPrefix = "agentland.notice."
    /// Subscriptions earlier plans saved for kinds the host no longer issues:
    /// the scheduled-run kinds, removed with schedules on 2026-10-06. Every
    /// save deletes them, so an account's leftovers go with its next save.
    public static let retiredSubscriptionIDs: [CKSubscription.ID] =
        ["schedule.run.finished", "schedule.run.budget_exceeded", "schedule.run.failed"].map { subscriptionIDPrefix + $0 }

    /// The kinds to subscribe to, in `NoticeKind.allCases` order.
    public let enabledKinds: [NoticeKind]
    /// Alerts play the default sound; off, they play `silentSoundName`.
    public let sound: Bool

    public init(enabledKinds: some Sequence<NoticeKind> = NoticeKind.allCases, sound: Bool = true) {
        let enabled = Set(enabledKinds)
        self.enabledKinds = NoticeKind.allCases.filter(enabled.contains)
        self.sound = sound
    }

    /// Whether a subscription's `soundName` plays a sound: anything but the silent one does (CloudKit leaves
    /// it as saved; nil only for a subscription this app did not save).
    public static func playsSound(_ soundName: String?) -> Bool { soundName != silentSoundName }

    /// `agentland.notice.<kind>`, stable across versions.
    public static func subscriptionID(for kind: NoticeKind) -> CKSubscription.ID {
        subscriptionIDPrefix + kind.rawValue
    }

    public static func kind(forSubscriptionID id: CKSubscription.ID) -> NoticeKind? {
        guard id.hasPrefix(subscriptionIDPrefix) else { return nil }
        return NoticeKind(rawValue: String(id.dropFirst(subscriptionIDPrefix.count)))
    }

    /// The subscriptions to save, one per enabled kind.
    public func subscriptions(zoneID: CKRecordZone.ID = NoticeRecord.zoneID) -> [CKQuerySubscription] {
        enabledKinds.map { kind in
            let subscription = CKQuerySubscription(recordType: NoticeRecord.recordType,
                                                   predicate: NSPredicate(format: "%K == %@", NoticeRecord.Field.kind, kind.rawValue),
                                                   subscriptionID: Self.subscriptionID(for: kind),
                                                   options: [.firesOnRecordCreation])
            subscription.zoneID = zoneID
            subscription.notificationInfo = Self.notificationInfo(for: kind, sound: sound)
            return subscription
        }
    }

    /// The subscriptions of the kinds turned off, then `retiredSubscriptionIDs`, to delete.
    public var subscriptionIDsToDelete: [CKSubscription.ID] {
        NoticeKind.allCases.filter { !enabledKinds.contains($0) }.map(Self.subscriptionID(for:)) + Self.retiredSubscriptionIDs
    }

    public static func notificationInfo(for kind: NoticeKind, sound: Bool = true) -> CKSubscription.NotificationInfo {
        let info = CKSubscription.NotificationInfo()
        info.titleLocalizationKey = kind.titleLocalizationKey
        info.alertLocalizationKey = NoticeAlertText.bodyLocalizationKey
        info.alertLocalizationArgs = [NoticeRecord.Field.alertBody]
        info.desiredKeys = desiredKeys
        info.soundName = sound ? soundName : silentSoundName
        return info
    }
}
