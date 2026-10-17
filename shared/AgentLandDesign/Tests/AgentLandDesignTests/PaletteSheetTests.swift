import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import AgentLandBranding
@testable import AgentLandDesign

/// Writes the palette sheet for the slate brand: the opening cover, a Home-like screen (the real tent,
/// clown frame 0 and arched title over a 2×3 grid of `ActionTile`s), a chat-like screen (user bubble,
/// reply, tool row, glass composer) and a settings-like grouped list, in light and dark. Runs only with
/// `AGENTLAND_DESIGN_EVIDENCE=1`; writes `.evidence/design-system-20260924/`.
@MainActor
final class PaletteSheetTests: XCTestCase {
    static let folderName = "design-system-20260924"

    func testWritePaletteSheet() throws {
        guard ProcessInfo.processInfo.environment["AGENTLAND_DESIGN_EVIDENCE"] == "1" else {
            throw XCTSkip("Set AGENTLAND_DESIGN_EVIDENCE=1 to write the palette sheet")
        }
        XCTAssertFalse(AgentLandClownArtwork.frames(.day).isEmpty, "the packaged clown frames load")
        XCTAssertNotNil(AgentLandWordmark.restingImage(color: CGColor(gray: 1, alpha: 1)), "the title renders")
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let folder = repository.appendingPathComponent(".evidence").appendingPathComponent(Self.folderName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for panel in SheetPanel.all {
            try write(panel.view, scale: 2, to: folder.appendingPathComponent("slate-\(panel.slug).png"))
        }
        try write(PaletteSheet(), scale: 1.5, to: folder.appendingPathComponent("palette-sheet.png"))
    }

    private func write<V: View>(_ view: V, scale: CGFloat, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.cgImage, "nothing rendered for \(url.lastPathComponent)")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        print("Wrote \(url.path) (\(image.width)×\(image.height) px)")
    }
}

// MARK: - Panels

@MainActor
private struct SheetPanel {
    static let size = CGSize(width: 390, height: 700)

    let caption: String
    let slug: String
    let view: AnyView

    static var all: [SheetPanel] {
        var panels = [SheetPanel(caption: "Opening cover", slug: "cover", view: AnyView(CoverPanel().panelFrame()))]
        for appearance in [AgentLandAppearance.light, .dark] {
            let name = appearance.isDark ? "dark" : "light"
            panels.append(SheetPanel(caption: "Home, \(name)", slug: "home-\(name)",
                                     view: AnyView(HomePanel(appearance: appearance).panel(appearance))))
        }
        for appearance in [AgentLandAppearance.light, .dark] {
            let name = appearance.isDark ? "dark" : "light"
            panels.append(SheetPanel(caption: "Chat, \(name)", slug: "chat-\(name)",
                                     view: AnyView(ChatPanel().panel(appearance))))
        }
        for appearance in [AgentLandAppearance.light, .dark] {
            let name = appearance.isDark ? "dark" : "light"
            panels.append(SheetPanel(caption: "Settings, \(name)", slug: "settings-\(name)",
                                     view: AnyView(SettingsPanel().panel(appearance))))
        }
        return panels
    }
}

private extension View {
    /// An iPhone-width panel in one appearance, with iPhone tap targets.
    func panel(_ appearance: AgentLandAppearance) -> some View {
        self
            .environment(\.colorScheme, appearance.isDark ? .dark : .light)
            .environment(\._colorSchemeContrast, appearance.increasedContrast ? .increased : .standard)
            .environment(\.agentLandMinimumTapTarget, AgentLandTapTarget.iOSMinimum)
            .environment(\.agentLandAnnouncer, AgentLandAnnouncer { _, _ in })
            .panelFrame()
    }

    func panelFrame() -> some View {
        frame(width: SheetPanel.size.width, height: SheetPanel.size.height).clipped()
    }
}

/// The circus as Home draws it at rest (Reduce Motion or UI tests): the tent with its dark doorway and
/// clown frame 0 in front of it at the orbit's start, optionally with the arched title and a quip, in
/// circus scene units (336 × 360, tent centred at (168, 180)) times `scale`.
private struct CircusArt: View {
    let ink: Color
    let background: Color
    /// The clown's tones: the day ramp on the light paper, the night ramp on slate.
    var ramp: AgentLandClownRamp = .night
    var showsTitle = true
    var quip: String?
    var quipColor: Color = .clear
    let scale: CGFloat

    /// The scene's top in scene units: the title's canvas starts above the circus.
    static var top: CGFloat { min(0, AgentLandWordmark.canvas.minY) }
    static var height: CGFloat { 360 - top }

    var body: some View {
        let top = showsTitle ? Self.top : 0
        ZStack(alignment: .topLeading) {
            if showsTitle { title(top: top) }
            AgentLandTentMark(side: 252 * scale, elapsed: nil, color: ink)
                .offset(x: 42 * scale, y: (54 - top) * scale)
            clown(top: top)
        }
        .frame(width: 336 * scale, height: (360 - top) * scale, alignment: .topLeading)
    }

    @ViewBuilder private func title(top: CGFloat) -> some View {
        let canvas = AgentLandWordmark.canvas
        if let image = AgentLandWordmark.restingImage(color: CGColor(gray: 1, alpha: 1)) {
            Image(decorative: image, scale: 1)
                .renderingMode(.template)
                .resizable()
                .interpolation(.none)
                .foregroundStyle(ink)
                .frame(width: canvas.width * scale, height: canvas.height * scale)
                .offset(x: canvas.minX * scale, y: (canvas.minY - top) * scale)
        }
        if let quip {
            let centre = AgentLandWordmarkGeometry.quipCentre, size = AgentLandWordmarkGeometry.quipSize
            Text(quip)
                .agentLandFont(.quip)
                .foregroundStyle(quipColor)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: size.width * scale, height: size.height * scale)
                .offset(x: (centre.x - size.width / 2) * scale, y: (centre.y - size.height / 2 - top) * scale)
        }
    }

    @ViewBuilder private func clown(top: CGFloat) -> some View {
        let time: TimeInterval = 0
        let frames = AgentLandClownArtwork.frames(ramp), outlines = AgentLandClownArtwork.outlines
        if !frames.isEmpty {
            let index = AgentLandClownMotion.frameIndex(at: time, frameCount: frames.count)
            let centre = AgentLandClownMotion.orbitPosition(at: time)
            ZStack {
                if index < outlines.count, !AgentLandClownMotion.isBehind(at: time) {
                    sprite(outlines[index], side: 72, color: background)
                }
                Image(decorative: frames[index], scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 72 * scale, height: 72 * scale)
                ForEach(AgentLandClownMotion.juggling?.balls(at: time) ?? [], id: \.slot) { ball in
                    ballView(ball).offset(x: (ball.point.x - 48) * 0.75 * scale, y: (ball.point.y - 48) * 0.75 * scale)
                }
            }
            .frame(width: 72 * scale, height: 72 * scale)
            .scaleEffect(x: AgentLandClownMotion.isFacingLeft(at: time) ? -1 : 1, y: 1)
            .offset(x: (centre.x - 36) * scale, y: (centre.y - 36 - top) * scale)
        }
    }

    /// The app's ball: the tinted 16-pixel sprite in its spin frame inside a backdrop-coloured ring.
    private func ballView(_ ball: AgentLandJuggling.LocalBall) -> some View {
        ZStack {
            if let ring = AgentLandJugglingBall.ringFrame(for: ball.spinFrame) { sprite(ring, side: 12, color: background) }
            if let frame = AgentLandJugglingBall.tintedFrame(tint: ball.tint, spinFrame: ball.spinFrame) {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 12 * scale, height: 12 * scale)
            }
        }
    }

    private func sprite(_ image: CGImage, side: CGFloat, color: Color) -> some View {
        Image(decorative: image, scale: 1)
            .renderingMode(.template)
            .resizable()
            .interpolation(.none)
            .foregroundStyle(color)
            .frame(width: side * scale, height: side * scale)
    }
}

/// The opening cover: white art on the brand color, no title (it enters on Home), the circus at the
/// window anchor (centre at 0.46 of the height).
private struct CoverPanel: View {
    var body: some View {
        let scale: CGFloat = 0.92
        ZStack(alignment: .top) {
            AgentLandColor.brand.color(for: .light)
            CircusArt(ink: AgentLandColor.onBrand.color(for: .light), background: AgentLandColor.brand.color(for: .light),
                      showsTitle: false, scale: scale)
                .padding(.top, SheetPanel.size.height * 0.46 - 180 * scale)
        }
    }
}

/// Home: the title and quip over the circus at the cover's anchor, then the launcher tiles.
private struct HomePanel: View {
    let appearance: AgentLandAppearance

    var body: some View {
        let scale: CGFloat = 0.92
        let sceneTop = SheetPanel.size.height * 0.46 - 180 * scale
        VStack(spacing: AgentLandSpacing.large - AgentLandSpacing.xxSmall) {
            CircusArt(ink: AgentLandColor.artInk.color(for: appearance), background: AgentLandColor.artBackdrop.color(for: appearance),
                      ramp: appearance.isDark ? .night : .day, quip: "Juggling three pull requests", quipColor: AgentLandColor.artInkSecondary.color(for: appearance),
                      scale: scale)
            Grid(horizontalSpacing: AgentLandSpacing.xSmall, verticalSpacing: AgentLandSpacing.xSmall) {
                GridRow {
                    ActionTile("New chat", systemImage: "bubble.left.and.bubble.right", showsDisclosure: true)
                    ActionTile("New terminal", systemImage: "terminal", showsDisclosure: true)
                }
                GridRow {
                    ActionTile("Browse files", systemImage: "folder")
                    ActionTile("Resume work", systemImage: "clock.arrow.circlepath")
                }
                GridRow {
                    ActionTile("Open workspace", systemImage: "square.grid.2x2")
                    ActionTile("Pair a device", systemImage: "qrcode")
                }
            }
            .padding(.horizontal, AgentLandSpacing.large)
        }
        .padding(.top, sceneTop + CircusArt.top * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AgentLandColor.artBackdrop)
    }
}

/// A chat: a user bubble, a reply paragraph, a tool row and the glass composer.
private struct ChatPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AgentLandSpacing.medium) {
            VStack(alignment: .leading, spacing: AgentLandSpacing.xxxSmall) {
                Text("Fix the login redirect").agentLandFont(.heading3).foregroundStyle(AgentLandColor.text)
                Text("Claude Code · agentland").agentLandFont(.caption).foregroundStyle(AgentLandColor.textSecondary)
            }
            .padding(.bottom, AgentLandSpacing.xSmall)
            HStack {
                Spacer(minLength: 64)
                Text("Why does /login send me back to the sign-in page after I sign in?")
                    .agentLandFont(.body)
                    .foregroundStyle(AgentLandColor.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(AgentLandColor.surface, in: AgentLandRadius.shape(AgentLandRadius.bubble))
            }
            VStack(alignment: .leading, spacing: AgentLandSpacing.xSmall) {
                Label("Sonnet 4.5", systemImage: "bubble.left.and.text.bubble.right")
                    .agentLandFont(.caption)
                    .foregroundStyle(AgentLandColor.textSecondary)
                Text("The redirect loops because the session cookie is written after the redirect has already gone out, so the browser follows it without a session. Set the cookie before calling `redirect(to:)`.")
                    .agentLandFont(.body)
                    .foregroundStyle(AgentLandColor.text)
                    .lineSpacing(3)
            }
            HStack(spacing: AgentLandSpacing.xSmall) {
                Image(systemName: "terminal").foregroundStyle(AgentLandColor.textSecondary).agentLandIconFrame()
                Text("Ran `swift test`").agentLandFont(.secondary).foregroundStyle(AgentLandColor.text)
                Spacer(minLength: AgentLandSpacing.xSmall)
                Image(systemName: "checkmark.circle.fill").foregroundStyle(AgentLandColor.success)
                Text("Succeeded").agentLandFont(.metadata).foregroundStyle(AgentLandColor.textSecondary)
                Image(systemName: "chevron.right").agentLandFont(.caption).fontWeight(.semibold)
                    .foregroundStyle(AgentLandColor.glyphTertiary)
            }
            .padding(.horizontal, AgentLandSpacing.small)
            .agentLandRowHeight()
            .background(AgentLandColor.surface, in: AgentLandRadius.shape(AgentLandRadius.card))
            .overlay(AgentLandRadius.shape(AgentLandRadius.card).strokeBorder(AgentLandColor.separator, lineWidth: 1))
            Spacer(minLength: 0)
            GlassControlGroup {
                VStack(alignment: .leading, spacing: AgentLandSpacing.small) {
                    Text("Message Claude Code").agentLandFont(.body).foregroundStyle(AgentLandColor.textSecondary)
                    HStack(spacing: AgentLandSpacing.xSmall) {
                        Image(systemName: "plus").foregroundStyle(AgentLandColor.text).frame(width: 28, height: 28)
                        chip("Asks first")
                        chip("Sonnet 4.5 · High")
                        Spacer(minLength: 0)
                        Image(systemName: "mic").foregroundStyle(AgentLandColor.textSecondary).frame(width: 28, height: 28)
                        Image(systemName: "arrow.up")
                            .agentLandFont(.bodyEmphasized)
                            .foregroundStyle(AgentLandColor.onTint)
                            .frame(width: 32, height: 32)
                            .background(AgentLandColor.tint, in: Circle())
                    }
                }
                .padding(14)
                .glassControl(in: AgentLandRadius.shape(AgentLandRadius.composer))
            }
            // ImageRenderer draws nothing for content on Liquid Glass, so the sheet shows the composer
            // as it looks under Reduce Transparency.
            .environment(\._accessibilityReduceTransparency, true)
        }
        .padding(AgentLandSpacing.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AgentLandColor.canvas)
    }

    private func chip(_ title: String) -> some View {
        Text(title)
            .agentLandFont(.caption)
            .foregroundStyle(AgentLandColor.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(Capsule().strokeBorder(AgentLandColor.separator, lineWidth: 1))
    }
}

/// Settings: the app's card with its icon, then grouped rows.
private struct SettingsPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AgentLandSpacing.large - AgentLandSpacing.xxSmall) {
            Text("Settings").agentLandFont(.heading1).foregroundStyle(AgentLandColor.text)
            HStack(spacing: AgentLandSpacing.small) {
                AppIcon(side: 52)
                VStack(alignment: .leading, spacing: AgentLandSpacing.xxxSmall) {
                    Text("AgentLand").agentLandFont(.bodyEmphasized).foregroundStyle(AgentLandColor.text)
                    Text("Version 0.1.0 · Studio Mac").agentLandFont(.metadata).foregroundStyle(AgentLandColor.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(AgentLandSpacing.small)
            .background(AgentLandColor.surface, in: AgentLandRadius.shape(AgentLandRadius.card))
            .overlay(AgentLandRadius.shape(AgentLandRadius.card).strokeBorder(AgentLandColor.separator, lineWidth: 1))
            section("App") {
                row("General", systemImage: "gearshape") { chevron }
                divider
                row("Appearance", systemImage: "circle.lefthalf.filled") { value("System"); chevron }
                divider
                row("Haptics", systemImage: "hand.tap") { toggle(on: true) }
            }
            section("This device") {
                row("Require device unlock", systemImage: "lock") { toggle(on: true) }
                divider
                row("Connection", systemImage: "network") {
                    StatusDot(.online).accessibilityHidden(true)
                    value("Connected")
                    chevron
                }
                divider
                row("What’s new", systemImage: "sparkles") { Badge("New", style: .prominent); chevron }
            }
            section(nil) {
                row("Forget this Mac", systemImage: "trash", tint: AgentLandColor.danger) { EmptyView() }
            }
        }
        .padding(AgentLandSpacing.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AgentLandColor.canvas)
    }

    private func section<Content: View>(_ title: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AgentLandSpacing.xSmall - AgentLandSpacing.xxxSmall) {
            if let title {
                Text(title.uppercased()).agentLandFont(.metadata).foregroundStyle(AgentLandColor.textSecondary)
                    .padding(.leading, AgentLandSpacing.small)
            }
            VStack(spacing: 0) { content() }
                .background(AgentLandColor.surface, in: AgentLandRadius.shape(AgentLandRadius.card))
                .overlay(AgentLandRadius.shape(AgentLandRadius.card).strokeBorder(AgentLandColor.separator, lineWidth: 1))
        }
    }

    private func row<Accessory: View>(_ title: String, systemImage: String, tint: AgentLandColor? = nil,
                                      @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: AgentLandSpacing.small) {
            Image(systemName: systemImage)
                .foregroundStyle(tint ?? AgentLandColor.textSecondary)
                .agentLandIconFrame()
            Text(title).agentLandFont(.body).foregroundStyle(tint ?? AgentLandColor.text)
            Spacer(minLength: AgentLandSpacing.xSmall)
            accessory()
        }
        .padding(.horizontal, AgentLandSpacing.small)
        .agentLandRowHeight()
    }

    private var divider: some View {
        Rectangle().fill(AgentLandColor.separator).frame(height: 1).padding(.leading, 44)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").agentLandFont(.caption).fontWeight(.semibold)
            .foregroundStyle(AgentLandColor.glyphTertiary)
    }

    private func value(_ text: String) -> some View {
        Text(text).agentLandFont(.body).foregroundStyle(AgentLandColor.textSecondary)
    }

    /// A drawn switch (AppKit-backed controls don't render offscreen).
    private func toggle(on: Bool) -> some View {
        Capsule()
            .fill(on ? AnyShapeStyle(AgentLandColor.tint) : AnyShapeStyle(AgentLandColor.separator))
            .frame(width: 46, height: 28)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(.white).padding(2).shadow(color: .black.opacity(0.15), radius: 1, y: 1)
            }
    }
}

/// The app icon: the white tent on the brand color.
private struct AppIcon: View {
    let side: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous).fill(AgentLandColor.brand.color(for: .light))
            AgentLandTentMark(side: side * 0.8, elapsed: nil, color: AgentLandColor.onBrand.color(for: .light))
        }
        .frame(width: side, height: side)
    }
}

// MARK: - The sheet

private struct PaletteSheet: View {
    private let ink = Color(white: 0.12), muted = Color(white: 0.36)

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            VStack(alignment: .leading, spacing: 10) {
                Text("AgentLand palette").font(.system(size: 40, weight: .bold)).foregroundStyle(ink)
                Text("The paper/slate theme: slate covers, launch screen and app icon; art in the text color.")
                    .font(.system(size: 19)).foregroundStyle(ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Rendered on a Mac with ImageRenderer from the AgentLandDesign components and the packaged AgentLandBranding art (tent, clown frame 0, arched title), with Mac text sizes and iPhone tap targets. ImageRenderer can't draw Liquid Glass, so the chat composer appears in its Reduce Transparency form. 2026-09-24.")
                    .font(.system(size: 15)).foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 1700, alignment: .leading)
            HStack(alignment: .top, spacing: 24) {
                brandColumn
                ForEach(SheetPanel.all, id: \.slug) { panel in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(panel.caption).font(.system(size: 17, weight: .semibold)).foregroundStyle(ink)
                        panel.view
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color(white: 0.8), lineWidth: 1))
                    }
                }
            }
            tokenStrip
        }
        .padding(40)
        .background(Color.white)
    }

    private var brandColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Navy").font(.system(size: 34, weight: .bold)).foregroundStyle(ink)
            Text(AgentLandColor.brand.light.description).font(.system(size: 19, design: .monospaced)).foregroundStyle(ink)
            Text("Brand color").font(.system(size: 15)).foregroundStyle(muted)
            AppIcon(side: 132).padding(.top, 8)
            Text("App icon").font(.system(size: 13)).foregroundStyle(muted)
            Text("AgentLandColor.brand")
                .font(.system(size: 13, design: .monospaced)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 200, alignment: .leading)
        .padding(.top, 30)
    }

    private var tokenStrip: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tokens: light, dark, light with Increase Contrast, dark with Increase Contrast")
                .font(.system(size: 19, weight: .semibold)).foregroundStyle(ink)
            let tokens = AgentLandColor.semanticColors + AgentLandColor.artColors + [.brand, .onBrand, .tentDoorway]
            let rows = stride(from: 0, to: tokens.count, by: 8).map { Array(tokens[$0..<min($0 + 8, tokens.count)]) }
            Grid(alignment: .topLeading, horizontalSpacing: 24, verticalSpacing: 20) {
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(rows[row]) { token in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(token.name).font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundStyle(ink)
                                HStack(spacing: 4) {
                                    ForEach(token.isFixed ? [AgentLandAppearance.light] : AgentLandAppearance.allCases, id: \.self) { appearance in
                                        swatch(token.rgb(for: appearance))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func swatch(_ rgb: AgentLandRGB) -> some View {
        let label = rgb.relativeLuminance > 0.35 ? Color.black : Color.white
        return Text(rgb.description)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(label)
            .frame(width: 70, height: 44)
            .background(rgb.color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(white: 0.8), lineWidth: 1))
    }
}
