# AgentLandDesign

AgentLand's own design tokens and base components for iPhone, iPad and Mac (iOS 26, macOS 26), following Apple's Human Interface Guidelines (Color, Typography, Accessibility, Materials).

The iPhone and iPad screens use it (the workspace in `shared/AgentLandWorkspace`, the chat in `shared/AgentLandChat`, and the app's covers, pairing and Settings). The Mac app (`macos/Package.swift`) links it; its own screens move over in a later phase. `AgentLandTheme` in AgentLandBranding stays for the art's internals and the Mac.

## Colors

Every color has four values: light, dark, and each with Increase Contrast. Every platform draws the owner's paper and slate for the backgrounds, secondary text and separators (the owner's choice, 2026-10-07: "Paper & slate", Home's tone carried into every screen, menu, panel, sheet and row; it reverses the system backgrounds of 2026-10-06). On iPhone and iPad primary text, glyphs and the status colors draw the system's own semantic colors instead (`AgentLandColor.system` names each one), so they follow light and dark and Increase Contrast as the system does: `label` keeps 4.5:1 on every paper and slate background, and secondary text keeps the token's values because the system's `secondaryLabel` falls below 4.5:1 on slate (3.9:1 on a panel, 4.3:1 on a row); `tertiaryLabel` and the status colors under small text can be what Xcode's accessibility audit calls "Contrast nearly passed", which the UI tests log rather than fail. `SystemTextContrastTests` checks and records this on iOS. The Mac keeps the values below everywhere, and the accent, the brand and the art keep theirs on every platform.

| Token | Use | iPhone and iPad |
|---|---|---|
| `canvas` | Screen background: screens, the iPhone header, chat, Files, Git, Browser; the art's own paper and slate. | its own values |
| `surface` | Rows and grouped cells, bands, tiles, chips, user bubbles, code blocks. | its own values |
| `surfaceRaised` | Header panels, sheets, notices, banners, popovers, and the opaque stand-in for glass under Reduce Transparency. With Increase Contrast in light mode it equals the canvas; its `separator` border tells them apart. | its own values |
| `text` | Primary text. | `label` |
| `textSecondary` | Details, metadata, placeholders, section headers. | its own values (4.5:1 on paper and slate) |
| `glyphTertiary` | Chevrons and decorative symbols only (3:1). Use `textSecondary` for words. | `tertiaryLabel` |
| `tint` | AgentLand blue, the accent: links, borderless buttons, selection, prominent fills. | its own values, also the app's AccentColor asset |
| `onTint` | Text and symbols on a `tint` fill. Dark in dark mode: white on the light dark-mode tint would fall below 4.5:1. | its own values |
| `success`, `warning`, `danger` | Status text and symbols. | `systemGreen`, `systemOrange`, `systemRed` |
| `separator` | Hairlines and row separators. Decorative normally; at least 3:1 with Increase Contrast, where borders carry the edges. | its own values |
| `brand` | AgentLand's slate (fixed): the opening, lock and loading covers, the launch screen and the app icon's background. | its own value |
| `onBrand` | Art and text on the brand (fixed white). | its own value |
| `artBackdrop` | The paper/slate behind the Home and empty-chat art, which picks its day or night tones from it. The Mac's canvas values. | its own values |
| `artInk` | One-color art on the art backdrop: the paper/slate theme's primary text color (dark ink on paper, light ink on slate). | its own values |
| `artInkSecondary` | Words that belong to the art on its backdrop (Home's quip), where the system's secondary label would fall below 4.5:1. | its own values |
| `tentDoorway` | The tent's doorway, the same dark shade everywhere (fixed). | its own value |

In SwiftUI, use a token as a shape style: `.foregroundStyle(AgentLandColor.text)`, `.background(AgentLandColor.canvas)`. It resolves from the environment's color scheme and contrast on every platform (tested for all four appearances). `AgentLandColor.x.color` is for APIs that require a `Color`. `uiColor` resolves from the trait collection's interface style and accessibility contrast (the system color itself where there is one). `nsColor` resolves from the drawing appearance, including AppKit's high-contrast appearances. On macOS, SwiftUI passes only the plain light or dark appearance when it resolves an `NSColor`, so SwiftUI code on the Mac should use the shape style to get the Increase Contrast values. `rgb(for:)` is always the token's own value.

The accent on iPhone and iPad is the app's AccentColor asset (`ios/AgentLand/Assets.xcassets`, the global accent in `ios/agentland.yml`), with `tint`'s four values (`ColorResolutionTests` compares them). Views take it from the environment, so they need no `.tint(AgentLandColor.tint)`; switches keep the system's green.

### Brand

The values are the owner's established paper/slate theme (the values of `AgentLandTheme`): the HIG pass had introduced new cooler colors and a navy brand, and on 2026-09-24 the owner asked for the old theme back. On 2026-10-06 the owner chose the system's colors for the iPhone and iPad interface, with paper/slate kept only behind the Home and empty-chat art (`artBackdrop`); the Mac keeps the theme. The brand is slate #27313F, the same as the dark art backdrop, so the covers, launch screen and icon match the art. Two values differ from `AgentLandTheme` so every text pair keeps its contrast: the status colors (success, warning, danger) are darker in light mode and danger lighter in dark mode, and Increase Contrast has its own darker/lighter text and borders.

Circus artwork can use `AgentLandColor.artTones`, the five-tone day/night ramps
shared with the packaged clowns. These decorative tones are separate from the
semantic interface colors; a cross-package regression checks both ramps.

### Values

| Token | iPhone and iPad | Light | Dark | Light, Increase Contrast | Dark, Increase Contrast |
|---|---|---|---|---|---|
| `canvas` | these values | #F4F0E7 | #27313F | #F4F0E7 | #222B38 |
| `surface` | these values | #E7E1D5 | #344153 | #E7E1D5 | #2E3A4B |
| `surfaceRaised` | these values | #FBF7F0 | #3C4A5D | #FBF7F0 | #344153 |
| `text` | `label` | #354052 | #D6DDE7 | #1B222C | #F4F6F9 |
| `textSecondary` | these values | #59616C | #AEBCCC | #2F353D | #E2E8EF |
| `glyphTertiary` | `tertiaryLabel` | #6B7280 | #8E9BAD | #4F5663 | #B4C0CF |
| `tint` | these values | #32648B | #93C4E6 | #24506F | #B9DCF2 |
| `onTint` | these values | #FFFFFF | #27313F | #FFFFFF | #1B222C |
| `success` | `systemGreen` | #15703A | #5EDC8C | #0F5A2E | #8BE8AD |
| `warning` | `systemOrange` | #8A4A06 | #F5C04A | #6E3A04 | #F9D383 |
| `danger` | `systemRed` | #B3261E | #FFA59D | #8F1D17 | #FFB1AA |
| `separator` | these values | #C8C0B3 | #53647A | #847B6D | #8395AD |
| `artBackdrop` | these values | #F4F0E7 | #27313F | #F4F0E7 | #222B38 |
| `artInk` | these values | #354052 | #D6DDE7 | #354052 | #D6DDE7 |
| `artInkSecondary` | these values | #59616C | #AEBCCC | #2F353D | #E2E8EF |
| `brand` | these values | #27313F | fixed | fixed | fixed |
| `onBrand` | these values | #FFFFFF | fixed | fixed | fixed |
| `tentDoorway` | these values | #1B222C | fixed | fixed | fixed |

### Contrast

WCAG 2.x contrast ratios for every checked pair, computed by `AgentLandContrast` and asserted by `ContrastTests`:

- These are the tokens' own values: the interface on every platform, and the art and its words. On iPhone and iPad primary text, glyphs and the status colors draw the system's colors, whose contrast is the system's.
- Text pairs need 4.5:1 (AA). Primary and secondary text need 7:1 (AAA) with Increase Contrast.
- Glyph and art pairs need 3:1 (non-text graphics and large text).
- Increase Contrast never lowers a pair.
- The standard separator is a decorative hairline. With Increase Contrast it needs 3:1 against the canvas and surface.

| Pair | Kind | Needs | Light | Dark | Light, IC | Dark, IC |
|---|---|---|---|---|---|---|
| text on canvas | text | 4.5; IC 7 | 9.20 | 9.61 | 14.08 | 13.19 |
| text on surface | text | 4.5; IC 7 | 8.04 | 7.58 | 12.30 | 10.64 |
| text on surfaceRaised | text | 4.5; IC 7 | 9.80 | 6.59 | 14.99 | 9.57 |
| textSecondary on canvas | text | 4.5; IC 7 | 5.51 | 6.80 | 10.88 | 11.57 |
| textSecondary on surface | text | 4.5; IC 7 | 4.81 | 5.36 | 9.50 | 9.34 |
| textSecondary on surfaceRaised | text | 4.5; IC 7 | 5.87 | 4.66 | 11.58 | 8.40 |
| glyphTertiary on canvas | glyph | 3 | 4.25 | 4.66 | 6.49 | 7.74 |
| glyphTertiary on surface | glyph | 3 | 3.71 | 3.67 | 5.67 | 6.24 |
| glyphTertiary on surfaceRaised | glyph | 3 | 4.53 | 3.19 | 6.91 | 5.61 |
| tint on canvas | text | 4.5 | 5.54 | 7.06 | 7.53 | 9.92 |
| tint on surface | text | 4.5 | 4.84 | 5.56 | 6.58 | 8.00 |
| tint on surfaceRaised | text | 4.5 | 5.90 | 4.84 | 8.02 | 7.19 |
| success on canvas | text | 4.5 | 5.41 | 7.57 | 7.32 | 9.69 |
| success on surface | text | 4.5 | 4.73 | 5.97 | 6.39 | 7.81 |
| success on surfaceRaised | text | 4.5 | 5.77 | 5.19 | 7.80 | 7.03 |
| warning on canvas | text | 4.5 | 6.03 | 7.84 | 8.13 | 9.98 |
| warning on surface | text | 4.5 | 5.27 | 6.18 | 7.11 | 8.05 |
| warning on surfaceRaised | text | 4.5 | 6.42 | 5.37 | 8.66 | 7.24 |
| danger on canvas | text | 4.5 | 5.75 | 6.96 | 7.84 | 8.24 |
| danger on surface | text | 4.5 | 5.02 | 5.49 | 6.85 | 6.65 |
| danger on surfaceRaised | text | 4.5 | 6.12 | 4.77 | 8.35 | 5.98 |
| onTint on tint | text | 4.5 | 6.30 | 7.06 | 8.56 | 11.12 |
| separator on canvas | boundary | decorative; IC 3 | 1.59 | 2.17 | 3.67 | 4.67 |
| separator on surface | boundary | decorative; IC 3 | 1.38 | 1.71 | 3.20 | 3.77 |
| onBrand on brand | text | 4.5 | 13.15 | 13.15 | 13.15 | 13.15 |
| artInk on artBackdrop | art | 3 | 9.20 | 9.61 | 9.20 | 10.44 |
| artInkSecondary on artBackdrop | text | 4.5; IC 7 | 5.51 | 6.80 | 10.88 | 11.57 |

`ContrastTests.testReadmeRecordsTheCurrentTables` fails when these tables no longer match the code.

## Type roles

Every role is a Dynamic Type text style (none has a fixed size), so text follows the reader's setting up to AX5 on iPhone and iPad. Use `.agentLandFont(.body)` or `AgentLandTypeRole.body.font`.

| Role | Text style |
|---|---|
| `body` | body |
| `bodyEmphasized` | body, semibold |
| `secondary` | subheadline |
| `metadata`, `caption`, `caption2` | footnote, caption, caption2 |
| `code` | subheadline, monospaced |
| `codeSmall` | footnote, monospaced |
| `heading1`, `heading2`, `heading3` | title2, title3, headline |
| `quip` | callout, italic |

The iPhone and iPad app's text follows the reader's Text Size setting exactly (owner's decision, 2026-10-06; it was one step larger, through a root `agentLandLargerText()`, from 2026-09-27). The workspace's ⌘+ and ⌘− step from that setting and ⌘0 returns to it. The Mac app's text styles do not follow `dynamicTypeSize`.

`agentLandIconFrame(_:)` gives icons a square box that grows with text (`@ScaledMetric`: 16, 20 or 28 pt at the default size). `agentLandRowHeight(_:)` gives rows a minimum height that grows with body text and never drops below the minimum tap target (44 pt on iPhone and iPad, 28 pt on Mac at the default size).

## Tap targets

`minimumTapTarget()` makes a control label's hit area at least 44×44 pt on iPhone and iPad and 28×28 pt on Mac. By default it grows only the hit area, around the control, and leaves the layout alone; `.reserveSpace` grows the frame instead. Apply it to a button's or menu's label, not to the button. The minimum comes from `EnvironmentValues.agentLandMinimumTapTarget`, which previews and tests can set to the other platform's value.

## Spacing, radius, motion

- **Spacing:** 2, 4, 8, 12, 16, 24, 32, 48 (`AgentLandSpacing.xxxSmall` … `xxLarge`).
- **Radius:** chip 8, card 12, bubble 20, composer 28, all continuous. `AgentLandRadius.concentric(outer:padding:)` gives an inner shape the radius that shares the outer one's centre (a bubble 8 pt inside the composer: 20).
- **Motion:** `smooth` (`.smooth`, 0.3 s) for things that move or resize, `snappy` (`.snappy`, 0.2 s) for small state changes, and `drawer` (`.easeInOut`, 0.2 s) for opening and closing the iPhone side drawers. Under Reduce Motion they become a 0.12 s ease, or nothing with `reducedMotion: .none`. Launching with `-AgentLandUITestsDisableAnimations` turns them off, as it does for the app and the title. Use `.agentLandAnimation(_:value:)` or `withAgentLandAnimation(_:reduceMotion:_:)`.

## Liquid Glass

iOS controls use `.agentLandControlButton()` (`.glass`) and `.buttonStyle(.agentLandPrimary)` (`.glassProminent`). The control modifier applies `.menuStyle(.button)` and `.buttonStyle(.glass)` directly so native menus render their button chrome; the primary style delegates its button to `.glassProminent`. Actions, roles and disabled states remain with SwiftUI. The Mac keeps its existing styles. Use native menus, segmented pickers and toolbar defaults; plain content rows retain their normal styling.

Glass belongs to the navigation and controls layer only:

- `glassControl()` for floating controls: the composer, jump to latest, a docked "needs your input" pill. System bars bring their own.
- Never on content: messages, rows, cards, code blocks, the terminal.
- Never glass on glass: a `glassControl()` inside another adds nothing.
- `GlassControlGroup` wraps neighbouring glass controls in one `GlassEffectContainer`.
- At most one `.glassProminent` control per screen. A label on a `tint` fill of its own takes `onTint`.
- Under Reduce Transparency, `glassControl()` draws an opaque `surfaceRaised` fill with a `separator` border.

## Components

- **`ActionTile`:** a symbol and a title on the `surface` card, at least 48 pt tall, with the pointer highlight on iPad and a raised fill under the Mac cursor, and an optional disclosure chevron. It replaces `AgentLandWorkActionLabel`. It is a label: put it in a `Button` or `Menu` with `.agentLandControlButton()`. iOS supplies content only; the native button draws the chrome. The Mac retains the tile surface. At accessibility sizes the symbol moves above the title. The browser's ports use it.
- **`ActionCapsule` and `ActionCapsuleGrid`:** Home's actions as ovals (HIG, Buttons: capsules). A symbol and body text of medium weight on the `surface` fill with a `separator` border, at least 56 pt tall by default, with an explicit `compact` 48 pt baseline for Home (both grow with text and preserve platform minimum targets), with the pointer highlight on iPad and a raised fill under the Mac cursor, and an optional disclosure chevron. The content is centred and a long title wraps instead of shrinking; the capsule fills the height it is offered. At accessibility sizes the symbol moves above the title and the shape becomes a rounded rectangle. It is a label, like `ActionTile`. `ActionCapsuleGrid` lays capsules out in equal columns (16 pt gaps by default, Home explicitly uses 12 pt), every cell as tall as the tallest, and centres a last row that is not full (five actions in two columns put the fifth under the middle).
- **`InlineNotice`:** the one toast style: tone symbol, title, message, an optional action and a dismiss button, each at least the minimum tap target. VoiceOver hears it when it appears or its text changes; warnings and errors say so first and interrupt current speech. At accessibility sizes the buttons move below the text. `identifiers` puts UI-automation identifiers on its text, action and dismiss button, never on the container.
- **`ConnectionStatusBanner`:** keep it in the view tree. It draws nothing while online, shows the offline card with an optional Retry, announces the loss (interrupting) and the recovery, and is read before the screen's content (`accessibilitySortPriority` 1000; place it beside the content in one accessibility container). `identifier` and `retryIdentifier` go on the offline card and its Retry.
- **`StatusDot`:** online ●, working ◉, needs attention ◆, offline ■, idle ○. The shapes differ as well as the colors, and it grows with text. Its accessibility label is the status.
- **`Badge`:** a count ("99+" past 99) or a short word, `prominent` (`onTint` on `tint`) or `neutral` (`textSecondary` in a `separator` outline).
- **`ContentUnavailable`:** `ContentUnavailableView`, optionally with one primary action; `ContentUnavailable.search(text:)` for empty searches. iPhone and iPad keep the system's text colors; the Mac draws it in AgentLand's.
- **List backgrounds:** lists hide their own background over their page, `agentLandListPage` in the environment (the owner's choice, 2026-10-07): the canvas on a full screen (the default), `surfaceRaised` in a sheet (`agentLandSheetPage()`, which also sets the sheet's `presentationBackground`), and nothing inside a header panel, whose own raised platter is the page (`agentLandPanelPage()`). `listPageBackground()` hides a list's background over that page (and sets the navigation container's background, so a pushed page keeps it), `hidesListPageBackground()` hides it where something around the list paints the page, and `groupedPageBackground()` paints the page around a list or in its place; the Mac always paints the canvas. Rows are `surface` with `separator` between them: `listRowFill(_:separator:)` on a row on every platform, `surfaceRows()` over sections on iPhone and iPad, and `AgentLandForm`, a grouped `Form` whose rows are filled that way (a plain `Form` on the Mac); `macListRowBackground(_:separator:)` fills a row on the Mac only (Files' canvas rows, which stay clear over their page on iPhone and iPad).
- **`AgentLandPrimaryButtonStyle`** (`.buttonStyle(.agentLandPrimary)`): on iOS the native `.glassProminent` button in the accent from the environment (the AccentColor asset); on the Mac `onTint` on a `tint` capsule. At least the minimum tap target.
- **Haptics:** `.agentLandHaptic(.selection | .success | .warning, trigger:)` through `sensoryFeedback`.
- **`AgentLandAnnouncer`:** the VoiceOver announcement the notice and banner use, read from the environment so tests can record it.

Each component has previews.

## Tests

```sh
swift test --package-path shared/AgentLandDesign
```

- Contrast for every pair in every appearance, and this README's tables.
- Color resolution through SwiftUI's environment (all four appearances), AppKit appearances, and on iOS the trait collection.
- Type roles, spacing, radius, tap-target geometry, scaled icons and rows, motion fallbacks and the UI-test switch, haptics.
- `ImageRenderer` renders of every component at the default and AX5 sizes, light and dark. They check sizes, that every hit area reaches both the platform minimum and 44 pt without overlapping its neighbours, and that the accessibility-size layouts take effect. Sampled pixels check the fills: tile `surface`, notice `surfaceRaised`, primary `tint`, and the glass fallback `surfaceRaised`.
- VoiceOver announcements: a notice's text and priority, and a banner hosted in a window announcing loss and recovery.

Limits:

- **Dynamic Type on the Mac.** macOS has no Dynamic Type, so under `swift test` the AX5 renders keep Mac text sizes. They still exercise the accessibility-size layouts, and the text-growth check runs only when the suite runs on iOS.
- **Glass offscreen.** `ImageRenderer` draws nothing for content on Liquid Glass, so glass is checked for layout and its Reduce Transparency form for color.
- **Test-only dependency.** The test target depends on AgentLandBranding for the palette sheet. If AgentLandBranding ever depends on this package, move the sheet into AgentLandBranding's tests.

## Palette sheet

```sh
AGENTLAND_DESIGN_EVIDENCE=1 swift test --package-path shared/AgentLandDesign --filter PaletteSheetTests
```

This writes `.evidence/design-system-20260924/` at the repository root:

- `palette-sheet.png` shows the tokens' own values (the Mac's paper/slate theme and the art): the opening cover, Home (tent, clown frame 0, arched title and quip over a 2×3 grid of `ActionTile`s), a chat (user bubble, reply, tool row, composer) and a settings list with the app icon, each in light and dark, plus every token's values.
- The individual panels are `slate-*.png`.
