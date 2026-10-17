# AgentLand iPhone navigation concepts

Open `index.html` directly or serve this directory as static files. This interactive artifact has no packages, network requests or build step. The appearance control switches all three previews between AgentLand's paper and slate colors. Select task tabs, open **Open Work**, search the sample work, switch workspaces, and try the six Home actions.

All three concepts now share **exactly one top navigation row**: a pinned, labeled Open Work control on the left, horizontal task tabs beside it, and a contextual task-actions control when work is selected. The status area above it is simulated system chrome. There is no second navigation or workspace-header row. Only the Home composition changes between concepts.

Captured previews: [All three Homes, light](previews/home-light.png) · [All three Homes, dark](previews/home-dark.png) · [All three working screens](previews/working.png) · [Open Work sheet](previews/open-work.png) · [stacked mobile layout](previews/mobile.png). Browser-check results are in [checks.json](previews/checks.json). The lead refreshes these artifacts after each browser review; until then they describe the previous capture.

All workspace names, tasks, chat messages, file contents and terminal output are invented sample data. The previews do not connect to AgentLand or persist anything. The sample-data note and comparison captions sit outside the phone frames.

## Design foundation

- **Color:** existing paper `#F4F0E6`, slate `#27313F`, raised paper `#E8E2D5`, secondary text `#59616A`, and circus blue-gray `#6A7892`. Slate appearance uses raised slate `#364252` and secondary text `#B4BBC4`.
- **Type:** the copied Holtwood One SC face carries the arched AgentLand wordmark. System sans serif carries navigation and work content; monospace appears in terminal and file samples.
- **Layout:** three equal phone previews sit side by side on a wide screen and stack on a narrow screen. Each phone reserves a status area and gesture bar. The single navigation row stays above the independently scrolling task view; chat history scrolls while the composer remains pinned below it.
- **Hierarchy:** raised chrome separates navigation from the paper work surface. The selected tab joins that surface visually, with a distinct shape and weight. Home keeps all six actions and identifies the current workspace below the circus artwork.

## Three Home alternatives

**A · Action grid.** The existing two-column, six-action structure gives destinations equal emphasis. The arched title and tent retain the most space. Labels can wrap naturally without competing with redundant chevrons.

**B · Primary actions.** New Chat and Resume Work take the first two full-width positions. The remaining four actions form a compact two-column grid below them. This is a hypothesis about useful starting and resuming paths, not a research finding that these actions should be preferred.

**C · Grouped list.** A smaller horizontal circus header precedes six text-led actions under Start, Find work and Preferences. Flat separators and consistent row heights make the launcher easier to scan as a list.

These alternatives now compare Home hierarchy with navigation held constant. None claims demonstrated superiority.

## Shared interaction model

Task tabs use browser-like rounded tops. Long titles truncate within the available tab-strip width instead of overlapping controls; accessible labels, title tooltips, task headings and Open Work retain the full name. Choosing a task scrolls its selected tab into view. The left control remains pinned while tabs move horizontally. Sample destinations opened from Home remain in that workspace's tab strip for the current page session, so returning to another tab does not immediately remove them.

Open Work is a searchable bottom sheet with workspace chips and task rows. Current workspace context appears below its title, each row includes distinguishing context, and the current task has a checkmark. Search includes all three sample workspaces. Choosing a workspace shows its Home behind the sheet; choosing a task dismisses the sheet and selects it. The active task's trailing control opens a small sheet with context and relevant working navigation actions. Root Home has no trailing task control. Settings remains one of the six Home actions.

Sheets focus a useful control on opening, keep Tab/Shift-Tab within their controls, make the covered phone controls inert, and dismiss with Close, Escape or a backdrop click. Dismissal returns focus to the opening control; selecting a destination focuses its selected tab. The prototype offers navigation actions rather than a simulated Close Tab or Stop operation, whose production lifetime semantics need native implementation.

The six Home actions still route to sample chat, terminal, files, resumed chat, workspace switching or settings. Chat links into files, and Files and Terminal have working navigation actions. These demonstrate route intent rather than host behavior.

## Guidance and scope

The owner's latest **one navigation bar** direction supersedes earlier two-row proposals. The refinement preserves the owner-approved paper/slate palette and local circus/font assets. It removes repeated workspace chrome, makes task selection visible, and compares three Home arrangements without changing production app code.

Frontend Design informed the restrained hierarchy and consistency of typography, spacing and surfaces. UI/UX Pro Max's native `references/pro-rules.md` and focused keyboard guidance informed 44-pixel prototype controls, safe-area separation, labeled controls, visible focus, reduced motion and sheet focus handling. These are design checklists, not evidence of usability or native accessibility certification.

The tent and Holtwood One SC font are copied from the repository's shared branding assets. `assets/OFL.txt` contains the font license. No external assets are loaded.

## Verification and limits

The prior browser pass checked Home routes, workspace search/switching, task selection and composer bounds, with no JavaScript errors or document overflow at 320, 375, 402 and 844 CSS pixels. The lead repeated that browser pass after the single-bar refinement; the refreshed results are in `previews/checks.json`.

This is an HTML/Chromium prototype. Closing or reordering tabs, retained task drafts, actual editor state, real software-keyboard behavior, native Dynamic Type, VoiceOver and host connections are outside the demonstration. Sample work content is static. Local tab choices exist only until the page reloads. Native implementation still needs its own runtime and accessibility verification.
