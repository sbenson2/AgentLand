import SwiftUI

/// Icon boxes that grow with Dynamic Type (`@ScaledMetric`), for aligning symbols and small images in a
/// column. SF Symbols scale with their font; the box keeps a row of them aligned as they do.
public enum AgentLandIconSize: String, CaseIterable, Sendable {
    /// 16 pt at the default text size, scaled like footnote text.
    case small
    /// 20 pt, scaled like body text.
    case regular
    /// 28 pt, scaled like title2 text.
    case large

    public var baseSide: CGFloat {
        switch self {
        case .small: 16
        case .regular: 20
        case .large: 28
        }
    }

    public var relativeTo: Font.TextStyle {
        switch self {
        case .small: .footnote
        case .regular: .body
        case .large: .title2
        }
    }
}

/// Row minimum heights that grow with body text (`@ScaledMetric`) and never fall below the minimum
/// tap target.
public enum AgentLandRowHeight: String, CaseIterable, Sendable {
    /// One line: 44 pt on iPhone and iPad and 28 pt on Mac at the default size.
    case standard
    /// A title and a detail line: 60 pt on iPhone and iPad and 40 pt on Mac.
    case twoLine

    public var baseHeight: CGFloat {
        #if os(macOS)
        self == .standard ? 28 : 40
        #else
        self == .standard ? 44 : 60
        #endif
    }
}

public extension View {
    /// A square frame for an icon that grows with Dynamic Type.
    func agentLandIconFrame(_ size: AgentLandIconSize = .regular, alignment: Alignment = .center) -> some View {
        modifier(ScaledIconFrame(size: size, alignment: alignment))
    }

    /// A minimum row height that grows with Dynamic Type and keeps the minimum tap target.
    func agentLandRowHeight(_ height: AgentLandRowHeight = .standard, alignment: Alignment = .leading) -> some View {
        modifier(ScaledRowHeight(height: height, alignment: alignment))
    }
}

struct ScaledIconFrame: ViewModifier {
    @ScaledMetric private var side: CGFloat
    private let alignment: Alignment

    init(size: AgentLandIconSize, alignment: Alignment) {
        _side = ScaledMetric(wrappedValue: size.baseSide, relativeTo: size.relativeTo)
        self.alignment = alignment
    }

    func body(content: Content) -> some View {
        content.frame(width: side, height: side, alignment: alignment)
    }
}

struct ScaledRowHeight: ViewModifier {
    @ScaledMetric private var height: CGFloat
    @Environment(\.agentLandMinimumTapTarget) private var minimum
    private let alignment: Alignment

    init(height: AgentLandRowHeight, alignment: Alignment) {
        _height = ScaledMetric(wrappedValue: height.baseHeight, relativeTo: .body)
        self.alignment = alignment
    }

    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity, minHeight: max(minimum, height), alignment: alignment)
    }
}
