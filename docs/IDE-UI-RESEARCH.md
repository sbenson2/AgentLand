# Open-source IDE and agent UI research — 2026-09-29

The strongest reference combination for AgentLand is **Happier for mobile agent sessions, Runestone for native iPhone/iPad editing, Code App for tablet workspace arrangement, CodeEdit for Mac window structure, and Zed for agent change review**. Emdash adds a useful task-oriented desktop reference. These projects solve different parts of the interface; adopting an entire application would bring substantial unrelated behavior and architecture.

My recommendation is to explore three arrangements: **one focused surface on iPhone; a primary surface with an optional companion on iPad; and configurable adjacent working surfaces on Mac**. These are design hypotheses informed by the references and research below, not experimentally established pane counts. Keep AgentLand’s paper/slate identity, circus artwork, centered workspace selector, Home launcher, and native controls as the foundation.

## Scope and evidence

This is a report-first investigation. It combines public project documentation, selected source files at pinned commits, six visually inspected publisher/project screenshots, and six peer-reviewed papers. Source inspection establishes that a reviewed path exists, not that the product works reliably. Published screenshots can predate the source snapshot. No reference app was installed, built, or connected to owner data; no AgentLand application code or installed app was changed for this research.

Evidence is saved in `.evidence/ide-ui-research-20260929/`: source pins and licenses, inspected-file manifests, original screenshots, paper manuscripts and extracted text, and Apple’s official HIG data. This is a focused review, not an exhaustive market survey or systematic literature review.

## iPhone references

| Reference | What its UI contributes | What we can use | Limits |
| --- | --- | --- | --- |
| **[Happier](https://github.com/happier-dev/happier)** | Its published phone screens emphasize sessions needing attention, a focused conversation, and a separate review surface. Approval UI includes the session, machine and path context. | MIT source: study the information hierarchy, approval context, pane adaptation and session switching. | React Native/TypeScript, not a drop-in SwiftUI component. It belongs to the Happy lineage, so these are related references rather than two independent designs. [Screens and lineage](https://github.com/happier-dev/happier/blob/2890e87c9ea7eaad7c14fc3ae8b88fc283b1c011/README.md), [approval context](https://github.com/happier-dev/happier/blob/2890e87c9ea7eaad7c14fc3ae8b88fc283b1c011/apps/ui/sources/components/approvals/ApprovalSessionContextCard.tsx). |
| **[Runestone](https://github.com/simonbs/Runestone)** | Native text editing, line numbers, syntax highlighting, search and selection behavior offer a better starting point for touch editing than arranging a desktop web editor inside a small viewport. | The MIT **editor framework** is a direct component candidate for iPhone and iPad. | The app’s complete UI is not what this repository supplies. It is an editor framework, not an agent IDE. Mac Catalyst support is described as unfinished; it is not the native Mac solution. [Framework source and scope](https://github.com/simonbs/Runestone/blob/592434a103a4d1ab83e14f87ac6eef569dd7a99d/README.md), [app/core distinction](https://runestone.app/landing-page/open-source/). |
| **[CloudCLI / Claude Code UI](https://github.com/siteboon/claudecodeui)** | Its published mobile screen puts a conversation above a composer and labeled Chat, Shell, Files, Git and Tasks destinations. Tool edits expose diffs inline. | A responsive-web comparison for destination labels, keyboard avoidance and contextual tool disclosure. | It is a web UI, not a native iPhone editor. Its AGPL-3.0-or-later license includes additional terms; prioritize studying the arrangement over importing its implementation. [Mobile reference](https://github.com/siteboon/claudecodeui/blob/dc7cb6c6dcd22988f3241e10303298046ead351e/public/screenshots/mobile-chat.png), [workspace tabs](https://github.com/siteboon/claudecodeui/blob/dc7cb6c6dcd22988f3241e10303298046ead351e/src/modules/project-workspace/WorkspaceTabs.tsx), [license](https://github.com/siteboon/claudecodeui/blob/dc7cb6c6dcd22988f3241e10303298046ead351e/LICENSE). |

**Suggested iPhone arrangement:** retain the centered workspace selector and one primary surface. Offer a short, labeled route to the selected task’s conversation, changed files, and terminal. A selected file or diff occupies the main viewport; returning to chat restores its position. Approval context and its decision controls appear together. Keep uncommon configuration behind the existing actions menu.

```text
             Workspace / selected tab       Actions
Task context and readable state
──────────────────────────────────────────────────
One main surface: conversation, editor, or review

Pending approval with affected path, when present
Composer or editing controls above the keyboard
```

The arrangement should reduce the number of places a person must inspect to answer “what needs me?” Avoid making tiny icons, clipped paths, terminal output and a transcript compete in permanent columns. A bottom destination strip is an option to test, not a recommendation to add a second global navigation system immediately. Happier’s compact controls and CloudCLI’s many destinations also show the density tradeoff; the screenshots alone do not establish that either arrangement is easier to use.

## iPad references

| Reference | Tablet arrangement | What we can use | Limits |
| --- | --- | --- | --- |
| **[Code App](https://github.com/thebaselab/codeapp)** | The reviewed iPad screenshot shows an activity rail and file tree on the left, editor tabs above the main editor, and output/terminal below it. Reviewed SwiftUI code handles regular and compact sidebars and clamps a resizable panel against available height. | MIT app UI source is relevant to split sizing, editor tabs, contextual keyboard tools and persisted widths. | The project targets both iPhone and iPad, but its documented design is iPad-first and follows VS Code. The default Monaco editor’s lack of native touch selection is explicitly documented. Its bundled language runtimes have separate licensing and are outside this UI review. [Interface guide](https://code.thebaselab.com/guides/getting-familiar), [regular sidebar](https://github.com/thebaselab/codeapp/blob/6b508f35f45b5cd8706708179400078e90f528f4/CodeApp/Views/RegularSidebar.swift), [panel](https://github.com/thebaselab/codeapp/blob/6b508f35f45b5cd8706708179400078e90f528f4/CodeApp/Views/PanelView.swift). |
| **Happier** | Its official documentation distinguishes phone single-focus presentation from a tablet terminal docked at the bottom. Source supports terminal placement in a sidebar, details pane or bottom pane, with pane sizing based on the main content’s remaining space. | Study explicit tablet behavior and bounds that protect the primary surface. | I inspected phone and desktop screenshots, not a current iPad screenshot. Tablet conclusions here come from documentation and source, not a hands-on tablet test. [Tablet documentation](https://happier.dev/), [docking rules](https://github.com/happier-dev/happier/blob/2890e87c9ea7eaad7c14fc3ae8b88fc283b1c011/apps/ui/sources/components/sessions/terminal/embeddedTerminalDocking.ts), [pane sizing](https://github.com/happier-dev/happier/blob/2890e87c9ea7eaad7c14fc3ae8b88fc283b1c011/apps/ui/sources/components/appShell/panes/layout/paneSizing.ts). |
| **[Blink Shell](https://github.com/blinksh/blink)** | A terminal-focused iOS reference for external keyboard modifiers, configurable shortcuts, text sizing and touch input. | Study terminal input ergonomics alongside AgentLand’s existing SwiftTerm implementation. | It is a terminal, not an agent IDE. GPL-3.0 source calls for a license-compatible reuse approach. No Blink screenshots or runtime were tested here. [Input guidance](https://github.com/blinksh/blink/blob/a90b4423c8b7a86770c24a7eaa6c13b0a5904b18/README.md), [terminal controller](https://github.com/blinksh/blink/blob/a90b4423c8b7a86770c24a7eaa6c13b0a5904b18/Blink/Terminal/TermController.swift), [license](https://github.com/blinksh/blink/blob/a90b4423c8b7a86770c24a7eaa6c13b0a5904b18/COPYING). |

**Suggested iPad arrangement:** start with the same focused workspace as iPhone, then allow one companion surface when the window has room. Useful pairs are conversation + diff, editor + conversation, and editor + terminal. Let the person select the companion. The existing centered selector can continue to own workspace navigation; simultaneous working content does not require restoring the former navigation sidebar.

```text
                 Workspace / selected tab       Actions
───────────────────────────────────────────────────────
Primary surface                 │ Optional companion
Editor or change review         │ Conversation
                                │
────────────────────────────────┴──────────────────────
Optional terminal/output dock, opened when needed
```

The terminal dock is an alternative presentation, not a demand to keep a third surface visible. Narrow resizable windows, portrait, large text and the software keyboard should collapse supplementary content into the selected surface or an explicit overlay. Preserve the hidden surface’s session and draft. Derive layout from readable content widths and remaining height rather than a device-name check. Apple’s [layout guidance](https://developer.apple.com/design/human-interface-guidelines/layout) covers resizing, multitasking and Dynamic Type; its [sidebar guidance](https://developer.apple.com/design/human-interface-guidelines/sidebars) recognizes the space cost of persistent navigation.

## Desktop references for agentic programming

| Reference | UI arrangement worth studying | Reuse assessment |
| --- | --- | --- |
| **[Zed](https://github.com/zed-industries/zed)** | Agent conversations connect to a changed-files summary and an explicit Review Changes action. Review opens a multi-buffer tab, with individual hunk or whole-set decisions documented for the agent review workflow. | Best reference here for connecting conversation to inspectable code changes. The reviewed `agent_ui` crate is GPL-3.0-or-later; GPUI is Apache-2.0, but that does not make the editor/agent UI permissive. Rust/GPUI is also a substantial mismatch with AgentLand’s SwiftUI shell. Prefer adapting interaction principles. [Agent review](https://zed.dev/docs/ai/agent-panel), [agent UI license](https://github.com/zed-industries/zed/blob/bd747337d7be138834e20972b9e203c7b239cc47/crates/agent_ui/Cargo.toml), [GPUI license](https://github.com/zed-industries/zed/blob/bd747337d7be138834e20972b9e203c7b239cc47/crates/gpui/Cargo.toml). |
| **[Emdash](https://github.com/generalaction/emdash)** | A project/task navigator makes the task the unit of work. Reviewed code provides resizable, collapsible workspace regions, movable tab panes, and task rows with agent attention and branch context. The product documents separate worktrees for parallel tasks. | Apache-2.0: a useful source for task grouping and pane/state contracts. Its React/TypeScript desktop architecture requires adaptation. Copying the entire workbench would greatly expand AgentLand’s scope. [Product/source](https://github.com/generalaction/emdash/blob/873a3e2067f4abc136272ed2b61abea3a2c07bcf/README.md), [layout](https://github.com/generalaction/emdash/blob/873a3e2067f4abc136272ed2b61abea3a2c07bcf/apps/emdash-desktop/src/renderer/lib/layout/workspace-layout.tsx), [pane ownership](https://github.com/generalaction/emdash/blob/873a3e2067f4abc136272ed2b61abea3a2c07bcf/apps/emdash-desktop/src/core/primitives/workbench-shell/browser/tabs/pane-layout-store.ts). |
| **[CodeEdit](https://github.com/CodeEditApp/CodeEdit)** | A native Mac editing reference: tabs and split editors, supplementary navigator/inspector regions, and a collapsible utility area. Its windowing design describes reducing chrome for single-file windows. | MIT Swift/AppKit/SwiftUI source has the closest platform fit. CodeEdit itself is an editor reference; this review does not establish it as an agent IDE. Its separate MIT `CodeEditSourceEditor` package supports macOS and explicitly says it is not ready for production use. Evaluate before adopting. [Workspace source](https://github.com/CodeEditApp/CodeEdit/blob/fa2aebd86373211c78626074b53ab75010767575/CodeEdit/WorkspaceView.swift), [windowing design document](https://github.com/CodeEditApp/CodeEdit/wiki/Workspace-Windowing-%26-Layout-Strategy), [editor package and readiness](https://github.com/CodeEditApp/CodeEditSourceEditor/blob/1fa4d3c3ffba007482111466cb9721416f97ae00/README.md). |

**Suggested Mac arrangement:** let a person keep conversation and code/review adjacent and open terminal/output when it is useful. Treat Files as optional working content. Preserve the centered workspace selector; an optional task or file list should earn its screen space through navigation benefit.

```text
                 Workspace / selected tab       Actions
───────────────────────────────────────────────────────
Optional files  │ Main editor / change review │ Agent chat
or task list    │                            │
                │                            │
────────────────┴────────────────────────────┴─────────
Optional terminal/output area
```

This sketch shows a possible wide-window configuration, not the default for every Mac window. A smaller window can use two working surfaces or one. Focus commands, resize handles, clear pane titles and restored cursor/scroll positions matter more than displaying the maximum number of panes. Zed’s agent-specific review semantics must also be checked against each external agent’s capabilities; a UI reference is not proof that every ACP provider can support every decision action. [External-agent ownership](https://zed.dev/docs/ai/external-agents).

## Peer-reviewed research and its UI implications

| Paper and venue | Evidence examined | Implication for AgentLand, explicitly an inference | Boundary |
| --- | --- | --- | --- |
| **Barke, James & Polikarpova — [Grounded Copilot](https://arxiv.org/abs/2206.15000), PACMPL / OOPSLA1, 2023.** [Published record](https://doi.org/10.1145/3586030). | Observed 20 participants. Identified acceleration, when the programmer knows the next step, and exploration, when they use the assistant to investigate options. | Support both a quiet, focused editing flow and a conversation/review flow with room for explanation. | These are observed behaviors, not evidence that users need two new mode buttons. Desktop Copilot assistance differs from autonomous multi-agent work. |
| **Mozannar et al. — [Reading Between the Lines](https://www.microsoft.com/en-us/research/publication/reading-between-the-lines-modeling-user-behavior-and-costs-in-ai-assisted-programming/), CHI 2024.** | A 21-programmer study used the CUPS activity taxonomy. In the examined manuscript, verifying suggestions was the largest average state, at 22.4% of session time. | Make changed files, diffs, relevant output and verification results easy to reach from the conversation. Evaluate review effort, not just message count or generation speed. | The percentage describes this study’s tasks and participants; it is not an estimate for AgentLand or today’s agents. |
| **Henley & Fleming — [The Patchworks Code Editor](https://austinhenley.com/pubs/Henley2014CHI_Patchworks.pdf), CHI 2014.** | A controlled navigation study with 15 university students compared Patchworks, Eclipse and Code Bubbles. Patchworks improved navigation speed relative to Eclipse, reduced navigation mistakes relative to both comparators, and required less arranging than Code Bubbles. | Stable working positions, a bounded set of adjacent views and easy return to prior context are plausible improvements. | This tested Java code navigation on desktop. It does not establish an optimal iPad pane count or justify an infinite canvas. |
| **Amershi et al. — [Guidelines for Human-AI Interaction](https://www.microsoft.com/en-us/research/publication/guidelines-for-human-ai-interaction/), CHI 2019.** | Eighteen guidelines were evaluated in multiple rounds, including 49 design practitioners assessing 20 AI products. | Give activity understandable states; keep dismissal, correction and control near the associated action. Separate permission to execute from assessment of the resulting change. | General AI interaction evidence, not a mobile coding-agent layout experiment. |
| **Parhi, Karlson & Bederson — [Target Size Study for One-Handed Thumb Use](https://www.cs.umd.edu/~bederson/images/pubs_pdfs/p203-parhi.pdf), MobileHCI 2006.** | Two phases examined discrete and serial tapping on handheld touchscreens. Their combined recommendations were 9.2 mm and 9.6 mm respectively. | Protect usable touch targets as chrome becomes compact. Prefer large contextual controls over a dense desktop activity rail on iPhone. | Older handheld hardware and physical millimeters do not translate directly into modern iOS points. Use current platform guidance rather than converting these numbers mechanically. |
| **O’Brien — [How Scientists Use Large Language Models to Program](https://arxiv.org/abs/2502.17348), CHI 2025.** [Published record](https://doi.org/10.1145/3706598.3713668). | Survey, interviews and interaction-log review explored information seeking and code-verification strategies in scientific programming. Reported strategies included executing code, inspecting output, and examining generated code. | Keep explanations connected to the actual file and output, with quick movement between them. Agent narration should not substitute for visible verification evidence. | Scientists at one university are a specific population; this is supporting context rather than proof of professional agent-IDE behavior. |

Taken together, these papers support investigating **navigation cost, review effort, retained context and understandable control**. They do not directly validate AgentLand’s proposed layouts or compare the reviewed products. Phone/tablet agent-interface evidence remains a gap in this focused review.

For implementation constraints, Apple’s current [accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility) recommends 44×44 pt default controls on iOS/iPadOS, supports larger text and requires information to remain perceivable beyond color alone. Retain AgentLand’s mobile touch-target policy, Dynamic Type, VoiceOver labels, keyboard access, Reduce Motion and Reduce Transparency behavior when assessing denser arrangements.

## What to reuse first

| Candidate | Practical next evaluation | Adoption boundary |
| --- | --- | --- |
| **Runestone** | Evaluate native selection, syntax highlighting, find/replace, editing with the software keyboard, and AgentLand’s retained draft lifecycle. | Strongest component candidate. Verify compatibility with the current editor contract before adding the dependency. |
| **Code App UI source** | Study width clamping, compact/regular transitions, tab arrangement and input toolbars. | Recreate the useful rules in AgentLand’s shared workspace/design layers; copying a full Monaco/runtimes setup is unnecessary for layout work. |
| **CodeEdit / CodeEditSourceEditor** | Study Mac editor/utility-area placement; separately assess package readiness and draft/undo integration. | Closest Mac code fit, with an explicit production-readiness limitation. |
| **Happier / Emdash** | Adapt approval context, readable attention states, retained pane ownership and task-linked review. | MIT/Apache-2.0 sources are plausible reuse candidates, but their TypeScript UI is not a native Swift component. |
| **Zed / Blink / CloudCLI** | Use the reviewed interaction arrangements as references. | Their relevant code is copyleft; direct incorporation needs an appropriate license-compatible approach. |

These are file-level candidates, not blanket clearance for every dependency, artwork asset or trademark. MIT and Apache source reuse still requires retaining the applicable license/copyright notices; bundled third-party code needs its own review. No code was imported in this investigation.

## Relevance to the installed AgentLand redesign

The current shared [workspace shell](../shared/AgentLandWorkspace/Sources/AgentLandWorkspace/Surfaces/WorkspaceView.swift) mounts only the selected surface and retains sessions in the workspace registry. That provides the state foundation for this investigation. The main arrangement opportunity is reducing repeated switching between an agent’s explanation, the changed file and its output on wide screens. On iPhone, the same transition should stay explicit and readable.

Before another implementation pass, compare static prototypes for these specific flows:

1. **iPhone:** notice a task requiring attention, inspect the affected path, decide on an approval, then review a changed file and return to the same conversation position.
2. **iPad:** read a conversation beside its diff, open terminal output, resize the window, and show/hide the keyboard while retaining drafts and selection.
3. **Mac:** work between conversation, editor and output; resize or hide a companion without losing place; use keyboard focus commands and review changes in context.

Measure task completion, unnecessary switches, wrong-session actions, time spent finding changes, and lost context. Include large text, VoiceOver and touch-only iPad use. Compare against the installed redesign. Implementation remains paused for review of this report; proposed layouts and component evaluations are separate next steps.

## Visual references examined

These are original project-published images, not screenshots from a hands-on evaluation. Their depicted releases and controls can differ from the current source.

- [Happier phone sessions, conversation and review](https://raw.githubusercontent.com/happier-dev/happier/2890e87c9ea7eaad7c14fc3ae8b88fc283b1c011/.github/mobile-2000.png): one focused phone surface at a time; attention grouping.
- [Happier desktop conversation beside review](https://raw.githubusercontent.com/happier-dev/happier/2890e87c9ea7eaad7c14fc3ae8b88fc283b1c011/.github/desktop-2000.png): adjacent conversation and diff, with a session list.
- [Code App iPad editor](https://thebaselab.com/code/clang.png): left navigation, tabbed code, output below. This is a historical published image, not a capture of the pinned build.
- [CodeEdit Mac reference](https://user-images.githubusercontent.com/806104/194004176-3143d19f-1ad9-449c-bd41-8c4f9998f44b.png): conventional Mac editor hierarchy. The image is historical; source corroborates the workspace structure, not every depicted feature.
- [Emdash published workspace](https://emdash.sh/media/blog/public-v1-beta/v1beta.jpg): task/project grouping and restrained empty-state actions. The inspected image does not itself demonstrate active agent or review panes.
- [CloudCLI mobile conversation and inline diff](https://raw.githubusercontent.com/siteboon/claudecodeui/dc7cb6c6dcd22988f3241e10303298046ead351e/public/screenshots/mobile-chat.png): labeled destination strip with a keyboard-adjacent composer.

## Source snapshot register

| Project | Commit inspected | License examined | Source date, UTC |
| --- | --- | --- | --- |
| Code App | [6b508f3](https://github.com/thebaselab/codeapp/tree/6b508f35f45b5cd8706708179400078e90f528f4) | MIT app source | 2026-09-15 |
| Runestone | [592434a](https://github.com/simonbs/Runestone/tree/592434a103a4d1ab83e14f87ac6eef569dd7a99d) | MIT framework | 2026-03-25 |
| Happier | [2890e87](https://github.com/happier-dev/happier/tree/2890e87c9ea7eaad7c14fc3ae8b88fc283b1c011) | MIT root and UI | 2026-09-29 |
| CodeEdit | [fa2aebd](https://github.com/CodeEditApp/CodeEdit/tree/fa2aebd86373211c78626074b53ab75010767575) | MIT | 2026-08-18 |
| CodeEditSourceEditor | [1fa4d3c](https://github.com/CodeEditApp/CodeEditSourceEditor/tree/1fa4d3c3ffba007482111466cb9721416f97ae00) | MIT; macOS package | 2025-12-31 |
| Zed | [bd74733](https://github.com/zed-industries/zed/tree/bd747337d7be138834e20972b9e203c7b239cc47) | Agent UI GPL-3.0-or-later; GPUI Apache-2.0 | 2026-09-28 |
| Emdash | [873a3e2](https://github.com/generalaction/emdash/tree/873a3e2067f4abc136272ed2b61abea3a2c07bcf) | Apache-2.0 | 2026-09-27 |
| CloudCLI | [dc7cb6c](https://github.com/siteboon/claudecodeui/tree/dc7cb6c6dcd22988f3241e10303298046ead351e) | AGPL-3.0-or-later, additional terms | 2026-09-28 |
| Blink | [a90b442](https://github.com/blinksh/blink/tree/a90b4423c8b7a86770c24a7eaa6c13b0a5904b18) | GPL-3.0 | 2026-04-14 |

The Happier snapshot is its default `dev` branch, not an assertion about an App Store release. Wiki and product-documentation links are live references and are not pinned by these code commits. Paper venues were checked separately from preprint upload dates; the CUPS paper is CHI 2024, despite its earlier arXiv identifier. Runtime compatibility, responsiveness, performance, security, accessibility and agent-provider coverage remain untested for these reference projects.
