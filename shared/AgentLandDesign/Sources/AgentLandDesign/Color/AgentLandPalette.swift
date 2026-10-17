import SwiftUI

/// AgentLand's palette: the owner's paper/slate theme (the values of `AgentLandTheme`, restored on 2026-09-24) on every
/// platform. On iPhone and iPad the backgrounds, secondary text and separators draw these values too (the owner's
/// choice of 2026-10-07, "Paper & slate" everywhere, reversing the system backgrounds of 2026-10-06), so every screen,
/// panel, sheet and row shares Home's paper and slate; primary text, glyphs and the status colors stay the system's
/// (`system`), and the accent stays AgentLand blue, which the app's AccentColor asset holds too. Every text and glyph
/// pair of these values is checked against WCAG 2.x in every appearance (`AgentLandContrast.requirements`, recorded in
/// the package README).
public extension AgentLandColor {
    /// The screen background: screens, the iPhone header, chat, Files, Git and Browser (the art's own paper and slate,
    /// `artBackdrop`).
    static let canvas = AgentLandColor("canvas", light: 0xF4F0E7, dark: 0x27313F,
                                       lightIncreasedContrast: 0xF4F0E7, darkIncreasedContrast: 0x222B38)
    /// Rows and grouped cells, bands, tiles, chips, user bubbles and code blocks.
    static let surface = AgentLandColor("surface", light: 0xE7E1D5, dark: 0x344153,
                                        lightIncreasedContrast: 0xE7E1D5, darkIncreasedContrast: 0x2E3A4B)
    /// Things that float above content: header panels, sheets, notices, banners, popovers and the opaque stand-in for
    /// glass. With Increase Contrast in light mode it matches the canvas; its `separator` border tells them apart.
    static let surfaceRaised = AgentLandColor("surfaceRaised", light: 0xFBF7F0, dark: 0x3C4A5D,
                                              lightIncreasedContrast: 0xFBF7F0, darkIncreasedContrast: 0x344153)
    /// Primary text (iPhone and iPad: `label`).
    static let text = AgentLandColor("text", light: 0x354052, dark: 0xD6DDE7,
                                     lightIncreasedContrast: 0x1B222C, darkIncreasedContrast: 0xF4F6F9,
                                     system: .label)
    /// Secondary text: details, metadata, placeholders, section headers. These values on iPhone and iPad too, since the
    /// system's `secondaryLabel` falls below 4.5:1 on the slate panels and rows (3.9:1 and 4.3:1).
    static let textSecondary = AgentLandColor("textSecondary", light: 0x59616C, dark: 0xAEBCCC,
                                              lightIncreasedContrast: 0x2F353D, darkIncreasedContrast: 0xE2E8EF)
    /// Glyphs only (chevrons, disclosure arrows, decorative symbols), checked at 3:1 like other
    /// non-text graphics (iPhone and iPad: `tertiaryLabel`). Use `textSecondary` for words.
    static let glyphTertiary = AgentLandColor("glyphTertiary", light: 0x6B7280, dark: 0x8E9BAD,
                                              lightIncreasedContrast: 0x4F5663, darkIncreasedContrast: 0xB4C0CF,
                                              system: .tertiaryLabel)
    /// AgentLand blue, the accent: links, borderless buttons, selection, prominent fills. On iPhone and iPad the
    /// app's AccentColor asset has these same four values and is the app's accent, so views take it from the
    /// environment's tint without a `.tint`; use the token where an API needs the color itself (UIKit's caret, a
    /// stroke). Switches stay the system's green.
    static let tint = AgentLandColor("tint", light: 0x32648B, dark: 0x93C4E6,
                                     lightIncreasedContrast: 0x24506F, darkIncreasedContrast: 0xB9DCF2)
    /// Text and glyphs on a `tint` fill. Dark on the light dark-mode tint, so primary buttons keep their
    /// contrast in dark mode.
    static let onTint = AgentLandColor("onTint", light: 0xFFFFFF, dark: 0x27313F,
                                       lightIncreasedContrast: 0xFFFFFF, darkIncreasedContrast: 0x1B222C)
    /// Status colors (iPhone and iPad: `systemGreen`, `systemOrange` and `systemRed`).
    static let success = AgentLandColor("success", light: 0x15703A, dark: 0x5EDC8C,
                                        lightIncreasedContrast: 0x0F5A2E, darkIncreasedContrast: 0x8BE8AD,
                                        system: .systemGreen)
    static let warning = AgentLandColor("warning", light: 0x8A4A06, dark: 0xF5C04A,
                                        lightIncreasedContrast: 0x6E3A04, darkIncreasedContrast: 0xF9D383,
                                        system: .systemOrange)
    static let danger = AgentLandColor("danger", light: 0xB3261E, dark: 0xFFA59D,
                                       lightIncreasedContrast: 0x8F1D17, darkIncreasedContrast: 0xFFB1AA,
                                       system: .systemRed)
    /// Hairlines and borders, row separators included. Decorative in the standard appearances; at least 3:1
    /// against the canvas and surface with Increase Contrast, where borders carry the separation.
    static let separator = AgentLandColor("separator", light: 0xC8C0B3, dark: 0x53647A,
                                          lightIncreasedContrast: 0x847B6D, darkIncreasedContrast: 0x8395AD)

    /// AgentLand's slate: the opening, lock and loading covers, the launch screen and the app icon's
    /// background.
    static let brand = AgentLandColor(fixed: "brand", 0x27313F)
    /// Art and text on the brand color (the covers and the icon).
    static let onBrand = AgentLandColor(fixed: "onBrand", 0xFFFFFF)
    /// The paper/slate behind the Home and empty-chat art on every platform: the art takes it as its backdrop and picks
    /// its day or night tones from it. The values are the canvas's.
    static let artBackdrop = AgentLandColor("artBackdrop", light: 0xF4F0E7, dark: 0x27313F,
                                            lightIncreasedContrast: 0xF4F0E7, darkIncreasedContrast: 0x222B38)
    /// One-color art on the art backdrop (tent, clown, arched title): the paper/slate theme's primary text color.
    static let artInk = AgentLandColor("artInk", light: 0x354052, dark: 0xD6DDE7,
                                       lightIncreasedContrast: 0x354052, darkIncreasedContrast: 0xD6DDE7)
    /// Words that belong to the art on its backdrop (Home's quip): the paper/slate theme's secondary text color,
    /// which keeps 4.5:1 there where the system's secondary label would not.
    static let artInkSecondary = AgentLandColor("artInkSecondary", light: 0x59616C, dark: 0xAEBCCC,
                                                lightIncreasedContrast: 0x2F353D, darkIncreasedContrast: 0xE2E8EF)
    /// The tent's open doorway, the same dark shade wherever the tent is drawn.
    static let tentDoorway = AgentLandColor(fixed: "tentDoorway", 0x1B222C)

    /// Circus shading, darkest first. The packaged artwork uses these same five day/night tones
    /// (branding/clown-ride.json); the base paper/slate interface palette stays independent.
    static let artTones: [AgentLandColor] = [
        AgentLandColor("artOutline", light: 0x11161D, dark: 0x0F141B,
                       lightIncreasedContrast: 0x11161D, darkIncreasedContrast: 0x0F141B),
        AgentLandColor("artDark", light: 0x354052, dark: 0x62708A,
                       lightIncreasedContrast: 0x354052, darkIncreasedContrast: 0x62708A),
        AgentLandColor("artMid", light: 0x66728A, dark: 0x909DB3,
                       lightIncreasedContrast: 0x66728A, darkIncreasedContrast: 0x909DB3),
        AgentLandColor("artLight", light: 0xB3BDCA, dark: 0xC7D0DC,
                       lightIncreasedContrast: 0xB3BDCA, darkIncreasedContrast: 0xC7D0DC),
        AgentLandColor(fixed: "artWhite", 0xFFFFFF)
    ]

    /// The adaptive interface tokens, in table order.
    static let semanticColors: [AgentLandColor] = [
        .canvas, .surface, .surfaceRaised, .text, .textSecondary, .glyphTertiary,
        .tint, .onTint, .success, .warning, .danger, .separator
    ]

    /// The adaptive tokens of the art (backdrop and ink), which keep their own values on every platform.
    static let artColors: [AgentLandColor] = [.artBackdrop, .artInk, .artInkSecondary]
}
