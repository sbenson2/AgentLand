import XCTest
@testable import AgentLandWorkspace

final class HomeLauncherLayoutTests: XCTestCase {
    func testPhoneLauncherLowersTheTitleAndUsesTheBottomActionArea() {
        let input = HomeLauncherLayout.Input(
            container: CGSize(width: 390, height: 730),
            safeArea: .init(top: 0, leading: 0, bottom: 0, trailing: 0),
            title: CGSize(width: 366, height: 73),
            scene: CGSize(width: 336, height: 268),
            quipHeight: 60,
            actions: CGSize(width: 350, height: 192),
            isAccessibilitySize: false
        )
        let plan = HomeLauncherLayout.phonePlan(input)

        XCTAssertEqual(plan.title.minY, 30, "raised 24 points from 54")
        XCTAssertEqual(plan.scene.minY, 54 + plan.title.height + 8, "the circus stays below the title's former place")
        XCTAssertEqual(plan.quip.minY - plan.scene.maxY, HomeLauncherLayout.phoneQuipGap, "the smaller phone quip sits slightly lower")
        XCTAssertGreaterThan(plan.scene.height, 220, "the approved phone circus is larger than the previous launcher")
        XCTAssertEqual(plan.actions.maxY, 730 - HomeLauncherLayout.minimumBottomClearance)
        XCTAssertGreaterThanOrEqual(plan.actions.minY - plan.quip.maxY, HomeLauncherLayout.phoneQuipClearance)
        XCTAssertFalse(plan.allowsScrolling)
    }

    /// The quip dropped 20 points (owner's requests, 2026-10-04): the drop comes out of its clearance above the
    /// action area, so the circus keeps its height and the actions their place, wherever the circus is limited.
    func testThePhoneQuipDropsWithoutMovingTheCircusOrActions() {
        for (height, quip, actions) in [(CGFloat(800), CGFloat(30), CGFloat(192)), (730, 60, 192), (760, 46, 300)] {
            let plan = HomeLauncherLayout.phonePlan(.init(
                container: CGSize(width: 402, height: height),
                safeArea: .init(top: 0, leading: 0, bottom: 0, trailing: 0),
                title: CGSize(width: 366, height: 73),
                scene: CGSize(width: 404, height: 268),
                quipHeight: quip,
                actions: CGSize(width: 362, height: actions),
                isAccessibilitySize: false
            ))
            // The layout before the drop: 26 below the circus, 24 above the actions.
            let sceneTop = plan.title.maxY + 8 + HomeLauncherLayout.phoneTitleRaise
            let before = min(268, max(0, height - HomeLauncherLayout.minimumBottomClearance - sceneTop - 26 - quip - 24 - actions))
            XCTAssertEqual(plan.scene.height, before, accuracy: 1e-9, "The circus keeps its height")
            XCTAssertEqual(plan.quip.minY - plan.scene.maxY, 46, "Dropped 20 points from 26")
            XCTAssertEqual(plan.actions.maxY, height - HomeLauncherLayout.minimumBottomClearance, "The actions keep their place")
            XCTAssertGreaterThanOrEqual(plan.actions.minY - plan.quip.maxY, HomeLauncherLayout.phoneQuipClearance - 1e-9)
            XCTAssertFalse(plan.allowsScrolling)
        }
    }

    func testPhoneInlineChoicesGrowUpwardAndYieldDecorationBeforeTapTargets() {
        let input = HomeLauncherLayout.Input(
            container: CGSize(width: 320, height: 620),
            safeArea: .init(top: 0, leading: 0, bottom: 0, trailing: 0),
            title: CGSize(width: 296, height: 59),
            scene: CGSize(width: 336, height: 268),
            quipHeight: 68,
            actions: CGSize(width: 280, height: 344),
            isAccessibilitySize: false
        )
        let plan = HomeLauncherLayout.phonePlan(input)

        XCTAssertEqual(plan.actions.height, 344, "all choices retain their measured touch targets")
        XCTAssertEqual(plan.actions.maxY, 620 - HomeLauncherLayout.minimumBottomClearance)
        XCTAssertLessThan(plan.scene.height, 268)
        XCTAssertLessThanOrEqual(plan.quip.maxY + HomeLauncherLayout.phoneQuipClearance, plan.actions.minY)
        XCTAssertFalse(plan.allowsScrolling, "ordinary phone menus have no nested scroller")
    }

    func testPhoneAccessibilityKeepsReadableChoicesInOnePageScroller() {
        let plan = HomeLauncherLayout.phonePlan(.init(
            container: CGSize(width: 390, height: 730),
            safeArea: .init(top: 0, leading: 0, bottom: 0, trailing: 0),
            title: CGSize(width: 366, height: 73),
            scene: CGSize(width: 336, height: 268),
            quipHeight: 130,
            actions: CGSize(width: 350, height: 520),
            isAccessibilitySize: true
        ))

        XCTAssertTrue(plan.allowsScrolling)
        XCTAssertEqual(plan.actions.height, 520)
        XCTAssertGreaterThanOrEqual(plan.contentHeight - plan.actions.maxY, HomeLauncherLayout.minimumBottomClearance)
    }

    func testPortraitPlanKeepsTheLauncherInsideTheSafeAreaWithBottomClearance() {
        let plan = HomeLauncherLayout.plan(.init(
            container: CGSize(width: 390, height: 760),
            safeArea: .init(top: 0, leading: 0, bottom: 34, trailing: 0),
            title: CGSize(width: 278, height: 81),
            scene: CGSize(width: 336, height: 360),
            quipHeight: 40,
            actions: CGSize(width: 342, height: 168),
            isAccessibilitySize: false
        ))

        XCTAssertFalse(plan.allowsScrolling)
        XCTAssertLessThan(plan.title.minY, plan.scene.minY)
        XCTAssertLessThan(plan.scene.minY, plan.quip.minY)
        XCTAssertLessThan(plan.quip.minY, plan.actions.minY)
        XCTAssertGreaterThanOrEqual(760 - plan.actions.maxY, HomeLauncherLayout.minimumBottomClearance + 34)
        XCTAssertLessThanOrEqual(plan.actions.maxY, 760 - 34 - HomeLauncherLayout.minimumBottomClearance)
    }

    func testShortWidePlanPutsTheArtBesideTheActionsAndShrinksTheArtToFit() {
        let plan = HomeLauncherLayout.plan(.init(
            container: CGSize(width: 844, height: 390),
            safeArea: .init(top: 0, leading: 0, bottom: 21, trailing: 0),
            title: CGSize(width: 278, height: 81),
            scene: CGSize(width: 336, height: 360),
            quipHeight: 40,
            actions: CGSize(width: 344, height: 168),
            isAccessibilitySize: false
        ))

        XCTAssertFalse(plan.allowsScrolling)
        XCTAssertTrue(plan.usesWideLayout)
        XCTAssertLessThan(plan.scene.maxX, plan.actions.minX)
        XCTAssertLessThan(plan.scene.height, 360, "decoration contracts before the launcher actions")
        XCTAssertGreaterThanOrEqual(390 - max(plan.scene.maxY, plan.actions.maxY), HomeLauncherLayout.minimumBottomClearance + 21)
    }

    /// The phone landscape capture has the current 465×93 wordmark and a measured 261 pt, three-row
    /// action grid (the narrower right column wraps Resume Work). The launcher must retain its tap targets
    /// rather than placing that third row below the viewport.
    func testShortWidePlanShrinksTitleForMeasuredThreeRowLauncher() {
        let plan = HomeLauncherLayout.plan(.init(
            container: CGSize(width: 844, height: 390),
            safeArea: .init(top: 0, leading: 0, bottom: 0, trailing: 0),
            title: CGSize(width: 465, height: 93),
            scene: CGSize(width: 336, height: 360),
            quipHeight: 40,
            actions: CGSize(width: 480, height: 261),
            isAccessibilitySize: false
        ))

        XCTAssertTrue(plan.usesWideLayout)
        XCTAssertLessThan(plan.title.height, 93, "The title yields after the tent has reached the action row")
        XCTAssertLessThan(plan.titleScale, 1, "Home receives the resolved uniform title scale")
        XCTAssertLessThan(plan.scene.maxX, plan.actions.minX)
        XCTAssertLessThanOrEqual(plan.actions.maxY, 390 - HomeLauncherLayout.minimumBottomClearance)
        XCTAssertGreaterThanOrEqual(390 - plan.actions.maxY, HomeLauncherLayout.minimumBottomClearance)
        XCTAssertFalse(plan.allowsScrolling)
    }

    /// A landscape iPhone 17 Pro (2026-10-05): Home's container is 750 wide below the header, the 2×2 grid of the
    /// owner's larger buttons is 191.3 pt tall and the quip 40. With the portrait band above the buttons the column
    /// ran past the bottom clearance (testLandscapeHome measured 26.7 of 32 pt); the short-wide layout drops the band,
    /// since its quip keeps its own gap above the buttons, and the actions then keep the clearance. Portrait keeps it.
    func testPhoneLandscapeKeepsTheBottomClearanceWithoutTheActionBand() {
        func plan(height: CGFloat, wide: Bool) -> HomeLauncherLayout.Plan {
            HomeLauncherLayout.phonePlan(.init(
                container: CGSize(width: 750, height: height),
                safeArea: .init(top: 0, leading: 0, bottom: 0, trailing: 0),
                title: CGSize(width: 452, height: 92.6),
                scene: CGSize(width: 404, height: 268),
                quipHeight: 40,
                actions: CGSize(width: 480, height: max(192, 191.3 + HomePhoneActionArea.clearBand(wide: wide))),
                isAccessibilitySize: false))
        }
        for height in [CGFloat(321), 342] {
            let landscape = plan(height: height, wide: true)
            XCTAssertTrue(landscape.usesWideLayout)
            XCTAssertLessThanOrEqual(landscape.actions.maxY, height - HomeLauncherLayout.minimumBottomClearance,
                                     "the actions keep 32 pt below them at \(height)")
            XCTAssertLessThan(landscape.scene.maxX, landscape.actions.minX)
            XCTAssertLessThanOrEqual(landscape.quip.maxY, landscape.actions.minY)
            XCTAssertGreaterThanOrEqual(landscape.scene.minX, 0, "the art stays inside the content")
            XCTAssertLessThanOrEqual(landscape.actions.maxX, 750, "the buttons stay inside the content, none cut off")
        }
        XCTAssertGreaterThan(plan(height: 321, wide: false).actions.maxY, 321 - HomeLauncherLayout.minimumBottomClearance,
                             "the portrait band is what overflowed")
        XCTAssertEqual(HomePhoneActionArea.clearBand(wide: false), 52, "portrait keeps its band")
    }

    func testAccessibilityPlanAllowsScrollingOnlyWhenItsExpandedContentNeedsIt() {
        let plan = HomeLauncherLayout.plan(.init(
            container: CGSize(width: 390, height: 760),
            safeArea: .init(top: 0, leading: 0, bottom: 34, trailing: 0),
            title: CGSize(width: 278, height: 110),
            scene: CGSize(width: 336, height: 360),
            quipHeight: 76,
            actions: CGSize(width: 342, height: 432),
            isAccessibilitySize: true
        ))

        XCTAssertTrue(plan.allowsScrolling)
        XCTAssertGreaterThan(plan.contentHeight, 760 - 34)
        XCTAssertGreaterThanOrEqual(plan.contentHeight - plan.actions.maxY, HomeLauncherLayout.minimumBottomClearance)
    }
}
