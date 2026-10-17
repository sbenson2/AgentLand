import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Settings → Apple Intelligence (owner, 2026-10-16: "the later option too as a toggle featuer (apple intelligence,
/// which also controls the quips on devcie no?)"): one switch on each device for all AgentLand writes with Apple's
/// on-device model: Home's quips (`QuipStore`), chat names and terminal names, and on the Mac the names of every
/// terminal on its host. On by default (a missing value is on); off, AgentLand writes its own quips
/// (`GrammarQuipProvider`) and rule-based names. Every use reads it again, so a change applies without a relaunch.
public nonisolated enum AppleIntelligence {
    public static let settingKey = "agentland.appleIntelligence"
    public static let settingDefault = true

    /// Whether the person lets AgentLand use the model on this device.
    public static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: settingKey) as? Bool ?? settingDefault
    }

    /// Whether the system's model can run now, whatever the switch says.
    public enum Availability: Equatable, Sendable {
        case available
        /// This device can't run Apple Intelligence.
        case notEligible
        /// Apple Intelligence is off in System Settings.
        case turnedOff
        /// The model is still downloading or getting ready.
        case notReady
        /// Another reason, or a system without the model.
        case unavailable
    }

    public static var availability: Availability {
        #if canImport(FoundationModels)
        let availability = SystemLanguageModel.default.availability
        if case .available = availability { return .available }
        guard case let .unavailable(reason) = availability else { return .unavailable }
        switch reason {
        case .deviceNotEligible: return .notEligible
        case .appleIntelligenceNotEnabled: return .turnedOff
        case .modelNotReady: return .notReady
        default: return .unavailable
        }
        #else
        return .unavailable
        #endif
    }

    /// The switch is on and the model can run: what every use of the model checks first, and again when its answer
    /// arrives, so a switch turned off meanwhile drops that answer.
    public static func canUseModel(_ defaults: UserDefaults = .standard) -> Bool {
        isOn(defaults) && availability == .available
    }

    /// The status line of the setting while the model can't run (nil when it can): why, and that AgentLand uses its
    /// own quips and names meanwhile. `device`: "iPhone", "iPad" or "Mac".
    public static func unavailableText(_ availability: Availability, device: String) -> (title: String, message: String)? {
        let meanwhile = "Until then AgentLand writes its own quips and names."
        switch availability {
        case .available:
            return nil
        case .notEligible:
            return ("Not available on this \(device)", "This \(device) can’t run Apple Intelligence, so AgentLand writes its own quips and names.")
        case .turnedOff:
            let place = device == "Mac" ? "System Settings" : "Settings"
            return ("Apple Intelligence is off", "Turn on Apple Intelligence in \(place) → Apple Intelligence & Siri. " + meanwhile)
        case .notReady:
            return ("Apple Intelligence is getting ready", "Its model is still downloading or getting ready. " + meanwhile)
        case .unavailable:
            return ("Apple Intelligence is unavailable", "Apple Intelligence can’t be used right now. " + meanwhile)
        }
    }
}
