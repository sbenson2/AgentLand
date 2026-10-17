# AgentLand iPhone Home comparison · Round 2

Open `index.html` directly or serve this directory. The artifact is self-contained: local artwork/font assets, plain HTML/CSS/JavaScript, no package installation, network request or build step. It is a new comparison round; `../iphone-concepts/` remains unchanged.

All three alternatives share the same fixed **single-row top bar**: pinned Open Work on the left, horizontally scrolling task tabs, and a contextual task-actions control when a working tab is selected. Each has exactly the same six Home actions and working sample routes. Workspace context stays in Home, Open Work and task details rather than a second navigation row. Chat history scrolls independently above a pinned composer.

Fresh captures: [Homes in paper](previews/home-light.png) · [Homes in slate](previews/home-dark.png) · [Working screens](previews/working.png) · [Open Work](previews/open-work.png) · [Narrow stacked comparison](previews/mobile.png). Detailed results are in [browser checks](previews/checks.json).

## What changed in this round

**A · Compact launcher.** A small horizontal wordmark/tent lockup precedes a balanced two-column grid placed higher on screen. Larger action cells keep mixed-length labels comfortable. This tests finding any destination without emphasizing one, with less visual presence for the artwork.

**B · Continue first.** A recent sample conversation, its workspace and its state form the main Home anchor. Resume Work is part of that card. New Chat sits under Start; the four other actions follow together. This tests whether naming the resumable work makes continuation easier to recognize, and depends on having useful recent work. The sample recent task is selected from that workspace's existing conversation data; it is not live activity or measured recency.

**C · Action list.** Compact branding precedes six generous full-width rows in three groups: Start, Continue and Tools. This tests the scanning value of full-width labels and explicit separation, at the cost of using more vertical space than a grid.

The paper/slate theme, Holtwood wordmark face, tent asset, shared tab bar, sheets and working-screen routes are reused. Changes are confined to Home markup, local comparison copy and Home-specific styles. No new backend or production app behavior is introduced.

## Compare the layouts

In each concept, resume **Fix sign-in callback**, switch to **Website refresh** through Open Work, and browse **README.md**. Compare which starting point is easiest to find, how clearly the current workspace is identified, and how much scrolling is needed. The page includes this prompt and the sample-data note outside the phone frames.

The hypotheses are not usability results. Clear grouping, separation, restrained competing styles and adequate targets informed the comparison. Neither these prototypes nor the cited research in the project evaluation establish that continuation-first hierarchy, a grid, or a list is best for AgentLand.

## Shared interactions and limits

Open Work searches all three sample workspaces. Workspace chips switch the Home behind the sheet; selecting a task dismisses it. Long tab titles truncate to the available space, while full names remain in Open Work and task headings. The selected tab scrolls into view. Destinations opened from Home remain in the local workspace's tab strip until page reload.

Sheets contain keyboard focus, make covered phone controls inert, and dismiss through Close, Escape or a backdrop click. Existing action and route selectors are retained. The appearance control compares paper and slate globally; reduced motion is respected.

All names, state labels, messages, files and terminal output are invented sample content. No host connects, no real operation executes, and nothing persists across reload. Closing/reordering tabs, retained drafts, actual editor state, a real software keyboard, native Dynamic Type and VoiceOver remain outside this HTML demonstration.

## Checks

Worker verification: `node --check app.js` and a source-level check that each Home renders each of the six action destinations exactly once; static markup contains one Open Work control and one task strip in each of its three navigation rows.

The lead's fresh Chromium pass checked 15 non-sheet Home destinations across the three concepts, Open Work search, workspace switching and task selection. No JavaScript errors or document overflow were found at 320, 375, 402 and 844 CSS pixels, and visible Home controls met the 44-pixel minimum. A final check confirmed standalone `file://` loading, exactly three navigation elements, and B's Continue card updating to **Update landing copy** after switching to Website refresh. The lead reviewed the comparison and captured the current round's previews; capture animations were disabled to prevent appearance-switch transition frames. These are prototype browser checks, not native iPhone, VoiceOver, Dynamic Type or comparative-user-performance evidence. No prior previews were copied into this round.

The local font copy includes its license at `assets/OFL.txt`. Production app code and installed devices are unchanged.
