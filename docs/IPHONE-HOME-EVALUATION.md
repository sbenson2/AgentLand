# iPhone Home, work switching and layout evaluation — September 29, 2026

Evaluation only. Preserve AgentLand's paper/slate palette, circus artwork, owner-requested larger text, six Home actions and native iPhone behavior. No implementation or skill installation is proposed as part of this report.

The owner's updated direction is a top-left **Open Work** menu and Chrome-like tabs across the top. Evaluate that direction alongside Home and the working-screen layout; the previous handoff's centered-picker preference is superseded for these proposals. Implementation remains paused. The visual identity already holds together. A new theme or wholesale imitation of another app is not justified by the evidence.

## Evidence and scope

Repository: `~/Developer/AgentLand`, `main`, HEAD `0e6d0e3`. The uncommitted redesign is the baseline; the commit alone does not reproduce it. This evaluation covers iPhone Home, workspace/task switching and related screen arrangement.

Fresh screenshot capture uses the existing `testHomeCapsulesAndQuip`, `testDarkAppearance` and `testSidebarNavigation` cases on the disposable iPhone simulator, with a local deterministic model and isolated host. The physical iPhone was detected but not used for capture, updated, or reconfigured. These are screen captures, not camera photographs or evidence of physical thumb comfort. Capture results and provenance are recorded in the [evidence directory](../.evidence/iphone-home-evaluation-20260929/).

The fixture adds a Home ellipsis menu, the workspace name “Fixture,” and a fixed quip. Those are not production defects. The tests use disable-animation launch flags: still captures cannot establish the quality or distraction of the production animation. The intentional larger text is part of the baseline.

Browse the [screenshot comparison gallery](../.evidence/iphone-home-evaluation-20260929/gallery.html), or open Home directly in [light](../.evidence/iphone-home-evaluation-20260929/screenshots/home-light.png), [dark](../.evidence/iphone-home-evaluation-20260929/screenshots/home-dark.png), and [accessibility text](../.evidence/iphone-home-evaluation-20260929/screenshots/home-large-text.png). The [current workspace picker](../.evidence/iphone-home-evaluation-20260929/screenshots/workspace-switcher.png) is baseline evidence, not the proposed design.

Reference images are six unaltered publisher screenshots retrieved from Apple's App Store on September 29. Things and Bear include advertising text and device frames; comparison concerns the depicted app interface, not their promotional composition. Screenshot age and appearance need not match the currently listed app version. Bear's supplied imagery depicts an older phone; one GitHub Inbox image has Spanish interface labels. None of the reference apps was installed or usability-tested here.

## Verified peer-reviewed research

These are published research papers, distinct from platform guidelines and skill authors' advice. “Verified” means the publication identity, venue and described findings were checked against author/institutional records and accessible paper text; it does not mean the studies were independently replicated here.

| Paper and verified venue | Evidence | Appropriate use for AgentLand; limits |
| --- | --- | --- |
| **Parhi, Karlson & Bederson (2006), Target Size Study for One-Handed Thumb Use on Small Touchscreen Devices.** ACM MobileHCI, pp. 203–210. DOI: `10.1145/1152215.1152260`. [Author-hosted paper](https://www.microsoft.com/en-us/research/wp-content/uploads/2006/01/parhi-mobileHCI06.pdf). | Two phases with 20 right-handed participants tested discrete and serial thumb targets on an HP iPAQ. Authors recommended about 9.2 mm for discrete targets and 9.6 mm for serial targets after considering performance and preference. | Protect target size and separation while adjusting label space. This old PDA experiment does not identify a universal iPhone thumb zone, and millimetres cannot be substituted directly for SwiftUI points. It does not establish that the bottommost position is always best. |
| **Tuch et al. (2012), The role of visual complexity and prototypicality regarding first impression of websites: Working towards understanding aesthetic judgments.** International Journal of Human-Computer Studies 70(11), pp. 794–811. DOI: `10.1016/j.ijhcs.2012.06.003`. [Google Research publication record](https://research.google/pubs/the-role-of-visual-complexity-and-prototypicality-regarding-first-impression-of-websites-working-towards-understanding-aesthetic-judgments/), [University of Basel abstract](https://edoc.unibas.ch/entities/publication/5752512e-9b52-4af9-9140-d07fed6b562e). | Two screenshot experiments found that visual complexity and familiarity of layout affected aesthetic judgments; simpler, more prototypical websites were rated more appealing. The first experiment used 119 website screenshots. | Keep navigation recognizable and reduce competing emphasis. This is evidence about first-impression aesthetics on websites, not task success on phones. It does not prove that shrinking AgentLand's tent improves usability. Venue and abstract were verified; the publisher's full text was not available through the attempted DOI access. |
| **Amershi et al. (2019), Guidelines for Human-AI Interaction.** ACM CHI. DOI: `10.1145/3290605.3300233`. [Author-hosted paper](https://www.microsoft.com/en-us/research/wp-content/uploads/2019/01/Guidelines-for-Human-AI-Interaction-camera-ready.pdf). | Eighteen guidelines were developed through multiple evaluation rounds, including 49 design practitioners assessing 20 AI-infused products. They address understandable capabilities, contextual information and user control. | Clearly distinguish a selected workspace, actual agent activity and playful decorative copy. Keep invocation, correction and dismissal discoverable. This validates the relevance of guidelines across evaluated products, not one specific Home arrangement or a randomized improvement in end-user performance. |
| **Mozannar et al. (2024), Reading Between the Lines: Modeling User Behavior and Costs in AI-Assisted Programming.** ACM CHI 2024; venue confirmed by [Microsoft Research](https://www.microsoft.com/en-us/research/publication/reading-between-the-lines-modeling-user-behavior-and-costs-in-ai-assisted-programming/). [Author paper, version 5](https://arxiv.org/html/2210.14306v5). | Twenty-one programmers retrospectively labeled their Copilot sessions. Verifying suggestions was the largest average activity category, at 22.4% of session time. | For later iPhone work, evaluate returning to an existing conversation and inspecting its output, as well as starting a chat. This desktop code-completion study does not determine the best mobile Home layout or prove that every AgentLand user prioritizes review. |
| **Chang et al. (2021), When the Tab Comes Due: Challenges in the Cost Structure of Browser Tab Usage.** ACM CHI. DOI: `10.1145/3411764.3445585`. [Author-hosted paper](https://josephcc.com/static/papers/233987809/paper.pdf), [conference award record](https://chi2021.acm.org/information/5208.html). | Ten information workers were interviewed four times over two weeks, followed by a survey of 103 participants. The paper describes competing pressures to retain tabs for future work and close them to reduce clutter and resource costs. | Pair visible tabs with a searchable, grouped overview and clear close semantics. This supports treating tabs as retained work, not merely buttons. It does not prove a horizontal strip beats a picker on iPhone or prescribe an ideal tab count. |

Apple's [accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility) is the native platform reference, not peer-reviewed research. Use it alongside the project's stricter minimum 44-point phone target rule, readable Dynamic Type, adequate spacing and appropriate accessibility behavior. The Home component has a 48-point baseline and 12-point grid gaps; neither a screenshot nor a visual assessment alone proves accessibility compliance.

No reliable claim here says that six actions are intrinsically too many, that all labels must fit one line, or that a particular layout will improve conversion by a stated percentage. Those would require different evidence.

## Popular design skills: adoption versus demonstrated results

Inspected the actual public `SKILL.md` files, skills.sh listings and GitHub repository metadata. Counts below are snapshots from September 29, not unique active-user counts. GitHub stars describe the entire repository, which can contain multiple skills. Security audit badges are not usability evaluations. I found no independent controlled UX-outcome benchmark for these three in the sources inspected.

| Skill | Adoption observed | Fit for this project |
| --- | --- | --- |
| [SwiftUI Expert — AvdLee](https://www.skills.sh/avdlee/swiftui-agent-skill/swiftui-expert-skill) · [source](https://github.com/AvdLee/SwiftUI-Agent-Skill) | **33.2K installs**, **3,624 repository stars** from GitHub API. | Best prospective addition for native implementation and review: SwiftUI layout, safe areas, navigation, state, accessibility labels and API availability. Its current instructions include SDK 27 topics; advice must match AgentLand's installed SDK and deployment target. It is implementation guidance, not a substitute for user research or an established visual direction. |
| [Frontend Design — Anthropic](https://www.skills.sh/anthropics/skills/frontend-design) · [source](https://github.com/anthropics/skills/tree/main/skills/frontend-design) | **934.9K installs**, **178,965 repository stars** across the skills repository. | Already installed; its local file matches the fetched upstream file. Useful for coherent typography, hierarchy, restraint and screenshot critique. Web-specific implementation and marketing-page advice must yield to native iPhone conventions. Keep using its applicable design principles. |
| [UI/UX Pro Max — nextlevelbuilder](https://www.skills.sh/nextlevelbuilder/ui-ux-pro-max-skill/ui-ux-pro-max) · [source](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill) | **375.7K installs**, **131,472 repository stars**. | Useful as a searchable checklist/reference collection; it includes SwiftUI guidance. Its broad priority table mixes web concepts and “44×44px” with mobile advice. Validate platform units and rationale. Its palette/style generator is unnecessary for AgentLand's established identity. Secondary reference, not the primary decision-maker. |

The installed `design-taste-frontend` explicitly lists native mobile as out of scope and directs readers to Apple HIG/Material. It should not govern this iPhone pass. No new skill was installed or executed. Downloaded candidate files were inspected as reference material only.

Optional future install commands, if selected:

```sh
npx skills add https://github.com/avdlee/swiftui-agent-skill --skill swiftui-expert-skill
npx skills add https://github.com/nextlevelbuilder/ui-ux-pro-max-skill --skill ui-ux-pro-max
```

## Comparison with established iPhone apps

Things and Bear were both named in Apple's [2017 Design Awards](https://www.apple.com/newsroom/2017/06/apple-design-awards-celebrate-the-best-in-innovation-and-creativity/). The US App Store lookup returned Things at 4.82/5 from 27,971 ratings, Bear at 4.68/5 from 6,863, and GitHub at 4.83/5 from 37,326. These are recognition and adoption signals. They do not isolate the contribution of a particular screen, or prove commercial success or superior usability for AgentLand's tasks.

| Reference | What is visible in the inspected image | Useful comparison with AgentLand |
| --- | --- | --- |
| [Things 3](https://apps.apple.com/us/app/things-3/id904237743), [navigation image](../.evidence/iphone-home-evaluation-20260929/references/things-1.png), [Today image](../.evidence/iphone-home-evaluation-20260929/references/things-2.png) | Navigation uses aligned labels, category icons, Quick Find and separated project groups. Today uses task titles with lighter project context and a distinct add control. | Adopt the clarity of label alignment and primary/secondary information. AgentLand's capsules give labels less horizontal room and give all six destinations similar weight. Do not copy a long task list onto the fixed launcher. |
| [GitHub Mobile](https://apps.apple.com/us/app/github/id1477376905), [Home image](../.evidence/iphone-home-evaluation-20260929/references/github-1.png), [Inbox image](../.evidence/iphone-home-evaluation-20260929/references/github-2.png) | Home distinguishes My Work from Favorites and has labeled persistent destinations. Inbox combines item title, repository context, status and time. The Inbox screenshot also devotes substantial space to an onboarding prompt. | Strong reference for a future populated picker/Resume Work: explain which work an item belongs to. For Home, consider distinguishing starting, resuming and configuration through emphasis. Its density and promotional prompt are not improvements to copy. |
| [Bear](https://apps.apple.com/us/app/bear-markdown-notes/id1016366447), [editor image](../.evidence/iphone-home-evaluation-20260929/references/bear-1.png), [navigation image](../.evidence/iphone-home-evaluation-20260929/references/bear-2.png) | The depicted document receives most of the working surface. Navigation is grouped separately, with readable labels and a selected tag. | Keep AgentLand's distinctive artwork on Home and protect room for content in working screens. Bear demonstrates coherent identity with restrained chrome; it does not show that AgentLand needs Bear's colors, fonts, drawer, or an identical Home. |

## Top-left Open Work and top tabs

**Recommendation: evaluate a two-row top area first.** One row identifies the work context and provides the top-left Open Work control; a second, horizontally scrollable row exposes open items. This makes switching to a visible item one tap and separates choosing a workspace from choosing an item within it. A single crowded row is the comparison option, not the initial preference.

Illustrative structure only; these are not screenshots or implemented UI:

```text
A. Two rows, recommended starting point
┌─────────────────────────────────────────┐
│ Open Work ▾     Workspace name       ⋯  │
│ [Fix login] [Terminal] [README…]  →      │
├─────────────────────────────────────────┤
│                                         │
│             Selected content            │
│                                         │
│ Chat composer / relevant editing tools  │
└─────────────────────────────────────────┘

B. One row, compare for space savings
┌─────────────────────────────────────────┐
│ Work ▾  [Fix login] [Terminal]  →    ⋯  │
├─────────────────────────────────────────┤
│             Selected content            │
└─────────────────────────────────────────┘
```

The examples show hypothetical labels, not existing user tasks. The arrow represents horizontal overflow, not a proposed tiny tap target. Candidate A costs approximately one additional 44-point row before content relative to a one-row arrangement; this is an initial layout budget, not a measured prototype. At accessibility sizes it may need more height. Candidate B leaves little room for readable titles once the fixed controls are reserved. On a narrow phone, showing fewer readable tabs is preferable to shrinking all tabs into indistinguishable fragments.

**Define the hierarchy before choosing tab shapes:**

- Open Work is the global overview: Home, workspaces, standalone Chats, and open items. Keep it anchored at the top left, outside the scrolling tab strip. A searchable sheet can support full titles, workspace/path subtitles, agent identity and waiting/running text. Use the existing model and retained sessions; do not introduce a new task backend.
- Proposed default: the strip contains open items in the selected workspace; standalone chats form their own context. This keeps unrelated projects out of a narrow row. Selecting an item in Open Work reveals its context and scrolls its selected tab into view. Global tabs across all workspaces remain a comparison option if cross-project switching is the dominant task.
- A tab represents an existing chat, terminal, file/editor or other retained surface. The word “task” must not imply that each current tab is an independent running agent. Use a type icon plus a useful title, with the complete accessible name including context and state. Stable ordering helps re-find an item; do not reorder tabs whenever an agent produces output.
- Show selection through shape/weight as well as color. Use restrained state marks, with full status text in the overview and accessible label. Do not add continuous activity animation to every tab.
- Keep close discoverable in the current-item actions and overview. Tiny close crosses on every narrow tab would compete with selection. Preserve dirty-editor confirmation. Closing a terminal tab must retain the established remote-terminal behavior; closing a chat must not be presented as stopping the agent. Stop remains a separate explicit control.
- Preserve a direct Home route in Open Work and the six Home actions. Evaluate the tab row on working surfaces first; whether it remains visible on Home is an explicit prototype comparison because it consumes space in the fixed launcher. Never make tabs disappear unpredictably when typing.

Google's [current iPhone/iPad tab help](https://support.google.com/chrome/answer/2391819?co=GENIE.Platform%3DiOS&hl=en) documents a tab switcher, search and groups. It does not establish that a desktop-width strip is the best arrangement on an ordinary portrait iPhone. Use Chrome's retained-item model as inspiration, with phone-sized labels and controls. Top-left reach still needs a physical-phone check; familiarity alone does not establish comfort.

## Layout around the tabs

| Surface | Evaluation advice |
| --- | --- |
| Home | Keep the circus launcher. If tabs remain visible here, shrink decorative spacing first, keeping the title, six actions and bottom clearance. The new top-left control should replace the centered switcher rather than coexist with it. |
| Chat | Let the selected tab carry the conversation title. Show concise agent/state context without repeating a full title header. Keep the conversation as the main content area, the composer above the keyboard, and Send/Stop and permission decisions reachable. Evaluate a labeled model/options control instead of a row of partially visible chips. |
| Files/editor | Keep the tab's file identity and a compact path/dirty-state/Save area. Avoid a tab label, a second full filename header and a third command band for the same file. Folder navigation still needs a useful location cue. |
| Terminal | Give output the remaining height. Keep its keyboard accessory local to terminal input; the top tab row must not become another terminal command strip. |
| Review | Open a supported changed file or Git surface as a clearly related destination, preserving a reliable return to the conversation and its position. Keep approval-to-execute distinct from reviewing resulting changes. |
| Settings | Retain Home access and bottom-origin presentation. Reduce repeated header bands. The current decorative grabber should either gain deliberate drag behavior or be removed; no gesture change is made here. |

The first comparison should include two, six and twelve open items; duplicate long titles; two workspaces; a standalone chat; one waiting agent; a dirty editor; and keyboard-visible chat. These are proposed test conditions, not evidence already gathered. Compare switching accuracy, time to find a named item, wrong-context selections and visible working space. Current evidence does not exercise all of those conditions.

## Home findings and priority

These are evaluator judgments and source-supported observations, not measured user failures.

1. **Preserve the visual foundation.** The shaded title and tent belong to one palette and rendering style. Native action text stays readable and distinct from display lettering. There are six labeled actions rather than ambiguous icon-only launchers. Keep these strengths.
2. **First refinement candidate: label space and alignment.** New Terminal, Browse Files, Resume Work and Open Workspace wrap while New Chat and Settings are single-line in the reviewed portrait baseline. The issue is uneven scanning rhythm, not wrapping by itself. Symbol/disclosure reservations and centered text make the narrow labels work harder. Evaluate padding and alignment before reducing type. Keep full, meaningful labels and adequate targets.
3. **Second candidate: action priority.** Creating, returning, browsing and configuration have the same capsule treatment. That makes the launcher easy to recognize as a set but does little to indicate the most relevant next action. Compare modest emphasis within the existing six-action layout. Whether New Chat or Resume Work deserves priority depends on actual usage; no usage telemetry was examined. Keep Settings directly reachable.
4. **Review artwork-to-action spacing, without removing the identity.** The eye reaches a broad display title and tent before the actions. That is appropriate for a branded launcher, but a returning worker may prefer the actions to command more attention. A modest spacing change is a hypothesis to compare, not a research-proven fix. Do not refill the resulting room with extra content or a scrolling activity feed.
5. **Keep playful content separate from status.** The fixed test quip mentions pull requests, but it is not live status. This evaluation does not claim the production app currently reports fictitious progress. If real waiting/running state later appears near Home navigation, make it visually and semantically distinct from quips.

No contrast failure, physical reach failure or VoiceOver failure is asserted from these still images. No recommendation is made to remove the text enlargement, shrink targets or change the palette. The proposed top tab strip is the owner's requested direction for evaluation, not an implemented change or a research-proven outcome.

## What would establish an improvement later

If the owner requests proposals, compare the current Home with one conservative refinement first. Use the same artwork, labels, text size, viewport and appearance. Ask representative users to start a standalone chat, start an agent chat in a named workspace, resume a named conversation, browse a file and find Settings. Observe first choice, backtracking, completion and perceived clarity; do not infer success from preference alone.

Verify light/dark, the smallest supported iPhone viewport, long labels, accessibility text and all six actions. Use a physical phone for one-handed comfort, VoiceOver and production motion. Keep the fixed ordinary-text launcher and accessibility scrolling contracts. Those checks are future acceptance work, not claims established by this evaluation.

## Capture outcome

All three existing UI cases passed on September 29: `testHomeCapsulesAndQuip`, `testDarkAppearance`, and `testSidebarNavigation`. Ten fresh 1206×2622 captures were retained and visually inspected, alongside six publisher reference images. Home's test checks its six targets, spacing, fixed ordinary-text layout, long quip, Settings presentation and accessibility scrolling. These results do not constitute a complete accessibility or physical-device usability evaluation. The current picker fixture is sparse; duplicate titles and many simultaneous sessions still require a dedicated later evaluation.

The initial attempt stopped before UI execution because the default temporary build cache lacked SwiftTerm's package manifest. It also logged a temporary-directory cleanup error. The retry used the intact build cache from the preceding Home pass and both requested cases succeeded; the additional picker case then succeeded. Application code was not changed to obtain those results. The harness restored `Fixture.json` to disabled.

Reproduction, using the disposable simulator already booted:

```sh
AGENTLAND_DERIVED_DATA=/private/tmp/agentland-home-redesign/ios-derived \
  python3 integration/check-ios-product.py <simulator-UDID> \
  --tests testHomeCapsulesAndQuip,testDarkAppearance
AGENTLAND_DERIVED_DATA=/private/tmp/agentland-home-redesign/ios-derived \
  python3 integration/check-ios-product.py <simulator-UDID> \
  --tests testSidebarNavigation
```

Logs, capture timestamps/hashes and unchanged-source verification are recorded in the [evidence summary](../.evidence/iphone-home-evaluation-20260929/verification.json). The `.evidence/` directory is local and git-ignored; include it when handing this report to another machine. No backend, saved-state format, iPad/Mac layout, dependency or branding change is part of this evaluation.
