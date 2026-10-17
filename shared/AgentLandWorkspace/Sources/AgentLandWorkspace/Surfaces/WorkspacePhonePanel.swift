import SwiftUI
import AgentLandDesign

/// The iPhone header's quick tab menu (the left drawer was removed with the bottom tabs, owner 2026-10-11).
enum PhonePanelKind: Hashable, CaseIterable {
    case tabSwitcher

    /// The tab menu stays centered under its button.
    var alignment: PhonePanelGeometry.Alignment { .centred }

    /// The task menu fits its rows up to the most a panel may be.
    var fillsRoom: Bool { false }
}

/// Where a header panel sits (owner's instruction of 2026-10-05, "push the menus below the header", replacing the
/// panels that covered their buttons the same day): it grows out of its button's glass down to its resting frame just
/// below the header, `gap` under the header buttons' glass, so the buttons stay in view and take taps while it is
/// open; the drawer's leading edge sits on its button's leading glass edge, Settings' trailing edge on the gear's, the
/// task menu centred under its button. The drawer and Settings use the shell's width less their edge insets;
/// the quick switcher fits its widest row, capped at those same margins (owner, 2026-10-09).
/// The task menu is as tall as its rows up to `maxHeight`, the drawer and
/// Settings take all the height below the header (`PhonePanelKind.fillsRoom`). Every panel stays inside the shell's
/// margins and above the keyboard.
///
/// The native `Menu` it was measured against (iPhone 17 Pro simulator, iOS 26.5, 2026-10-05,
/// `testPhonePanelScreenshots` with `-AgentLandPhoneReferenceMenu`) is 250 pt wide, its corners fit a 24 pt circle and
/// it goes in well under 0.1 s.
struct PhonePanelGeometry {
    /// How a panel lines up with its button.
    enum Alignment { case leading, trailing, centred }

    /// The grown panel's corner radius, as the measured iOS 26 menu's.
    static let cornerRadius: CGFloat = 24
    /// The space between the header buttons' glass and a panel resting below them: the system's standard 8 pt
    /// spacing, the margin a native menu keeps from the screen's edge (measured: clamped 8 pt from the right) and the
    /// panel's own `bottomMargin`, so the header, the panel and the keyboard are kept apart by one margin.
    static let gap: CGFloat = AgentLandSpacing.xSmall
    /// The least room the panel keeps below it, above the keyboard or the shell's bottom.
    static let bottomMargin: CGFloat = 8
    /// The least a panel is tall, as long as the room below the header allows.
    static let minimumHeight: CGFloat = 120

    /// A round header button's glass: the circle centred in its layout frame (a `.glass` circle button's frame is wider
    /// than its glass). The task button's capsule fills its frame.
    static func glass(of frame: CGRect, round: Bool) -> CGRect {
        guard round, frame.width > frame.height else { return frame }
        return CGRect(x: frame.midX - frame.height / 2, y: frame.minY, width: frame.height, height: frame.height)
    }

    /// The panel's resting frame in the shell's space. `button` is the source button's glass, `alignment` how the panel
    /// lines up with it (it is as wide as the margins allow), `margin` the least space it
    /// keeps from the shell's sides (the header buttons' edge inset), `headerBottom` where the header buttons' glass
    /// ends, `available` the shell's size as it is now (shorter while the keyboard is up), `fit` the height its
    /// content asks for (nil: as tall as it may be) and `maxHeight` the most a panel may be tall.
    static func frame(button: CGRect, alignment: Alignment, margin: CGFloat, headerBottom: CGFloat,
                      available: CGSize, fit: CGFloat?, maxHeight: CGFloat, fitWidth: CGFloat? = nil) -> CGRect {
        let panelWidth = min(max(0, fitWidth ?? available.width), max(0, available.width - 2 * margin))
        let x: CGFloat = switch alignment {
        case .leading: button.minX
        case .trailing: button.maxX - panelWidth
        case .centred: button.midX - panelWidth / 2
        }
        let left = min(max(margin, x), max(margin, available.width - margin - panelWidth))
        let top = max(0, headerBottom + gap)
        let room = max(minimumHeight, available.height - top - bottomMargin)
        // Never past the shell's (or the keyboard's) edge, even where the room is less than the least height.
        let height = min(fit ?? maxHeight, maxHeight, room, available.height - top)
        return CGRect(x: left, y: top, width: panelWidth, height: max(0, height))
    }
}

/// The height a panel's content asks for: the task menu fits its rows (nil: all the panel may have). The drawer
/// still reports its root's height, but it and Settings take all the room below the header (`PhonePanelKind.fillsRoom`).
struct PhonePanelFitHeightKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}

struct PhonePanelFitWidthKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}

/// The tap-outside region of an open header panel: the whole shell but the header's buttons, which stay tappable
/// (filled even-odd, so each button's frame is a hole).
struct PanelDismissShape: Shape {
    let holes: [CGRect]

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        for hole in holes where !hole.isEmpty { path.addRect(hole) }
        return path
    }
}

#if os(iOS)
/// The header's panels, over the phone shell (owner's instruction of 2026-10-05, "push the menus below the header",
/// with a compact width like Apple's menus, a quick close and no dim). The panel first takes its button's exact frame
/// and capsule shape over the button, then its Liquid Glass grows down to its resting frame below the header (with
/// `AgentLandMotion.drawer`, the 0.25 s spring), rounding to a menu's corners, while the button's label it carries
/// fades and the content, laid out at its full size from the start, comes into focus; it shrinks back into the button
/// in `AgentLandMotion.quickDuration` (0.1 s, `drawerClose`) when it closes. The header's buttons stay in view and
/// take taps meanwhile: the same button closes its panel, another closes it and opens its own. Nothing is dimmed. A
/// tap anywhere else closes it and reaches nothing behind it (`phonePanelDismiss`). For VoiceOver the panel is modal,
/// as an iOS menu is: the header and the content are hidden from it, and its escape or the Dismiss element closes it.
/// Reduce Motion fades the full panel in place; UI-test runs show it at once.
///
/// Explicit geometry, as Home's action boxes: `glassEffectID` morphs did not reliably start from the tapped button.
struct WorkspacePhonePanelLayer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The panel the header wants open.
    let requested: PhonePanelKind?
    /// The panel on screen (growing, grown or shrinking).
    @Binding var shown: PhonePanelKind?
    /// Each header button's frame in the shell's space.
    let buttons: [PhonePanelKind: CGRect]
    /// The most the task menu is tall: about 70% of the shell without the keyboard. The drawer and Settings take all
    /// the room below the header.
    let maxHeight: CGFloat
    /// Where the header ends in the shell's space, for a panel's top before the buttons have reported their frames.
    let headerBottom: CGFloat
    /// The shell's height without the keyboard, and the keyboard's top in the shell's space while it is up: the
    /// panel's room ends above the keyboard.
    let shellHeight: CGFloat
    let keyboardTop: CGFloat?
    let content: (PhonePanelKind) -> AnyView
    let label: (PhonePanelKind) -> AnyView
    let close: () -> Void

    @State private var grown = false
    @State private var fit: [PhonePanelKind: CGFloat] = [:]
    @State private var fitWidths: [PhonePanelKind: CGFloat] = [:]

    var body: some View {
        let open = shown != nil || requested != nil
        ZStack(alignment: .topLeading) {
            if open {
                // A tap anywhere outside the panel and the header's buttons closes it, as outside a menu; the buttons
                // are holes in it, so their own taps reach them. Like UIKit's dismiss region it is an element of its
                // own, so nothing under it counts as reachable; VoiceOver stays in the modal panel and closes it with
                // its escape.
                Color.clear
                    .contentShape(PanelDismissShape(holes: Array(buttons.values)), eoFill: true)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .onTapGesture(perform: close)
                    .accessibilityElement()
                    .accessibilityLabel("Dismiss")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { close() }
                    .accessibilityIdentifier("phonePanelDismiss")
            }
            // The room a panel has: the shell's width, down to the keyboard's top while it is up.
            GeometryReader { proxy in
                let room = CGSize(width: proxy.size.width,
                                  height: min(shellHeight > 0 ? shellHeight : proxy.size.height, keyboardTop ?? .infinity))
                if let shown { panel(shown, in: room) }
            }
        }
        .animation(fadeAnimation, value: open)
        .onChange(of: requested, initial: true) { _, kind in
            if let kind { present(kind) } else { dismiss() }
        }
    }

    /// The growth: the app's one interface speed with a menu's small settle (`AgentLandMotion.drawer`).
    private var animation: Animation? { AgentLandMotion.drawer.animation(reduceMotion: reduceMotion) }
    /// The shrink back into the button: a native menu's quick close (`AgentLandMotion.drawerClose`).
    private var closeAnimation: Animation? { AgentLandMotion.drawerClose.animation(reduceMotion: reduceMotion) }
    /// The dismiss region's coming and going, at the one speed without the settle.
    private var fadeAnimation: Animation? { AgentLandMotion.smooth.animation(reduceMotion: reduceMotion) }

    /// The button's glass the panel grows out of and shrinks back into.
    private func source(_ kind: PhonePanelKind, in size: CGSize) -> CGRect {
        guard let frame = buttons[kind] else {
            return CGRect(x: 16, y: 6, width: 50, height: 50)
        }
        return PhonePanelGeometry.glass(of: frame, round: kind != .tabSwitcher)
    }

    /// The header's leading inset, where the drawer button used to sit.
    private func margin(_ kind: PhonePanelKind, in size: CGSize) -> CGFloat { 16 }

    /// Where the header buttons' glass ends: the panels rest `PhonePanelGeometry.gap` below it.
    private var buttonsBottom: CGFloat {
        buttons.values.map(\.maxY).max() ?? headerBottom
    }

    @ViewBuilder private func panel(_ kind: PhonePanelKind, in size: CGSize) -> some View {
        let button = source(kind, in: size)
        let target = PhonePanelGeometry.frame(button: button, alignment: kind.alignment,
                                              margin: margin(kind, in: size), headerBottom: buttonsBottom,
                                              available: size, fit: kind.fillsRoom ? nil : fit[kind],
                                              maxHeight: kind.fillsRoom ? .infinity : maxHeight,
                                              fitWidth: kind == .tabSwitcher ? fitWidths[kind] : nil)
        let frame = grown ? target : button
        let radius = grown ? PhonePanelGeometry.cornerRadius : min(button.width, button.height) / 2
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        // Only the glass and the mask over the content move and grow; the content and the button's label never move
        // (owner, 2026-10-08: inside the glass, Settings' content swept in from the gear as the panel crossed the
        // screen). Outside a glass container, the content drawn over the glass stays sharp.
        ZStack(alignment: .topLeading) {
            // The system supplies the material, highlights and accessibility treatment.
            // An opaque fill behind this layer masks Liquid Glass's appearance.
            Color.clear
                .frame(width: frame.width, height: frame.height)
                .glassControl(in: shape, interactive: false)
                .contentShape(shape)
                .offset(x: frame.minX, y: frame.minY)
            // The content, laid out at the grown size and place from the start, uncovered as the glass grows.
            content(kind)
                .environment(\.agentLandInsideGlass, true)
                // The native glass platter stays visible behind lists and pushed pages.
                .agentLandPanelPage()
                .frame(width: target.width, height: target.height, alignment: .top)
                .onPreferenceChange(PhonePanelFitHeightKey.self) { height in
                    if fit[kind] != height { fit[kind] = height }
                }
                .onPreferenceChange(PhonePanelFitWidthKey.self) { width in
                    if fitWidths[kind] != width { fitWidths[kind] = width }
                }
                // As an iOS 26 menu's items: in place from the start, coming into focus as the glass grows.
                .opacity(grown ? 1 : 0)
                .blur(radius: grown || reduceMotion ? 0 : 6)
                .animation(contentAnimation, value: grown)
                .mask(alignment: .topLeading) {
                    shape.frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX - target.minX, y: frame.minY - target.minY)
                }
                .offset(x: target.minX, y: target.minY)
                .allowsHitTesting(grown)
            // The button's label, where it was, fading as the glass leaves the button for the panel.
            label(kind)
                .frame(width: button.width, height: button.height)
                .opacity(grown ? 0 : 1)
                .animation(labelAnimation, value: grown)
                .offset(x: button.minX, y: button.minY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, close)
        // Modal for VoiceOver, so XCUITest lists the panel as an alert; the UI tests tell it from the system's by this.
        .accessibilityIdentifier("phoneHeaderPanel")
    }

    /// The content comes into focus as the glass grows (an iOS 26 menu's items show, blurred, from its first frame)
    /// and fades over the first half of the quick shrink; under Reduce Motion it fades with the panel.
    private var contentAnimation: Animation? {
        guard let animation else { return nil }
        if reduceMotion { return animation }
        return grown ? .easeOut(duration: AgentLandMotion.standardDuration) : .easeOut(duration: AgentLandMotion.quickDuration / 2)
    }

    /// The button's label fades over the first half of the growth and back over the second half of the quick shrink.
    private var labelAnimation: Animation? {
        guard let animation else { return nil }
        if reduceMotion { return animation }
        if grown { return .easeOut(duration: AgentLandMotion.standardDuration / 2) }
        let half = AgentLandMotion.quickDuration / 2
        return .easeIn(duration: half).delay(half)
    }

    /// The panel takes its button's place without animation, then grows on the next update. Reduce Motion fades the
    /// full panel in place, and UI-test runs show it at once. Another panel still on screen is replaced at once.
    private func present(_ kind: PhonePanelKind) {
        guard let animation, shown == nil || shown == kind else {
            var swap = Transaction()
            swap.disablesAnimations = true
            withTransaction(swap) { shown = kind; grown = true }
            return
        }
        if shown == kind {
            withAnimation(animation) { grown = true }
            return
        }
        if reduceMotion {
            withAnimation(animation) { shown = kind; grown = true }
            return
        }
        var swap = Transaction()
        swap.disablesAnimations = true
        withTransaction(swap) { shown = kind; grown = false }
        DispatchQueue.main.async {
            guard requested == kind, shown == kind else { return }
            withAnimation(animation) { grown = true }
        }
    }

    /// The panel shrinks back into its button, quickly, then goes.
    private func dismiss() {
        guard shown != nil else { return }
        guard let animation else {
            shown = nil
            grown = false
            return
        }
        if reduceMotion {
            withAnimation(animation) { shown = nil; grown = false }
            return
        }
        withAnimation(closeAnimation) { grown = false } completion: {
            guard requested == nil else { return }
            var swap = Transaction()
            swap.disablesAnimations = true
            withTransaction(swap) { shown = nil }
        }
    }
}

#endif
