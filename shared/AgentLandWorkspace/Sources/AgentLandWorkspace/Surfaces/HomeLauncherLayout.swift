import CoreGraphics

/// The bounded geometry for Home's launcher. It deliberately has no view dependencies so the policy for
/// safe-area clearance, short-wide placement, and accessibility scrolling stays testable.
struct HomeLauncherLayout {
    static let minimumBottomClearance: CGFloat = 32
    private static let topClearance: CGFloat = 12
    private static let titleGap: CGFloat = 8
    private static let sceneGap: CGFloat = 8
    private static let quipGap: CGFloat = 12
    /// On iPhone the quip sits this far below the circus and at least `phoneQuipClearance` above the action area
    /// (owner's requests, 2026-10-04: dropped 20 points in all, from 26 and 24, so the circus and actions keep
    /// their places). The action area opens with a clear 52-point band above its capsules, so the quip still
    /// clears the capsules by more than 50 points.
    static let phoneQuipGap: CGFloat = 46
    /// On iPhone the title sits this much higher than its former 54 points below the top, the circus and
    /// everything below it unmoved (owner's request, 2026-10-04).
    static let phoneTitleRaise: CGFloat = 24
    static let phoneQuipClearance: CGFloat = 4
    private static let wideGap: CGFloat = 24
    private static let portraitSceneCap: CGFloat = 220

    struct SafeArea: Equatable, Sendable {
        var top: CGFloat
        var leading: CGFloat
        var bottom: CGFloat
        var trailing: CGFloat
    }

    struct Input: Equatable, Sendable {
        var container: CGSize
        var safeArea: SafeArea
        var title: CGSize
        var scene: CGSize
        var quipHeight: CGFloat
        var actions: CGSize
        var isAccessibilitySize: Bool
    }

    struct Plan: Equatable, Sendable {
        var title: CGRect
        /// Uniform factor applied to the supplied title size. Home uses it to render the wordmark at the
        /// same resolved size the geometry reserved.
        var titleScale: CGFloat
        var scene: CGRect
        var quip: CGRect
        var actions: CGRect
        var contentHeight: CGFloat
        var allowsScrolling: Bool
        var usesWideLayout: Bool
    }

    static func plan(_ input: Input) -> Plan {
        let content = CGRect(
            x: input.safeArea.leading,
            y: input.safeArea.top,
            width: max(0, input.container.width - input.safeArea.leading - input.safeArea.trailing),
            height: max(0, input.container.height - input.safeArea.top - input.safeArea.bottom)
        )
        let wide = !input.isAccessibilitySize && content.width >= 640 && content.width / max(content.height, 1) >= 1.45
        return wide ? widePlan(input, content: content) : portraitPlan(input, content: content)
    }

    /// The approved iPhone composition shares one bottom area between the four actions and their
    /// inline choices. More choices grow upward; the circus yields before readable content does.
    static func phonePlan(_ input: Input, compactTent: Bool = false) -> Plan {
        let content = CGRect(
            x: input.safeArea.leading, y: input.safeArea.top,
            width: max(0, input.container.width - input.safeArea.leading - input.safeArea.trailing),
            height: max(0, input.container.height - input.safeArea.top - input.safeArea.bottom)
        )
        if !input.isAccessibilitySize && content.width >= 640 && content.width / max(content.height, 1) >= 1.45 {
            return widePlan(input, content: content)
        }
        let titleSize = scaledToFit(input.title, width: content.width)
        let title = centered(size: titleSize, atY: content.minY + 54 - phoneTitleRaise - (compactTent ? 8 : 0), in: content)
        // The iPhone tab launchers tighten only the tent composition, without scaling any artwork.
        let sceneTop = title.maxY + (compactTent ? 16 : 8 + phoneTitleRaise)
        let bottom = content.maxY - minimumBottomClearance
        let naturalSceneHeight = min(input.scene.height, 268)
        let quipGap = compactTent ? 48 : phoneQuipGap
        let actionGap = compactTent ? 48 : phoneQuipClearance
        let sceneBudget = max(0, bottom - sceneTop - quipGap - input.quipHeight - actionGap - input.actions.height)
        let sceneHeight = input.isAccessibilitySize ? naturalSceneHeight : min(naturalSceneHeight, sceneBudget)
        let scene = centeredScene(input.scene, height: sceneHeight, atY: sceneTop, in: content)
        let actionTop = max(scene.maxY + quipGap + input.quipHeight + actionGap, bottom - input.actions.height)
        // Divide the remaining tent-to-actions space evenly around the quip.
        let quipTop = compactTent ? scene.maxY + (actionTop - scene.maxY - input.quipHeight) / 2 : scene.maxY + phoneQuipGap
        let quip = CGRect(x: content.minX + 20, y: quipTop,
                          width: max(0, content.width - 40), height: input.quipHeight)
        let actions = centered(size: fitted(input.actions, to: content.width), atY: actionTop, in: content)
        let requiredHeight = actions.maxY + minimumBottomClearance - content.minY
        return Plan(title: title, titleScale: scale(from: input.title, to: titleSize), scene: scene,
                    quip: quip, actions: actions, contentHeight: max(content.height, requiredHeight),
                    allowsScrolling: requiredHeight > content.height + 0.5, usesWideLayout: false)
    }

    private static func portraitPlan(_ input: Input, content: CGRect) -> Plan {
        let bottom = content.maxY - minimumBottomClearance
        let titleSize = scaledToFit(input.title, width: content.width)
        let title = centered(size: titleSize, atY: content.minY + topClearance, in: content)
        let fixedHeight = titleGap + sceneGap + input.quipHeight + quipGap + input.actions.height
        let naturalSceneHeight = min(input.scene.height, portraitSceneCap)
        let availableSceneHeight = max(0, bottom - title.maxY - fixedHeight)
        // Decoration is the first thing that contracts when an ordinary window becomes short. Accessibility
        // preserves its readable content and uses the scroll view only when that content cannot fit.
        let sceneHeight = input.isAccessibilitySize ? naturalSceneHeight : min(naturalSceneHeight, availableSceneHeight)
        let scene = centeredScene(input.scene, height: sceneHeight, atY: title.maxY + titleGap, in: content)
        let quip = CGRect(x: content.minX, y: scene.maxY + sceneGap, width: content.width, height: input.quipHeight)
        let actions = centered(size: fitted(input.actions, to: content.width), atY: quip.maxY + quipGap, in: content)
        let naturalBottom = actions.maxY + minimumBottomClearance - content.minY
        return Plan(title: title, titleScale: scale(from: input.title, to: titleSize), scene: scene, quip: quip, actions: actions,
                    contentHeight: max(content.height, naturalBottom),
                    allowsScrolling: input.isAccessibilitySize && naturalBottom > content.height,
                    usesWideLayout: false)
    }

    private static func widePlan(_ input: Input, content: CGRect) -> Plan {
        let bottom = content.maxY - minimumBottomClearance
        let actionSize = fitted(input.actions, to: max(0, content.width * 0.52))
        let actionHeight = input.quipHeight + quipGap + actionSize.height
        // The wide circus shares its row with the launcher. It can contract to that row, but it cannot
        // make the action grid taller than the available height. Once the tent has reached that limit,
        // shrink the wordmark uniformly so the three launcher rows and bottom clearance remain visible.
        let titleHeightBudget = max(0, bottom - (content.minY + topClearance) - titleGap - actionHeight)
        let titleSize = scaledToFit(input.title, width: content.width, height: titleHeightBudget)
        let title = centered(size: titleSize, atY: content.minY + topClearance, in: content)
        let rowTop = title.maxY + titleGap
        let rowHeight = max(0, bottom - rowTop)
        // The art also yields to the row's width: art, gap and actions stay inside the content (a landscape iPhone's
        // row ran 9 to 28 pt past the trailing safe area and the buttons were cut off, 2026-10-05).
        let widthBudget = max(0, content.width - wideGap - actionSize.width)
        let widthLimitedHeight = input.scene.width > 0 ? widthBudget * input.scene.height / input.scene.width : 0
        let sceneHeight = min(input.scene.height, rowHeight, actionHeight, widthLimitedHeight)
        let sceneSize = scaled(input.scene, height: sceneHeight)
        let rowWidth = sceneSize.width + wideGap + actionSize.width
        let rowX = content.midX - rowWidth / 2
        let scene = CGRect(x: rowX, y: rowTop + (rowHeight - sceneSize.height) / 2, width: sceneSize.width, height: sceneSize.height)
        let quip = CGRect(x: scene.maxX + wideGap, y: rowTop + max(0, (rowHeight - actionHeight) / 2),
                          width: actionSize.width, height: input.quipHeight)
        let actions = CGRect(x: quip.minX, y: quip.maxY + quipGap, width: actionSize.width, height: actionSize.height)
        let contentHeight = max(content.height, max(scene.maxY, actions.maxY) + minimumBottomClearance - content.minY)
        return Plan(title: title, titleScale: scale(from: input.title, to: titleSize), scene: scene, quip: quip, actions: actions,
                    contentHeight: contentHeight, allowsScrolling: false, usesWideLayout: true)
    }

    private static func centered(size: CGSize, atY y: CGFloat, in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.midX - size.width / 2, y: y, width: size.width, height: size.height)
    }

    private static func centeredScene(_ scene: CGSize, height: CGFloat, atY y: CGFloat, in bounds: CGRect) -> CGRect {
        centered(size: scaled(scene, height: height), atY: y, in: bounds)
    }

    private static func fitted(_ size: CGSize, to width: CGFloat) -> CGSize {
        guard size.width > width, size.width > 0 else { return size }
        return CGSize(width: width, height: size.height)
    }

    private static func scaledToFit(_ size: CGSize, width: CGFloat, height: CGFloat = .greatestFiniteMagnitude) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let factor = min(1, max(0, width) / size.width, max(0, height) / size.height)
        return CGSize(width: size.width * factor, height: size.height * factor)
    }

    private static func scale(from original: CGSize, to resolved: CGSize) -> CGFloat {
        guard original.width > 0 else { return 1 }
        return resolved.width / original.width
    }

    private static func scaled(_ size: CGSize, height: CGFloat) -> CGSize {
        guard size.height > 0 else { return .zero }
        return CGSize(width: size.width * height / size.height, height: height)
    }
}
