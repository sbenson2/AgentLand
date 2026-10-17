import SwiftUI
import AgentLandBranding
import AgentLandDesign
#if os(iOS)
import UIKit
#endif

/// The app's version and build, as Settings → About shows them.
public var agentLandAppVersion: String {
    let info = Bundle.main.infoDictionary ?? [:]
    let version = info["CFBundleShortVersionString"] as? String ?? "0.1.0"
    let build = info["CFBundleVersion"] as? String ?? "1"
    return "\(version) (\(build))"
}

/// About AgentLand: the version, this device and its system (each once in Settings), what's new, and the
/// notice of every open-source part AgentLand ships, each on a page of its own.
public struct AboutSettingsPane: View {
    public init() {}

    public var body: some View {
        AgentLandForm {
            Section("AgentLand") {
                LabeledContent("Version", value: agentLandAppVersion)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("aboutVersion")
            }
            Section("This \(Self.deviceKind)") {
                LabeledContent("Name", value: Self.deviceName).accessibilityElement(children: .combine)
                LabeledContent("System", value: Self.systemVersion).accessibilityElement(children: .combine)
            }
            Section("What’s new") {
                ForEach(Self.whatsNew, id: \.self) { line in
                    Text(line).accessibilityIdentifier("aboutWhatsNew")
                }
            }
            Section {
                ForEach(Self.notices) { notice in
                    NavigationLink {
                        LicenceTextPage(notice: notice)
                    } label: {
                        VStack(alignment: .leading, spacing: AgentLandSpacing.xxxSmall) {
                            Text(notice.name)
                            Text(notice.licence).agentLandFont(.metadata).foregroundStyle(AgentLandColor.textSecondary)
                        }
                    }
                    .accessibilityLabel(notice.name)
                    .accessibilityValue(notice.licence)
                    .accessibilityIdentifier(notice.identifier)
                }
            } header: {
                Text("Open source")
            } footer: {
                // A text style of its own, the one the system gives a form's footer (Xcode's Dynamic Type audit, run
                // 1791351089, read this footer as not growing at all).
                Text("AgentLand uses these parts under their licences. Each page shows the full notice.")
                    #if os(iOS)
                    .font(.footnote)
                    #endif
            }
        }
        .settingsForm()
        #if os(iOS)
        // Room under the last footer, so it stays in the Settings panel's view while larger text pushes the page down
        // (Xcode's Dynamic Type audit, run 1791344878, found it "unsupported" at the panel's lower edge, where it left the
        // view at the first larger size).
        .contentMargins(.bottom, AgentLandSpacing.xxLarge * 2, for: .scrollContent)
        #endif
    }

    /// What this version brings, in a few lines.
    static let whatsNew = [
        "Settings has one place for everything: your Mac first, then this app.",
        "New: a default model for chats, open tool details, long pastes as files, the terminal’s own text size, cursor, key bar and bell, notification sound, hiding AgentLand in the app switcher, forgetting a Mac and clearing this device’s copy of its chats.",
        "Chat runs Claude Code and Codex in your workspace, on your Claude and ChatGPT subscriptions."
    ]

    #if os(iOS)
    static var deviceKind: String { UIDevice.current.model }
    static var deviceName: String { UIDevice.current.name }
    static var systemVersion: String { UIDevice.current.systemName + " " + UIDevice.current.systemVersion }
    #else
    static var deviceKind: String { "Mac" }
    static var deviceName: String { Host.current().localizedName ?? "This Mac" }
    static var systemVersion: String { "macOS " + ProcessInfo.processInfo.operatingSystemVersionString }
    #endif

    /// Every notice the app carries: SwiftTerm, GRDB and iroh's in the app's bundle, and the title's open-licence
    /// faces' in the branding package. A notice whose file is missing still shows its licence by name.
    static var notices: [OpenSourceNotice] {
        var notices = [
            OpenSourceNotice(id: "swiftterm", name: "SwiftTerm", licence: "MIT License", identifier: "aboutSwiftTermNotice",
                             url: Bundle.main.url(forResource: "SwiftTerm-LICENSE", withExtension: "txt")),
            OpenSourceNotice(id: "grdb", name: "GRDB", licence: "MIT License", identifier: "aboutGRDBNotice",
                             url: Bundle.main.url(forResource: "GRDB-LICENSE", withExtension: "txt"))
        ]
        if let iroh = irohNoticeURL {
            notices.append(OpenSourceNotice(id: "iroh", name: "iroh", licence: "MIT or Apache 2.0, and its crates’ licences",
                                            identifier: "aboutIrohNotices", url: iroh,
                                            summary: "AgentLand reaches your Mac from anywhere through iroh, built from pinned source with the crates it links, each under its own licence."))
        }
        for face in AgentLandWordmarkFaces.all where face.licenceURL != nil {
            notices.append(OpenSourceNotice(id: face.id, name: face.displayName, licence: "SIL Open Font License 1.1",
                                            identifier: "aboutFontNotice-\(face.id)", url: face.licenceURL,
                                            summary: "One of the faces of the title on Home."))
        }
        return notices
    }

    /// The notices of the iroh library's crates (scripts/collect-iroh-ffi-notices.py), in the bundle of an
    /// app that links it.
    static var irohNoticeURL: URL? { Bundle.main.url(forResource: "IrohLib-NOTICES", withExtension: "txt") }
}

/// An open-source part and where its notice is.
struct OpenSourceNotice: Identifiable, Hashable {
    let id: String
    let name: String
    let licence: String
    let identifier: String
    let url: URL?
    var summary: String?
}

/// A notice's full text, read when the page opens and laid out a paragraph at a time as it scrolls.
struct LicenceTextPage: View {
    let notice: OpenSourceNotice
    @State private var paragraphs: [String]?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AgentLandSpacing.xSmall) {
                if let summary = notice.summary {
                    Text(summary)
                        .agentLandFont(.body)
                        .foregroundStyle(AgentLandColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, AgentLandSpacing.xSmall)
                }
                if let paragraphs {
                    ForEach(paragraphs.indices, id: \.self) { index in
                        Text(paragraphs[index])
                            .agentLandFont(.metadata)
                            .foregroundStyle(AgentLandColor.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, AgentLandSpacing.medium)
            .padding(.vertical, AgentLandSpacing.large)
        }
        .groupedPageBackground()
        .accessibilityIdentifier("licenceText")
        .workspaceSettingsPage(notice.name)
        .task {
            guard paragraphs == nil else { return }
            let url = notice.url, name = notice.name, licence = notice.licence
            paragraphs = await Task.detached(priority: .utility) {
                guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
                    return ["\(name) is distributed under the \(licence). Its licence is included with AgentLand."]
                }
                return text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }.value
        }
    }
}

/// Appearance: the device's, light or dark, saved as `agentland.appearance`, chosen from a checkmarked list as the
/// Settings app's choices are. The app defaults to Dark, including Reset Appearance
/// (owner's follow-up, 2026-10-09); a saved choice is kept.
public struct AppearanceSettingsPane: View {
    @AppStorage("agentland.appearance") private var appearance = "dark"

    public init() {}

    public var body: some View {
        AgentLandForm {
            Section("Theme") {
                ForEach([("System", "system"), ("Light", "light"), ("Dark", "dark")], id: \.1) { title, value in
                    SettingsChoiceRow(title, selected: appearance == value) { appearance = value }
                        .accessibilityIdentifier("appearanceOption-\(value)")
                }
            }
            Section {
                Button { appearance = "dark" } label: { ActionRowLabel("Reset Appearance") }
                    .accessibilityIdentifier("appearanceReset")
            }
        }
        .settingsForm()
        .agentLandHaptic(.selection, trigger: appearance)
    }
}

/// One choice of several, as the Settings app lists them: its title (and a line under it), and the accent's checkmark
/// on the one chosen. A tap chooses it; VoiceOver reads it selected.
public struct SettingsChoiceRow: View {
    let title: String
    let detail: String?
    let selected: Bool
    let choose: () -> Void

    public init(_ title: String, detail: String? = nil, selected: Bool, choose: @escaping () -> Void) {
        self.title = title; self.detail = detail; self.selected = selected; self.choose = choose
    }

    public var body: some View {
        Button(action: choose) {
            HStack(spacing: AgentLandSpacing.small) {
                VStack(alignment: .leading, spacing: AgentLandSpacing.xxxSmall) {
                    Text(title).foregroundStyle(AgentLandColor.text)
                    if let detail {
                        Text(detail).agentLandFont(.secondary).foregroundStyle(AgentLandColor.textSecondary)
                    }
                }
                Spacer(minLength: AgentLandSpacing.small)
                if selected {
                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint).accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

public extension View {
    /// A Settings page's form: `AgentLandForm { Section { … } header: { … } footer: { … } }` in the grouped style, on
    /// the page its surroundings give it (the header panel's raised paper or slate on iPhone, the drawer's on iPad) with
    /// paper or slate rows and separators (owner's choice, 2026-10-07), and paper and slate behind it on the Mac.
    func settingsForm() -> some View {
        formStyle(.grouped).listPageBackground()
    }

    /// A change's outcome on a Settings page (`WorkspaceNotice`), the native way on iPhone and iPad (owner's decision,
    /// 2026-10-06): a failure or a warning in the system's alert, which OK puts away (`dismiss`); a plain success shows
    /// nothing beyond the rows' own state. The Mac shows its notices in the page as before (`InlineNotice`).
    func settingsNoticeAlert(_ notice: WorkspaceNotice?, dismiss: @escaping () -> Void) -> some View {
        modifier(SettingsNoticeAlert(notice: notice, dismiss: dismiss))
    }
}

private struct SettingsNoticeAlert: ViewModifier {
    let notice: WorkspaceNotice?
    let dismiss: () -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        let shown = notice?.tone == .success ? nil : notice
        content.alert(shown?.title ?? "", isPresented: Binding(get: { shown != nil }, set: { if !$0 { dismiss() } }),
                      presenting: shown) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            if let message = notice.message { Text(message) }
        }
        #else
        content
        #endif
    }
}

/// A row's title and symbol, for a row button or a navigation row: on iPhone both in the system's label colour (white
/// in Dark), as the Settings app draws an action row that is not destructive, secondary while the row is disabled.
/// iPad and the Mac keep the button's own tint (native-full side build, 2026-10-16; the owner asked for white symbols
/// in the Workspace and Settings tabs the same day).
public struct ActionRowLabel: View {
    @Environment(\.isEnabled) private var isEnabled
    private let title: String
    private let systemImage: String?

    public init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    public var body: some View {
        if let systemImage {
            Label { titleText } icon: { Image(systemName: systemImage).rowIconStyle() }
        } else {
            titleText
        }
    }

    @ViewBuilder private var titleText: some View {
        if WorkspacePlatform.isPhone {
            Text(title).foregroundStyle(isEnabled ? AgentLandColor.text : AgentLandColor.textSecondary)
        } else {
            Text(title)
        }
    }
}

public extension View {
    /// A row's symbol on iPhone in the label colour, white in Dark (owner, 2026-10-16: "white ios native icons"),
    /// secondary while the row is disabled; iPad and the Mac keep the list's accent.
    @ViewBuilder func rowIconStyle() -> some View {
        if WorkspacePlatform.isPhone { modifier(PhoneRowIcon()) } else { self }
    }
}

private struct PhoneRowIcon: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    func body(content: Content) -> some View {
        content.foregroundStyle(isEnabled ? AgentLandColor.text : AgentLandColor.textSecondary)
    }
}

/// A state a Settings page shows in place, the native way (owner's decision, 2026-10-06): the host isn't connected, a
/// read failed. A row with the state's symbol in orange and its title, what it means in the section's footer, and the
/// one button that helps, when one does.
public struct SettingsStatusSection: View {
    let title: String
    let systemImage: String
    let message: String?
    let identifier: String
    let actionTitle: String?
    let actionIdentifier: String?
    let action: (() -> Void)?

    public init(_ title: String, systemImage: String, message: String? = nil, identifier: String,
                actionTitle: String? = nil, actionIdentifier: String? = nil, action: (() -> Void)? = nil) {
        self.title = title; self.systemImage = systemImage; self.message = message; self.identifier = identifier
        self.actionTitle = actionTitle; self.actionIdentifier = actionIdentifier; self.action = action
    }

    public var body: some View {
        Section {
            Label {
                Text(title).foregroundStyle(AgentLandColor.text)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(AgentLandColor.warning)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier)
            .listRowFill(.surface)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .accessibilityIdentifier(actionIdentifier ?? identifier + "Action")
                    .listRowFill(.surface)
            }
        } footer: {
            if let message {
                Text(message).agentLandFont(.metadata).foregroundStyle(AgentLandColor.textSecondary)
            }
        }
    }
}

/// The label of a row's … menu: on iPhone and iPad the system's `ellipsis.circle` in the accent, as the Settings app
/// draws it; the Mac keeps its ellipsis in the text color. At least the minimum tap target either way.
public struct SettingsMenuLabel: View {
    public init() {}

    public var body: some View {
        Group {
            #if os(iOS)
            Label("Actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly).foregroundStyle(.tint)
            #else
            Image(systemName: "ellipsis").foregroundStyle(AgentLandColor.text)
            #endif
        }
        .font(AgentLandTypeRole.body.font)
        .frame(minWidth: AgentLandTapTarget.platformMinimum, minHeight: AgentLandTapTarget.platformMinimum)
        .contentShape(Rectangle())
    }
}

/// A switch row: its title, and under it what it does, as the Settings app's switches show it (the form shows the
/// second text as the row's subtitle, and VoiceOver reads both).
public struct SettingsToggleRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool
    public init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title; self.detail = detail; _isOn = isOn
    }
    public var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
            if let detail { Text(detail) }
        }
    }
}
