import Foundation

/// The text of a notice's push alert.
///
/// - Title: one per kind (`NoticeKind.titleLocalizationKey`), e.g. "Reply
///   ready". The subscription names the key; iOS looks it up in the app's
///   `Localizable` table on the device.
/// - Body: "<title> · <project>", or the project alone when the notice has no
///   title (none issued, or left out by "Include chat titles"). The Mac
///   composes it into the record's `alertBody` field, and the subscription's
///   `alertLocalizationKey` (`notice.body`, "%@") shows that field. A body built
///   on the device from two fields would show an empty title when the record
///   has none, so the Mac picks the form.
///
/// The format strings live in this package's `Localizable.xcstrings`. The iOS
/// app must carry `appLocalizationKeys` with the same text in its own
/// `Localizable.xcstrings`, because iOS resolves a push's localization keys in
/// the app's main bundle only; `keysMissingOrDifferent(in:)` checks that.
public enum NoticeAlertText {
    /// CloudKit may cut a string longer than 100 characters when it copies a
    /// field into a push, so `alertBody` stays within this many UTF-16 units.
    public static let pushValueLimit = 100
    /// The project name's share of the body, in UTF-16 units.
    public static let projectNameLimit = 40
    /// The key the subscriptions use for the body; its value is "%@".
    public static let bodyLocalizationKey = "notice.body"
    static let bodyFormatKey = "notice.body.titleAndProject"
    static let testTitleKey = "notice.test.title"

    /// Every key a subscription names: the four titles and the body. The iOS
    /// app's `Localizable.xcstrings` must contain all of them.
    public static var appLocalizationKeys: [String] {
        NoticeKind.allCases.map(\.titleLocalizationKey) + [bodyLocalizationKey]
    }

    /// The title of the notice "Send Test Notification" writes.
    public static var testTitle: String { localized(testTitleKey) }

    /// The alert body for a title (nil or empty when there is none) and a
    /// project name, at most `pushValueLimit` UTF-16 units.
    public static func body(title: String?, projectName: String) -> String {
        let project = truncated(singleLine(projectName), limit: projectNameLimit)
        let title = singleLine(title ?? "")
        guard !title.isEmpty else { return truncated(project, limit: pushValueLimit) }
        guard !project.isEmpty else { return truncated(title, limit: pushValueLimit) }
        let format = localized(bodyFormatKey)
        let fixed = String(format: format, "", "").utf16.count
        let titleLimit = pushValueLimit - fixed - project.utf16.count
        return String(format: format, truncated(title, limit: titleLimit), project)
    }

    /// Keys of `appLocalizationKeys` that `bundle` lacks or words differently
    /// from this package, both in this process's language. An app test can
    /// assert that `keysMissingOrDifferent(in: .main)` is empty.
    public static func keysMissingOrDifferent(in bundle: Bundle) -> [String] {
        appLocalizationKeys.filter { key in
            let missing = "\u{1}missing\u{1}"
            let value = bundle.localizedString(forKey: key, value: missing, table: nil)
            return value == missing || value != localized(key)
        }
    }

    /// A key's text from this package's catalog.
    public static func localized(_ key: String) -> String {
        let missing = "\u{1}missing\u{1}"
        let value = Bundle.module.localizedString(forKey: key, value: missing, table: nil)
        return value != missing ? value : catalog[key] ?? key
    }

    /// Xcode compiles the String Catalog into `Localizable.strings`; SwiftPM
    /// on the command line (`swift test`) copies the catalog into the resource
    /// bundle as it is. Then the catalog itself is read, in the preferred
    /// language it has, else its source language.
    private static let catalog: [String: String] = {
        guard let url = Bundle.module.url(forResource: "Localizable", withExtension: "xcstrings"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = root["strings"] as? [String: [String: Any]] else { return [:] }
        let source = root["sourceLanguage"] as? String ?? "en"
        func value(_ entry: [String: Any], _ language: String) -> String? {
            let localizations = entry["localizations"] as? [String: [String: Any]]
            let unit = localizations?[language]?["stringUnit"] as? [String: Any]
            return unit?["value"] as? String
        }
        let languages = Set(strings.values.flatMap { ($0["localizations"] as? [String: Any]).map { Array($0.keys) } ?? [] })
        let language = Bundle.preferredLocalizations(from: Array(languages)).first ?? source
        return strings.compactMapValues { value($0, language) ?? value($0, source) }
    }()

    /// One line: control characters and line breaks become spaces, runs of
    /// white space collapse, and the ends are trimmed.
    static func singleLine(_ text: String) -> String {
        var result = ""
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) {
                pendingSpace = !result.isEmpty
                continue
            }
            if pendingSpace { result.append(" "); pendingSpace = false }
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    /// `text` cut at a character boundary so that it and a closing ellipsis
    /// fit in `limit` UTF-16 units; unchanged when it fits already.
    static func truncated(_ text: String, limit: Int) -> String {
        guard text.utf16.count > limit else { return text }
        guard limit > 1 else { return limit == 1 ? "…" : "" }
        var result = ""
        for character in text {
            guard result.utf16.count + character.utf16.count + 1 <= limit else { break }
            result.append(character)
        }
        while result.last?.isWhitespace == true { result.removeLast() }
        return result + "…"
    }
}
