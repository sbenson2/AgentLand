import SwiftUI
import AgentLandBranding
import AgentLandDesign

/// The empty conversation keeps Home's title, circus and current quip above the existing composer.
/// Artwork yields to the keyboard and large text sizes; the composer belongs to ChatScreen.
struct PlainChatLanding: View {
    /// The tent's flag and the clown move (the tab is in front, active and unlocked).
    let animated: Bool
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(\.agentLandArtwork) private var artwork
    @ObservedObject private var quips = QuipStore.shared
    @State private var promptSize = CGSize(width: 240, height: 34)

    var body: some View {
        GeometryReader { geometry in
            let titleScale = min(0.82, max(0.48, (geometry.size.width - 24) / AgentLandTitleBlock.canvas.width))
            let placement = PlainChatLandingLayout(frame: geometry.frame(in: .global), artwork: artwork,
                                                   prompt: promptSize, titleSize: AgentLandTitleBlock.designSize(scale: titleScale))
            if let title = placement.titleFrame {
                AgentLandWordmark(color: AgentLandColor.artInk.color, active: animated,
                                  referenceDate: artwork.referenceDate, onTap: quips.advance, tonalArt: true)
                    .frame(width: title.width, height: title.height)
                    .position(x: title.midX, y: title.midY)
                    .accessibilityIdentifier("plainChatWordmark")
            }
            if let scale = placement.tentScale {
                // The clown comes out of the door at the workspace's reveal, as on Home.
                AgentLandCircusLoading(showsClown: true, animated: animated, markColor: AgentLandColor.artInk.color,
                                       workSurface: true, referenceDate: artwork.referenceDate, backdrop: AgentLandColor.artBackdrop.color,
                                       revealedAt: workspace.circusRevealedAt ?? .distantFuture)
                    .scaleEffect(scale)
                    .frame(width: PlainChatLandingLayout.sceneSize.width * scale, height: PlainChatLandingLayout.sceneSize.height * scale)
                    .position(placement.tentCenter)
                    .accessibilityHidden(true)
            }
            quip
                .foregroundStyle(AgentLandColor.artInkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: max(0, geometry.size.width - 48))
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { promptSize = $0 }
                .position(placement.promptCenter)
                .accessibilityIdentifier("plainChatPrompt")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plainChatLanding")
        .background(AgentLandColor.artBackdrop)
        .onChange(of: animated, initial: true) { _, active in if active { workspace.circusShown() } }
    }
    @ViewBuilder private var quip: some View {
        if WorkspacePlatform.isPhone {
            HomePhoneQuip(text: quips.current, active: animated, referenceDate: artwork.referenceDate)
        } else {
            Text(quips.current).agentLandFont(.quip)
        }
    }

}

/// The title, circus and quip fit above the composer. The title yields first in a short frame, then the
/// circus shrinks or disappears; the quip remains readable. Coordinates are local to the landing.
struct PlainChatLandingLayout: Equatable {
    /// The circus stage's size at scale 1.
    static let sceneSize = AgentLandCircusLoading.stageSize
    /// From the scene's centre to the top of what it draws, and to the foot of the tent, at scale 1.
    static let aboveCentre: CGFloat = 180
    static let belowCentre: CGFloat = 126
    /// Between the circus and the quip.
    static let gap: CGFloat = 20
    /// Kept clear at the frame's top and bottom.
    static let margin: CGFloat = 12
    /// A tent drawn smaller than this is left out.
    static let smallestScale: CGFloat = 0.3

    /// The title yields when the keyboard leaves too little room.
    let titleFrame: CGRect?
    let tentScale: CGFloat?
    let tentCenter: CGPoint
    let promptCenter: CGPoint

    init(frame: CGRect, artwork: AgentLandArtworkLayout, prompt: CGSize, titleSize: CGSize = .zero) {
        let titleTop: CGFloat = 30
        let titleGap: CGFloat = 16
        let titleSpace = titleTop + titleSize.height + titleGap
        let minimumScene = (Self.aboveCentre + Self.belowCentre) * Self.smallestScale
        let showsTitle = titleSize.height > 0 && frame.height >= titleSpace + minimumScene + Self.gap + prompt.height + 2 * Self.margin
        titleFrame = showsTitle ? CGRect(x: (frame.width - titleSize.width) / 2, y: titleTop,
                                        width: titleSize.width, height: titleSize.height) : nil
        let contentTop = showsTitle ? titleSpace : 0
        let availableHeight = max(0, frame.height - contentTop)
        let anchor = artwork.center(in: frame)
        let scale = artwork.scale
        let promptY = anchor.y + Self.belowCentre * scale + Self.gap + prompt.height / 2
        let fits = anchor.y - Self.aboveCentre * scale >= contentTop && promptY + prompt.height / 2 <= frame.height - Self.margin
        if fits, artwork.windowFrame.height > 0 {
            tentScale = scale
            tentCenter = anchor
            promptCenter = CGPoint(x: anchor.x, y: promptY)
            return
        }
        // Fit the circus and quip into the space beneath the title.
        let x = artwork.windowFrame.width > 0 ? anchor.x : frame.width / 2
        let room = availableHeight - 2 * Self.margin - Self.gap - prompt.height
        let fitted = min(scale > 0 ? scale : 1, room / (Self.aboveCentre + Self.belowCentre))
        if fitted >= Self.smallestScale {
            let top = contentTop + (availableHeight - ((Self.aboveCentre + Self.belowCentre) * fitted + Self.gap + prompt.height)) / 2
            tentScale = fitted
            tentCenter = CGPoint(x: x, y: top + Self.aboveCentre * fitted)
            promptCenter = CGPoint(x: x, y: tentCenter.y + Self.belowCentre * fitted + Self.gap + prompt.height / 2)
        } else {
            tentScale = nil
            tentCenter = CGPoint(x: x, y: contentTop + availableHeight / 2)
            promptCenter = CGPoint(x: x, y: contentTop + availableHeight / 2)
        }
    }
}
