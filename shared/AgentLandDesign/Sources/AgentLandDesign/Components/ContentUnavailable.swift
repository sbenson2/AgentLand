import SwiftUI

/// `ContentUnavailableView` with an optional primary action. On iPhone and iPad it keeps the system's own colors;
/// the Mac draws it in AgentLand's (primary text in `text`, the symbol and description in `textSecondary`, actions
/// in the tint).
public struct ContentUnavailable<Actions: View>: View {
    private let title: String
    private let systemImage: String
    private let description: String?
    private let descriptionIdentifier: String?
    private let actions: Actions

    /// `descriptionIdentifier` goes on the description's text, for UI automation.
    public init(_ title: String, systemImage: String, description: String? = nil, descriptionIdentifier: String? = nil,
                @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.descriptionIdentifier = descriptionIdentifier
        self.actions = actions()
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let description {
                if let descriptionIdentifier {
                    Text(description).accessibilityIdentifier(descriptionIdentifier)
                } else {
                    Text(description)
                }
            }
        } actions: {
            actions
        }
        .agentLandUnavailableStyle()
    }
}

public extension ContentUnavailable where Actions == EmptyView {
    init(_ title: String, systemImage: String, description: String? = nil) {
        self.init(title, systemImage: systemImage, description: description) { EmptyView() }
    }

    /// The system's "no results" view for a search.
    static func search(text: String) -> some View {
        ContentUnavailableView.search(text: text).agentLandUnavailableStyle()
    }
}

public extension ContentUnavailable where Actions == ContentUnavailablePrimaryAction {
    init(_ title: String, systemImage: String, description: String? = nil,
         actionTitle: String, action: @escaping () -> Void) {
        self.init(title, systemImage: systemImage, description: description) {
            ContentUnavailablePrimaryAction(title: actionTitle, action: action)
        }
    }
}

/// The single primary button of a `ContentUnavailable`.
public struct ContentUnavailablePrimaryAction: View {
    let title: String
    let action: () -> Void

    public var body: some View {
        Button(title, action: action).buttonStyle(.agentLandPrimary)
    }
}

extension View {
    /// The Mac's colors for `ContentUnavailableView`; iPhone and iPad keep the system's.
    @ViewBuilder func agentLandUnavailableStyle() -> some View {
        #if os(macOS)
        foregroundStyle(AgentLandColor.text, AgentLandColor.textSecondary)
            .tint(AgentLandColor.tint)
        #else
        self
        #endif
    }
}

#Preview("Content unavailable") {
    VStack {
        ContentUnavailable("No chats yet", systemImage: "bubble.left.and.bubble.right",
                           description: "Start a chat from Home.")
        ContentUnavailable("Can’t reach Studio Mac", systemImage: "wifi.exclamationmark",
                           description: "Your chats are kept on this iPhone.", actionTitle: "Retry", action: {})
    }
    .background(AgentLandColor.canvas)
}
