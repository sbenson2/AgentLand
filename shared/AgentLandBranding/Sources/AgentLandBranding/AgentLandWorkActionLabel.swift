import SwiftUI

/// The same compact launcher control on Mac, iPhone, and iPad.
public struct AgentLandWorkActionLabel: View {
    public let title: String
    public let symbol: String
    public let showsDisclosure: Bool

    public init(_ title: String, symbol: String, showsDisclosure: Bool = false) {
        self.title = title
        self.symbol = symbol
        self.showsDisclosure = showsDisclosure
    }

    public var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(AgentLandTheme.muted)
                .frame(width: 20)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
            if showsDisclosure {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(AgentLandTheme.muted)
            }
        }
        .foregroundStyle(AgentLandTheme.foreground)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(AgentLandTheme.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(AgentLandTheme.line, lineWidth: 1))
        .contentShape(Rectangle())
    }
}
