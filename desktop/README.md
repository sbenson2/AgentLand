# AgentLand desktop host

`agentland-host` is the Go host for the independent AgentLand protocol. It owns
the authenticated `/v1` API, configured project routing, device pairing,
revocation, and the OpenCode adapter. The native macOS companion in
[`../macos/`](../macos/) configures and manages this same executable.

The active independent iOS application uses this host over HTTPS. The host does
not install a service, daemon, login item, VPN configuration, relay, or bridge.

## Provenance

AgentLand's owner wrote this host's Go code for an earlier prototype,
PocketCPU, and releases it here under the MIT license in
[`../LICENSE`](../LICENSE). Every commit in the prototype's archive is the
owner's, and the archive records the host as newly implemented Go code; no
CPTR code was copied into it.

The host's third-party dependencies keep their own licenses: the Go standard
library, Gorilla WebSocket and `golang.org/x/sys` from the start, and the
modules added since. Their license texts are in [`licenses/`](licenses/) and
listed in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md). The prototype's
original dependency notice is kept as
[`ARCHIVED_THIRD_PARTY_NOTICES.md`](ARCHIVED_THIRD_PARTY_NOTICES.md).

## State and OpenCode boundary

The module is `agentland/host`; its CLI is `agentland-host`. By default it
writes private host state to `agentland/host.json` under the OS user
configuration directory, or `agentland-host.json` when that directory is
unavailable. The state contains configuration, pairing-code hashes, device
records, and the folders of removed workspaces (`removedProjects`). Reusing that
state preserves configured projects and pairings; `init` refuses to overwrite it.
The host never imports CPTR or prior prototype state.

The Mac companion manages a private OpenCode runtime automatically: it runs the
OpenCode the host installs from the agent registry into `<state>.agents/opencode`
(`install-opencode` in "Configure and run the CLI"; the app ships none of its own).
For standalone CLI use or advanced external mode, install and start OpenCode
separately, bound to a loopback HTTP address. The current adapter authenticates to it as `opencode`
with the password supplied through the configured environment variable. For an
OpenCode server on the default port, configure the same fresh password for both
processes:

```sh
export OPENCODE_SERVER_PASSWORD='choose-a-fresh-secret'
opencode serve --pure --hostname 127.0.0.1 --port 4197

export AGENTLAND_OPENCODE_PASSWORD="$OPENCODE_SERVER_PASSWORD"
```

The host stores only the environment-variable name, never its value. The macOS
companion stores the value in the macOS Keychain and supplies it only to the
owned children it starts. The host accepts only credential-free loopback
OpenCode HTTP URLs such as `http://127.0.0.1:4197`.

## Local web workspace

Enable the terminal-first browser workspace with an absolute Vite bundle:

```sh
agentland-host serve --web-assets /absolute/path/to/AgentLandWeb ...
```

This starts a separate plain HTTP listener on literal `127.0.0.1` with an
ephemeral port. The native companion obtains a one-use launch URL through its
local session. Browser API calls use a process-local bearer token and the
explicit allowlist documented in `docs/HOST-API.md`.

## Chat state and routes

`serve` keeps chat state beside the host state file, all private to the user:

- `<state>.chats.json`: Claude Code and Codex chats created through AgentLand.
- `<state>.queue.json`: the prompt queue. A message that was being sent when
  the host was killed comes back as failed (it may have been delivered); the host
  never resends it. One that the agent refused unsent because the host's shutdown
  had begun is queued again, on disk, and the next start sends it.
- `<state>.schedules.json`: left by hosts before 2026-10-06, when schedules were
  removed; it is neither read nor deleted. Their archive table `schedule_runs` and
  the notices' `schedule_id` and `run_id` columns stay (the migrations are
  unchanged), unused.
- `<state>.titles.json`: the names the host gave OpenCode chats (its auto titles,
  which OpenCode never holds, and the device names it wrote to OpenCode), at most
  2048, the least recently named forgotten first. Claude Code and Codex chats keep
  theirs in `<state>.chats.json`. A file from a newer host stops the start.
- `<state>.attachments/` (mode 0700): uploaded files (mode 0600) under random
  host-chosen names. Unsent uploads expire after 24 hours; any other file there
  older than 24 hours is removed at startup and while the host runs.
- `<state>.agents/` (mode 0700, every folder 0700, owned by the user): the agent
  catalog, kept unless `serve` runs with `--no-agents` (see "Agents and ACP chats"):
  `registry.json` (the ACP registry's last good document and its ETag), `.icons/`, and
  one folder per installed agent with its versions, `current.json` and `status.json`
  (for OpenCode also `failed.json`, a version the Mac app said did not start).
  No agent id ends in `.json` or starts with `.`, so none names the folder's own files.
- `<state>.serve.lock` (mode 0600): the state's lock, held by `serve` while it runs and
  by `install-opencode` while it installs; each refuses to run while the other holds it.
- `<state>.acp-processes.json`: the agent processes this host runs (ACP agents, Claude
  Code, Codex), for the next host after a kill (see `serve` below).
- `<state>.chat-home/` (mode 0700): the Chats space's folder, where OpenCode runs plain
  chats, with the host's `opencode.json` (mode 0600, written again whenever it differs;
  see "Plain chats"). No route shows it.
- `<state>.memory.json` (mode 0600): plain chats' memory, its entries and its switch,
  written only by the host.
- `<state>.memory.sock` (a Unix socket, mode 0600, this user's processes only): how the
  plain chats' tool server saves and forgets memory entries through the host.
- `<state>.archive/` (mode 0700, owned by the user, never a symlink): the local
  archive, kept unless `serve` runs with `--no-archive`. `archive.db` (SQLite in
  WAL mode, mode 0600) holds chats, messages, interactions (outcomes only) and
  terminal-log records; `blobs/` holds attachment bytes by SHA-256;
  `terminals/YYYY/MM/<id>.log` (mode 0600) holds each terminal's raw output.
  Terminal input is never recorded. Nothing expires: only an archive delete
  removes data. When that disk runs low, terminal output (counted as gap bytes)
  and attachment bytes stop being recorded under 2 GiB free, and chat text only
  under 256 MiB; each resumes when space returns. Terminal output is recorded as
  it arrives; chats as described below.

The archive keeps every chat the chat hub holds, whichever provider feeds it
(`archive_chat_capture.go`): each message when it appears or changes (a
streaming reply at most once a second), with the chat's title, model, mode and
effort, and each approval or question's outcome with a one-line summary, never
an answer. `POST /v1/messages` and the queue archive the user message, with its
attachments' bytes, and wait until that is committed before the provider sees it;
a copy the provider certainly did not receive is removed again. A send keeps the
chat in the hub through its turn, so chats no device streams are captured too.
When the host starts, and every ten minutes after a finished pass, a backfill
(`archive_backfill.go`) imports what the archive
lacks: OpenCode sessions of the configured projects updated since its last pass,
at about four requests a second and never while a chat runs a turn, and the Claude
Code and Codex chats in `<state>.chats.json`, which it only reads. It keeps its
place in the archive, so a restart resumes where it stopped, and running it again
changes nothing. It does not read Claude Code's or Codex's own session folders.
`POST /v1/chat/continue` (`archive_continue.go`) starts a chat with another
provider or model from an archived one, with a seed built from the archive that
goes out with the new chat's first message.

Chat routes, all authenticated and scoped to a configured project and chat:

- `GET /v1/messages` returns `messages` (with `reasoning` and `attachments`
  display metadata; attachment contents are never returned) and, for a rewound
  OpenCode chat, `rewind.messageId`. Messages from that point on are hidden.
- `POST /v1/attachments?projectId=&sessionId=&name=` takes the raw file with its
  type in `Content-Type`: PNG, JPEG, GIF, WebP or PDF up to 10 MiB; plain text,
  Markdown, CSV or JSON up to 2 MiB. Each device may hold 32 unsent files and
  64 MiB. `POST /v1/messages` accepts up to five uploaded IDs in `attachments`;
  only the uploading device can send them, to the chat they were uploaded for.
  OpenCode receives them inline (text types as plain text, which OpenCode adds
  to the prompt); Claude Code and Codex read them from the attachments folder.
- `POST /v1/messages/rewind` hides the latest user message of an idle OpenCode
  chat with an empty queue so it can be edited and resent; OpenCode also
  reverts file changes made after it. `POST /v1/messages/restore` undoes that.
  Claude Code and Codex chats rewind too (below).
- `POST /v1/chat/regenerate` drops the latest turn of an idle chat with an empty
  queue and sends its prompt text again: Claude Code chats (below) and OpenCode
  chats, which are reverted to that prompt first. A prompt that had attachments
  cannot be regenerated (409 `regenerate_unavailable`; attachments are not kept).
- `GET /v1/queue`, `POST /v1/queue` and `POST /v1/queue/remove` manage up to 20
  queued messages per chat, shared by all devices. The host sends the first one
  when the chat is idle and not rewound, after the previous prompt has appeared
  in the transcript (or 90 seconds). A failed item is kept, blocks the rest of
  that chat's queue until removed, and is never retried. Once the host's shutdown
  has begun (`BeginShutdown`) no queued message is sent, and one caught mid-send
  that the agent refused unsent (its process had just been ended) goes back to
  `queued` rather than `failed` (`sendQueued`); one whose delivery may have
  happened stays failed with "could not confirm", as before.

- `GET /v1/chat/events` streams one chat as NDJSON (`application/x-ndjson`): `ready`,
  a `snapshot` unless the `after` cursor resumes, then message, part, delta, status,
  turn, interaction and queue events, a `beat` every 10 s and `end` after 120 s.
  OpenCode chats stream live from the host's one connection to OpenCode's
  `/global/event`, Codex chats from the host's Codex app-server and Claude Code
  chats from each chat's own `claude` process (both below).
  Each device may hold 8 streams. The stream extends its own connection deadlines,
  so the listener's 20 s read and 35 s write timeouts do not cut it.
- `GET /v1/chat/messages` pages a chat's messages with ordered parts, newest first.
  `GET /v1/messages?parts=1` adds `parts`, `createdAt`, `model` and `usage`;
  without it the response is unchanged.
- `POST /v1/messages` takes an optional `clientMessageId`: a repeat returns the first
  receipt (`duplicate: true`) and is never sent again.
- Chat names (`chat_title.go`, `chat_title_store.go`): every chat's info carries
  `titleSource` (`default`, `provider`, `auto`, `device`) and `titleBasis`, the
  newest message its title describes. A delivered user message names a chat whose
  title is a placeholder or an earlier auto name from its first clause of three
  words (free naming, never over a provider's or device's title); for OpenCode
  chats that name stays on the host and OpenCode's own generated title replaces
  it. `POST /v1/chat/title` takes a name a device wrote, refuses one based on an
  older message than the current name (409 `title_stale`), and writes it to
  OpenCode with `PATCH /session/{id}` or to the chats registry.

`GET /v1/capabilities` lists the configured features in `chatFeatures`; when chats
can stream, each provider's transport in `chatProviderInfo`; and `archive` when the
host keeps an archive. The event stream contract is in
[`../docs/HOST-API.md`](../docs/HOST-API.md).

### Codex chats

Codex chats stream through one shared `codex app-server` per host (`codex_*.go`),
started on the first Codex chat operation and spoken to as JSON-RPC over stdio
(Codex 0.156.1 sends no `"jsonrpc"` member; the host sends none and accepts either).
The server runs in its own process group with the host's environment minus
`AGENTLAND_*` and `OPENCODE_SERVER_*`, so it uses the Mac user's own Codex sign-in
and configuration. Its output is read one line at a time; a line over 8 MiB is
skipped and the reply gets a notice. Only the last 64 KiB of its stderr is kept, for
the log line written when it crashes. After a crash the running turn ends with an
error and the next start waits 1, 5, then 30 seconds; after 15 idle minutes the
server stops. At most 16 threads stay loaded; the least recently used idle one is
unsubscribed. The handshake names the host (`agentland_host`) and reads the Codex
version from `userAgent`. Versions 0.156.x, 0.162.0 and every later 0.x release (since
2026-10-12, checked with 0.162.1; since 2026-10-16, 0.163.0's app-server schema compared with
0.162.1's) run in full mode; any other version runs
in compatibility mode, where a method Codex answers as unknown (JSON-RPC -32601, or
-32600 "unknown variant" as 0.156.1 does) turns off the feature that needs it.
Experimental API is never requested.

- A new chat starts a thread in the project folder (`thread/start`); after a restart
  the thread is resumed (`thread/resume`, `excludeTurns`) before the next turn. A
  message is `turn/start` with the text, images as `localImage` inputs, the host's
  user message ID as `clientUserMessageId`, and the chat's model and effort. The
  message is recorded before it is sent; the `turn/start` answer (or `turn/started`)
  confirms delivery. When the request was written but no answer came, the reply says
  delivery is uncertain, and the host never sends it again.
- Modes (`GET /v1/chat/options`, `POST /v1/messages` `mode`): `ask` ("Ask", the
  default since 2026-10-12: workspace-write, approvals come to the devices),
  `auto-review` ("Auto-review", the default before, what `codex exec --approve-for-me`
  did: workspace-write sandbox, commands that need more reviewed by Codex's reviewer),
  `read-only` ("Read only") and `full-access` ("Full access"). Over `exec`, `ask` is not
  offered and the default is `auto-review`. Models come from `model/list` with their
  reasoning efforts.
- Items stream in Codex's order as parts of one reply per turn: agent messages and
  plans as text, reasoning (summary, or raw text when a model gives no summary),
  commands as `Command` tools with streamed output, file changes as `Edit` tools with
  their diffs followed by a patch part, MCP and dynamic tool calls, web searches,
  images and plan updates as tools, and compaction, review, auto-review decisions
  and warnings as notices. A reply that reaches 256 parts continues in another
  message of the same turn.
- Approvals become permission interactions offering exactly Codex's
  `availableDecisions`: `accept` is once; `acceptForSession`, or else
  `acceptWithExecpolicyAmendment` (Codex saves a command rule), is always;
  `decline`, or else `cancel` (which also stops the turn), is reject. Codex 0.156.1
  lists them although they are experimental API; without the list the usual
  accept/acceptForSession/decline are offered. File-change approvals offer those
  three; permission requests are granted for the turn or the session, or not at all.
  `alwaysLabel` (`interaction_always.go`) says which: "Allow this command in this
  chat" (Codex forgets it when the app-server stops), or a rule Codex saves in its
  home folder's `rules/default.rules` for every project. Question requests (`item/tool/requestUserInput`) become question interactions;
  secret answers are masked by clients and only passed to Codex. Any other request
  from Codex, such as an MCP elicitation, is answered at once with a JSON-RPC error.
- Stop sends `turn/interrupt`. Rewind hides the latest user message and its reply
  until restore; the next message drops them and removes their turn from Codex's
  history with `thread/revert` first. Codex does not restore files
  (`filesRestore: "unavailable"`), and only turns Codex reported through the
  app-server can be rewound. Fork (`POST /v1/chat/fork`) copies the chat through a
  message's turn into a new chat with `thread/fork` and `lastTurnId`.
- When the app-server does not start, messages run through `codex exec --json`
  for ten minutes before the server is tried again, and capabilities report
  `transport: "exec"`: streamed events, no approvals, rewind or fork. A new chat runs
  `codex exec --json --skip-git-repo-check --approve-for-me -C <project> [-m MODEL] -`
  (0.156.1 refuses `--sandbox` together with `--approve-for-me`); a resumed one runs
  `codex exec resume --json --skip-git-repo-check -c sandbox_mode="workspace-write"
  -c approval_policy="on-request" -c approvals_reviewer="auto_review" [-m MODEL] THREAD -`
  in the project folder, which gives Codex the same sandbox and reviewer as the new
  run. Before this change a resumed run dropped them and used the Mac's Codex
  configuration. Each run is its own process group (`oneshot.go`): Stop and the
  hour's limit give it SIGTERM at once and SIGKILL 2 s later, the host's shutdown
  SIGKILL after 1 s, so a tool of the run that ignores SIGTERM ends too.
- `<state>.chats.json` keeps each streamed Codex chat's settings, message parts,
  Codex turn IDs and rewind point under `codex`.

What was checked against the real Codex 0.156.1 (`AGENTLAND_TEST_CODEX=1 go test
-run TestCodexContract .`, with a throwaway `CODEX_HOME` and `HOME`, a local fake of
the OpenAI Responses API as a custom model provider and outbound HTTP pointed at a
closed port; no sign-in and no model credits): the handshake and version; streamed
reasoning and text deltas; a command approval arriving with `availableDecisions`
(`accept`, `acceptWithExecpolicyAmendment`, `cancel`), its always worded as
`Allow commands starting with "touch agentland-contract.txt" in all projects`, and
the approved command running; usage; `thread/revert` removing the rewound turn from what the model
receives next; `thread/fork` with `lastTurnId` keeping only earlier turns;
`turn/interrupt`; `model/list` with efforts; the exec fallback, new and resumed,
both running with the workspace-write sandbox and auto-review; and the app-server
resuming a thread that `codex exec` created, so chats from the one-shot runs go on
with their history. Covered by unit tests
with a fake codex only: file-change and permission approvals, question requests
(Codex 0.156.1 offers its question tool only in Plan mode, which needs experimental
API, so capabilities do not list `questions`), MCP elicitations, crashes and restart
backoff, oversized lines, compatibility mode, the idle stop and the loaded-thread
limit.

### Claude Code chats

Each Claude Code chat streams through its own long-lived process
(`claude_*.go`), speaking the Agent SDK stream-json protocol on stdin and stdout:

```sh
claude -p --verbose --input-format stream-json --output-format stream-json \
  --include-partial-messages --replay-user-messages --permission-prompt-tool stdio \
  --allow-dangerously-skip-permissions --permission-mode MODE [--model MODEL] [--effort LEVEL] [--max-budget-usd USD] \
  (--session-id UUID | --resume UUID [--resume-session-at UUID --resume-drops-turn UUID] [--fork-session]) \
  [--add-dir ATTACHMENTS_FOLDER]
```

`claude` is found like the terminal's programs (`/opt/homebrew/bin`,
`/usr/local/bin`, `~/.local/bin`, then `PATH`); its version comes from the resolved
path (a `versions/2.1.280` file, or the npm package's `package.json`) and is never
learned by running a model request. The process runs in the project folder, in its own
process group, with the host's environment minus `AGENTLAND_*`, `OPENCODE_SERVER_*`
and a parent Claude Code session's markers (`CLAUDECODE`, `CLAUDE_CODE_SESSION_ID`,
`CLAUDE_CODE_MESSAGING_*` and the like), plus
`CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=true`,
`CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS=1` and `CLAUDE_CODE_STARTUP_FAILURE_RESULTS=1`,
so it uses the Mac user's own Claude sign-in and settings. Last come `AGENTLAND_CHAT=<the
chat's ID>`, `AGENTLAND_HOST` and `AGENTLAND_HOST_STATE`, for `agentland-host chats
continue` (docs/HOST-API.md, "Continuing a chat in a new one"). Prompts go only on stdin.
`--permission-prompt-tool stdio` is what sends approvals to the host; without it
Claude Code denies every request. `--allow-dangerously-skip-permissions` (2026-10-12)
lets a running process switch into Bypass permissions; it allows nothing by itself.

- Lifecycle: a process starts when the chat first sends, and the host's first frame
  is an `initialize` control request, whose model list is kept for 30 minutes per
  installed binary (path and modification time) for `GET /v1/chat/options`; when no
  process has run, that route starts one only to initialize it (no model request).
  A process stops after 10 idle minutes, never while an approval or question waits.
  At most 6 run at once: the least recently used idle one stops for a new one, and
  when all six are working a send answers 429 `agent_capacity`. Stopping sends
  `interrupt` when a turn runs, closes stdin, then after 5 s sends SIGTERM to the
  process group and after 5 more SIGKILL, and only to that group; when the host
  stops, stdin closes and SIGTERM goes at once, SIGKILL 1 s later (see `serve`
  below). Output is read one line at a time; a line over 32 MiB ends the turn with
  a `protocol_error` reply and the process. The last 64 KiB of stderr is kept for diagnosis only and never shown.
- Delivery: every prompt carries a host-made uuid, which becomes the user message's
  ID and the receipt's `messageId`; with an archive it is the ID the archive already
  filed the message under, so the archived message and the chat's are one. The
  prompt counts as delivered when Claude Code
  replays it with that uuid (`--replay-user-messages`); the receipt waits for that
  (a send's write deadline is extended to 3 minutes for it). A process that ends
  first, or a replay that has not come after 30 s, makes the send uncertain (502
  `delivery_uncertain`; a repeat of its `clientMessageId` answers 409) and it is
  never sent again; a replay that comes later still starts the turn. A process that
  failed to start or initialize never received the prompt (502 `upstream_error`), so
  a repeat may send it.
- Streaming: `stream_event` content blocks become parts in the order Claude emitted
  them (text and `thinking` with `part.delta`, tools with their input once complete),
  one reply per Anthropic message; the finished `assistant` blocks reconcile them;
  `tool_result`s complete their tool parts (`is_error` makes them errors); `result`
  ends the turn with its usage and cost: the rise of `total_cost_usd` over what the
  process started from (`claude_cost.go`). That total is the session's; Claude Code
  saves it when a process exits on its own (end of input, or SIGTERM, which it
  handles with exit status 143) and restores it on `--resume` and into a fork, so
  the host carries each session's saved total across processes, rolls it back when
  a process dies by a signal (nothing was saved), and assumes it was saved when the
  host never saw the process end. A process whose starting total is unknown (a chat
  from before the host carried totals) or lower than expected leaves its first
  turn's cost out rather than count earlier spending twice. `system/init` gives the
  session ID and permission mode,
  `system/api_retry` shows as status `retry`, `session_state_changed` and `status`
  keep status and mode current, and `compact_boundary` adds a notice. Messages of
  subagents (`parent_tool_use_id`) are not shown.
- Approvals and questions: `can_use_tool` control requests become permission
  interactions offering once and reject, plus always when Claude suggested permission
  rules (`permission_suggestions`); the answer is `{behavior: "allow", updatedInput:
  <the original input>}` (always adds `updatedPermissions`: the suggestions) or
  `{behavior: "deny", message}`. The interaction's `alwaysLabel` and `alwaysDetail`
  (`interaction_always.go`) put the suggestions in words: the rules and whether they
  are saved (local, project or user settings) or last only while the chat's process
  runs, mode switches and extra folders; secrets are masked, and an unknown
  suggestion shape gives a generic label, logged once. `ExitPlanMode` is a permission
  titled "Leave plan mode and start on this plan?" whose detail is the plan (at most
  16 KiB, no `input`): the CLI's plan-file `input.plan`, else the model's own tool
  call's `plan` (2.1.296 sends `input: {}`), else a line saying Claude Code did not send
  it (`claudePlanNotSent`). `AskUserQuestion` becomes a question interaction (1-4 questions, choices,
  multi-select, free text); the answer is `allow` with `updatedInput.answers` keyed by
  question text, several choices joined with ", ", and a rejection denies. Answers are
  passed on and never stored. A `control_cancel_request` resolves the interaction as
  `gone`; any other request from the CLI is answered with an error.
- Controls: stop is `interrupt`, a model change `set_model` and a mode change
  `set_permission_mode` on the running process (modes `default` "Ask", `acceptEdits`,
  `plan`, `auto` and `bypassPermissions`; `default` is the default since 2026-10-12,
  `auto` before; `dontAsk`, listed until then, is still taken so a chat that has it
  keeps it). A different effort
  restarts the process between turns with `--effort`, resuming the session. A turn
  Claude Code ends with `error_max_budget_usd` shows as a reply error `max_budget`.
- Rewind hides the latest user message and its reply (`filesRestore: "onSend"`).
  The next message first has a process holding the whole session put the files back
  (`rewind_files`, a dry run first, the real one when `canRewind`), then starts one
  with `--resume S --resume-session-at <the entry before the prompt>
  --resume-drops-turn <the prompt's uuid>`, or a new session when the dropped turn
  was the first; the rewound messages are dropped when the new prompt is replayed.
  Claude Code refusing that truncation answers 409 `rewind_refused` and nothing is
  sent (restore and send again). Restore only clears the hidden mark. Regenerate is
  a rewind of the latest turn plus its prompt sent again. Fork copies the chat through
  a message's turn into a new chat whose first process runs `--resume S
  --fork-session --resume-session-at <that turn's last entry>`; its session ID comes
  from `system/init`.
- A process that ends mid-turn ends the turn with an error reply (`agent_exited`)
  that keeps what streamed, and pending interactions resolve as `gone`; the next
  message resumes the session. A host that stopped mid-turn shows that reply as
  failed after a restart.
- `<state>.chats.json` keeps each Claude chat's model, mode, effort, fork parent,
  streamed messages, rewind point, cost carried across processes (`costSession`,
  `costSaved`, `costTotal`) and uuid chain (each prompt's uuid with the
  transcript entry before it and the last entry of its turn) under `claude`, the
  rewind point again under `claudeRewind`, and the Claude session ID as `nativeId`;
  the archive's backfill imports the streamed messages from there as well.
  Replies from the earlier one-shot runs stay in `messages`; such a chat resumes its
  session, and its first streamed turn cannot be rewound (the host never saw the
  earlier entries).

What was checked against the real Claude Code 2.1.280
(`AGENTLAND_TEST_CLAUDE=1 go test -run TestClaudeContract .`, zero credits: a local
fake of the Anthropic Messages API as `ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY=fake-key`,
a throwaway `HOME` and `CLAUDE_CONFIG_DIR`, an environment holding nothing of the
owner's, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, `DISABLE_TELEMETRY` and
`DISABLE_AUTOUPDATER`): `initialize` and its model list; the version from the npm
package path; replay-based delivery with the host's uuid; streamed thinking, text
and tool parts in order; a Bash approval arriving as `can_use_tool` with
suggestions (a local-settings rule, the project folder for the session and a
switch to acceptEdits, worded in `alwaysLabel`), answered always (Claude applied
the suggested rules, including the switch to acceptEdits, which the chat then
showed); `AskUserQuestion` answers
reaching the model as `"Which color?"="Blue", "Which sizes?"="S, L"`; `interrupt`
ending the turn as aborted; `set_model` (the next request used the new model);
`set_permission_mode` to plan and `ExitPlanMode` arriving with its plan, approved
once; an effort restart with `--effort` and `--resume`; a Write approved once, then
rewind: `rewind_files` (dry run and real) removed the written file and the
truncating resume dropped the turn from what the model received; regenerate; fork,
with the new session ID from `system/init` and only the forked history sent to the
model; a truncation Claude Code refuses answering 409 `rewind_refused`; a turn with a
budget of $0.0001 in a new process with `--max-budget-usd 0.0001`: one model request,
then `error_max_budget_usd` ("Reached maximum budget ($0.0001)") as the reply's
`max_budget` error, and the next turn in a new process without the flag; the first
turn after the effort restart, after the truncating resume, of the fork and after the
budgeted process each cost one plain turn (629 µ$) while `total_cost_usd` reported
the session's $0.0075–$0.0113. Covered by
unit tests with a fake claude only (the test binary run as `claude` by a
test-package `init` hook, following JSONL scripts): deny answers, a withdrawn
request, requests the host does not handle, uncertain delivery when the process dies before the
replay and a late replay, process capacity and eviction, the idle stop waiting for a
pending request, the group kill (a tool process dies with Claude Code, which
ignores SIGTERM), a crash mid-turn, an oversized line, a stderr flood, api_retry,
attachments with `--add-dir`, the queue, chats from the one-shot runs, a host that
stopped mid-turn, the cost carried across an effort restart, an idle stop, a SIGKILL,
a host restart, forks of a running and a stopped source and a chat without a carried
total, and the legacy `GET /v1/messages` shape.

Archive routes under `/v1/archive/` (contract in
[`../docs/HOST-API.md`](../docs/HOST-API.md)) serve the change feed (a long-poll
with `wait`, woken when a batch commits a change), chat pages, full-text search
with each result's provider, export, attachment bytes (`blob`, by chat, message
and name, never by hash alone; `archive_blob.go`) and terminal logs to paired
devices, for configured projects only. `GET /v1/archive/stats` and the whole-archive export
answer only this Mac's own loopback session; any other caller gets 403
`local_only`. Stats report both free-space floors (`minimumFreeBytes`,
`chatMinimumFreeBytes`) and whether each pauses capture now (`capturePaused`,
`chatCapturePaused`), and the backfill's progress per project (`backfill`) and
state (`backfillState`).

### Agents and ACP chats

`serve` keeps an agent catalog (`agents_*.go`) unless it runs with `--no-agents`:
every agent of the Agent Client Protocol registry, the known CLIs already on the Mac,
and OpenCode, which the host installs from the registry. Contract:
[`../docs/HOST-API.md`](../docs/HOST-API.md), "Agents".

- **Registry.** `https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json`,
  read with `User-Agent: AgentLand-host/<version>`, `If-None-Match`, a 4 MiB cap and
  https-only redirects, 2 minutes after start and every 24 hours (plus 0–60 minutes),
  and by `GET /v1/agents` when its copy is over an hour old. Each entry is checked
  on its own (`agents_registry.go`), and the first 2,000 valid ones are kept; the last
  good document is kept in `<state>.agents/registry.json`. Icons (SVG or PNG, 256 KiB
  each, 64 MiB in all) are kept in `<state>.agents/.icons/` and served by
  `GET /v1/agents/icon`, which answers 404 when there is none to give and 503
  `icon_unavailable` when one was not fetched within 5 s (the read goes on); those of
  ids the registry no longer lists go after each read.
- **Distribution.** For this Mac's platform (`darwin-aarch64` or `darwin-x86_64`):
  a binary with `sha256`, else npm, else uv, else a binary without `sha256`, which
  installs only after the owner's confirmation (`allowUnverified`). An agent not
  installed with none of these is listed with `supported: false` (and `verified:
  false`); the member is absent on every other agent.
- **Local agents.** `claude`, `codex`, `gemini`, `qwen`, `goose`,
  `copilot`, `cursor-agent`, `amp`, `kimi`, `droid` and `vibe`, found in
  `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin` and `PATH`, then in version
  managers' folders (`agents_lookup.go`: `~/.volta/bin`, `~/.asdf/shims`,
  `~/.local/share/mise/shims`, fnm's default alias, nvm's default version; only folders
  this user owns); `node`, `npm` and `uv` are found the same way. Their versions come
  from `--version` (5 s, first 4 KiB, cached per file), Claude Code's from its path.
  Those that speak ACP chat with the registry's arguments for their id.
- **Installs** (`agents_install.go`) go into `<state>.agents/<id>/<version>/`:
  downloads over HTTPS only (500 MiB, 30 minutes), the SHA-256 checked before
  unpacking; unpacking (`agents_unpack.go`) goes through an `os.Root` on the new
  folder, writes nothing through a link, refuses absolute paths, `..`, links that
  leave the folder (every link is resolved against the finished tree by name, without
  case on macOS, then again on disk through the `os.Root`, so no other spelling of a
  name leads out), devices and pipes, and more than 100,000 entries or 4 GiB; files
  are 0600 or 0700. npm packages
  install with `npm install --prefix <folder> --no-audit --no-fund <package@version>`
  and run from `node_modules/.bin`, never through `npx`; uv tools with
  `uv tool install` and `UV_TOOL_DIR`/`UV_TOOL_BIN_DIR` inside the folder. Installers
  get `PATH`, `HOME`, `USER`, `LOGNAME`, `TMPDIR` and `LANG` only, 10 minutes, and are
  ended with their process group when the host stops. One change per agent at a time.
- **The check** (`agents_check.go`): a new version must answer ACP `initialize`
  (protocol version 1, no client capabilities) within 20 s before `current.json`
  names it; OpenCode's check runs `opencode serve --pure` on a free loopback port with
  throwaway `HOME`, `XDG_*` and `TMPDIR` folders and a random password and asks
  `/global/health` (the version), `/session` and `/provider`. No session, no model call.
  A failure removes the new folder and keeps the current version, with `lastError`.
  `current.json` keeps the previous version; older folders are removed. For binaries
  it records the SHA-256 of the command file, which the Mac app checks before it runs
  a managed OpenCode.
- **Automatic updates** are off by default (`POST /v1/agents/settings`, advertised as
  `updateSettings`). The persisted host-wide setting enables scheduled and before-terminal
  checks. Manual updates and essential first OpenCode installation still work while off.
  Named terminal preparation (`agents_terminal.go`) updates an agent at most once an hour
  (any automatic attempt counts), waits at most 30 seconds, joins active updates, reserves the
  agent through PTY registration, and resolves the updated executable. Busy agents defer
  with `updateNotice`. A failed or slow update never refuses creation (since 2026-10-17): the
  installed version starts with an `updateNotice`; a slow update in place is stopped first, one
  installed beside the running version goes on. Every attempt logs one line (`agents: <id>
  update (<trigger>): <old> → <new>, <result>`). Shells are unchanged.
  The scheduled run (`agents_update.go`) installs a registry agent's new version and runs
  supported local Codex and Claude Code native updaters once each agent is idle: none of its chat turns running or waiting, none of its terminals
  running (for OpenCode, no OpenCode chat turn either), checked every minute until the
  next run. `GET /v1/agents` gives the Mac's own session `restartWanted` and
  `idleForSeconds` for the managed OpenCode (sampled every 15 s). An OpenCode whose
  session status query fails or takes longer than 2 s counts as busy for both, since
  it may be stuck in the middle of a turn. Native updater support is checked with bounded,
  command-specific `update --help`, cached by executable identity; the exact path then runs
  with literal `update`, a clean environment, timeout and process-group cancellation. Local
  updates remain independent of the registry and preserve updater opt-outs.
- **OpenCode** (`agents_opencode.go`). The Mac app ships no OpenCode of its own (owner's
  decision, 2026-09-27), so OpenCode's entry is always a registry agent, and an
  `opencode` found on the Mac is not listed. While no managed OpenCode passes the
  checks the Mac app makes before it runs one (private 0700 folders, a record of this
  user's with a `sha256` that the program matches), `serve` installs the registry's at
  once when it starts, and each update run tries again: no 2-minute wait and no idle
  wait, since nothing of OpenCode's can run. Only a binary checked by the registry's
  `sha256` installs so; any other download waits for the owner's Install, with
  `lastError`. Uninstalling OpenCode answers 409 `agent_required`. `install-opencode`
  (`agents_install_opencode.go`) does the same install as a one-shot command before the
  Mac app starts OpenCode. When a managed OpenCode does not start, the Mac app says so
  with its own session (`POST /v1/agents/opencode/failed`): for the current version the
  host goes back to the previous one when it is kept and intact, and automatic updates
  skip that version (`opencode/failed.json`) until the registry offers another.
- **ACP chats** (`acp_*.go`) are kept in `<state>.chats.json` under `acp` (session IDs
  `<agent id>:<32 hex>`, such as `gemini:0f3a…`; the provider is the agent's id). One
  process per chat, from `current.json` (or the local command), started at the first
  send, in its own process group with a clean environment (the agent's own variables,
  `PATH`, `HOME`, `USER`, `LOGNAME`, `SHELL`, `TMPDIR`, `LANG`, `LC_*`); JSON-RPC 2.0
  lines of at most 4 MiB, the last 64 KiB of stderr kept for diagnosis. `initialize`,
  then `session/new` or `session/load`, `session/set_mode` for a mode the chat lists,
  and `session/prompt` with text (and images when the agent takes them); a process
  that does not answer `initialize`, `session/new`, `session/load` or
  `session/set_mode` in time is ended. `session/cancel` stops a turn, sent only once
  the prompt is written, and a turn not ended 10 s later ends with its process. Updates map to text, reasoning, tool and plan parts;
  `session/request_permission` becomes an approval with the agent's options, except
  after Stop, when it is answered `cancelled` at once. `-32000` becomes the reply error
  `agent_auth_required` with the agent's sign-in methods and ends the process, so the
  next send starts one that sees a sign-in made meanwhile. `fs/*`, `terminal/*` and
  any other request get `-32601`. A process stops after 10 idle minutes, never while
  an approval waits. When the host stops, every agent's process group ends within a
  second (see `serve` below).
- **Terminals.** `terminalPrograms` adds every usable agent with a terminal command
  (a registry install's command without its ACP arguments, when it has some; a local
  command); clients still send only the id.
- **Providers.** `GET /v1/providers` lists OpenCode's providers from its `GET /provider`
  (id, name, connected, model count, key variable names; never a key or options).

The one check against the real registry is `AGENTLAND_TEST_ACP_LIVE=1 go test -run
TestLiveRegistryInstall .`. It installs goose into a temporary state folder with a
throwaway `HOME` and runs its `initialize` check (no session, no model call). Everything else is covered by unit tests with fakes: a
registry served over TLS on loopback, a fake ACP agent (the test binary, re-executed by
an `init` hook) that scripts updates, approvals, sign-in failures, crashes, oversized
lines and hangs, a fake `opencode serve`, fake `npm` and `uv` scripts, and archive
fixtures with zip-slip and link escapes.

### Chat in workspaces

Since 2026-10-12 Chat is Claude Code and Codex in the workspace the person selected
(`../docs/HOST-API.md` "Chat in workspaces"; `workspace_chats_test.go`). A Chat chat is an
ordinary workspace chat of its provider (above): the owner's own CLI in the workspace's
folder, with its settings, instructions, MCP servers and tools, approvals and questions
answered in the chat. There is no persona, memory or AgentLand tool for them any more:
the Chats-space profile (`plainConversationIdentity`, `claudeMCPConfig`,
`applyPlainCodexProfile`, the restricted Claude flags) was removed.

- `capabilities.workspaceChats` (`plain_chat_types.go`, `plainChats.workspaceCapability`)
  lists Claude Code and Codex from the last sign-in check (`chat_subscription.go`, kept
  5 minutes for a subscription answer, 10 seconds for any other): those signed in with a
  subscription under `providers`, the others under `unavailableProviders` with what to do.
  The version gate (`plainVersionSupported`: Claude Code 2.1.295 or later within 2.x,
  Codex 0.162.0 or later within 0.x) stays, since the sign-in checks were verified only there. `generalChats`
  lists no providers unless `serve --opencode-chat`.
- `chatProviderReady` checks every Claude Code and Codex create, options, send,
  regenerate and continue, in any project: 400 `agent_auth_required` with the sign-in's
  message, or 503 `agent_unavailable`. Every Chat process gets no API-key variables, Codex
  runs with `forced_login_method="chatgpt"`, and a Claude Code process that reports an API
  key is ended. A host without `PlainChatOptions` (tests) relies on those process guards.
- Claude Code and Codex chats in the Chats space are read-only: requests that would start
  their agent answer 503 `agent_unavailable` (`chatsSpaceRetiredMessage`), and
  `POST /v1/chat/continue` carries one into a workspace chat without sending anything.
- `chat_tools.go`, the memory store and `/v1/memory` stay for OpenCode chats under
  `--opencode-chat`; `<state>.memory.json` is left untouched, and `chat-tools` takes only
  `--state`.

### Plain chats

Plain AI chats (`plain_chats.go`, `../docs/HOST-API.md` "Plain chats") are OpenCode chats
in the Chats space, the reserved project `chats` whose folder is `<state>.chat-home/`;
since 2026-10-12 only with `serve --opencode-chat` (the Mac app never passes it; saved
ones stay readable). Only
the chat routes resolve it (`chatProject`); every other route knows only the configured
workspaces and answers `chats` as an unknown project, and `init` and `config set` refuse
it as a project ID. The host writes the folder's own `opencode.json`, never OpenCode's
global configuration: every tool denied for the folder, `default_agent` `chat`, and the
`chat` agent (primary, 12 steps, AgentLand's assistant prompt) allowed only `invalid`,
`websearch`, `agentland_fetch`, `agentland_memory_save` and `agentland_memory_forget`
(exact keys), whose local MCP server `agentland` is this program's `chat-tools`. When the
file changed, at start too, the host asks OpenCode to load the folder again
(`POST /instance/dispose?directory=…`), and it does so at most every 10 minutes while
`GET /agent` lacks the `chat` agent with AgentLand's prompt; a tool server that `GET /mcp`
shows failed or closed is connected again (`POST /mcp/agentland/connect`) at most once a
minute. Each plain chat is created with the same rules as its session permission list,
and every prompt sent to one (a send, the queue, regenerate, an edit, a continued chat's
first message) runs the `chat` agent with the memory's entries as `system` text while
memory is on and the memory tools are listed: a short header, then a JSON array of
`{"id", "text"}`.

`capabilities.plainChats` is listed while OpenCode's `GET /agent` for the folder lists the
`chat` agent with AgentLand's prompt; the host checks at start, every minute while it
holds and every 10 s while it does not, and the pulse names the capability's revision
whenever it changes. `websearch` is listed while `GET /experimental/tool` shows it for the
space's default model; `searchProvider` only with `serve --websearch-provider exa`, which
the Mac app passes when it runs OpenCode with `OPENCODE_ENABLE_EXA=1` and
`OPENCODE_WEBSEARCH_PROVIDER=exa`. `fetch` is listed while `GET /mcp` shows `agentland`
connected, and `memory` with it while the memory store and its socket are open. The
instruction files OpenCode could add are listed as found at the first check and written
to the host's log. Until the agent is confirmed, sends there answer 503
`agent_unavailable` and queued messages wait. A Chats space OpenCode cannot serve counts
as idle, and the backfill reads it last, once the agent was confirmed since the start.

`agentland-host chat-tools --state <host.json>` (`chat_tools.go`) is the MCP server OpenCode
starts on stdio; it keeps no state and runs at most four tool calls at once.
`agentland_fetch` (`web_fetch.go`, `web_robots.go`, `web_markdown.go`) reads one public
http or https page on port 80 or 443: the name is resolved once per connection and
refused when any address is not the public internet's (loopback, private, link-local,
shared 100.64/10, multicast, unspecified, IPv6 unique-local, IANA's other special-purpose
blocks, or the IPv4-mapped, NAT64 or 6to4 form of one) or is on one of this computer's
links (its own addresses and their prefixes, the IPv6 /64 among them), and the connection
goes to the address checked; every redirect (at most 5, never https to http, no `Referer`
to another host) is checked again; every failed or refused connection reads "The page
could not be reached."; robots.txt is respected for `AgentLand` (over 2,000 rules
disallow everything); at most 5 MB after decompression within 30 s, the Markdown
conversion included (at most 100,000 tokens, end tags matched on a stack at most 512
deep); the model gets Markdown of at most 50 KB and 2,000 lines, and the tool part names
the page as its source. `agentland_memory_save` and `agentland_memory_forget` go through
`<state>.memory.sock` (`memory.go`), whose peer credentials are checked as the tunnel
socket's are; a save cancelled after it reached the host is forgotten again, and neither
works while memory is off. The host is the only writer of `<state>.memory.json` (at most
50 entries and 2,000 characters of visible text, cleaned again when the store is loaded;
`GET`, `PATCH` and `DELETE /v1/memory`, `POST /v1/memory/settings`).

Tool parts of `websearch`, `agentland_fetch`, `agentland_memory_save` and
`agentland_memory_forget` carry `sources` and `memory` (`plain_chat_results.go`), which the
archive keeps (schema version 5). Tests use
the fake OpenCode and local servers; one opt-in check runs the pinned OpenCode in
throwaway folders with a throwaway `HOME` and a fake model provider that must never be
called, and checks from `GET /agent`, `GET /mcp` and a plain chat's rules that the `chat`
agent can use only its own tools:

```sh
AGENTLAND_TEST_PLAIN_CHAT_OPENCODE=/path/to/opencode go test -run TestInstalledOpenCodeGivesThePlainChatAgentOnlyItsTools .
```

### Notices

With the Mac's local session (`--local-session-env`), the host keeps notices for
the Mac app (`notices.go`): a turn that finished or failed, an approval or
question waiting, with IDs and a title and never message text. They are kept 7 days, 1000 at most, in
the archive's `notices` table (in memory without an archive), and served only to
this Mac's session by `GET /v1/notices` (a long poll) and `POST /v1/notices/ack`. A chat
notice is left out while a present device reported viewing that chat in the
last 45 s (`POST /v1/device/presence` takes `view`, held in memory only).
Contract: [`../docs/HOST-API.md`](../docs/HOST-API.md), "Presence and notices".

### Workspaces

Paired devices manage the host's workspaces (its configured projects) while it
runs (`workspaces.go`). `GET /v1/projects` adds each workspace's `directory`,
`gitRepository` and `activity` (chats with a turn running, running terminals);
`GET /v1/folders` lists the sub-folders of the workspace home; `POST /v1/projects`,
`/v1/projects/create` (optionally with `git init -b main`), `/v1/projects/rename`
and `/v1/projects/remove` add, create, rename and remove workspaces. The workspace
home is this user's home folder, or the folder `serve --workspace-home <dir>` names
(the integration scripts pass a temporary one). Folders are reached through the
home's `os.Root`: a path must stay inside the home once its links are resolved, and
the home's `Library`, any `.Trash` and, unless asked for, dot folders are left out.
Each change is one locked transaction on the host state that keeps devices, pending
pairings and the other workspaces; routes read the workspaces from the state, so the
archive feed's epoch and notices follow at once. Removing never touches
the folder, refuses while a chat turn runs, ends the workspace's terminals only when
asked, and records the folder so adding it again restores its ID and archive.
Contract: [`../docs/HOST-API.md`](../docs/HOST-API.md), "Workspaces".

Connection and terminal streaming routes, also authenticated:

- `GET /v1/pulse` streams one JSON line at a time (`application/x-ndjson`):
  `ready` with `intervalMs`, then `beat` every 1.5 s, and `end` after 24 s (inside
  the 35 s write timeout); clients open the next one immediately. When graceful
  shutdown starts, open pulses send `stopping` and new ones answer with it, so
  apps can say the Mac host stopped instead of waiting for a timeout. A client
  treats a broken or silent stream as unreachable. Pulses carry no workspace data.
- `GET /v1/terminal/output?...&wait=<ms>` holds the read until new bytes arrive,
  up to 20 s (default 300 ms for older clients). Shutdown releases waiting reads.
- Terminal objects carry `programTitle`, the last OSC 0 or 2 title the program
  set, cleaned (`terminal_title.go`: the output reader follows titles across
  packets with fixed buffers), and on macOS, while the program set none, the
  `command` of the terminal's foreground process group, read from
  `kern.proc.pid` and `kern.procargs2` at most every 2 s when a device lists its
  terminals (`terminal_command_darwin.go`; it needs the `pid` OpenCode 1.18.31
  reports for the PTY).

## Configure and run the CLI

From this directory, initialize one or more absolute, existing project
directories. The password environment variable must be present whenever the
host is served.

```sh
export AGENTLAND_OPENCODE_PASSWORD='the-same-server-password'
go run ./cmd/agentland-host init \
  --project app='My project'=/absolute/path/to/project
```

Inspect the non-secret configuration or replace its project list while
preserving devices and pairing records:

```sh
go run ./cmd/agentland-host config show
go run ./cmd/agentland-host config set \
  --opencode-url http://127.0.0.1:4197 \
  --password-env AGENTLAND_OPENCODE_PASSWORD \
  --project app='My project'=/absolute/path/to/project \
  --project docs='Documentation'=/absolute/path/to/docs
```

For local development, `--dev-http` is restricted to loopback and cannot be
used by a phone or tablet:

```sh
go run ./cmd/agentland-host serve --listen 127.0.0.1:9841 --dev-http
```

For a phone or tablet, serve HTTPS. Supply a certificate trusted by that device
or create a local certificate for the advertised DNS name or IP address. The
local-certificate command creates a new directory only; use a new directory
when rotating it.

```sh
go run ./cmd/agentland-host tls init \
  --directory "$HOME/Library/Application Support/AgentLand/certificates/lan-1" \
  --hosts 192.168.1.25,agentland.local

go run ./cmd/agentland-host serve \
  --listen 0.0.0.0:9841 \
  --cert "$HOME/Library/Application Support/AgentLand/certificates/lan-1/server.crt" \
  --key "$HOME/Library/Application Support/AgentLand/certificates/lan-1/server.key"
```

`tls init` prints the certificate file, key file, and SHA-256 DER fingerprint.
Enter that fingerprint in the mobile pairing flow. The mobile client verifies
the certificate name, expiry, and pinned fingerprint; the host does not install
trust roots or bypass TLS validation. Direct HTTPS does not provide NAT
traversal. A pre-existing Tailscale HTTPS path may be used separately without
changing Tailscale settings. No relay is included; the Mac app's remote access
reaches the host through its tunnel socket (see "Remote access tunnel").

Terminal routes remain disabled unless the host owner explicitly adds
`--enable-terminal`. This allows a paired device to create shells with the host
user's privileges.

`serve` holds the state's lock (`<state>.serve.lock`) for as long as it runs, and
does not start while another process holds it. The Mac app ships no OpenCode: before
it starts OpenCode (a first launch, or a managed OpenCode that is missing or damaged),
it installs the registry's with the host's one-shot command, which takes the same lock:

```sh
go run ./cmd/agentland-host install-opencode --state /path/to/host.json
```

It reports ready at once when `<state>.agents/opencode` holds a managed OpenCode that
passes the Mac app's checks (its `sha256` included); otherwise it reads the registry and
installs OpenCode as `serve` would (a binary checked by `sha256` only, then OpenCode's
check). Its stdout is one JSON object per line: `registry`, `downloading` (with
`received` and `total`, at most twice a second), `checking`, then `ready` (exit status 0)
or `failed` with a `code` such as `busy`, `offline`, `unverified_download` or
`check_failed` (exit status 1). See `../docs/HOST-API.md`, "install-opencode".

OpenCode starts `agentland-host chat-tools --state /path/to/host.json` itself, from the
Chats space's `opencode.json`, as the plain chats' tool server on stdio (see "Plain
chats"); it is not run by hand.

## Web previews

`serve --enable-preview` lets paired devices open web servers that this
computer's user runs on loopback ports, such as a Vite or Next dev server on
`localhost:5173`, in the app's Browser tab. It starts a second HTTPS listener
with the same certificate and key, on the `--listen` host and port 9842 unless
`--preview-listen` names another (`host:port`, or `:port` for the `--listen`
host). Previews need HTTPS, so `--dev-http` refuses them. The Mac companion does
not turn them on yet. Capabilities advertise
`"preview": {"port": N, "scheme": "https", "features": ["revokeAll"]}` only while
they are on, and apps combine the port and scheme with the host name they
connected to; the contract is in [`../docs/HOST-API.md`](../docs/HOST-API.md).

```sh
go run ./cmd/agentland-host serve \
  --listen 0.0.0.0:9841 --cert server.crt --key server.key \
  --enable-preview
```

- `GET /v1/preview/ports` lists this user's listening TCP ports that the proxy
  can reach (bound to 127.0.0.1, ::1 or every address) with the executable name
  only, never a command line. macOS runs `/usr/sbin/lsof` (3 s, 256 KiB of
  output); Linux reads `/proc/net/tcp` and `tcp6` and finds process names
  through `/proc/<pid>/fd` where it may. Other systems, including Windows, list
  nothing, so previews cannot be opened there. The API and preview ports, the
  configured OpenCode port and the host's own sockets are never listed. SSH,
  printing, the Docker API and common databases (22, 631, 2375, 2376, 3306, 5432,
  6379, 9200, 27017) are hidden unless `--preview-allow-port <port>` (repeatable)
  allows them.
- `POST /v1/preview/sessions {port}` checks the port against a fresh scan and
  returns a session secret of 32 random bytes. The app sets it as the
  `__Host-agentland-preview` cookie (Secure, HttpOnly, SameSite=Strict, Path=/)
  in a non-persistent web view store. The host keeps only its SHA-256, in memory,
  so a restart ends every session. A session belongs to one device and one port;
  a device may hold 8, the host 64. It ends 30 minutes after its last request
  while none is in progress, 12 hours after creation, on
  `POST /v1/preview/sessions/revoke`, within about 5 seconds of the device's
  revocation, and when the host stops. This Mac's own session opens ports
  directly and cannot create one.
- `POST /v1/preview/sessions/revoke {all: true}` ends every session of the
  calling device and answers how many were live (`count`). The app sends it
  once per host each launch, before its first preview there, so sessions left
  from before it restarted stop counting toward the eight.

The preview listener serves no `/v1` routes. It proxies every path except those
under `/__agentland/` (reserved) to the session's port:

- Every request needs a live session cookie. Its SHA-256 is compared in constant
  time with the stored ones, and the device's revocation is rechecked at least
  every 5 seconds.
- Requests go only to `127.0.0.1:<port>`, then `[::1]:<port>` when nothing
  answers there (Node binds `localhost` to ::1 on macOS), never to the request's
  Host or URI. Absolute-form URIs and CONNECT answer 400. The proxy ignores proxy
  environment variables and follows no redirects.
- Browser origins are allowed, but a request other than GET or HEAD, and any
  WebSocket, whose `Origin` is not the preview origin answers 403.
- Upstream requests carry `Host: localhost:<port>` for dev-server host checks
  and `X-Forwarded-Proto: https`. An `Origin` or `Referer` of the preview origin
  becomes `http://localhost:<port>`. The session cookie and hop-by-hop headers
  are removed.
- In responses, a `Location` to the server's own address becomes a relative
  path, `Set-Cookie` loses `Domain` and can never set the session cookie, and
  `Strict-Transport-Security` is dropped. WebSockets (hot reload) pass through.
- Limits: request headers 64 KiB within 10 s; bodies up to 64 MiB, within 2
  minutes plus 1 second per 256 KiB; 64 requests in progress per session,
  WebSockets included; 60 s for idle connections and for each response write.
  Otherwise responses may stream and WebSockets stay open. Revoking a session or
  its device, and stopping the host, close them.
- Answers from the proxy itself carry `X-AgentLand-Preview-Error: <code>`, so the
  app can tell an ended session from the previewed server's own 401.

Known limits: pages that write absolute `http://localhost:<port>` URLs into their
HTML or scripts do not load those through the proxy; the previewed server must
speak plain HTTP; a port is checked when its session opens, not on every
request.

## Pair and revoke devices

Pairing codes are single-use and expire after ten minutes by default. Keep the
host's state file; it is the authoritative record for device revocation.

```sh
go run ./cmd/agentland-host pair
go run ./cmd/agentland-host pair --pin
go run ./cmd/agentland-host devices
go run ./cmd/agentland-host revoke --device DEVICE_ID
```

`pair --pin` creates a cryptographically random ten-digit PIN, including any
leading zero. It is hashed in host state, works once, and can last at most ten
minutes. The pairing route limits guesses to ten per client address and thirty
across all addresses per minute. Use PINs only over the existing verified HTTPS
transport. The Mac companion displays the matching certificate fingerprint
and QR invitation; Bonjour advertisements never contain a pairing secret.

`serve` stays in the foreground and responds to `SIGINT` and `SIGTERM`; use
`Ctrl-C` to stop a CLI run. It does not create a persistent service. The Mac app
kills the host 2 s after asking it to stop, so as soon as HTTP shutdown begins the
host ends the Claude Code, Codex and ACP agents' processes, and the one-shot
`claude -p` and `codex exec` runs, whatever they do: stdin closes and each process
group gets SIGTERM at once, then SIGKILL after 1 s. That runs alongside the HTTP
drain and the rest of the shutdown. A host that is itself killed
cannot end them, so on macOS the host records each agent process it starts (ACP
agents, Claude Code, Codex's app-server and its `codex exec` runs), by pid and the
kernel's start time to the microsecond, in `<state>.acp-processes.json`
(`acp_leftovers.go`), and the next host ends the group of each one that is still
the same process (pid and start time), leads its own process group, was adopted by
launchd (its host is gone), is this user's and runs what the host ran:

- an ACP agent: an executable inside the agents folder (binary installs; uv installs,
  whose scripts name the Python of the tool's environment in the folder, and the
  kernel reports that path), or `node` whose script (its first argument that is not an
  option, as `kern.procargs2` gives it) is inside the agents folder: npm installs,
  and the record names the very script;
- Claude Code or Codex: exactly the executable the host ran, which the record keeps
  (the kernel reports the path the host passed to exec, links not followed). A
  Claude Code or Codex that runs as a `node` script is not ended this way.

This runs with or without the agent catalog. Local ACP commands live outside the
agents folder, so they are never ended this way, and neither is a tool whose agent
has ended or that left the agent's group, nor anything the host did not start.

## Remote access tunnel

The Mac app reaches paired devices from anywhere through iroh and bridges each
of their streams to the host (`remote_access.go`, `tunnel.go`; contract in
[`../docs/HOST-API.md`](../docs/HOST-API.md), "Remote access (iroh)"). The host
never speaks iroh. `serve --tunnel-socket <state folder>/tunnel.sock`, with
`--local-session-env` and the HTTPS listener, serves the same API and
certificate on a Unix socket: bound in a private folder, set to 0600, checked
to be this user's and then moved into place; each connection must come from a
process of this user (`LOCAL_PEERCRED`, `SO_PEERCRED`); Windows refuses the
flag. Each connection starts with the 84-byte line `agentland-tunnel/1
<node ID>\n`, the node ID iroh verified, read within 5 s; a node ID that is not
a paired device's, a malformed or late line, more than 16 open or 60 new
connections a minute for one device, or 128 in all close the connection without
a word, and the host logs each accepted or refused connection (device ID and
the node ID's first 8 characters only; a tunnel connection's remote address is
`iroh/` and those 8 characters, so net/http's own lines carry no more).

Requests through the socket are never this Mac's own: the local session token
is refused, a token must belong to the device whose node ID the line named
(403 `tunnel_device_mismatch`), and pairing and registering answer 403
`tunnel_refused`. Devices give their node ID (the 32-byte Ed25519 key in hex)
at pairing when their QR invitation carries `remoteAccess`, or later with
`POST /v1/remote-access/device` over TCP, each time with an Ed25519 proof that
they hold the key (small-order and non-canonical keys, which no private key
backs, are refused before the proof is checked); `revoke` clears it. The Mac
app follows the admitted node IDs with `GET /v1/remote-access/peers` (a
long-poll that wakes on pairing, registering and revoking, including a `revoke`
command run in another process, noticed within 250 ms; an empty list is `[]`)
and reports its endpoint with `POST /v1/remote-access/endpoint` (direct
addresses global unicast only), which the state file keeps across restarts and
`capabilities.remoteAccess` shows to devices with a `revision`; the pulse names
that revision after `ready` and again when it changes. Revoking a device also
closes its tunnel connections.

## Build and verify

Go 1.26.8 or newer is required by `go.mod`.

```sh
go test ./...
go vet ./...
go build -trimpath -ldflags='-s -w' -o /tmp/agentland-host ./cmd/agentland-host
/tmp/agentland-host version
/tmp/agentland-host init --help
```

Cross-compilation produces CLI development binaries only. It does not establish
Windows or Linux desktop-GUI support:

```sh
for target in darwin/arm64 darwin/amd64 linux/arm64 linux/amd64 windows/arm64 windows/amd64; do
  os=${target%/*}; arch=${target#*/}; suffix=''
  [ "$os" = windows ] && suffix=.exe
  GOOS=$os GOARCH=$arch go build -trimpath -ldflags='-s -w' -o "/tmp/agentland-host-$os-$arch$suffix" ./cmd/agentland-host
done
```
