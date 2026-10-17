import SwiftUI
import XCTest
#if os(macOS)
import AppKit
#endif
@testable import AgentLandDesign

/// Renders every component with `ImageRenderer` at the default and AX5 text sizes, in light and dark,
/// and checks sizes and hit areas. Hit areas are checked against this platform's minimum and against
/// 44 pt, the iPhone and iPad minimum.
///
/// macOS has no Dynamic Type, so on the Mac the AX5 renders keep Mac text sizes; they still exercise
/// the accessibility-size layouts (stacked tiles, buttons below text). Where the suite runs on iOS,
/// AX5 text is also checked to grow.
///
/// On iOS the launcher labels (`ActionTile`, `ActionCapsule`) draw no chrome of their own: the native button style
/// their Button or Menu takes (`agentLandControlButton()`) supplies the glass, its height and its fill, and the primary
/// button is the native `.glassProminent`. `ImageRenderer` draws no Liquid Glass, so there the checks are the labels'
/// layout and hit areas, and the colors are those of the opaque fills that remain (notices, the Reduce Transparency
/// fallback), which draw the system's colors (`drawnColor`).
@MainActor
final class ComponentRenderTests: XCTestCase {
    private let minimums: [CGFloat] = Array(Set([AgentLandTapTarget.platformMinimum, AgentLandTapTarget.iOSMinimum])).sorted()
    private let schemes: [ColorScheme] = [.light, .dark]

    // MARK: minimumTapTarget

    func testExpandedHitAreaKeepsLayoutAndGrowsAroundTheControl() throws {
        for minimum in minimums {
            let icon = Color.gray.frame(width: 17, height: 17).minimumTapTarget()
            let result = try render(icon.padding(30), minimumTapTarget: minimum)
            XCTAssertEqual(result.size, CGSize(width: 77, height: 77), "layout keeps the 17 pt control")
            let hit = try XCTUnwrap(result.tapTargets.first)
            XCTAssertEqual(hit.width, minimum, accuracy: 0.01)
            XCTAssertEqual(hit.height, minimum, accuracy: 0.01)
            // Centred on the control, within the half point SwiftUI rounds positions by.
            XCTAssertEqual(hit.midX, 38.5, accuracy: 0.51)
            XCTAssertEqual(hit.midY, 38.5, accuracy: 0.51)
        }
        // A control that is already big enough keeps its own size.
        let wide = try render(Color.gray.frame(width: 120, height: 60).minimumTapTarget(), minimumTapTarget: 44)
        XCTAssertEqual(try XCTUnwrap(wide.tapTargets.first).size, CGSize(width: 120, height: 60))
    }

    func testReservedTapTargetGrowsTheLayout() throws {
        let result = try render(Image(systemName: "xmark").minimumTapTarget(.reserveSpace), minimumTapTarget: 44)
        XCTAssertEqual(result.size, CGSize(width: 44, height: 44))
        XCTAssertEqual(try XCTUnwrap(result.tapTargets.first).size, CGSize(width: 44, height: 44))
    }

    func testExpandedHitAreaKeepsTextBaselines() throws {
        // A label with an expanded hit area still lines up on the first baseline with its neighbour.
        let row = HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("Model").font(.title)
            Text("Change").font(.footnote).minimumTapTarget()
        }
        let result = try render(row, minimumTapTarget: 44)
        XCTAssertLessThan(result.size.height, 44, "the grown hit area does not change the row's height")
        XCTAssertEqual(result.tapTargets.count, 1)
    }

    // MARK: ActionTile

    func testActionTile() throws {
        var heights: [DynamicTypeSize: CGFloat] = [:]
        for minimum in minimums {
            for scheme in schemes {
                for typeSize in renderTestTypeSizes {
                    for tile in [ActionTile("New terminal", systemImage: "terminal", showsDisclosure: true),
                                 ActionTile("Open workspace", systemImage: "square.grid.2x2")] {
                        let result = try render(tile, width: 180, typeSize: typeSize, colorScheme: scheme, minimumTapTarget: minimum)
                        XCTAssertTrue(result.hasVisiblePixels)
                        XCTAssertEqual(result.size.width, 180)
                        #if os(iOS)
                        XCTAssertGreaterThanOrEqual(result.size.height, minimum, "the label fills the tap target")
                        #else
                        XCTAssertGreaterThanOrEqual(result.size.height, max(minimum, 48))
                        #endif
                        assertTapTargets(result, count: 1, minimum: minimum, "ActionTile \(typeSize) \(scheme)")
                        heights[typeSize] = result.size.height
                    }
                }
            }
        }
        // At accessibility sizes the symbol stacks above the title.
        XCTAssertGreaterThan(try XCTUnwrap(heights[.accessibility5]), try XCTUnwrap(heights[.large]))
        let disabled = try render(ActionTile("Browse files", systemImage: "folder").disabled(true), width: 180)
        XCTAssertTrue(disabled.hasVisiblePixels)
        #if os(iOS)
        // On iOS the label has no fill of its own: beside its title it is clear, and the button style draws the glass.
        for scheme in schemes {
            let tile = try render(ActionTile("Browse files", systemImage: "folder"), width: 180, colorScheme: scheme)
            XCTAssertNil(tile.color(at: CGPoint(x: tile.size.width - 2, y: tile.size.height / 2)), "no tile fill, \(scheme)")
        }
        #else
        // The tile sits on `surface` in each appearance.
        for (scheme, appearance) in [(ColorScheme.light, AgentLandAppearance.light), (.dark, .dark)] {
            let tile = try render(ActionTile("Browse files", systemImage: "folder"), width: 180, colorScheme: scheme)
            assertColor(tile.color(at: CGPoint(x: 6, y: tile.size.height / 2)), equals: AgentLandColor.surface.rgb(for: appearance),
                        "tile fill, \(appearance)")
        }
        #endif
    }

    // MARK: ActionCapsule

    func testActionCapsule() throws {
        var heights: [DynamicTypeSize: CGFloat] = [:]
        for minimum in minimums {
            for scheme in schemes {
                for typeSize in renderTestTypeSizes {
                    for capsule in [ActionCapsule("New Terminal", systemImage: "terminal", showsDisclosure: true),
                                    ActionCapsule("Open Workspace", systemImage: "square.grid.2x2")] {
                        let result = try render(capsule, width: 180, typeSize: typeSize, colorScheme: scheme, minimumTapTarget: minimum)
                        XCTAssertTrue(result.hasVisiblePixels)
                        XCTAssertEqual(result.size.width, 180)
                        #if os(iOS)
                        XCTAssertGreaterThanOrEqual(result.size.height, minimum, "the label fills the tap target")
                        #else
                        XCTAssertGreaterThanOrEqual(result.size.height, 56, "at least 56 pt tall")
                        #endif
                        assertTapTargets(result, count: 1, minimum: minimum, "ActionCapsule \(typeSize) \(scheme)")
                        heights[typeSize] = max(heights[typeSize] ?? 0, result.size.height)
                    }
                }
            }
        }
        // At accessibility sizes the symbol stacks above the title.
        XCTAssertGreaterThan(try XCTUnwrap(heights[.accessibility5]), try XCTUnwrap(heights[.large]))
        let disabled = try render(ActionCapsule("Browse Files", systemImage: "folder").disabled(true), width: 180)
        XCTAssertTrue(disabled.hasVisiblePixels)
        #if os(iOS)
        // On iOS the label has no fill or border of its own at any size: the button style draws the glass.
        for scheme in schemes {
            let label = try render(ActionCapsule("Browse Files", systemImage: "folder"), width: 180, colorScheme: scheme)
            XCTAssertNil(label.color(at: CGPoint(x: 6, y: label.size.height / 2)), "no capsule fill, \(scheme)")
            XCTAssertNil(label.color(at: CGPoint(x: 90, y: 0.5)), "no capsule border, \(scheme)")
            let large = try render(ActionCapsule("Browse Files", systemImage: "folder"), width: 180, typeSize: .accessibility5,
                                   colorScheme: scheme)
            XCTAssertNil(large.color(at: CGPoint(x: 8, y: 8)), "no card fill, \(scheme)")
        }
        #else
        for (scheme, appearance) in [(ColorScheme.light, AgentLandAppearance.light), (.dark, .dark)] {
            // An oval on `surface`: filled at its middle height near the end, open at the corners where it curves.
            let oval = try render(ActionCapsule("Browse Files", systemImage: "folder"), width: 180, colorScheme: scheme)
            assertColor(oval.color(at: CGPoint(x: 6, y: oval.size.height / 2)), equals: AgentLandColor.surface.rgb(for: appearance),
                        "capsule fill, \(appearance)")
            assertColor(oval.color(at: CGPoint(x: 90, y: 0.5)), equals: AgentLandColor.separator.rgb(for: appearance),
                        "capsule border, \(appearance)")
            XCTAssertNil(oval.color(at: CGPoint(x: 4, y: 4)), "a capsule's corner is open, \(appearance)")
            // At accessibility sizes a rounded rectangle, filled much nearer its corners.
            let card = try render(ActionCapsule("Browse Files", systemImage: "folder"), width: 180, typeSize: .accessibility5,
                                  colorScheme: scheme)
            assertColor(card.color(at: CGPoint(x: 8, y: 8)), equals: AgentLandColor.surface.rgb(for: appearance),
                        "rounded rectangle fill, \(appearance)")
        }
        #endif
    }

    func testCompactActionCapsuleUsesTheLauncherBaselineWithoutReducingItsTapTarget() throws {
        for minimum in minimums {
            let standard = try render(ActionCapsule("New Chat", systemImage: "bubble.left"), width: 180,
                                      minimumTapTarget: minimum)
            let compact = try render(ActionCapsule("New Chat", systemImage: "bubble.left", compact: true), width: 180,
                                     minimumTapTarget: minimum)

            #if os(iOS)
            // On iOS the native button style sets the height (`controlSize(.large)`), so both labels fill the tap target.
            XCTAssertGreaterThanOrEqual(compact.size.height, minimum)
            XCTAssertEqual(compact.size.height, standard.size.height, "the button style, not the label, sizes the control")
            #else
            XCTAssertGreaterThanOrEqual(compact.size.height, max(minimum, 48))
            XCTAssertLessThan(compact.size.height, standard.size.height,
                              "Home's compact launcher capsules use the 48 pt baseline")
            #endif
            assertTapTargets(compact, count: 1, minimum: minimum, "compact ActionCapsule")
        }
    }

    /// Two columns 16 pt apart both ways, every cell one size; a fifth capsule is centred under the middle;
    /// one column takes the full width.
    func testActionCapsuleGrid() throws {
        func grid(_ titles: [String], columns: Int = 2) -> some View {
            ActionCapsuleGrid(columns: columns) {
                ForEach(titles, id: \.self) { title in
                    ActionCapsule(title, systemImage: "folder")
                }
            }
        }
        let long = "Open a workspace from another folder on your Mac"
        let six = try render(grid(["New Chat", "New Terminal", "Browse Files", "Resume Work", long, "Settings"]), width: 354)
        let cells = six.tapTargets.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        XCTAssertEqual(cells.count, 6)
        for cell in cells {
            XCTAssertEqual(cell.width, (354 - 16) / 2, accuracy: 0.5)
            XCTAssertEqual(cell.height, cells[4].height, accuracy: 0.5, "every capsule is as tall as the tallest")
        }
        XCTAssertGreaterThan(cells[4].height, 56, "the long title wraps and makes its row taller")
        XCTAssertEqual(cells[1].minX - cells[0].maxX, 16, accuracy: 0.5, "16 pt apart across")
        XCTAssertEqual(cells[2].minY - cells[0].maxY, 16, accuracy: 0.5, "16 pt apart down")
        XCTAssertEqual(cells[0].minX, 0, accuracy: 0.5)
        XCTAssertEqual(cells[1].maxX, 354, accuracy: 0.5)
        XCTAssertEqual(six.size.height, 3 * cells[0].height + 2 * 16, accuracy: 0.5)

        let five = try render(grid(["New Chat", "Browse Files", "Resume Work", "Open Workspace", "Settings"]), width: 354)
        let fifth = try XCTUnwrap(five.tapTargets.max { $0.minY < $1.minY })
        XCTAssertEqual(five.tapTargets.count, 5)
        XCTAssertEqual(fifth.midX, 177, accuracy: 0.5, "the fifth is centred")
        XCTAssertEqual(fifth.width, (354 - 16) / 2, accuracy: 0.5, "at a column's width")

        let one = try render(grid(["New Chat", "Browse Files", "Settings"], columns: 1), width: 354)
        let rows = one.tapTargets.sorted { $0.minY < $1.minY }
        XCTAssertEqual(rows.count, 3)
        for row in rows { XCTAssertEqual(row.width, 354, accuracy: 0.5) }
        XCTAssertEqual(rows[1].minY - rows[0].maxY, 16, accuracy: 0.5)
    }

    // MARK: InlineNotice

    func testInlineNoticeButtonsAndLayout() throws {
        let notice = InlineNotice("Chat moved to the archive", message: "Its files are still on your Mac.",
                                  actionTitle: "Undo", action: {}, onDismiss: {})
        var heights: [DynamicTypeSize: CGFloat] = [:]
        for minimum in minimums {
            for scheme in schemes {
                for typeSize in renderTestTypeSizes {
                    let result = try render(notice, width: 360, typeSize: typeSize, colorScheme: scheme, minimumTapTarget: minimum)
                    XCTAssertTrue(result.hasVisiblePixels)
                    assertTapTargets(result, count: 2, minimum: minimum, "InlineNotice \(typeSize) \(scheme)")
                    heights[typeSize] = result.size.height
                }
            }
        }
        XCTAssertGreaterThan(try XCTUnwrap(heights[.accessibility5]), try XCTUnwrap(heights[.large]),
                             "the buttons move below the text at accessibility sizes")
        // Without buttons there is nothing to hit.
        let plain = try render(InlineNotice("Copied"), width: 360)
        XCTAssertEqual(plain.tapTargets.count, 0)
        let dismissOnly = try render(InlineNotice("Saved", tone: .success, onDismiss: {}), width: 360, minimumTapTarget: 44)
        assertTapTargets(dismissOnly, count: 1, minimum: 44, "dismiss only")
        // Notices are raised above the content.
        for (scheme, appearance) in [(ColorScheme.light, AgentLandAppearance.light), (.dark, .dark)] {
            let result = try render(notice, width: 360, colorScheme: scheme)
            assertColor(result.color(at: CGPoint(x: 6, y: result.size.height / 2)),
                        equals: drawnColor(.surfaceRaised, appearance), "notice fill, \(appearance)")
        }
    }

    func testInlineNoticeSpeaksItsToneAndText() throws {
        XCTAssertEqual(InlineNotice("Copied").spokenText, "Copied")
        XCTAssertEqual(InlineNotice("Couldn't save", message: "The Mac is offline.", tone: .error).spokenText,
                       "Error: Couldn't save The Mac is offline.")
        XCTAssertEqual(InlineNotice("Low disk space", tone: .warning).spokenText, "Warning: Low disk space")
        for tone in InlineNotice.Tone.allCases {
            XCTAssertFalse(tone.systemImage.isEmpty)
        }
        XCTAssertEqual(Set(InlineNotice.Tone.allCases.map(\.systemImage)).count, InlineNotice.Tone.allCases.count,
                       "each tone has its own symbol shape")

        let log = AnnouncementLog()
        _ = try render(InlineNotice("Couldn't save", tone: .error), width: 360, announcer: log.announcer)
        XCTAssertEqual(log.entries.map(\.text), ["Error: Couldn't save"])
        XCTAssertEqual(log.entries.first?.priority, .high)
    }

    // MARK: ConnectionStatusBanner

    func testConnectionBannerLayoutAndRetryTarget() throws {
        let offline = ConnectionStatus.offline(title: "Can’t reach Studio Mac",
                                               detail: "The Mac may be asleep or on another network. Reconnecting…")
        var heights: [DynamicTypeSize: CGFloat] = [:]
        for minimum in minimums {
            for scheme in schemes {
                for typeSize in renderTestTypeSizes {
                    let result = try render(ConnectionStatusBanner(status: offline, retry: {}), width: 360,
                                            typeSize: typeSize, colorScheme: scheme, minimumTapTarget: minimum)
                    XCTAssertTrue(result.hasVisiblePixels)
                    assertTapTargets(result, count: 1, minimum: minimum, "banner \(typeSize) \(scheme)")
                    heights[typeSize] = result.size.height
                }
            }
        }
        XCTAssertGreaterThan(try XCTUnwrap(heights[.accessibility5]), try XCTUnwrap(heights[.large]))
        // Online, it takes no room.
        let online = try render(VStack(spacing: 0) {
            Color.gray.frame(height: 10)
            ConnectionStatusBanner(status: .online, retry: {})
        }, width: 360)
        XCTAssertEqual(online.size.height, 10)
        XCTAssertEqual(online.tapTargets.count, 0)
    }

    func testConnectionBannerAnnouncements() {
        let offline = ConnectionStatus.offline(title: "No network connection", detail: "Reconnecting when you're back online.")
        let first = ConnectionStatusBanner.announcement(from: offline, to: offline, recovered: "Back online")
        XCTAssertEqual(first?.text, "No network connection. Reconnecting when you're back online.")
        XCTAssertEqual(first?.priority, .high)
        XCTAssertNil(ConnectionStatusBanner.announcement(from: .online, to: .online, recovered: "Back online"),
                     "nothing to say when it opens online")
        let recovered = ConnectionStatusBanner.announcement(from: offline, to: .online, recovered: "Back online")
        XCTAssertEqual(recovered?.text, "Back online")
        XCTAssertEqual(recovered?.priority, .normal)
        let other = ConnectionStatus.offline(title: "AgentLand stopped on Studio Mac")
        XCTAssertEqual(ConnectionStatusBanner.announcement(from: offline, to: other, recovered: "Back online")?.text,
                       "AgentLand stopped on Studio Mac")
        XCTAssertGreaterThan(ConnectionStatusBanner.accessibilitySortPriority, 0, "read before the screen's content")
    }

    #if os(macOS)
    /// The banner, hosted in a real window, announces the loss and the recovery as the status changes.
    func testConnectionBannerAnnouncesInAWindow() {
        final class Model: ObservableObject { @Published var status = ConnectionStatus.online }
        struct Host: View {
            @ObservedObject var model: Model
            let announcer: AgentLandAnnouncer
            var body: some View {
                ConnectionStatusBanner(status: model.status, recoveredAnnouncement: "Reconnected to Studio Mac")
                    .environment(\.agentLandAnnouncer, announcer)
                    .frame(width: 360, height: 120, alignment: .top)
            }
        }
        let log = AnnouncementLog(), model = Model()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 360, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(model: model, announcer: log.announcer))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
        settle()
        XCTAssertTrue(log.entries.isEmpty, "silent while online")
        model.status = .offline(title: "Can’t reach Studio Mac")
        settle()
        model.status = .online
        settle()
        XCTAssertEqual(log.entries.map(\.text), ["Can’t reach Studio Mac", "Reconnected to Studio Mac"])
        XCTAssertEqual(log.entries.map(\.priority), [.high, .normal])
    }
    #endif

    // MARK: StatusDot and Badge

    func testStatusDots() throws {
        for status in StatusDot.Status.allCases {
            for scheme in schemes {
                for typeSize in renderTestTypeSizes {
                    let result = try render(StatusDot(status), typeSize: typeSize, colorScheme: scheme)
                    XCTAssertTrue(result.hasVisiblePixels, "\(status)")
                    XCTAssertEqual(result.size.width, result.size.height, "\(status) is square")
                    XCTAssertGreaterThanOrEqual(result.size.width, 10)
                }
            }
            XCTAssertFalse(status.label.isEmpty)
        }
        XCTAssertEqual(Set(StatusDot.Status.allCases.map(\.color)).count, StatusDot.Status.allCases.count)
    }

    func testBadges() throws {
        XCTAssertEqual(Badge.label(forCount: 3), "3")
        XCTAssertEqual(Badge.label(forCount: 99), "99")
        XCTAssertEqual(Badge.label(forCount: 128), "99+")
        XCTAssertEqual(Badge.label(forCount: -2), "0")
        for style in Badge.Style.allCases {
            for scheme in schemes {
                for typeSize in renderTestTypeSizes {
                    let single = try render(Badge(count: 3, style: style), typeSize: typeSize, colorScheme: scheme)
                    XCTAssertTrue(single.hasVisiblePixels)
                    XCTAssertEqual(single.size.width, single.size.height, "one digit stays a circle")
                    let long = try render(Badge(count: 128, style: style), typeSize: typeSize, colorScheme: scheme)
                    XCTAssertGreaterThan(long.size.width, long.size.height)
                }
            }
        }
    }

    // MARK: ContentUnavailable and the primary button

    func testContentUnavailable() throws {
        for scheme in schemes {
            for typeSize in renderTestTypeSizes {
                let plain = try render(ContentUnavailable("No chats yet", systemImage: "bubble.left.and.bubble.right",
                                                          description: "Start a chat from Home."),
                                       width: 360, typeSize: typeSize, colorScheme: scheme)
                XCTAssertTrue(plain.hasVisiblePixels)
                for minimum in minimums {
                    let withAction = try render(ContentUnavailable("Can’t reach Studio Mac", systemImage: "wifi.exclamationmark",
                                                                   description: "Your chats are kept on this device.",
                                                                   actionTitle: "Retry", action: {}),
                                                width: 360, typeSize: typeSize, colorScheme: scheme, minimumTapTarget: minimum)
                    assertTapTargets(withAction, count: 1, minimum: minimum, "ContentUnavailable action \(typeSize)")
                }
            }
        }
        let search = try render(ContentUnavailable.search(text: "redirect"), width: 360)
        XCTAssertTrue(search.hasVisiblePixels)
    }

    func testPrimaryButtonKeepsTheTapTarget() throws {
        for minimum in minimums {
            for typeSize in renderTestTypeSizes {
                let result = try render(Button("Go") {}.buttonStyle(.agentLandPrimary), typeSize: typeSize, minimumTapTarget: minimum)
                assertTapTargets(result, count: 1, minimum: minimum, "primary button \(typeSize)")
                XCTAssertGreaterThanOrEqual(result.size.width, minimum)
                XCTAssertGreaterThanOrEqual(result.size.height, minimum)
            }
        }
        #if !os(iOS)
        // On iOS the button is the native `.glassProminent` in the accent, which `ImageRenderer` does not draw.
        // A tint capsule in each appearance (its label is onTint, dark in dark mode).
        for (scheme, appearance) in [(ColorScheme.light, AgentLandAppearance.light), (.dark, .dark)] {
            let result = try render(Button("Reconnect") {}.buttonStyle(.agentLandPrimary), colorScheme: scheme, minimumTapTarget: 44)
            assertColor(result.color(at: CGPoint(x: 8, y: result.size.height / 2)), equals: AgentLandColor.tint.rgb(for: appearance),
                        "primary fill, \(appearance)")
        }
        #endif
    }

    // MARK: Glass

    /// `ImageRenderer` draws nothing for content on Liquid Glass (the system composites the effect), so the
    /// glass form is checked for layout only; the Reduce Transparency form is checked for its fill.
    func testGlassControlAndItsReduceTransparencyFallback() throws {
        let control = Label("Jump to latest", systemImage: "arrow.down")
            .labelStyle(.iconOnly)
            .frame(width: 36, height: 36)
            .glassControl(in: Circle())
        for (scheme, appearance) in [(ColorScheme.light, AgentLandAppearance.light), (.dark, .dark)] {
            let glass = try render(control.padding(8), colorScheme: scheme)
            XCTAssertEqual(glass.size, CGSize(width: 52, height: 52))
            let opaque = try render(control.padding(8).environment(\._accessibilityReduceTransparency, true), colorScheme: scheme)
            XCTAssertEqual(opaque.size, glass.size)
            assertColor(opaque.color(at: CGPoint(x: 14, y: 26)), equals: drawnColor(.surfaceRaised, appearance),
                        "Reduce Transparency fill, \(appearance)")
        }
        let group = GlassControlGroup(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "plus").frame(width: 36, height: 36).glassControl(in: Circle())
                Text("Message Claude Code").padding(.horizontal, 16).frame(height: 44)
                    .glassControl(in: RoundedRectangle(cornerRadius: AgentLandRadius.composer, style: .continuous))
            }
        }
        let grouped = try render(group.padding(8).environment(\._accessibilityReduceTransparency, true))
        XCTAssertTrue(grouped.hasVisiblePixels)
        XCTAssertEqual(grouped.size.height, 60)
    }

    func testGlassNeverStacks() {
        XCTAssertEqual(GlassControlBackground(reduceTransparency: false, insideGlass: false), .glass)
        XCTAssertEqual(GlassControlBackground(reduceTransparency: true, insideGlass: false), .opaque)
        XCTAssertEqual(GlassControlBackground(reduceTransparency: false, insideGlass: true), .none)
        XCTAssertEqual(GlassControlBackground(reduceTransparency: true, insideGlass: true), .none)
    }

    #if os(iOS)
    /// On iOS, text styles follow Dynamic Type, so AX5 renders are taller.
    func testAccessibilitySizesGrowText() throws {
        let standard = try render(Text("Resume work").agentLandFont(.body))
        let largest = try render(Text("Resume work").agentLandFont(.body), typeSize: .accessibility5)
        XCTAssertGreaterThan(largest.size.height, standard.size.height * 2)
    }
    #endif
}
