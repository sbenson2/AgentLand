# AgentLand chat UX specification

> **Clean-room note.** This specification was written from the observed behavior of the Open WebUI chat interface, version 0.11.4 (chat screen, transcript, composer, model picker, agent-question and approval flows, chat library and search). No source code, styles, component or API names, icons, SVG artwork, colors, translation strings or other text were copied. Behavior is paraphrased. Every user-facing label here is AgentLand's own wording, marked **(proposed)**, or **(existing)** when it already ships in AgentLand. Standard Apple vocabulary (Copy, Edit, Share, Delete, Rename, Pin, Cancel, Stop, Done) and the date-section names used by Apple Notes are platform conventions, not reference text. Implementers work from this document only and do not read the reference.

**Scope:** `shared/AgentLandChat` and the chat surfaces on iPhone, iPad and Mac. **Providers:** OpenCode, Claude Code, Codex. **Date:** 2026-09-23.

**Conventions**
- **Reference:** the observed web app, paraphrased. **AgentLand:** what to build. Where they differ, AgentLand wins.
- **Capability-gated:** shown only when the host advertises the feature for that chat's provider (`chatFeatures`). Otherwise the control is left out, never shown as an inert lookalike.
- Sizes are points at the default Dynamic Type size and scale with text size unless noted.

## 0. Ground rules for every section

1. **One shared implementation.** One implementation serves iPhone, iPad and Mac. Differences come only from size class, input (touch, pointer, hardware keyboard) and system conventions (menu bar, context menus, hover).
2. **No automatic resend.** Messages, queued items, uploads, rewinds, retries, answers and approvals whose delivery is uncertain are shown as uncertain. Only an explicit user action sends again.
3. **Liquid Glass only on floating controls.** Glass is allowed on the composer container (and whatever docks inside it), the jump-to-latest button and the docked "waiting for you" pill. Messages, cards, code blocks, tables and sheets use solid theme backgrounds. System bars use whatever the system provides. Never stack glass on glass.
4. **Provider fixed per chat.** Model, effort and mode can change inside a chat when the provider supports it.
5. **Absent beats inert.** Unsupported features are hidden. A control is disabled only to explain a temporary condition, such as offline or an upload in progress.
6. **HIG first.** Use system components: Menu, Picker, `.searchable`, confirmationDialog, context menus, swipe actions, sheets and popovers. Use SF Symbols, Dynamic Type and semantic colors from AgentLand's paper and slate themes.

## 1. Screen anatomy

**Reference layout**
- **Layout:** a chat library sits on the left. Below about 768 px it is an overlay drawer opened by swiping. Wider, it stays on screen, can be resized, and collapses to an icon rail. The chat pane fills the rest, and an optional settings panel can open on the far right (a bottom drawer on phones).
- **Header:** a transparent sticky header floats over the transcript. The background fades to transparent beneath it. It holds a sidebar toggle (phones), the chat title (left-aligned, truncated) with an overflow menu directly beside it, then new chat (phones) and the panel toggle.
- **Column:** transcript and composer share one centered column with a fixed maximum width of roughly 930 px. A user setting removes the cap.
- **Composer:** it floats at the bottom, in the same column, as a rounded, softly shadowed, slightly translucent card.
- **Model picker:** it sits in the composer's bottom toolbar, just before the send button. Older versions had it in the header.
- **New chat:** a new chat hides the title and centers the hero and composer vertically (§8).

**AgentLand, compact width** (iPhone, narrow iPad multitasking, narrow Mac window):

```
┌──────────────────────────────────────┐
│ ☰  Fix login redirect          ✎  ⋯ │  nav: drawer, title/subtitle, new chat, menu
│    Claude Code · my-app              │
├──────────────────────────────────────┤
│                  ╭─────────────────╮ │
│                  │ Why does /login │ │  user: trailing bubble
│                  │ loop?           │ │
│                  ╰─────────────────╯ │
│ ◇ Reasoning · 12 s                 › │  collapsed disclosures (solid)
│ ✓ Read 3 files · Ran 1 command     › │
│ The redirect loops because the       │  assistant: no bubble, full column
│ session cookie is set after …        │
│ ┌ swift ──────────────────────── ⧉ ┐ │  code block (solid)
│ │ …                                │ │
│ └──────────────────────────────────┘ │
│ ⧉   ↻   ⓘ                            │  action row (latest reply only)
│               ( ↓ • )                │  jump to latest (glass), when not following
│ ╭──────────────────────────────────╮ │
│ │ Message Claude Code              │ │  composer (glass)
│ │ + [Asks first ▾] [Sonnet ▾]  ◉ ↑ │ │  ◉ mic, ↑ send
│ ╰──────────────────────────────────╯ │
└──────────────────────────────────────┘
```

**AgentLand, regular width** (iPad full screen, Mac):

```
┌───────────────┬──────────────────────────────────────────────────┐
│ Chats    ✎  ⌕ │ Fix login redirect                          ✎  ⋯ │
│ Pinned        │ Claude Code · my-app                             │
│   Release …   │        ┌──────── readable column ────────┐       │
│ Today         │        │              ╭ user bubble ╮    │       │
│ ! Migrate …   │        │ reply text …                    │       │
│ ⟳ Fix login … │        │ ⧉ ↻ ⓘ                           │       │
│ • Tests …     │        │ ╭ composer (glass) ───────────╮ │       │
│ Yesterday …   │        │ ╰─────────────────────────────╯ │       │
│               │        └─────────────────────────────────┘       │
└───────────────┴──────────────────────────────────────────────────┘

Row accessories: ! waiting for you · ⟳ running · • unread.
```

- **Column:** transcript, inline cards and composer share one centered column. It is at most about 720 pt at default Dynamic Type, grows in proportion with text size, and has 16 pt side margins. There is no wide-mode toggle in v1.
- **Header:** the app's navigation bar holds it (the chat has no header bar of its own since the native-iOS pass, CH-25: the one it had was never shown). The title is the chat title on one line, tail-truncated. The subtitle is provider · workspace. Trailing items: New Chat (compose symbol) and an overflow menu with Rename, Pin, Copy Chat, Save as Markdown…, Chat Details and Delete. On iPhone, tapping the title opens Chat Details, a sheet with provider, model, mode, effort, workspace folder, created time and usage totals (SHOULD).
- **Model, effort and mode:** these live in the composer toolbar (§6). The provider appears only in the header subtitle and Chat Details, because it never changes.
- **Composer placement:** the composer floats above the transcript as a bottom safe-area inset (on iPhone and iPad a safe-area bar, so the transcript's scroll edge effect runs under it). The transcript's bottom inset tracks the composer's height plus 8 pt, so the last line is never covered. With the keyboard up, the composer rides the keyboard.
- **Empty chat:** the tent landing replaces the transcript (§8).

## 2. Transcript

### 2.1 User messages
**Reference:** a right-aligned rounded bubble on a light neutral fill, up to about 90% of the column. Attachments sit above the bubble: images as height-capped thumbnails, files as chips. Markdown is rendered by default. The timestamp appears on hover. A setting switches to an avatar-and-name, full-width layout.

**AgentLand:**
- **Bubble:** trailing, at most 80% of the column (compact) or 70% (regular). Continuous corners of about 18 pt, secondary fill from the theme, primary text.
- **Text:** shown as typed, as plain text with line breaks kept. Fenced blocks render as code blocks and nothing else is styled, so pasted logs are never restyled (SHOULD).
- **Attachments:** above the bubble, trailing-aligned. Images appear as thumbnails at most 200 pt tall with aspect kept. Files appear as chips: symbol, middle-truncated name, size. Tapping opens Quick Look.
- **Long messages:** more than 12 lines collapse to 8 lines with a fade and **Show Full Message** (proposed). The expanded state is per message and not saved (SHOULD).
- **Delivery badge:** when delivery is not normal, a badge appears under the bubble (§13).

### 2.2 Assistant replies
**Reference:** no bubble. A small model avatar shows at wide widths and a model-name line sits above each reply. Content spans the column, with an action row below.

**AgentLand:**
- **Style:** no bubble. Prose uses the body style with about 1.35 line height and about 0.6 em between paragraphs. Monospace appears only in code.
- **Reply header:** a provider glyph and model caption on the first reply, and again whenever the model changes; otherwise omitted (SHOULD).
- **Structure:** a reply is an ordered list of parts: status line, reasoning, tool activity, text, images, error and end marker (§2.7).

### 2.3 Streaming
**Reference:**
- **Placeholder:** an empty, unfinished reply appears the moment a message is sent, and the view always scrolls to the bottom on send.
- **Rendering:** text grows as deltas arrive. Parsing is throttled to one pass per display frame. New words fade in briefly (on by default).
- **Caret:** a thin pulsing caret follows the last text. If a status line is showing and no text has arrived, the status line stands in for the caret.
- **Cleanup and haptics:** a bare leading newline is dropped. A tiny vibration per chunk is available but off by default.

**AgentLand:**
- **Status line (MUST):** the user bubble appears optimistically. The reply placeholder shows **Starting Claude Code…** (proposed) until the first event, then **Waiting for Claude Code…** (proposed) after 3 s without output.
- **Update rate (MUST):** at most one layout pass per frame. Markdown parses incrementally, and an unfinished fence stays code (existing).
- **Caret (MUST):** a thin accent-colored bar after the last glyph. It pulses gently, stays static under Reduce Motion, and disappears when the reply finishes, stops or fails.
- **Polish (SKIP):** no per-word fade and no per-chunk haptics. Play one light haptic on send (iPhone); none on completion.

### 2.4 Auto-scroll and jump to latest
**Reference:**
- **Following:** "following" is on while the viewport is within a few pixels of the bottom. Scrolling away turns it off and returning turns it on. While following, new content keeps the view pinned, with at most one scroll per frame. A setting can disable following during generation.
- **Send and branches:** sending always scrolls to the bottom. Switching branches keeps following only if the user was near the bottom.
- **Jump button:** when not following, a small round down-arrow button floats centered just above the composer. It scrolls to the bottom and turns following back on. It carries no unread count or badge.

**AgentLand:**
- **What stops following:** only user-initiated scrolling (drag, wheel, keyboard, VoiceOver) more than 24 pt from the bottom. Content growth, expanding a disclosure, image loads and the keyboard appearing never stop it.
- **Anchoring:** while following, keep the bottom anchored with no animation per update. Expanding a disclosure keeps its header fixed on screen.
- **Resuming:** sending, answering an approval or question, or tapping Jump turns following back on.
- **Jump button:** a glass circle (`arrow.down`; the system's glass button on iPhone and iPad, 36 pt on the Mac) centered 12 pt above the composer, in one glass container with the docked pill. It shows when not following and at least one screen from the bottom, and fades in and out (instantly under Reduce Motion).
- **New-activity dot:** an accent dot on Jump when reply text, an approval or question, or an error arrived after following stopped. VoiceOver reads **Jump to Latest** with the value **New activity** (proposed).
- **Opening a chat:** start at the bottom, following. If the chat has an unread finished reply, start at the top of that reply (SHOULD).

### 2.5 Reasoning ("thinking")
**Reference:**
- **Default:** collapsed; a setting expands all details.
- **Header:** while live, a spinner plus a shimmering "working" label. When finished, a past-tense label with the duration (under a second, N seconds, or humanized minutes), or just a past-tense word if there is no duration.
- **Body:** muted, quoted Markdown. Expanding while live shows it streaming.
- **Grouping:** consecutive reasoning and tool items merge into a group (§2.7).

**AgentLand:**
- **Header:** collapsed by default. **Reasoning** (proposed) with an elapsed timer while live (**Reasoning · 0:07**) and the final duration when done (**Reasoning · 12 s**; **< 1 s** for very short). A ProgressView while live, a static symbol when done.
- **Expansion:** the user's choice persists per reply while the chat is open. Never auto-expand.
- **Body:** secondary color with a 2 pt leading rule, in the callout text style. No nested scroll view.
- **Redacted reasoning:** if the provider sends only redacted or encrypted reasoning, show the header without a chevron.

### 2.6 Tool calls

**Reference states:**

| State | Icon | Label, wide screens | Interaction |
|---|---|---|---|
| Arguments streaming | spinner | says the named tool is being set up | — |
| Running | spinner | says the named tool is running | — |
| Awaiting approval | tool glyph | asks whether to allow the named tool | inline allow/deny buttons |
| Awaiting user answer | tool glyph | says the user's answer is required | answered in the composer area |
| Done | green check | offers the named tool's result | expand |
| Failed, or output looks like an error | red cross | offers the result | expand |
| Denied | red cross | says the named tool was refused | expand |

- **Row:** one line with a chevron. Narrow screens show only the tool name.
- **Expanded card:** a bordered card with an input section and an output section. Input is a key/value list of the arguments (pretty JSON when not an object). Output is pretty JSON, or text cut at about 10,000 characters with a show-all control that states the full length. Images returned by a tool render under the row.
- **Error detection:** from the status, or by heuristics on the output text.
- **Sub-agents:** sub-agent calls are labeled with the delegated task, cut at about 60 characters. Background sub-agent results appear as a compact row that expands to the full text.

**AgentLand:**
- **Humanized rows:** the host normalizes provider tool names into kinds: read, edit/write, run command, search, fetch/web, plan, sub-agent, question and other (MCP). A row is the kind's symbol, a verb phrase and the target. Examples (proposed patterns): **Read `LoginView.swift`**, **Ran `npm test`**, **Edited `Auth.swift` +12 −3**, **Searched for "redirect"**. Unknown tools read **Used `tool_name`**.
- **States:** preparing, running, waiting for approval, waiting for answer, succeeded, failed, denied, interrupted. Each shows as symbol shape plus a text state, never color alone: spinner, hand, checkmark, exclamation mark, slashed circle, pause.
- **Expanded card (solid):**
  - Input: a command as a code block, a file edit as a diff (§2.11), anything else as a key/value list.
  - Output: monospaced, first 30 lines, then **Show N More Lines** (proposed). Output the host already shortened keeps its existing notice.
  - Both sections have Copy.
- **Long commands:** a running command shows live elapsed time; no fake progress percentage.
- **Sub-agents:** a sub-agent row shows the task summary and a nested, collapsed activity list (SHOULD).
- **Plain chats (§15):** their three tools show as plain cards instead of rows:
  - **Searched the web**: the sources as links, title with the site under it;
  - **Read <site>**: the page as a link;
  - **Memory updated**: the saved text, with **Undo**;
  - **Removed from memory**: the removed text, no Undo.

  Each card's summary is one VoiceOver element that states the number of sources. Undo and each link are their own elements, so Voice Control, Switch Control and Full Keyboard Access reach them. A save is announced once.

### 2.7 Grouping and interleaving
**Reference:**
- **Order:** a reply is an ordered list of items. Text renders as Markdown blocks. Runs of more than one consecutive non-text item (reasoning, tool calls, code runs, searches) between text blocks collapse into one group row; a run of one shows as a single row. Chronological order is kept: group, text, group, text.
- **Group header:** a status icon (spinner while anything runs; red cross if something failed or was denied; green check when done; a neutral glyph for reasoning-only groups), then a present-progressive verb while active or past tense when done, then a muted summary of tool names with counts. Collapsed by default.
- **Pending approvals in a group:** one pending call puts allow/deny on the collapsed header itself; several are listed beneath it, each with its own buttons.
- **Pending questions:** hidden from the transcript while pending, then shown as a normal tool row.

**AgentLand:**
- **Order:** same chronological model.
- **Group header:**
  - Live: a spinner, the current step ("Running `npm test`…") and a step count.
  - Done: a summary by kind, **Read 4 files · Edited 2 · Ran 3 commands** (proposed).
  - Failures add **· 1 failed** (proposed).
  - Collapsed by default.
- **Pending interactions:** a group never holds a pending approval or question. These break out into their own card at their chronological position (§4), so they are never hidden inside a collapsed group.
- **Plan updates:** plan or todo updates feed the docked plan panel (§5.4) and appear only as **Updated plan** (proposed) in the group summary.

### 2.8 Errors and retry
**Reference:** a failure shows a toast plus a low-emphasis inline panel (info symbol and message) under any partial content. Content is never removed, and a generic apology line is prefixed to provider errors. Retrying means using the reply's regenerate action; the panel has no retry button of its own.

**AgentLand:**
- **Card:** an inline error card at the end of the reply: solid, with a subtle warning tint and symbol. The title depends on the category (proposed): **Couldn't Reach Your Mac**, **Claude Code Isn't Signed In**, **Rate Limited**, **Reply Failed**. The body is the provider's bounded, selectable message.
- **Actions:** **Run Again** (proposed), plus guidance text where it helps.
- **No toasts:** chat errors don't produce toasts; the card is the record.
- **Run Again rules:** it runs only when the user taps it.
  - If the failed turn already did tool work, warn: **The agent may already have changed files.** (proposed)
  - Run Again sends the same prompt as a new turn.
  - When rewind is supported, offer **Rewind and Run Again…** (proposed) under the §3.4 rules.
- **Two failure types:** keep delivery failures of the user's message (§13) separate from provider failures of the reply.

### 2.9 Stopped and interrupted replies
**Reference:** stopping marks every in-flight reply of the turn finished and keeps partial text. Nothing visually marks the reply as stopped, and queued messages then proceed.

**AgentLand:**
- **Markers:** a caption under the partial reply: **Stopped** (proposed). If the host recorded an interruption after a restart: **Interrupted: your Mac's host restarted** (proposed). Running tool rows switch to the interrupted state.
- **Queue after Stop:** the queue continues in order (existing host behavior). Its header says so.

### 2.10 Long content
**Reference:** long messages render in full. Tool output is cut at about 10k characters. The list first renders the latest 8 messages and loads 8 more each time a loader at the top becomes visible, keeping the scroll position. Off-screen messages skip painting, which is disabled on Safari because of paint bugs.

**AgentLand:** see §2.1 (user collapse), §2.6 (tool output), §2.11 (code collapse) and §13 (paged history).

### 2.11 Markdown rendering (assistant text)

| Element | Reference | AgentLand |
|---|---|---|
| Code block | Rounded card. Header: language label left; collapse/expand and copy right (copy confirms for about 1 s), plus optional save, run and preview. The header pins while scrolling through a long block. Syntax-highlighted, no wrapping, horizontal scroll. Collapsed shows a hidden-line count. Collapse default comes from a setting (off). | MUST: card with language label and Copy (the symbol turns into a checkmark for 1.5 s, VoiceOver says **Code copied**, proposed). Horizontal scroll, no wrap. Blocks over 30 lines collapse to 15 with a fade and **Show N More Lines** (proposed; existing long-code collapse). SHOULD: syntax colors for light and dark; **Wrap Lines** (proposed) in the block menu; pinned header on long expanded blocks. SKIP: run, save, edit, HTML preview. |
| Diff | Old and new line-number gutters when hunks exist; a +/− column; add/remove tints with a left accent (removals also hatched); styled hunk and file headers; changed words emphasized within a line. | MUST: +/− column and tints (existing). SHOULD: line numbers from hunk headers and in-line emphasis. Always keep a non-color cue. |
| Table | Horizontal scroll, small text, emphasized header, row separators. Hover shows copy (Markdown) and export-to-CSV. | MUST: horizontal scroll, header emphasis, separators. SHOULD: **Copy Table** (proposed) as Markdown in the context menu. SKIP: CSV. |
| Lists | Ordered (honors the start number), unordered, nested. Task items have clickable checkboxes. | MUST: nesting and start numbers. Task items are display-only check symbols. |
| Quotes | Leading rule. Alert-style quotes become labeled callouts. | MUST: leading rule. SHOULD: callout styling so alert markers never show raw. |
| Headings | h1–h6 scaled. | MUST: map to title3, headline, subheadline; no oversized headings. |
| Links | Open in a new tab; in-app URLs navigate internally. | MUST: http(s) and mailto open in the system browser or mail app. Other schemes stay plain text (existing). SKIP v1: file-path links into Files. |
| Images | Inline. Tap opens a full-screen preview. A failed load shows a small "unavailable" chip. | SHOULD: host or attachment images inline with Quick Look. Remote Markdown images don't auto-load (privacy) and show as a link chip. A failed load shows a placeholder chip. |
| Inline code | Monospace pill; tap copies with a toast. | MUST: monospace with a subtle fill, selectable. No tap-to-copy on touch, where it conflicts with selecting and scrolling. |
| Math, diagrams, HTML embeds, footnotes, citations | Rendered. | SKIP: shown as plain code or text. |
| Selection actions | Selecting reply text shows floating buttons that ask about the selection. | SKIP v1: system selection and Copy only. |

## 3. Message actions

### 3.1 How actions are revealed
**Reference:**
- **Row:** a row of small icon buttons under each message. The latest reply's row is always visible. Older rows appear on pointer hover or keyboard focus; they are hidden by opacity, so focus reveals them.
- **High contrast:** a high-contrast setting keeps every row visible.
- **Overflow:** a row that doesn't fit scrolls horizontally.
- **Placement:** user rows sit trailing under the bubble; reply rows sit leading.

**AgentLand:**
- **Touch:** only the latest finished reply shows a persistent row. Every message has a long-press context menu with a preview. No hover rows.
- **Pointer (Mac, iPad trackpad):** hover or keyboard focus reveals a message's row. Right-click opens the same menu.
- **VoiceOver and Full Keyboard Access:** the same actions as custom accessibility actions.
- **Always visible:** rows stay visible when Increase Contrast or Full Keyboard Access is on.

### 3.2 Action inventory

| Action | Reference | AgentLand |
|---|---|---|
| Copy | User and reply. The reply copy leaves out reasoning and tool details. | MUST, both. Replies copy the Markdown of their text parts. |
| Edit | User: inline editor. Reply: inline editor with keep-both or replace. | User: **Edit and Resend…** (proposed) through rewind, capability-gated (§3.4). Reply editing SKIP. |
| Reuse text | through edit | **Use in Composer** (proposed; existing behavior), always available |
| Regenerate | Button plus a small menu: plain retry, retry with a typed instruction, quick longer/shorter variants | **Run Again…** (proposed), latest reply only, through rewind, capability-gated (§3.5). Variants SKIP. |
| Continue | extends the latest reply in place | SKIP (the user can type "continue") |
| Fork | new chat from this point | **Fork from Here** (proposed), capability-gated (§3.7) |
| Share one reply | — | **Share…** (proposed) as Markdown text, SHOULD |
| Text-to-speech | speech toggle with loading and playing states | SKIP |
| Info / usage | info button whose tooltip dumps raw usage numbers | **Details** popover (ⓘ), SHOULD (§10) |
| Rating | thumbs up/down plus an optional comment form | SKIP |
| Removing a message | user and reply, confirmed (a modifier skips confirmation) | SKIP; provider sessions can't drop turns |
| Branch navigation | "‹ n/m ›" when siblings exist; double-click the counter to type a number | SKIP (§3.6) |
| Timestamp | on hover, with the full date in a tooltip | time separators and Details (§10) |
| Plugin actions | extra model-defined buttons | SKIP |

**Order.** The reply row shows Copy · Run Again · Details. The reply menu adds Fork from Here, Share… and Select Text (iPhone). The user message menu offers Copy, Edit and Resend…, Use in Composer and Fork from Here.

### 3.3 Hover and focus visuals
- **Buttons:** 28 pt icons in the secondary color (44 pt touch targets), plain style, with tooltips on Mac.
- **Copy feedback:** the symbol turns into a checkmark for 1.5 s. There is no toast.

### 3.4 Editing a previous user message
**Reference:**
- **Editor:** the bubble becomes an inline editor. It grows up to a cap and then scrolls, attachments can be removed, Escape cancels, and ⌘/Ctrl-Enter sends.
- **Buttons:** save-in-place rewrites the message without generating; cancel; send. Send adds a sibling user message under the same parent and generates a new reply. The old branch stays reachable through sibling navigation.
- **Shortcut:** the Up arrow in an empty composer opens the editor on the last user message.

**AgentLand** (the providers rewind; they do not branch):
1. **Availability:** **Edit and Resend…** appears only on messages the host can rewind to. This is capability-gated; today that is the latest OpenCode message.
2. **Confirmation:** a confirmationDialog (iPhone) or alert (Mac) states the consequences: **Everything after this message will be removed from this chat. Changes Claude Code made to files after this point will be undone.** (proposed). The file sentence appears only when the host reports that it reverts files.
3. **Confirm:** the host rewinds and later turns disappear. The message text and attachments load into the composer, and the rewind banner appears (**Editing your last message**, existing) with Restore.
4. **Send or restore:** sending continues from that point. Until the next send, Restore brings back the removed turns and file changes.
5. **Uncertain rewind:** if the rewind's delivery is uncertain, show **Rewind not confirmed** (proposed) with **Refresh Status** (proposed). Never re-send it.
6. **In-place edits:** SKIP. Edits that don't regenerate would desync the provider session.

### 3.5 Regenerate becomes Run Again
**Reference:** regenerating adds a sibling reply. The old one stays and can be navigated to, and an extra instruction can be attached.

**AgentLand:** **Run Again…** on the latest reply rewinds the last turn and sends the same prompt again. It requires rewind support and follows the §3.4 confirmation, banner and Restore rules. Run Again from an error card follows §2.8. There is no variants menu.

### 3.6 Branch navigation: recommendation
**Reference:** keeps a message tree. Every edit or regenerate adds a sibling, and "‹ n/m ›" controls switch between branches.

**Recommendation: SKIP.** Provider sessions are linear. Fake branches would diverge from the agent's real state and from the files on disk. Rewind with Restore covers "try that again", and **Fork from Here** covers "keep both" as a separate chat.

### 3.7 Fork from Here
**Reference:** copies the conversation up to a message into a new chat, navigates there, and refuses while a reply is still running.

**AgentLand:**
- **Availability:** capability-gated. Disabled while the agent runs, with the reason as the menu subtitle.
- **Result:** opens a new tab titled **"<title> (fork)"** (proposed) and leaves the original untouched.
- **Files:** a fork shares the workspace, not a file snapshot. The menu subtitle says **Uses the same files** (proposed).

## 4. Agent questions and approvals

### 4.1 Reference behavior
**Questions**
- **Placement:** a soft card docked above the composer, outside the transcript.
- **Layout:** one question per page, with a short header, an "n/m" counter when there are several, the question text and options. Each option shows a label and a one-line description; hover shows the full text.
- **Recommendation pill:** the first option always gets one.
- **Free text:** an optional row with an inline field.
- **Flow:** tapping an option records it and moves to the next question. On the last question, the answers submit as soon as every question has one.
- **Footer:** decline (the request is rejected), back, and next or submit (disabled until complete).
- **Limits:** single-select only. An optional timeout declines automatically.
- **Afterwards:** the request becomes an ordinary tool row whose output contains the answers.

**Generic input dialogs:** confirm-only, text, masked text (with reveal) and select. Each is a modal with a focus trap; Escape cancels and Enter confirms.

**Approvals**
- **Mode:** a per-chat tool-permission mode (run freely, or ask every time) lives in the composer's "+" menu, each option with a one-line description. It appears when the server enables it.
- **Ask mode:** every tool call stops, with inline allow/deny on its row or under its collapsed group.
- **Switching modes:** switching to the free mode immediately approves the pending call.
- **Denied calls:** shown with a red cross and a denied label.
- **Keyboard:** chords for allow and deny work while a call is pending.

### 4.2 AgentLand approval card (tool permission)
- **Placement:** inline, at the request's chronological position, as its own solid card. It is never inside a group.
- **Off-screen pill:** if the card is off-screen, a glass pill docks above the composer: **Claude Code needs permission · Review** (proposed). Tapping it scrolls to the card and focuses it.
- **Content:** the provider glyph and a title such as **Allow Claude Code to run this command?**, **…to edit `Auth.swift`?** or **…to use `tool_name`?** (proposed). Then:
  - the exact command or target as selectable monospace (scrolls if long)
  - a collapsed diff for edits
  - the folder the command runs in, as a caption
  - any reason the provider gave
- **Buttons:** **Deny** · **Always Allow** · **Allow Once** (default, prominent). These are AgentLand's required options. On iPhone and iPad they are the system's bordered buttons in a large capsule, Allow Once (and a question's Send Answers) bordered prominent in the accent; the card is content, so no Liquid Glass.
  - Regular width: in a row, trailing-aligned.
  - Compact: stacked full width, with Allow Once on top and Deny at the bottom.
  - Always Allow shows its scope from the host as a caption, such as **Applies to `npm test` in this chat** (proposed). Omit Always Allow if the provider has no such option.
- **Deny with a note (SHOULD):** **Deny with Note…** (proposed) in the Deny button's menu. The text goes back to the agent where the provider supports it.
- **While resolving:** buttons are disabled with a spinner. Uncertain delivery shows **Not confirmed** with **Refresh Status** (proposed). The decision is never re-sent automatically.
- **Afterwards:** the card shrinks to a line in the tool timeline: **Allowed once**, **Always allowed** or **Denied** (proposed), with the time. The tool row then carries on as running, succeeded or failed.
- **Several pending:** one card each, in order. There is no Allow All.
- **Mode switches:** changing mode never approves a pending request (unlike the reference).
- **Alerts:** a warning-style haptic and a VoiceOver announcement when a request arrives with the chat visible (§12). The chat's library row shows the waiting state (§7).

### 4.3 AgentLand question card (the agent asks)
- **Placement:** inline at the end of the reply, as a solid card. The pill rule from §4.2 applies: **Claude Code asked 2 questions · Answer** (proposed).
- **Layout:** all 1–4 questions stacked in one card, each with its header, text and options, separated by dividers. There is no paging, so answers stay reviewable and VoiceOver reads the card in order.
- **Single-select:** radio rows with a label and a wrapping description (no truncation). A tap selects.
- **Multi-select:** checkmark rows, any number selectable. Used only when the provider marks the question as multi-select.
- **On iPhone and iPad** both are the system's button toggles: the chosen options in the selected tint, read as selected (native-iOS batch 7, 2026-10-07). The Mac keeps radio and checkbox rows.
- **Free text:** a **Something Else…** (proposed) row expands an inline field. For single-select questions, choosing it clears the option selection.
- **Secret input:** when a question is marked sensitive, use a SecureField with a reveal toggle. The value never goes into drafts, transcripts, exports, logs or accessibility values. After sending it reads **Provided (hidden)** (proposed).
- **No invented recommendations:** show a recommendation only if the provider marks an option. Show provider labels unchanged.
- **Footer:** **Dismiss** (existing; declines, and the agent continues) and **Send Answers** (proposed; prominent; enabled once every question has an answer). A tap never submits automatically.
- **Keyboard:** Tab and ⇧Tab move between questions, arrows move between options, Space toggles, ⌘Return sends.
- **Afterwards:** collapses to **Answered 2 questions** (proposed), expandable to question-and-answer pairs with secrets masked. Other outcomes: **Questions dismissed** or **Question closed** after expiry or interruption (proposed).
- **Timeouts:** a provider timeout shows the remaining time as a caption. On expiry the card collapses to the closed state; nothing is answered automatically.

### 4.4 Mode and approvals
The mode (§6) decides whether approval cards appear at all. The current mode is always visible in the composer, so the user knows whether the agent will ask first.

## 5. Composer

### 5.1 Structure
**Reference,** top to bottom, inside the floating stack:
- the question card
- a docked todo list while a reply runs
- the list of waiting messages, capped at a quarter of the viewport, then scrolling
- a status panel with the share of context used, the number of waiting messages and the chat id
- the composer card itself:
  - an optional mention chip row
  - the attachment row
  - the text area, with a button to open a full editor once the text is longer than two lines
  - a toolbar: "+" menu, divider, a menu of optional tools and chips for the tools that are on (horizontal scroll), then the model picker, then stop, or mic plus a voice-conversation button or send

**AgentLand:** one glass container. Everything docked shares it.

```
╭────────────────────────────────────────────────╮
│ Plan · 2 of 5 done                           ˅ │  docked plan (SHOULD, while running)
│ Queued · 2   Sends when the agent is ready   ˅ │  queue (existing)
│ [img] [README.md · 4 KB ◌] [×]                 │  attachments
│ Message Claude Code                            │  text (1–6 lines compact, 1–10 regular)
│ +   [Asks first ▾]  [Sonnet 4.5 · High ▾]  ◉ ↑ │  toolbar
╰────────────────────────────────────────────────╯
```

- **Placeholder:** **Message Claude Code**, **Message Codex** or **Message OpenCode** (proposed).
- **Growth:** the field grows a line at a time up to the cap, then scrolls inside; the transcript inset follows its height.
- **Full editor (SHOULD):** past 3 lines an expand button opens a full-height editor on the same draft: a sheet on iPhone, a larger editor on regular width.

### 5.2 Send, stop and queue

| Condition | Reference | AgentLand |
|---|---|---|
| Idle, empty | send disabled; mic; voice-conversation button | Send disabled; mic |
| Idle, text or attachments | send enabled | Send enabled |
| Uploads in progress | send shows a spinner and is disabled; a message sent with uploading files goes to the queue | Send shows progress and stays disabled until uploads finish (v1) |
| Agent running, empty | stop only | **Stop** (prominent) |
| Agent running, has text | send, which queues; stop is hidden until the field is empty | **Stop** and **Queue** both visible; Return queues |
| Approval or question pending | as running | as running; queueing allowed; the card stays first |
| Offline or host stopped | a disconnect toast | Send disabled; inline note **Offline · your draft is kept** (proposed) |
| Provider missing or signed out | model-picker empty state | §13 |

**Reference queue.** Prompts wait while a reply runs. When it finishes, all queued prompts go out together as one combined message. Each item offers:
- send-now, which stops the current reply and sends that item
- edit, which moves it back into the composer
- delete

With queueing turned off, sending while a reply runs stops the reply and sends at once.

**AgentLand queue** (existing host queue):
- **Order:** items go one at a time, in order, once the agent is idle. They are never merged.
- **Actions:** Edit (back to the composer, removed from the queue) and Delete. Reordering and send-now SKIP.
- **Failures:** a failed or uncertain item blocks the queue and shows its state. The user picks Send Again or Delete explicitly.
- **Stop:** Stop does not clear the queue. The header shows **Queue on hold** (proposed) if the host pauses it.

### 5.3 Keyboard
**Reference:**
- **Desktop:** Enter sends and Shift-Enter adds a line; a setting switches sending to Ctrl/⌘-Enter.
- **Touch devices:** Enter always adds a line.
- **IME:** sending is blocked during an IME composition and just after it ends.
- **Escape:** stops generation and clears temporary selections.
- **Other keys:** Up in an empty field edits the last user message; Tab accepts an inline suggestion.
- **Paste:** pasted images become attachments. A setting (off by default) turns very long pasted text into a text-file attachment, and a modifier bypasses it.

**AgentLand:**
- **Hardware keyboard (iPad, Mac):**
  - Return sends, or queues while the agent runs.
  - ⇧Return and ⌥Return add a line.
  - ⌘Return always sends.
  - SHOULD: a **Send with ⌘Return** (proposed) setting that makes Return add a line.
- **Software keyboard:** Return adds a line; only the button sends.
- **IME:** never send while marked text is active.
- **Stop keys (SHOULD):** Esc closes the topmost popover or menu; with nothing to close and the agent running, it stops. ⌘. always stops.
- **Edit last (SHOULD):** ↑ in an empty composer runs Edit and Resend… on the last message when available.
- **Paste:** pasted images attach (MUST). Converting long text to a file: an iPhone and iPad setting, Settings → Chat → Long pastes as files, off by default (owner's choice, 2026-10-04): a paste of more than 12 lines (a long message, §2.1) or of 1,000 characters is attached as a text file, while the host takes attachments.

### 5.4 Docked plan (agent todo list)
**Reference:** while a reply runs and the agent has open tasks, a collapsible panel above the composer shows k of n done and numbered tasks with status glyphs:
- done: check, struck through
- running: spinner
- cancelled: dashed, struck through
- pending: empty circle

It hides when nothing is pending.

**AgentLand (SHOULD):** the same behavior, fed by provider plan or todo updates. The header reads **Plan · 2 of 5 done** (proposed). The collapsed state is remembered per chat, and the panel hides when the run ends.

### 5.5 Attachments
**Reference:**
- **"+" menu:** file upload, camera or screen capture, attach a web page, pick from a library (files, notes, knowledge, other chats), cloud drives.
- **Drag and drop:** dropping anywhere over the chat shows a full-pane overlay. Paste attaches images.
- **Chips:** images are small square thumbnails with a corner remove control (hover-revealed). Files are chips with an upload spinner and a dismiss control.
- **Capability warnings:** a warning badge marks an image the chosen model can't see. Unsupported models disable the upload items, with a tooltip that explains why.
- **Limits:** count and size limits raise toasts.
- **Queued items:** show their uploading or failed state.

**AgentLand:**
- **"+" menu (MUST):** Photos, Camera (iPhone and iPad), Files. Paste works through the system. On iPad and Mac, drag-and-drop onto the chat highlights the composer.
- **Chips:**
  - The remove "×" is always visible on touch and appears on hover or focus with a pointer.
  - A progress ring shows while uploading.
  - A failed chip shows an exclamation mark and **Upload Again** (proposed). It uploads only when tapped, never automatically.
- **Limits:** the host's limits apply (existing): images and PDFs up to 10 MiB, text up to 2 MiB, at most 32 files or 64 MiB unsent. Files over a limit are rejected when picked, with an inline message on the composer, not a toast.
- **Capability warnings:** if the provider can't use a file type, the chip gets a warning badge and an explanation.
- **Privacy:** photos are re-encoded, which strips location (existing).

### 5.6 Voice and dictation
**Reference:**
- **Recording:** a mic button records, asking for permission on first use. A recording strip replaces the composer: cancel, live level bars, a running timer, confirm.
- **Result:** the transcript goes in at the cursor. An optional setting sends it automatically.
- **Voice conversations:** a separate full-screen spoken-conversation mode exists.

**AgentLand:**
- **Dictation (existing, on-device):** the mic toggles recording. The recording strip shows a level indicator, timer, Cancel and Done. Text goes in at the cursor and is never sent automatically (existing rule). System dictation also works in the field.
- **Spoken conversations:** SKIP.

### 5.7 Slash commands and mentions
**Reference:**
- **"/":** a popover of built-in commands (compact the context, fork, status, switch model, settings, off-the-record chat, create a skill), saved prompts and skills.
- **"@":** mentions models, files, folders, collections and URLs.
- **"#", "$", ":":** knowledge, skill and emoji pickers.
- **Keys:** arrows, Enter/Tab and Escape drive the popover.

**Recommendation:**
- **"@" workspace file mentions: SHOULD.** They insert a path token the providers understand, which is valuable for coding agents.
- **"/" palette: SKIP in v1.** Revisit once the host can advertise each provider's commands.
- **"#", "$", ":": SKIP.**

### 5.8 Drafts
**Reference:** a per-chat draft (text, non-image attachments, toggles) is saved about 0.5 s after typing stops, for the browser session only. Drafts over about 5,000 characters aren't saved. The draft is restored on return and cleared on send.

**AgentLand:** existing per-tab drafts: 500 ms autosave, flushed on backgrounding, holding text and references to uploaded attachments. No length cap below the host's limits. Secrets are never saved. A draft clears only when the host accepts the send, or the queue accepts the item.

### 5.9 Focus
**Reference:** focuses the composer on load and after sending (not during spoken conversations).

**AgentLand:**
- **Mac, and iPad with a hardware keyboard:** focus the composer on open and after send.
- **iPhone:** opening an existing chat doesn't raise the keyboard. Focus stays after sending if the field had it.

## 6. Model, effort and mode

**Reference:**
- **Trigger:** a compact trigger (the selected model's name and a chevron) in the composer toolbar opens a popover.
- **Search:** a search field, fuzzy over name, id and tags, driven by arrow keys and Enter.
- **Filters and compare:** filters by tag and by where the model is hosted, and an optional multi-model compare toggle.
- **List:** virtualized. Each row shows an avatar, the name, small metadata (such as size or loaded state), tag and description details on hover, a per-row menu (pin, copy a shareable link, hide) and a check on the selected model.
- **Empty states:** no models at all, with a link to connection settings; and no search results.
- **Defaults:** a save-as-default link appears only on a new chat. The selection is stored with the chat, and the default applies to new chats.

**AgentLand:**
- **Provider:** chosen when the chat is created (Home or the empty chat) and never changed. It shows in the header subtitle. A plain chat (§15) has no provider choice, mode chip or effort; its header subtitle is the model's name, and its model chip lists OpenCode's models.
- **Model and effort chip:** in the composer toolbar, formatted **Sonnet 4.5 · High** (proposed; the effort part is omitted when the provider has none). It opens one native menu, with no search (owner's request, 2026-10-07), in this order wherever it opens (it opens upward from the composer, and the system would otherwise turn it over):
  - the host's first five models, in the host's own order (the host sends no dates, so its order decides): the name, the context size under it when the host gives one, and the system's checkmark on the chosen one
  - **More Models** (existing), a submenu that slides in over the menu with every other model, under each provider's name when they come from more than one provider (providers by name, models in the host's order); absent with five models or fewer
  - an **Effort** (existing) section of host-advertised levels, for models that support it, checked the same way
  - on an empty chat only, **Use for New Claude Code Chats** (proposed) to set the per-provider default
  - with no models, one disabled row: **No Models**, **This provider has no models set up. Choose one in AgentLand on your Mac.** (existing)
  - The chat's title menu (on iPhone, the task menu) offers the same menu as its **Model** submenu, so both list the same models and efforts.
- **Mode chip:** left of the model chip. It shows the current mode's short name and a symbol that signals risk:
  - hand: asks first
  - pencil: edits on its own
  - list: plans only
  - bolt: runs without asking

  Tapping it opens a Menu of host-advertised provider modes (for example OpenCode's Build and Plan), each with a one-line description; an inline picker checks the mode in use. AgentLand's short summaries (proposed): **Asks first**, **Edits on its own**, **Plans only**, **Runs without asking**. The mode belongs to the chat, and the default comes from provider settings.
- **Escalation (SHOULD):** moving to a more permissive mode than the chat default asks for confirmation once per chat.
- **Mid-chat changes:** they apply from the next turn. They are disabled while a turn runs, unless the provider supports live switching (capability-gated). The change leaves a small divider in the transcript: **Switched to Opus 4.1** or **Mode: Plan** (proposed).
- **Large text on compact width:** at accessibility text sizes the chips collapse into one **Options** (proposed) menu holding Mode and, as a submenu, the model menu (models and Effort).

## 7. Chat library

**Reference:**
- **Sidebar sections:** navigation items, pinned models, and folders (nested, drag-and-drop, deletion with an optional delete-contents choice). Then chats: a collapsible pinned group, then chats under date headers (the current day, the day before, the past week, the past month, month names for this year, then years). The list scrolls infinitely with a loading row.
- **Rows:** a one-line title and a relative age at the trailing edge (5m, 2h, 3d). The age hides while row actions show.
  - Unread: a small colored dot and a slightly stronger title.
  - Generating: a spinner at the leading edge.
  - Current chat: a subtle fill.
- **Row menu (on hover):** share, download formats, rename, mark unread, pin, clone, move to folder, archive, and delete with a confirmation naming the chat.
- **Shortcuts:** holding Shift shows one-click archive and delete without confirmation. Double-click renames inline; Enter saves, Escape cancels. An optional hover preview exists, and a section menu marks everything read.
- **Search:** a command-palette modal:
  - shortcuts for starting something new
  - results grouped by date, each with a snippet around the match and the match highlighted
  - arrow-key navigation and a live preview pane
  - about 0.5 s debounce, plus prefix filters (tag, folder, pinned, shared, archived)
- **Phones:** the sidebar is a drawer that closes when a chat is chosen.

**AgentLand:**
- **Where it lives:** on iPhone, the workspace drawer's Chats section (existing). On iPad and Mac, the sidebar column. Plain chats (§15) belong to no workspace and come first, always, even when no workspace is open. The open workspace's agent chats follow under **Agent Chats**.
- **Sections:** Pinned (when any), then Today, Yesterday, Previous 7 Days, Previous 30 Days, month names for this year, then years (Apple Notes convention). Chats sort by last activity.
- **Row:** provider glyph, a one-line title, and the time at the trailing edge (Messages convention: clock time today, Yesterday, weekday, then date).
  - One accessory at a time, by priority:
    - waiting for approval or answer: hand symbol, VoiceOver **Waiting for you** (proposed) (MUST)
    - running: spinner (MUST)
    - failed or interrupted: symbol (SHOULD)
    - unread dot for a reply that finished since the chat was last viewed (SHOULD)
  - The open chat uses the List selection highlight.
- **Actions:**
  - The context menu (long-press or right-click) offers Rename, Pin/Unpin (SHOULD), Mark as Unread (Mail convention, SHOULD), Copy Chat, Save as Markdown… and Delete.
  - Swipes: leading swipe Pins, trailing swipe Deletes.
  - Rename: Return or double-click on a selected row renames inline on Mac; on iPhone, an alert with a text field.
- **Delete:** a destructive confirmationDialog, **Delete "<title>"?** with **Files the agent changed stay as they are.** (proposed; a plain chat has no files sentence). ⌘⌫ opens the same confirmation.
- **New chat:** the library's New Chat row, ⌘N, Home's New Chat and the empty-library button. With plain chats they start a plain chat at once, with no workspace. The coding agents are under the sidebar's **New Agent Chat…** row (⌥⌘N), which lists the providers for the open workspace. A host without plain chats keeps Home's provider menu and **New Chat With…**.
- **Search:** `.searchable`, placeholder **Find a Chat** (proposed):
  - MUST: instant local title filtering.
  - SHOULD: host content search, debounced about 300 ms, with snippets and highlighted matches, grouped like the list. A result opens its chat.
- **Paging:** more chats load as the end of the list appears. The existing recent-work search stays.
- **Empty:** ContentUnavailableView with the tent mark, **No Conversations Yet**, **Start a chat with Claude Code, Codex or OpenCode.** and a New Chat button (proposed). With plain chats, New Chat starts a plain chat.
- **SKIP:** archive, tags, folders, clone, hover previews, mark all read, and dragging chats between groups.

## 8. Empty and new chat

**Reference:**
- **Hero:** the header has no title. A vertically centered hero shows the model avatar(s) and name (a greeting with the user's name when no model is set) and up to two lines of model description.
- **Composer:** the composer sits centered with a friendlier placeholder.
- **Suggestions:** a short list of starter prompts sits under the composer. The list is shuffled, filtered as you type, and fades in item by item; each item has a title and subtitle. Tapping one sends it at once, unless a setting makes it insert instead.
- **Banners and variants:** admin banners can appear. An alternative layout keeps the composer at the bottom under a left-aligned greeting.
- **First send:** the view switches straight to the transcript. The chat is created, appears under today, and gets an automatic title after the first reply.

**AgentLand:**
- **Landing (existing):** keep the circus and the practical actions: Start a chat, Resume recent work, Browse files.
  - The tent breathes.
  - When the landing is first shown after the opening cover or an unlock, a clown comes out of its door.
  - Both pause under the existing rules: a still tent and no clown under Reduce Motion.

  The header shows the provider. Saved drafts, messages, pending interactions and running turns bypass the landing.
- **Plain chat landing (§15):** the same circus, **What's on your mind?** under it, and the composer. It has no workspace actions.
- **Starting:** Start a chat reveals and focuses the composer (existing). From then on the mode and model chips are visible.
- **Starter prompts: SKIP in v1.** The actions already offer starting points, and generic prompts don't fit a code workspace.
- **First send:**
  - The tent fades out (instantly under Reduce Motion). The user bubble appears, the reply placeholder shows its status line, and the composer docks at the bottom.
  - The title becomes the prompt's first line, trimmed to 50 characters, until the host supplies a better one.
  - The chat appears at the top of Today with its running spinner.

## 9. Share and export
**Reference:** the chat menu offers:
- **Share:** a server-side snapshot link. Messages sent later aren't included, access can be controlled, and the link can be revoked and recreated.
- **Download:** full-data JSON; plain text (each message under a role heading); PDF of the rendered transcript.
- **Copy:** the whole chat in the plain-text format.

**AgentLand:**
- **MUST: Copy Chat** (proposed) copies Markdown:
  - the title, then a provider and model line
  - each turn as **Me** or **Claude Code** in bold, followed by its text parts
  - reasoning and tool details left out; attachments listed by name
- **SHOULD: Save as Markdown…** (proposed) opens the share sheet with a `.md` file of the same content. A toggle in the sheet can add tool-activity summaries.
- **SKIP:** share links (AgentLand has no cloud), PDF and JSON. A debug JSON export can come later.
- **Never exported:** secrets or notes attached to denied approvals.

## 10. Status and metadata

**Reference:**
- **Per reply:** the model name above each reply, and a timestamp on hover.
- **Usage:** an info button whose tooltip lists raw usage fields.
- **Status timeline:** a one-line current status above the reply that shimmers while active. Tapping it expands the full history, for example searches with their queries and sources found.
- **Toasts:** context usage and compaction progress and results; generic notification events; a disconnect warning.

**AgentLand:**
- **Status line (MUST):** covers the time before output and provider-side waits. Examples: **Starting Claude Code…**, **Waiting for Claude Code…**, **Rate limited · retrying in 30 s** (proposed). Retries by the provider are displayed, never started by AgentLand. The line goes away once text or activity starts; no status history is kept.
- **Details popover (SHOULD):** for each finished reply: provider, model, effort, mode, start and finish times, duration, input and output tokens, cost when the host reports it, and a context-usage meter when reported.
- **Time separators (SHOULD):** a centered caption between turns more than 15 minutes apart (Messages style).
- **Compaction (SHOULD):** an inline divider, **Earlier messages summarized by Claude Code** (proposed).
- **Running state (MUST):** shown in the library row and the tab.
- **No toasts:** chat events never produce toasts. Connection state uses AgentLand's existing banner.

## 11. Keyboard shortcuts

**Reference defaults.** ⌘ is Ctrl off the Mac, and every shortcut can be rebound.

| Command | Default |
|---|---|
| Start a new chat | ⇧⌘O |
| New off-the-record chat | ⇧⌘' |
| Delete the current chat | ⇧⌘⌫ |
| Model picker | ⇧⌘M |
| Dictation | ⇧⌘L |
| Search | ⌘K |
| Settings | ⌘. |
| Shortcut list | ⌘/ |
| Sidebar | ⇧⌘S |
| Close dialog | Esc |
| Focus composer | ⇧Esc |
| Accept suggestion | Tab |
| Paste without file conversion | ⇧⌘V |
| Mention triggers | @ # / |
| Add a message pair without a reply | ⇧⌘Return |
| Regenerate | ⌘R |
| Allow tool | ⌥⌘Return |
| Deny tool | ⌥⌘⌫ |
| Stop | Esc, composer focused |
| Edit the most recent message | ↑, empty composer |
| Copy the most recent reply | ⇧⌘C |
| Copy the most recent code block | ⇧⌘; |
| Mute (spoken conversation) | M |
| Previous or next chat | no default |

**AgentLand.** Define these once as SwiftUI commands. They show in the Mac menu bar and in the iPad ⌘-hold overlay.

| Command | Keys | Notes |
|---|---|---|
| New Chat | ⌘N | File menu |
| New Home Tab / Close Tab | ⌘T / ⌘W | existing tabs |
| Previous / Next Tab | ⌃⇧Tab / ⌃Tab | |
| Find in Chat | ⌘F | SHOULD |
| Find Chats | ⌥⌘F | Notes and Mail convention |
| Show/Hide Sidebar | ⌃⌘S | system standard |
| Focus Composer | ⌘L | |
| Send / Queue | Return, ⌘Return | §5.3 |
| New Line | ⇧Return, ⌥Return | |
| Stop | ⌘. or Esc | Esc only when no popover or menu is open |
| Run Again (latest reply) | ⌘R | opens the rewind confirmation |
| Revise Latest Prompt | ↑ in an empty composer | capability-gated |
| Copy Latest Reply | ⇧⌘C | |
| Copy Latest Code | ⌥⇧⌘C | |
| Jump to Latest / Top | ⌘↓ / ⌘↑ | |
| Choose Model | ⇧⌘M | opens the model menu |
| Allow Once / Deny | ⌥⌘Return / ⌥⌘⌫ | only while an approval is pending; Always Allow deliberately has none |
| Send Answers | ⌘Return in a question card | |
| Add Attachment… | ⇧⌘A | Mail's attach shortcut |
| Delete (selected chat) | ⌘⌫ with the library focused | always confirms |
| Settings | ⌘, | Mac standard |
| Dictation | system (Globe key twice, or Edit ▸ Start Dictation) | |

There is no rebinding UI or custom shortcut sheet; the menu bar and the ⌘ overlay list the shortcuts.

## 12. Accessibility and motion

**Reference, observed:**
- **Screen readers:** the message list is a polite live log so screen readers pick up new messages, and a hidden heading labels the conversation. Icon buttons have labels, disclosures report whether they're expanded, and the model list is a listbox that reports its selection. Dialogs trap focus.
- **Keyboard:** hover-only controls also appear on keyboard focus.
- **High contrast:** a high-contrast setting adds focus rings, keeps hover controls visible and swaps the shimmer for solid text.
- **Reduced motion:** honored only by the phone drawer. The shimmer, pulsing caret, word fade-in and slide animations ignore it.

**AgentLand (MUST unless noted):**
- **Dynamic Type:** every text uses a text style, with code in monospace relative to body. At accessibility sizes, action rows wrap, composer chips collapse into Options, and bubbles widen to 90%.
- **VoiceOver structure:**
  - Each message is one element: **Your message, 9:41: …** or **Claude Code: …** (proposed), with its actions as custom actions (§3).
  - Disclosures report their state (expanded, running, failed).
  - A code block reads as **Code, Swift, 24 lines** (proposed), with a Copy action.
  - SHOULD: a **Turns** (proposed) custom rotor.
- **Announcements:** announcements, never per token, and only while the chat is visible (otherwise the library row carries the state):
  - **Claude Code finished** when a reply finishes
  - **Claude Code needs permission to run a command** when an approval arrives
  - **Claude Code asked 2 questions** when questions arrive
  - **Reply failed: rate limited** for errors
  - All proposed.
- **Focus:** approvals don't take focus from the composer. The docked pill can be focused and jumps to its card.
- **Reduce Motion:**
  - The caret stops pulsing and disclosures toggle without sliding.
  - Auto-scroll jumps instead of animating, and Jump and the pill appear without fading.
  - The circus stops: a still tent and no clown (existing).
- **Reduce Transparency:** on iPhone and iPad the system's glass on the composer, Jump and the pill answers it itself; on the Mac they use an opaque theme background.
- **Increase Contrast:** stronger borders on cards (on iPhone and iPad cards have a border only then) and, on the Mac, the composer; action rows always visible.
- **Differentiate Without Color:** tool, approval and delivery states always pair a symbol with text; diffs keep +/−.
- **Touch targets:** at least 44×44 pt on touch (28 pt on Mac), including chip remove buttons and Jump.
- **Keyboard reach:** Full Keyboard Access and Mac Tab navigation reach every action, and focus reveals hover rows.

## 13. Error and edge states

| Situation | Reference | AgentLand |
|---|---|---|
| Host unreachable, Mac asleep or app quit | Warning toast after about 2 s (longer grace just after returning from the background). A back-online toast only if the warning showed. After reconnecting, reloads the chat if a reply was running and has since finished. | Existing connection banner and wording. Content stays; polling pauses. Send is disabled with the inline note; drafts are kept. On recovery, resume from the cursor and reconcile read-only, so an in-flight reply updates to its real state. Nothing is resent. |
| User message provably not delivered | error toast plus an error on the reply | Bubble badge **Not Sent** (proposed) with **Send Again** (proposed), Edit and Delete (local only). Text is kept. |
| Delivery uncertain (timeout or dropped connection) | — | Badge **Not Confirmed** (proposed) with **Refresh Status**. Reconcile with the host transcript on reconnect; if the message is missing it becomes Not Sent. **Send Again** only on an explicit tap, which warns it may duplicate. |
| Provider not installed or removed | model picker empty state pointing to connection settings | The provider isn't offered on Home. Existing chats open read-only with **Claude Code isn't installed on your Mac.** (proposed) and no composer. |
| Provider signed out or auth expired | error panel | Error card **Claude Code Isn't Signed In** with **Sign in on your Mac, then choose Run Again.** (proposed). The composer stays enabled. |
| Rate limit or overload | error text | A status line with a countdown while the provider retries. If the provider gives up, an error card with Run Again. |
| Empty reply (no text, no tools) | the leading blank line is dropped; an error panel if an error came back | End caption **No response** (proposed) with Run Again. |
| Partial reply that then failed | partial content plus error panel | §2.8 |
| Stopped or interrupted | no marker | §2.9 |
| Very long transcript | latest 8 first; 8 more each time the top loader appears, scroll position kept; off-screen items skip painting | A lazy list. The first page is about the last 30 turns, with host cursor paging for earlier ones. Loading earlier pages keeps the visible message anchored, and a **Loading earlier messages** (proposed) row sits at the top. ⌘↑ loads pages progressively. |
| Very long single reply | rendered in full | Markdown blocks lay out lazily; code collapses; output is shortened |
| Upload failure | failed chip; the queued item marked | Failed chip with **Upload Again**. Send is disabled until the file is removed or uploaded again. |
| File too large or too many files | toast | Inline composer message stating the limit |
| Image gone (deleted or expired upload) | placeholder chip | **Attachment expired** (proposed) chip; the host keeps uploads 24 h |
| Chat deleted on another device | refreshed out of the sidebar | The tab shows **This chat was deleted.** (proposed) with Close, and the chat is never recreated |
| Model no longer offered | the selection empties and sending is blocked | The chip shows the stale model with a warning, and Send asks for another from the chip's menu |
| Host rejects a concurrent prompt because the agent is busy | — | The message goes to the queue (existing host behavior) |

## 14. Recommended scope for AgentLand v1

Constraints: no automatic resend after uncertain delivery; one shared implementation for iPhone, iPad and Mac; Liquid Glass only on floating controls (composer, Jump, docked pill), never on content; provider features capability-gated.

| Area | Behavior | Level | Rationale |
|---|---|---|---|
| Layout | Shared centered readable column for transcript and composer; full width on compact | MUST | One layout rule for all three platforms |
| Layout | User bubbles; bubble-free proportional prose for replies | MUST | Main fix for the terminal look |
| Layout | Header title plus provider·workspace subtitle; New Chat and overflow menu | MUST | Orientation without extra chrome |
| Layout | Chat Details sheet | SHOULD | One place for provider, mode and usage facts |
| Transcript | Plain-text user messages that render fenced code | SHOULD | Pasted logs stay faithful |
| Transcript | Collapse long user messages | SHOULD | Pasted logs swamp phone screens |
| Transcript | Model caption only when it changes | SHOULD | Less noise than a name on every reply |
| Streaming | Optimistic bubble plus status line before output | MUST | CLIs take seconds to start; silence looks broken |
| Streaming | Frame-coalesced updates and a streaming caret | MUST | Smooth, readable streaming |
| Streaming | Word fade-in, per-chunk haptics | SKIP | Motion and battery cost for little value |
| Scrolling | Follow rules, Jump button, new-activity dot | MUST | Reading back while the agent works is constant |
| Scrolling | Start at the first unread reply | SHOULD | Catch-up after background runs |
| Reasoning | Collapsed disclosure with timer and duration | MUST | Visible progress without flooding the view |
| Tools | Humanized rows with symbol-plus-text states | MUST | The core of an agent transcript |
| Tools | Grouped runs with summary headers; chronological interleaving | MUST | Long runs stay scannable |
| Tools | Expandable input and output, truncated output, Copy | MUST | Shows exactly what the agent did |
| Tools | Edits as diffs; nested sub-agent activity | SHOULD | Best review surface; delegation is common |
| Errors | Inline error card with an explicit Run Again | MUST | Visible and recoverable without auto-resend |
| Errors | Stopped and Interrupted markers | MUST | Partial replies otherwise look complete |
| Markdown | Code copy and auto-collapse, tables, lists, quotes, headings, safe links | MUST | Mostly built already; keep and polish |
| Markdown | Syntax colors, wrap toggle, pinned code header, table copy, callouts | SHOULD | Readability wins at modest cost |
| Markdown | Math, diagrams, HTML previews, code runs, citations, buttons on text selection, remote image loading | SKIP | Rare for coding agents, large surface, or a privacy risk |
| Actions | Copy; context menus; hover rows on pointer; accessibility actions | MUST | One action model everywhere |
| Actions | Edit and Resend through rewind, with confirmation and Restore | MUST (gated) | The providers' real equivalent of editing |
| Actions | Use in Composer | MUST | Fallback where rewind isn't supported |
| Actions | Run Again on the latest reply through rewind | SHOULD | Same mechanism; used less |
| Actions | Fork from Here; Details popover; Share one reply | SHOULD | Keep both paths honestly; transparency |
| Actions | Branch navigation, continue, ratings, text-to-speech, message deletion, variant menus, plugin buttons | SKIP | Providers can't back them, or low value |
| Approvals | Inline card: Allow Once / Always Allow (scoped) / Deny | MUST | Approvals gate the agent's real actions |
| Approvals | Docked "needs you" pill when the card is off-screen | MUST | A blocked agent must be noticed |
| Approvals | Deny with a note | SHOULD | Steers the agent without a new prompt |
| Approvals | Auto-approve on mode switch, Allow All | SKIP | Safety: every approval is explicit |
| Questions | Stacked card, single and multi select, Something Else text, explicit Send Answers, Dismiss | MUST | Matches the provider question tools |
| Questions | Secret input masked and never persisted or echoed | MUST | Credentials must not leak |
| Questions | After-state summaries in the transcript | MUST | Audit trail of decisions |
| Questions | Automatic recommendation pill, auto-submit on tap | SKIP | Invents intent; mis-taps would submit |
| Composer | Glass container, growth cap, per-provider placeholder | MUST | The primary floating control |
| Composer | Full-height editor | SHOULD | Long prompts on phones |
| Composer | Send/Stop/Queue states with Stop always reachable | MUST | Can't be trapped mid-run |
| Composer | Host queue: one at a time, Edit/Delete, failures block | MUST | Existing behavior, and the no-resend rule |
| Composer | Return, ⇧Return, ⌘Return and IME rules; newline on the software keyboard | MUST | Platform-correct text entry |
| Composer | Send with ⌘Return setting; Esc and ⌘. stop; ↑ edits last | SHOULD | Power-user comfort |
| Composer | Photos, Camera, Files, paste, drag-and-drop, chips with progress, explicit Upload Again | MUST | Attachments are part of the task |
| Composer | Dictation that never auto-sends | MUST | Existing; privacy and safety |
| Composer | Docked plan panel | SHOULD | Agents' todo lists show progress well |
| Composer | "@" file mentions | SHOULD | High value for code; needs a host file search |
| Composer | "/" palette, # $ : triggers, spoken conversations, long paste to file, web-page attach | SKIP | Provider-specific or out of scope |
| Composer | Per-tab drafts, with secrets excluded | MUST | Existing; no lost work |
| Selection | Provider fixed per chat and shown in the header | MUST | Sessions are provider-native |
| Selection | Model and effort chip; a menu of the host's first five models, with More Models for the rest | MUST | OpenCode lists can be long |
| Selection | Mode chip always visible, with host-advertised modes | MUST | The user must know whether the agent asks first |
| Selection | Default for new chats; confirm permission escalation | SHOULD | Fewer repeated choices; fewer surprises |
| Selection | Multi-model compare and merge | SKIP | One agent per chat |
| Library | Date-grouped list per workspace; selection highlight; New Chat entry points | MUST | Basic navigation |
| Library | Running and waiting-for-you row states | MUST | Agents run and block in the background |
| Library | Rename; Delete with confirmation | MUST | Basic hygiene |
| Library | Pin; unread dot and Mark as Unread | SHOULD | Triage many parallel runs |
| Library | Title search (MUST); content search with snippets (SHOULD) | MUST / SHOULD | Finding past work |
| Library | Archive, tags, folders, clone, previews | SKIP | Workspaces already group chats |
| Empty chat | Tent landing with existing actions; first-send transition; first-line title | MUST | Existing product rule, plus a clean handoff |
| Empty chat | Starter prompts | SKIP | Actions cover it; generic prompts don't fit code |
| Export | Copy Chat as Markdown | MUST | Cheap, universally useful |
| Export | Save as Markdown (.md) through the share sheet | SHOULD | Native sharing without a cloud |
| Export | Share links, PDF, JSON | SKIP | No cloud; low value |
| Metadata | Status line for provider waits and rate limits | MUST | Explains pauses without resending |
| Metadata | Time separators; compaction divider | SHOULD | Context for long sessions |
| Keyboard | Core commands: New Chat, Send, Stop, Jump, Sidebar, Find Chats, Allow/Deny, Copy Latest Reply | MUST | Mac and iPad keyboard users |
| Keyboard | The rest of the §11 table | SHOULD | Completeness |
| Accessibility | Dynamic Type reflow; VoiceOver structure and announcements; Reduce Motion; Reduce Transparency; Increase Contrast; non-color cues; 44 pt targets | MUST | Paid app; HIG baseline |
| Accessibility | Turns rotor | SHOULD | Faster VoiceOver navigation |
| Edge cases | Offline behavior under the existing connection rules; read-only reconciliation | MUST | No resend; honest state |
| Edge cases | Not Sent / Not Confirmed delivery states | MUST | The uncertain-delivery rule made visible |
| Edge cases | Paged history with anchored loading | MUST | Long agent sessions |
| Edge cases | Provider-missing and signed-out states | MUST | The most common setup failures |

## 15. Plain chats

The owner's request of 2026-09-27: standard AI chats, not programming ones, with the coding agents kept as an option. The host side is in docs/HOST-API.md "Plain chats".

- **What they are:** a chat with the host's own **chat** agent, which can only:
  - search the web;
  - read a web page;
  - keep a small memory about the user across chats.

  It can't run commands or read or change files. The chat belongs to no workspace: it lives in the host's reserved Chats space.
- **Starting:** New Chat (the library row, Home, ⌘N, the Mac toolbar) starts one at once; no workspace is needed. While offline it's refused at once with the offline notice, and nothing is sent. The coding agents stay under **New Agent Chat…** (§7).
- **Screen:**
  - It's the chat screen of §1–5, without the workspace and export lines, the mode chip, and the sentences about files the agent changed.
  - The header's subtitle is the model's name.
  - Kept: the model chip, attachments, dictation, the queue, Stop, Run Again, Edit & Resend, Copy and Save as Markdown, titles and the archive.
- **Tool activity:** the plain cards of §2.6.
- **Memory:**
  - A save shows **Memory updated** with Undo, because a page the model read can ask it to remember something.
  - A forget shows **Removed from memory**.
  - Settings → **Memory** lists, edits and deletes entries and turns memory off. Settings → **Chat Tools** says:
    - what each tool does;
    - where searches go;
    - that coding chats can search too;
    - which instruction files the model is also given.

    On iPhone and iPad both are one page, Settings → **Plain Chats** (2026-10-04); the "running code comes next" line was dropped as a placeholder.
- **Continue:** a plain chat continues only as a plain chat, with OpenCode's models.
- **Export:** a plain chat's Markdown names no workspace.
