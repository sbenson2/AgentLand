# A · Workspace explorer

## Git management tree

Git now has workspace-scoped sample repository state in `git-prototype.js` and tree rendering in `git-ui.js`. Expand staged, unstaged and untracked folders; inspect full-file before/after comparisons; stage or unstage individual files or all changes; enter a message and commit only staged files. Expand Branches to create, switch, track remote branches or delete a non-current branch. Switching with uncommitted changes offers stash-and-switch. History exposes each commit’s files. Stashes support save, apply and confirmed drop. Remotes support sample fetch, fast-forward pull, push/publish and adding a sample origin. Discard and deletion require confirmation. Solo chats offers sample initialization.

All operations are in-memory simulation: no files, Git commands, host or network are touched; reload resets state. No merge/rebase, conflict editor, partial-hunk staging, credentials or real repository integration is implemented. File comparisons show full content, not a computed line diff. Browser checks cover staging, staged commits, branch protection, publishing, stash apply, confirmation cancellation, workspace isolation, initialization and 320/375/402 widths. Independent state tests covered fast-forward/divergence protection and revealed an upstream-count issue that was corrected and rechecked. Evidence: `previews/git-management-checks.json` and `previews/git-management-tree.png`.

Current drawer controls use a two-step close: swipe a task or workspace left to reveal a red **Close** button, then tap it. A full swipe only reveals the button. The subtle left-chevron control, right-click, or Arrow Left offers the same reveal without a touch gesture; Escape or Arrow Right dismisses it. Only one row reveals Close at a time. Vertical scrolling does not reveal or close a row, and a horizontal swipe does not select it.

Workspace groups have more spacing, separators, an indented task rail, sample path labels, and SVG tent, clown, ticket and circus-ring terminal icons. These use the existing icon system; no new raster art was generated. The drawer shows only open workspaces and open task rows, with no search, Home row, bulk controls or Closed tasks section. The header menu remains a task switcher only.

Closing keeps the drawer open. Task ownership includes the workspace, so the two sample Terminal IDs are independent. Closing an inactive workspace leaves the current one selected; closing the active workspace selects the next open workspace and Home. Closing the last workspace shows **No open workspaces** and a Resume Workspace action in every explorer pane. Closed workspaces retain their sample files, tasks and history, and can be reopened from Home's Resume Workspace choices. This is in-memory prototype state; no folder is deleted and no remote process is stopped.

Latest verification: `node --check app.js` and `node previews/check-swipe-close.cjs` passed. The focused browser check covers mouse and touch reveal/tap, full swipe without closing, duplicate task IDs, no swipe navigation, vertical touch scrolling, keyboard reveal/Escape, inactive/active/last workspace closure, resume with preserved files, 320-pixel overflow, and zero page errors. Captures wait for the drawer entrance to settle: [workspace sections](previews/circus-workspaces.png), [task Close revealed](previews/task-close-revealed.png), [workspace Close revealed](previews/workspace-close-revealed.png), [check results](previews/swipe-close-checks.json). Earlier reports below document preceding versions.

## Latest refinement

All three header controls have outlines. The header dropdown only switches between open tasks. Workspace selection keeps the drawer open. The quip is 18px lower and cycles through Holtwood, Chalkduster, Papyrus and Marker Felt on each Home render (system-font fallbacks apply). Expanded Home groups and the growth layer have no surrounding border. Option grids size to their content rather than scrolling internally. Earlier browser checks passed all four actions at 320, 375, 402 and desktop widths, header borders and drawer retention, with no page errors. Captures: `previews/home-outlined-header.png` and `previews/home-borderless-options.png`. Earlier notes below describe prior iterations where superseded.

A focused interactive refinement of selected A. Open `index.html` directly or serve this directory. Home has four expanding actions, existing pixel artwork and a larger italic quip. The single header includes the workspace/current-task menu between the sidebar and Settings gear. Changes are confined to this prototype.

## Four Home actions

The top row is **New Chat** and **New Terminal**; the bottom row is **New Workspace** and **Resume Workspace**. Home has no Settings or Browse Files action. The header gear opens Settings and the left drawer contains Files.

The pressed action grows from its tile into the same 192-pixel launcher area over 240ms while its siblings fade behind it. Choices then fade into the expanded surface over 140ms. Back and Escape reverse the expansion and restore focus to the original action. The artwork, quip and launcher bounds stay in place. Focus stays inside Home during replacement; choices are inert until the transition completes. Reduced motion changes the choices immediately. Longer workspace lists scroll within this area.

New Chat offers Standalone Chat, OpenCode, Claude Code and Codex. Standalone Chat opens in Solo chats; the agent choices keep the selected workspace. New Terminal offers Shell and the three agent programs. Each creates or reopens one sample tab for its choice. New Workspace adds **Scratch project** (`~/Workspaces/Scratch`) or **App experiment** (`~/Developer/AppExperiment`) to the in-memory sample catalog, with a read-only README. Resume Workspace restores that workspace's last selected task, reopening a closed tab when necessary. These paths are sample labels; no directory, process or host is created.

## Header and explorer

The navigation row uses the same opaque paper/slate background as the main surface. It contains a 44 × 44-pixel sidebar control on the left, one **current-task button** with the workspace name above the task title in the center, and a 44 × 44-pixel Settings gear on the right. Both names update on selection. All controls have accessible names and expanded state. There is no persistent task strip or second navigation row.

The current-task button opens a compact menu directly below the header. It lists this workspace's open tabs, separate close controls, closed tabs that can be reopened, and Close other tabs. Switching/reopening dismisses the menu; closing refreshes it in place. Escape returns focus to the header button, outside clicks dismiss it, and Arrow Up/Down plus Home/End move among its controls. Closing a tab keeps the sample remote work intact.

The sidebar control opens the explorer **from the left, below the fixed header**. It replaces the current task content rather than opening a bottom sheet or covering the header. On this phone-sized prototype it occupies the full content width. The sidebar control closes it; Escape returns to the task and focuses the control. Choosing a workspace keeps the drawer open, updates the header and refreshes its scoped content so another action can follow. Choosing a task returns to task content.

Opening and closing use cancelable 180ms slide animations. A panel stays mounted through its closing motion and hides after completion. One owner and transition generation protect rapid opening/closing, task selection and left/right switching from stale completion callbacks. Only one panel is visible: selecting the other side replaces the previous panel and starts the new panel's entrance from its own edge. Reduced motion opens/closes immediately.

The explorer's local tabs are **Workspaces**, **Git**, **Files** and **Sessions**, laid out as exactly four equal-width columns with `repeat(4, minmax(0, 1fr))`. They belong to the replaceable explorer content rather than a persistent global navigation bar. Workspaces offers searchable grouped workspace/task context, including tasks whose tabs were closed. Files, Git and past sessions use distinct data for the selected workspace. AgentLand has Swift/project paths; Website refresh has `src/index.html` and `src/tokens.css`; Solo chats has local notes and an explicit no-repository Git state. Files and diffs are read only; Git performs no mutation. Arrow keys switch between the four explorer tabs.

Sessions displays **Past sessions** for the current workspace. Selecting a previous session opens/restores its conversation tab, dismisses the explorer and preserves workspace ownership. Reopening the same session reuses its identifier rather than creating duplicate tabs.

## Task controls

Task selection, closing and reopening are available in the header's compact menu and the left drawer's **Workspaces** pane. An explicit Home row returns to the launcher. Open tasks in the selected workspace have separate sibling **×** close buttons with 44-pixel targets. Closed rows offer reopening. **Close other tabs** preserves Home and the current task. Closing the selected task chooses a neighboring task or Home.

Closing a row or choosing Close other tabs keeps Workspaces open and refreshes its task list. Selecting or reopening a task dismisses the drawer. On viewports at or below 360 pixels, the decorative phone bezel and outer preview gutters are removed, allowing equal explorer columns to use the full native surface width while keeping labels readable at 13 pixels.

Closed task identifiers are kept in memory per workspace, with the original sample task catalog and opened file tasks retained for reopening through Workspaces or Files. Closing a task tab does not stop the sample remote conversation/terminal; the outside-phone caption says this explicitly. No stop-remote-task command is simulated. Files are read only, so there is no dirty-editor state or save/discard prompt. Tab choices reset on page reload.

## Settings from the right

The header gear opens Settings **from the right, below the fixed header**; closing slides it back to the right. It replaces task content and is mutually exclusive with the left explorer. Settings includes Connection, Security, Notifications and Appearance, with a Back to Settings route and Go to Home. Connection identifies the preview-only sample host; Security and Notifications toggle only local sample values; Appearance switches the actual paper/slate preview. None changes production settings or a host.

## Artwork provenance

`assets/native-home-light.png` and `assets/native-home-dark.png` are unchanged copies of `.evidence/iphone-home-evaluation-20260929/screenshots/home-light.png` and `home-dark.png`, each 1206 × 2622 pixels. CSS crops logical y130–214 for the broad shaded pixel wordmark. The circus uses the existing transparent `assets/tent-tone.png` and unchanged copies of the packaged `TentDoorway.png` and `ClownRide-whiteface.png` from `shared/AgentLandBranding/Sources/AgentLandBranding/Resources/`. The clown displays the first 96 × 96 sprite frame as a still. No raster was edited, generated or redrawn.

The scene uses opacity 0.88 over the exact captured paper `#F4F0E7` or slate `#27313F`, with sharp pixel rendering and proportional scaling. The tent and clown are 10% smaller than the preceding four-action version (about 241- and 130-pixel frames at full size). A 0.65-pixel SVG morphology filter thickens the existing wordmark's dark outline without changing a raster file. The wordmark remains 34 pixels lower than the original six-action version. Slate slightly lifts the transparent artwork with CSS brightness. The external tone control switches artwork opacity to/from 1; the doorway stays opaque. The phone has 402 CSS pixels of content width on a wide page and height 874. Home retains 64-pixel action targets and 12-pixel grid gaps. The actual gap below the grid remains 76 pixels, about half the original 151 pixels.

Home restores **Juggling three pull requests**, the quip shown in the original native screenshot, in 24-pixel italic text. Native Home uses `QuipStore.shared` and its `.quip` typography role; this prototype pins one existing quip rather than implementing that store. The quip and wordmark share a restrained CSS tilt/lift near the end of a 26-second cycle, stay still for most of it, pause under a drawer, and stop under reduced motion. This is a browser demonstration of occasional motion, not a reproduction of native per-letter choreography. The tent and clown remain still.

## Prototype selectors

- Header identity: `data-workspace-title`; explorer toggle: `data-open-work`; replaceable drawer: `data-explorer`.
- Header task selection: `data-task-menu`, `data-current-task-title`, `data-task-menu-panel`; task switches/reopening: `data-tab="<id>"`.
- Settings toggle/panel: `data-open-settings`, `data-settings-panel`; categories: `data-setting-category`; back: `data-settings-back`; Home: `data-settings-home`; appearance: `data-appearance="light|dark"`.
- Local pane controls: `data-explorer-tab="workspaces|git|files|sessions"`; session restoration: `data-session="<id>"`.
- Folder expansion: `data-tree-toggle="Sources"` or another folder path.
- File/diff selection: `data-open-file="README.md"` or folder/file path; diffs also carry `data-diff`.
- Drawer task commands: `data-close-tab="<id>"`, `data-close-other-tabs`; task selection/reopening: `data-pick="<id>"`.
- Home options: `data-home-actions`, `data-home-back`, `data-home-choice="chat|terminal|workspace|resume:<choice>"`.
- Existing `data-concept="a"`, `data-tab`, `data-action`, `data-workspace` and `data-pick` routes remain.

## Verification and limits

Fresh checks: `node --check app.js`, `node previews/check-home-menu.cjs` and `node previews/check-home-actions.cjs`. The browser scripts use the already-installed Playwright package and a local server at `http://127.0.0.1:8769`. The new menu check first failed against the old drawer closure, then passed workspace retention/scoping, menu geometry, switch/close/reopen, Escape/focus/outside dismissal, measured tile expansion/reversal, stable launcher bounds, reduced motion and narrow-screen overflow. The earlier route check still passes sample chat/terminal/workspace creation and restoration, four-action order, header Settings and equal drawer columns at 320/375/402 viewports. Neither recorded JavaScript errors. Full-size Home has 748-pixel client/scroll heights and no scrolling; the lower gap remains 76 pixels.

All task names, workspace names, status, file trees, content and diffs are invented sample data, identified outside the phone. There is no host connection, repository read, real Git operation or persistence. Circus images are still; title/quip and interaction motion are CSS/Web Animations. This HTML demonstration does not certify native animation, Dynamic Type, software-keyboard, VoiceOver or backend lifecycle behavior.

Latest evidence: [menu/expansion checks](previews/home-task-menu-checks.json), [Home routes](previews/home-four-actions-checks.json), [neutral Home](previews/home-task-menu.png), [open task dropdown](previews/task-dropdown-open.png), [expanded New Chat](previews/home-expanded-chat.png), [slate Home](previews/home-four-actions-dark.png) and [workspace choices](previews/home-resume-options.png). Older captures and reports remain as historical evidence. These checks establish Chromium prototype behavior, not native iOS accessibility or comparative usability.

The centered header task switcher sizes to its longest label plus padding, capped to leave room for the two side controls; text remains centered and long task titles truncate.
