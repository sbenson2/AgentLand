# A · Original artwork

A focused refinement of the selected A launcher. Open `index.html` directly or serve this directory. One centered interactive phone retains the single top navigation row, the balanced two-column grid, all six Home destinations, Open Work search/workspace switching and the sample working screens.

## Artwork and tone

Home restores the existing native **broad shaded pixel wordmark above the larger tent and clown**. It uses unchanged copies of these evaluation screenshots:

- `.evidence/iphone-home-evaluation-20260929/screenshots/home-light.png` → `assets/native-home-light.png`
- `.evidence/iphone-home-evaluation-20260929/screenshots/home-dark.png` → `assets/native-home-dark.png`

Both original files are 1206 × 2622 pixels, corresponding to a 402 × 874-point capture. A CSS viewport reveals only the logical **y130–430** artwork region, across the full original 402-point width. The larger lower bound preserves the dark capture's clown below the tent; the old navigation, quip and Home controls are excluded. The full screenshots remain unchanged on disk. There is no raster editing, new artwork, reimplementation of the wordmark or native app rendering in this artifact.

The visible scene keeps the original title/tent/clown proportions and positions relative to each other. It scales proportionally on narrower previews with pixelated image rendering and no blur, saturation change or geometry transformation. At desktop size the phone's content width is 402 CSS pixels and its height is 874, matching the capture's logical dimensions.

Default artwork opacity is **0.88**, a 12% softening over the matching opaque phone background. The external **Show original tones** control switches between opacity 0.88 and 1; it does not create another layout. Only artwork changes tone. Buttons, icons, navigation and task content retain their existing styling. The appearance control uses the matching original scene for paper and slate.

The screenshot's exact light paper is `#F4F0E7`, one channel above the earlier prototype's `#F4F0E6`. This artifact uses `#F4F0E7` only inside the phone to avoid a visible rectangle around the scene. Slate stays `#27313F`. Other theme tokens and production assets are unchanged.

## Layout and interactions

The full-width original scene replaces Round 2's small horizontal lockup and flat SVG wordmark. The A grid uses 64-pixel minimum action heights with 12-pixel gaps; the task view reserves 32 pixels below its content before the simulated bottom safe area. Narrow-screen content may scroll. Status and navigation remain outside that scroll view, and chat still scrolls above a pinned composer.

All route/action selectors are retained, including `data-concept="a"`, `data-open-work`, `data-tabs`, `data-action` and sheet controls. Open Work retains searchable sample workspaces, current-task indication, contained keyboard focus, Escape/Close/backdrop dismissal and focus restoration.

## Verification and limits

Worker checks compare screenshot hashes with the original files, check JavaScript syntax, and verify the Home's six action destinations and single navigation-row structure. The lead owns fresh browser verification and capture for this selected-A artifact; prior previews/checks were not copied.

The scene is a still capture, so paper and slate show the clown at their original capture positions rather than matching animation frames. No circus animation, native Dynamic Type, VoiceOver, software keyboard or host integration is claimed. Names, task states, messages, files and terminal output are invented sample data; nothing connects or persists. This is a prototype refinement only. Production source/assets, previous comparison directories, installed apps and devices remain untouched.

## Lead browser verification

Five destination routes and Open Work search passed without JavaScript errors. At 320, 375 and 402 CSS pixels, the page has no horizontal overflow, one navigation bar, and no visible phone buttons below 44px in either dimension. Light/dark and phone-only previews are in `previews/`; see `checks.json`. Artwork sources remain unchanged; the presentation is static, and this is not native iPhone runtime certification.
