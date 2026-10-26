# AgentLand host API — v1 additions (contract)

This is the contract between the Go host (`desktop/`) and the iPhone, iPad and Mac
clients for the 2026-09 program: streaming chat for all providers, the local archive,
file and Git changes, web previews and notices. Existing routes keep their
current shapes. Everything here is additive and advertised through capabilities.

## Local web workspace

With `serve --web-assets <absolute-directory>`, the host starts a second plain
HTTP listener on literal `127.0.0.1` with an ephemeral port. Native
`POST /v1/local-web/launch` returns `{ "url": "http://127.0.0.1:<port>/#launch=<64-hex-grant>" }`.
The grant is single-use for 60 seconds; same-origin `POST /web/session`
exchanges it for a process-local bearer token expiring after eight hours.

The browser listener requires an exact Host, same-origin Origin for unsafe
methods, and same-origin Fetch Metadata. `GET /web/state` returns
`{revision,state}`; `PUT /web/state` uses optimistic revision checks and returns
409 with the current revision and state. State is private persistent JSON beside
the host state as `<state>.web.json`; native `POST /v1/local-web/import` seeds
`state.legacy` once and advances the revision. Incoming state/import bodies are
limited to 2 MiB and the merged persisted document to 8 MiB; overflow and corrupt
state fail without replacing the saved document. Revisions are bounded to safe
JavaScript integers.

`/api` forwards only the explicit project, folder, capabilities, agent catalog,
terminal, chat, approval, attachment, file, and read-only Git routes. The chat routes
include Run Again (`POST /v1/chat/regenerate`), the queue (`POST /v1/queue` and
`/v1/queue/remove`) and Continue in a workspace (`POST /v1/chat/continue`) since
2026-10-12. Provider,
admin, pairing, revocation, remote-access, memory/settings, preview,
archives, and Git mutation routes are unavailable. The native bearer is never
returned to the browser.

## Conventions

- All device API routes are under `/v1`, HTTPS only, with bearer authentication. `GET /v1/health`
  and `POST /v1/pair` remain the only open routes. A request carrying `Origin` is
  rejected with 403 (separate preview/local-web listeners are exceptions; preview never serves
  `/v1`).
- Errors keep the shape `{"error": {"code": "…", "message": "…"}}`. Messages are safe to
  show; codes are stable. A few errors add fields inside `error` (such as
  `suggestedName`); their routes list them.
- JSON bodies are limited to 64 KiB unless a route says otherwise, and the host rejects
  unknown fields. **A client sends a new field only when the host advertises the
  capability that introduced it.**
- "Local-only" routes accept only the Mac's own loopback session (`local-mac`);
  any other authenticated caller gets 403 `local_only`. Requests through the remote-access
  tunnel socket are never the Mac's own session (see "Remote access (iroh)").
- Cursors are opaque strings to clients. Clients must not parse them.
- Times in the conversation model and the event stream (`createdAt`, `completedAt`,
  `start`, `end`, `nextAt`) are RFC 3339 UTC strings with milliseconds.
- A mutation whose outcome is uncertain (connection lost after sending, timeout) is
  reported to the user, never retried automatically. Routes that accept
  `clientMessageId` or similar idempotency keys return the original receipt for a
  repeat.

## Capabilities (`GET /v1/capabilities`)

Existing keys (`interactions`, `terminal`, `terminalPrograms`, `chatProviders`,
`chatFeatures`) keep their meaning. New keys:

```json
{
  "chatFeatures": ["reasoning", "attachments", "queue", "rewind",
                   "events", "parts", "stop", "regenerate", "fork", "continue",
                   "continueThrough", "modes", "effort", "clientMessageId", "title"],
  "chatProviderInfo": {
    "opencode": {"version": "1.18.31", "transport": "sse",
                 "features": ["rewind", "restoreFiles", "fork", "approvals", "questions"]},
    "claude":   {"version": "2.1.280", "transport": "stream-json",
                 "features": ["rewind", "restoreFiles", "fork", "approvals", "questions",
                              "modes", "effort"]},
    "codex":    {"version": "0.156.1", "transport": "app-server",
                 "features": ["rewind", "fork", "approvals", "modes", "effort"]}
  },
  "archive":   {"version": 1, "features": ["sync", "search", "export", "terminalLogs", "continue",
                                         "continueThrough", "changesWait", "blobs"]},
  "files":     ["move", "mkdir", "upload", "trash", "delete", "search"],
  "projects":  {"version": 1, "features": ["details", "browse", "add", "create", "rename", "remove"]},
  "git":       ["stage", "unstage", "commit", "stagedDiff", "unstagedDiff", "identity"],
  "preview":   {"port": 9842, "scheme": "https", "features": ["revokeAll"]},
  "presence":  ["views"],
  "notices":   true,
  "routes":    [{"kind": "local", "host": "robins-mac-mini.local", "port": 9841},
                {"kind": "tailscale", "host": "robins-mac-mini.tail1a2b3c.ts.net",
                 "addresses": ["100.88.12.34", "fd7a:115c:a1e0::1"], "port": 9841}],
  "tailscale": "running"
}
```

- A provider's `transport` may be `exec` (Codex fallback: streaming without approvals).
  Its `features` list is the truth for what that chat supports.
- A provider's `features` may include `modes` and `effort`: its chats take `mode` and
  `effort` on `POST /v1/messages` (Codex and Claude Code, see "Codex chats" and
  "Claude Code chats"). Clients send them to a chat only when its provider lists them.
- Codex lists `questions` only once its question tool works without experimental API
  (not in 0.156.1); a question request that arrives is still served.
- A provider whose chats do not stream on this host has `transport` `coarse`: the
  stream carries whole messages (the prompt when it is accepted, the reply when the
  run ends) and status changes, with no deltas. The host's own runner streams Claude
  Code (`stream-json`) and Codex. `version` appears once the host has read it; Claude
  Code's comes from the installed binary's path.
- `chatFeatures` lists `regenerate`, `fork`, `modes` and `effort` when at least one
  provider on the host supports them (`regenerate`: Claude Code, and OpenCode through
  its revert; `fork`, `modes`, `effort`: Claude Code and Codex, per their `features`).
- `events` and `chatProviderInfo` are advertised only when the host can stream every
  provider it lists; `parts`, `stop` and `clientMessageId` work on any host.
- `chatFeatures` lists `title` on every host with this contract (an addition): chats carry
  `titleSource` and `titleBasis`, the host names chats from their messages, and
  `POST /v1/chat/title` takes a name a device wrote (see "Chat names"). Clients send that
  route only to hosts that list `title` and read the two fields as optional.
- Terminal objects carry `programTitle` and, on macOS hosts, `command` (additions, see
  "Terminals"); no capability gates them, since clients only read them.
- `trash` is advertised only where the host can move items to a trash (macOS).
- `preview` appears only when the preview listener is enabled. It names the listener's
  `port` and `scheme` (`https`; an addition), which clients combine with the host name they
  connected to (hosts before `scheme` serve https too), and `features` (an addition):
  `revokeAll`, revoking every session of the caller's device at once.
- `schedules`: hosts before 2026-10-06 list it; schedules were removed then, and
  clients ignore the entry.
- `presence: ["views"]` appears on every host with this contract.
- `notices` appears only for the `local-mac` session, and only when the host keeps
  notices (it runs with the Mac's local session).
- `routes` appears only when the host runs with `--advertised-host` (see "Routes").
- `remoteAccess` appears only when the host runs with `--tunnel-socket` (see "Remote access
  (iroh)"). Answers through the tunnel leave out `preview`.
- `agents` and `agentCatalog` (additions) appear when the host keeps the agent catalog
  (`serve` does unless `--no-agents`; see "Agents"):

  ```json
  "agents": ["catalog", "install", "acp"],
  "agentCatalog": [{"id": "opencode", "name": "OpenCode", "chat": true, "terminal": true},
                   {"id": "claude", "name": "Claude Code", "chat": true, "terminal": true},
                   {"id": "gemini", "name": "Gemini CLI", "chat": true, "terminal": true}]
  ```

  `agents` lists `catalog` (`GET /v1/agents`, the icons and `GET /v1/providers`), `install`
  (the install, update and uninstall routes) and `acp` (ACP chats). `agentCatalog` lists the
  usable agents (installed or local) with the name to show, so the apps build New
  Chat and New Terminal without another request, in this order: `opencode`, `claude`, `codex`
  (those present), then the others sorted by name. Its ids are also in `chatProviders` (those
  with `chat`) and, when the host runs terminals, `terminalPrograms` (those with `terminal`).
  Registry ids are used as they are, except that `claude-acp` → `claude`, `codex-acp` →
  `codex` and `opencode` → `opencode` are AgentLand's own adapters and are listed once.
- With the catalog, `chatProviders` is `opencode`, then `claude` and `codex` when their
  commands are found, then the ACP agents; `terminalPrograms` is `shell` and the agents with a
  terminal command. Clients that know only some ids ignore the others.
- `chatProviderInfo` has an entry for each ACP agent in `chatProviders`, under its id:
  `{"version": "<installed version>", "transport": "acp", "features": ["approvals",
  "modes"]}` (`modes`: `session/set_mode` when the chat's agent lists modes). `chatFeatures`
  lists `modes` when any provider does.
- `workspaceChats` (2026-10-12) lists Chat's providers, Claude Code and Codex in the host's
  workspaces, with their sign-ins, independently of OpenCode (see "Chat in workspaces").
- `plainChats` (an addition) appears while the host's OpenCode has AgentLand's `chat` agent for
  plain chats, AI chats outside every workspace (see "Plain chats"). Since 2026-10-12 that is only
  with `serve --opencode-chat`.
- `generalChats` (2026-10-11) has the same shape and appears whenever the host has the Chats space.
  Since 2026-10-12 it lists no providers (`"providers": []`), so clients before `workspaceChats`
  offer no Chat instead of sending to the Chats space; with `serve --opencode-chat` it lists
  OpenCode alone ("Chat in workspaces").
- `vault` (2026-10-12) is `{"version": 1}` and appears only for the `local-mac` session, on a
  host that keeps an archive and offers the vault (see "Vault").

## Conversation model

```text
Message   { id, chatId, turnId, role: user|assistant, status: streaming|complete|error|aborted,
            ord, createdAt, completedAt?, provider, model?, usage?, error?{code, message},
            parts: [Part] }
Part      { id, kind: text|reasoning|tool|attachment|patch|notice|context, ord,
            text?, tool?, attachment?, start?, end? }
Tool      { name, callId, status: pending|running|completed|error, title?, input?, output?,
            error?, truncated, sources?, memory? }
Usage     { input, output, reasoning, cacheRead, cacheWrite, costMicros? }
Interaction { id, chatId, kind: permission|question, createdAt,
              choices: [once|always|reject]           // permission
              alwaysLabel?, alwaysDetail?              // when choices has always
              permission?{ tool, title, detail, input? }
              questions?: [{ id, text, header?, options:[{label, description?}],
                             multiple, custom, secret }] }
```

- Parts are in the provider's real order. Text, reasoning and tools interleave.
- Tool `input`/`output` fields are capped at 64 KiB each (`truncated` says so).
- A tool's `sources` and `memory` (additions) are described in "Plain chats", which also reserves
  `attachments` on tool parts.
- A text part keeps at most 512 KiB and a reasoning part 64 KiB; a part the host
  shortened carries `truncated: true` (an addition to `Part`).
- `provider` is `opencode`, `claude`, `codex` or an ACP agent's id (see "Agents"); `model`
  is `providerID/modelID` (`<id>/default` for ACP chats). A chat's `mode` is the OpenCode
  agent (`build`, `plan`), an ACP agent's session mode, and `effort` its model variant.
- A message's `error` may carry `authMethods` (an addition, ACP chats only): the names of the
  agent's sign-in methods, with `code` `agent_auth_required` ("Agents", ACP chats).
- `turnId` is the ID of the user message that started the turn. A reply that had not
  completed when its chat went idle is `aborted`; an aborted reply has no `error`.
- `ord` orders messages within a chat and parts within a message; it is not an index.
- A `patch` part lists the changed files in `text`, one project-relative path per line
  (a file outside the project shows only its name). `notice` parts report retries,
  compaction, subtasks, agent mentions and replies stopped by the output limit or a
  content filter.
- An OpenCode permission offers `choices: [once, reject]`; a Codex permission offers
  the choices Codex lists (see "Codex chats"), which may include `always`; a Claude
  Code permission offers `always` when Claude suggested permission rules (see
  "Claude Code chats"). A question's `id` is its position in the interaction. The
  legacy `GET /v1/interactions` question gains `secret` (an addition) when the answer
  should be masked.
- An interaction that offers `always` carries `alwaysLabel` (an addition): one
  sentence, at most 200 characters, saying what answering `always` grants, worded
  the same way for every provider: what it allows and where it applies (`in this
  chat`, `in this project`, `in all your projects`), such as `Allow Bash(npm test *)
  in this project`, `Switch this chat to Accept edits` or `Allow this command in this
  chat`. `alwaysDetail` (at most 300 characters) is there when there is more to say:
  where it is saved or when it ends, such as `Saved in this project's
  .claude/settings.local.json.` Rules, commands, hosts and folders in them are one
  line of at most 60 characters each (three at most, then `and N more`), and what
  looks like a password, token or key reads `…`. A grant the host cannot describe
  gets a generic label (`Allow and apply Claude Code's suggested permission changes`)
  and no detail, and the host logs its shape once. Clients show `alwaysLabel` instead
  of their own Always title, and `alwaysDetail` with it. OpenCode permissions offer
  no `always`, so they carry neither.
- `context` parts carry a seed from "continue with another model" and are shown
  collapsed.
- The legacy `GET /v1/messages` response keeps its exact current shape (joined `text`,
  `tools[]`, `reasoning[]`, `attachments[]`). `?parts=1` adds `parts`, `createdAt`,
  `model` and `usage`.

## Chat event stream

`GET /v1/chat/events?projectId=P&sessionId=S[&after=CURSOR]` → `application/x-ndjson`

One JSON object per line: `{"seq": N, "type": "…", …}`. The host sends:

| type | fields | notes |
|---|---|---|
| `ready` | `cursor`, `resumed` | First line. `resumed=false` means a `snapshot` follows. |
| `snapshot` | `chat{id, title, titleSource, titleBasis?, provider, model, mode, effort, continuedIn?, continuedAt?}`, `messages` (newest 40, oldest first), `hasMore`, `status`, `interactions`, `queue`, `rewind?` | Sent when there is no cursor, the epoch changed, or the cursor fell out of the ring. Replaces all client state. |
| `chat.updated` | `title?`, `titleSource?`, `titleBasis?`, `model?`, `mode?`, `effort?`, `continuedIn?`, `continuedAt?` | `title` and `titleSource` come together whenever the title, its source or its basis changes, with `titleBasis` when the title has one ("Chat names"). `continuedIn` and `continuedAt` come together once the chat continued in a new one ("Continuing a chat in a new one"). |
| `status` | `state: idle\|running\|waiting\|retry\|error`, `retry?{attempt, nextAt, message}` | `waiting` = an interaction is pending. |
| `message.created` | `message` | |
| `message.updated` | `messageId`, `status?`, `completedAt?`, `usage?`, `error?` | |
| `message.removed` | `messageId` | e.g. after rewind. |
| `part.created` | `messageId`, `part` | |
| `part.updated` | `messageId`, `part` | Full replacement of that part. |
| `part.delta` | `messageId`, `partId`, `field: text\|output`, `offset`, `delta` | `offset` is the field's length before this delta. On mismatch the client reconnects without a cursor. |
| `part.removed` | `messageId`, `partId` | |
| `interaction.requested` | `interaction` | |
| `interaction.resolved` | `id`, `outcome` | |
| `queue.updated` | `items` | Full replacement. |
| `turn.started` | `turnId` | |
| `turn.finished` | `turnId`, `outcome: completed\|error\|aborted`, `usage?` | |
| `beat` | `cursor` | Every 10 s. |
| `end` | `cursor` | Stream lifetime (120 s) reached; reconnect with the cursor. |
| `stopping` | — | Host shutdown began. |
| `unauthorized` | — | Device revoked; the stream closes. |

- Cursor format is `"<epoch>.<seq>"`. An epoch changes when the host restarts or the
  chat's in-memory ring is rebuilt. A rewind or restore rebuilds the chat, so open
  streams receive a new `snapshot` (with or without `rewind`) mid-stream.
- `seq` increases from line to line but may skip: coalesced deltas carry the `seq` of
  the last delta they absorb. `ready`, `snapshot` and the control lines carry the
  position the client's state reflects. `beat` carries the resume `cursor` (an
  addition), so a client whose stream breaks resumes from its last beat, `ready` or
  `end`.
- `part.delta` `offset` counts UTF-8 bytes. Deltas of one part leave at most ~30 times
  a second.
- `snapshot.status` is the object `{state, retry?}`.
- Lines never exceed 256 KiB. A part too large for one line arrives as `part.created`
  or `part.updated` with the start of its text or tool output, followed by
  `part.delta` lines for the rest; a tool input or error too large to share a line is
  shortened in the stream and marked `truncated`. The snapshot holds the newest
  messages that fit (at most 40; `hasMore` when more exist). When the newest message
  alone does not fit, the snapshot holds its first parts and the rest follow at once
  as `part.updated` events, as do interactions beyond the snapshot's share. Every
  subscriber may receive these; applying them again changes nothing.
- Queue items in events carry at most the first 4 KiB of each text; `GET /v1/queue`
  has the full text. At most 16 pending interactions per chat appear in the stream.
- The host sends no queued message once its shutdown has begun. One it was sending just
  then, which the agent refused unsent (its process was being ended), goes back to
  `queued`, never `failed`: the queue is kept on disk and the next start sends it. One
  whose delivery may have happened is `failed` with "could not confirm", as ever.
- `interaction.resolved` `outcome` is the reply for permissions (`once`, `always`,
  `reject`), `answered` or `rejected` for questions, or `gone` when the interaction
  disappeared without a reply the host saw.
- Limits: 8 concurrent streams per device (429 `stream_limit`), lines up to 256 KiB,
  auth rechecked every 30 s. Deltas may be coalesced by the host. The host tracks at
  most 32 chats at once (503 `chat_streams_busy`). A chat whose provider this host
  cannot stream answers 501 `unsupported_operation`.
- Clients stream only the selected, active, unlocked chat. While offline they keep
  content and resume from the cursor when `connectionEpoch` changes.

## Chat routes

| Route | Body / query | Response |
|---|---|---|
| `GET /v1/chat/messages` | `projectId, sessionId, before?, limit≤50` | `{messages, hasMore, oldestId}` newest-first page, with parts |
| `GET /v1/chat/options` | `projectId, sessionId` or `provider` | existing fields plus `models[{id, name, efforts?, defaultEffort?}]`, `modes[{id, name}]`, `defaultMode` |
| `POST /v1/sessions` | existing + `model?`, `mode?`, `effort?` (gated by `modes`/`effort`; Claude Code chats only so far, others 400 `unsupported_options`) | Session |
| `POST /v1/messages` | existing + `clientMessageId?` (32–64 chars), `mode?`, `effort?` | `202 {accepted, messageId, turnId, duplicate?}` |
| `POST /v1/abort` | unchanged | stops Claude, Codex and OpenCode turns |
| `GET /v1/interactions` | unchanged | now served for every provider |
| `POST /v1/permissions/reply` | adds `"always"` when the interaction offers it | 400 `invalid_request` for a choice the interaction does not offer |
| `POST /v1/questions/reply`, `/reject` | unchanged; secret answers are never stored | |
| `POST /v1/messages/rewind`, `/restore` | unchanged | adds `filesRestore: immediate\|onSend\|unavailable` |
| `POST /v1/chat/regenerate` | `projectId, sessionId, model?, mode?, effort?` | 202 receipt `{accepted, messageId, turnId}`; 409 `agent_busy` / `queue_not_empty` / `regenerate_unavailable`; 501 `unsupported_operation` |
| `POST /v1/chat/fork` | `projectId, sessionId, messageId?, title?` | 201 Session with `parentSessionId` |
| `POST /v1/chat/continue` | `projectId, sourceSessionId, provider, model?, mode?, effort?, title?, contextChars?` (default 48 000, max 200 000), `throughMessageId?` (gated by `continueThrough`) | 201 Session plus `seed{included, omitted, chars}`; 400 `invalid_through_message` |
| `POST /v1/chat/title` | `{projectId, sessionId, title, basedOn}` (gated by `title`) | `200 {title, titleSource, titleBasis}`; 400 `invalid_request`; 404 `not_found`; 409 `title_stale`; 502 `provider_unavailable` ("Chat names") |
| `POST /v1/chat/providers/check` | none (local-only: this Mac's session) | `204`, then read `capabilities.workspaceChats`; 403 `local_only`; 404 `not_found` on a host without Claude Code and Codex chats ("Subscriptions only", A check now) |

Continue builds its seed from the archive, so it works when the source provider is no
longer available (details below).

ACP chats (see "Agents"): `POST /v1/sessions` takes an ACP agent's id as `provider` (503
`agent_unavailable` when it is not usable); `POST /v1/messages` answers 202 once the message is
recorded, and 503 `agent_unavailable` when the chat's agent is not usable now (nothing is
recorded).

- `GET /v1/chat/messages`: `before` is a message ID, normally the previous page's
  `oldestId`; an unknown one answers 404. `limit` defaults to 50; other values answer
  400. A page stops early at 8 MiB (`hasMore` stays true). Messages from a rewind
  point on stay hidden.
- `POST /v1/messages` returns `messageId` and `turnId` when the host knows the user
  message's ID before it appears; both are that message's ID. OpenCode receives a
  host-made ID in its own ascending `msg_…` format. A repeat of a `clientMessageId`
  sent by the same device to the same chat waits for the first attempt if it is still
  in flight, then returns its receipt with `duplicate: true`. If that attempt's
  outcome is uncertain the repeat answers 409 `delivery_uncertain` and nothing is
  sent; only an attempt that definitely did not deliver lets a repeat send. The host
  keeps receipts for 24 hours, at most 32 per device and chat and 1024 in all.
- `POST /v1/messages/rewind` and `/restore` answer `{"rewound": true, "filesRestore"}`
  and `{"restored": true, "filesRestore"}`: `immediate` for OpenCode, which reverts
  files with the messages, `onSend` for Claude Code, whose files come back when the
  next message is sent, and `unavailable` for Codex.
- `POST /v1/chat/regenerate` drops the chat's latest turn and sends its prompt text
  again, with the body's `model`, `mode` and `effort` like a message. The chat must be
  idle with an empty queue. Claude Code chats rewind and send in one step (below);
  OpenCode chats are reverted to the prompt and sent it again (`effort` answers 400
  `unsupported_options`, `mode` is the agent). A prompt that had attachments answers
  409 `regenerate_unavailable` (attachments are not kept); a chat that cannot
  regenerate (Codex, or OpenCode without revert) answers 501. Delivery and its errors
  are those of `POST /v1/messages`, without `clientMessageId`.

### Claude Code chats

Each Claude Code chat runs its own `claude -p` process speaking the Agent SDK
stream-json protocol (tested with Claude Code 2.1.280; arguments, environment and
lifecycle in `desktop/README.md`).

- Since 2026-10-26 each chat's process has `AGENTLAND_CHAT=<the chat's ID>`,
  `AGENTLAND_HOST=<the host's own executable>` and `AGENTLAND_HOST_STATE=<the host's state
  file>` last in its environment, in place of any inherited, so its tools can run
  `agentland-host chats continue` ("Continuing a chat in a new one"). Codex chats are
  unchanged.

- `GET /v1/chat/options` for a Claude chat, or with `provider=claude` and no
  `sessionId` for a new one, lists `models` from the CLI's `initialize` answer as
  `claude/<value>` (`claude/default` is the CLI's default; others such as
  `claude/opus[1m]`, `claude/sonnet`) with `efforts` for models that take one;
  `modes` `default` ("Ask", ask each time), `acceptEdits` ("Accept edits"), `plan`, `auto`
  and `bypassPermissions` ("Bypass permissions"); and `defaultMode` `default` (since
  2026-10-12; `auto` before, and `dontAsk` was listed instead of `bypassPermissions`: a
  chat already in `dontAsk` keeps it, and the routes still take it). Every process starts
  with `--allow-dangerously-skip-permissions`, so a running chat can switch into
  `bypassPermissions`; the flag allows nothing by itself. The list is reused for 30
  minutes per installed binary; when no Claude process has run, the host starts one
  only to initialize it (no model request).
- `POST /v1/messages` and `POST /v1/sessions` take `model` (`claude/<value>`),
  `mode` and `effort` (`low`, `medium`, `high`, `xhigh`, `max`); they apply to that
  message and the chat's later ones, and `chat.updated` announces them. A model or
  mode change switches the running process; an effort change restarts it between
  turns.
- Delivery: the receipt comes once Claude Code replays the prompt with the host's
  uuid, which is the receipt's `messageId` and the user message's ID. A process that
  ends first, or a replay that has not come after 30 s, answers 502
  `delivery_uncertain` (an addition to the codes; a repeated `clientMessageId` answers
  409 `delivery_uncertain`); nothing is sent again, and a replay that comes later
  still starts the turn. 409 `agent_busy` while a turn runs; 429 `agent_capacity`
  (an addition) when six Claude processes are working; 502 `upstream_error` when
  Claude Code did not start, in which case nothing was sent.
- A permission interaction offers `once` and `reject`, plus `always` when Claude
  suggested permission rules, which `always` accepts (one of them may switch the
  chat's mode, announced with `chat.updated`). `permission.tool` is Claude's tool
  name, `title` its description, `detail` the blocked path or Claude's reason and
  `input` the tool input as JSON (at most 16 KiB). `ExitPlanMode` is a permission
  whose `detail` is the plan ("Chat in workspaces", Plan approval). `AskUserQuestion`
  is a question interaction (1-4 questions, `custom` always true); its answers go back
  keyed by question text, several choices joined with ", ". A request Claude withdraws
  resolves `gone`.
- `alwaysLabel` renders the suggestions `always` passes back: rules as `Tool(content)`
  with their destination (`session`: `in this chat`, not saved, ending when Claude
  Code restarts for the chat, for example after 10 idle minutes; `localSettings`:
  `in this project`, saved in the project's `.claude/settings.local.json`;
  `projectSettings`: `in this project`, saved in `.claude/settings.json`;
  `userSettings`: `in all your projects`), mode switches (`Switch this chat to
  Accept edits`; the chat keeps the mode) and folders (`allow access to <folder> in
  this chat`), joined with "; ". Claude Code 2.1.280 suggested, for example,
  `Bash(npm test *)` to local settings for a command, a switch to Accept edits for a
  write in the project (plus the folder for one outside it), and `Read(//<folder>/**)`
  for this chat for a read outside the project. Other suggestion types
  (`replaceRules`, `removeRules`, `removeDirectories`), rules that do not allow, and
  unknown destinations or modes get the generic label.
- Rewind hides the latest user message and its reply (`filesRestore: "onSend"`). The
  next message first has Claude Code put the files back (`rewind_files`, a dry run
  first) and then resumes the session without that turn (a new session when it was
  the first); the hidden messages are then dropped. When Claude Code refuses to drop
  the turn the send answers 409 `rewind_refused` and when it cannot put the files back
  502 `files_not_restored` (additions); nothing was sent either way. A turn whose
  transcript entries the host did not see (from before the chat streamed, or cut off
  by a host stop) answers 400 `unsupported_operation`.
- `POST /v1/chat/fork` copies the chat through `messageId`'s turn, or through its
  last visible message, into a new Claude chat (201 with `parentSessionId`). Its
  first message forks the source's Claude session at that point; the new session's
  ID comes from Claude. 409 `agent_busy` for the turn that runs, 404 for an unknown
  message, 501 `unsupported_operation` for a turn whose end the host did not see.
- Stop sends `interrupt`: the partial reply stays and shows as `aborted`. A process
  that ends mid-turn ends it with an error reply (`agent_exited`; `protocol_error`
  for an output line over 32 MiB) that keeps what streamed, pending interactions
  resolve `gone`, and the next message resumes the session. Status `retry` carries
  Claude's retry attempt and delay.
- Cost: a turn's last reply carries `usage.costMicros`, what the turn added to
  Claude Code's `total_cost_usd`. That total is the session's: Claude Code 2.1.280
  saves it when a process exits (end of input or SIGTERM, not SIGKILL) and restores
  it on `--resume`, with or without a truncation, and into a fork. The host keeps
  each chat's saved total across processes and host restarts, so the first turn
  after a restart (idle stop, effort change, rewind, budgeted run, host restart) or
  a fork's first turn counts only its own cost. When the host does not know what a
  process restored (a chat from before this host version, until one of its processes
  has exited), or a process reports less than it should have restored, that one turn
  has no `costMicros` rather than a doubled one.

### Codex chats

Codex chats run through one shared `codex app-server` on the host (tested with Codex
0.156.1 and, since 2026-10-12, 0.162.1; 0.163.0's app-server schema was compared with
0.162.1's on 2026-10-16; versions outside 0.156.x and 0.162.0 or later within 0.x run in
compatibility mode, see `desktop/README.md`).

- `GET /v1/chat/options` for a Codex chat, or with `provider=codex` and no
  `sessionId` for a new one, lists `models` from Codex's `model/list` as
  `codex/<model>` with `efforts` and `defaultEffort` (additions), after
  `codex/default` (Codex's own default); `modes` `[{id, name}]` with `ask` ("Ask",
  the default since 2026-10-12: workspace-write sandbox, approvals come to the devices),
  `auto-review` ("Auto-review", the default before: the same sandbox, commands that need
  more reviewed by Codex's reviewer), `read-only` ("Read only") and `full-access` ("Full
  access"); and `defaultMode`. Over the `exec` transport `ask` is not offered (a chat
  already in `ask` runs as `auto-review`, since nobody can be asked), the default is
  `auto-review` and only the default model is listed.
- `POST /v1/messages` on a Codex chat takes `mode` and `effort` (lowercase letters,
  digits, `_` and `-`, at most 32) and `model` as `codex/<model>`; they apply to that
  message and the chat's later ones, and `chat.updated` announces them. Other chats
  answer 400 `unsupported_options` when given `mode` or `effort`. `POST /v1/sessions`
  does not take them yet; a new chat gets them with its first message.
- Delivery: the message is recorded (and the `202` receipt returned) before Codex is
  contacted. If Codex refuses the turn or cannot be started, the reply is an error;
  if the request reached Codex but no answer came, the reply's error code is
  `delivery_uncertain`. Nothing is sent again.
- A Codex permission interaction offers the decisions Codex lists in the request's
  `availableDecisions`: `accept` as `once`; `acceptForSession`, or else
  `acceptWithExecpolicyAmendment` (Codex saves a rule allowing commands like it), as
  `always`; `decline`, or else `cancel` (which also stops the turn), as `reject`.
  File-change approvals offer `once`, `always` (for the session) and `reject`;
  permission requests grant the requested access for the turn (`once`) or the
  session (`always`), or nothing (`reject`). `permission.tool` is `Command`, `Edit` or
  `Permissions`.
- `alwaysLabel` for Codex: `Allow this command in this chat` (`acceptForSession`),
  `Allow changes to these files in this chat` and `Allow this access in this chat`,
  each with the detail that Codex forgets it when it restarts (the host stops the
  app-server after 15 idle minutes); `Allow commands starting with "<prefix>" in all
  projects` for a saved command rule (Codex 0.156.1 writes it to `rules/default.rules`
  in its home folder) and `Allow network access to <host> in all projects` for a
  saved network rule, each with the detail that Codex saves the rule.
- Questions (`item/tool/requestUserInput`) keep Codex's order; a question with
  `isOther` or without options takes free text (`custom`), and `isSecret` sets
  `secret`. A rejected question sends Codex no answers.
- Rewind hides the latest user message and its reply until restore. The next message
  drops them from the chat and has Codex remove their turn from its history
  (`thread/revert {threadId, beforeTurnId}`) before the new turn. Files stay as they
  are (`filesRestore: "unavailable"`). A message whose turn Codex did not report
  (sent over `exec`, or before streaming) answers 400 `unsupported_operation`.
- `POST /v1/chat/fork` (Codex over the app-server) copies the chat through the
  `messageId`'s turn, or through its last visible message, into a new chat with its
  own Codex thread (`thread/fork {threadId, lastTurnId, excludeTurns}`); it answers
  201 with the new Session and `parentSessionId`, 409 `agent_busy` while a turn runs,
  404 for an unknown message and 501 `unsupported_operation` for other chats and
  over `exec`.
- Over the `exec` transport there are no approvals, rewinds or forks; messages still
  stream as whole items. Each `codex exec` run is a process group of its own: Stop (and
  the hour's limit) gives the group SIGTERM at once and SIGKILL 2 s later, the host's
  shutdown SIGKILL 1 s later, so the tools it started end with it.

### Continue with another model

`POST /v1/chat/continue` starts a new chat, with any provider, from an archived one.

- It is advertised as `continue` in `chatFeatures` and `archive.features` when the
  host keeps an archive; without one it answers 501 `archive_unavailable`. Hosts that
  take `throughMessageId` also list `continueThrough` in both; clients send the field
  only to them.
- `sourceSessionId` is an archived chat of `projectId`. When the source's provider
  still has it, the host imports it into the archive first (at most 100 pages or
  15 s); otherwise the archive's copy is used as it is. An unknown chat, or one of
  another project, answers 404 `not_found`.
- From a Chats-space chat, `projectId` may name a workspace and `provider` `claude` or
  `codex` ("Chat in workspaces", Continue).
- `provider` is one of `chatProviders` (400 `invalid_provider` otherwise). `model`,
  `mode` and `effort` follow the new chat's provider: for OpenCode a
  `providerID/modelID` and the agent (`build`, `plan`), no effort; for Claude Code
  and Codex what `POST /v1/messages` takes (`claude/<value>` with a permission mode
  and an effort; `codex/<model>`, a Codex mode, an effort); for an ACP agent only
  `<id>/default` or nothing, no mode (the new chat lists none yet) and no effort. Other
  values answer 400 `invalid_agent_options`. `contextChars` must be 1 000–200 000 (400
  `invalid_request`). `title` (at most 200 bytes) defaults to the source's title plus
  " (continued)".
- The seed is a header naming the source chat, the source's first user message, then
  its newest messages that fit, oldest first, with `[N messages in between are left
  out.]` where messages are skipped, and a closing line. Each message is a `### User ·
  <time>` or `### Assistant (<model>) · <time>` block: its text, one line per tool
  call (`[Tool <name>: <title or start of input> (<status>)]`), `[Changed files: …]`,
  `[Attachments: <names>]`, and a line for a failed or stopped reply. Reasoning,
  notices, hidden (rewound) messages and an earlier seed are left out; a message
  larger than what is left is cut (`[… shortened]`). The seed is at most
  `contextChars` characters and 384 KiB.
- `throughMessageId` (an ID of one of the source's messages, as the archive lists
  them) ends the source there: the seed keeps the first user message and the newest
  messages up to and including that one that fit, under the same budget rules, and
  leaves the later ones out; the header says the chat continues from a point the user
  chose. `seed.included` and `seed.omitted` count only the messages up to it. A
  message the source does not show (unknown, of another chat, hidden by a rewind, or
  an ID over 256 bytes) answers 400 `invalid_through_message` and creates nothing.
  Choosing the source's own seed message (a chat continued before) carries nothing.
- The answer is the new Session, as `POST /v1/sessions` returns it, with
  `parentSessionId` (the source, as for a fork) and `seed{included, omitted, chars}`:
  the messages carried, those left out, and the seed's length in characters. A source
  with nothing to carry gives zeros and no seed. The archive records the new chat with
  `parentId` and `relation: "continue"`.
- The seed is the new chat's first message: ID `agentland-seed`, role `user`, `ord` 0,
  one `context` part. It is in the event stream's snapshot, on the last page of
  `GET /v1/chat/messages` (`before=agentland-seed` answers an empty page) and in the
  archive; its `completedAt` is set once it has been sent.
- Nothing is sent by the route. The chat's first message (sent or queued) goes to the
  provider as the seed, a blank line and the message, with the continue's model, mode
  and effort where the message names none; the provider's copy of that message is
  streamed, paged and archived without the seed. After an uncertain delivery the seed
  counts as sent; after a definite failure it waits for the next message; a rewind of
  the message that carried it makes the next one carry it again.
- Other answers: 507 `insufficient_storage` when the archive cannot record chat text
  (under 256 MiB free), 503 `agent_unavailable` when the provider cannot create the
  chat.

## Chat names

Owner request (2026-09-26): chat and terminal tabs describe what was last worked on in
them instead of their agent's name ("OpenCode", "Claude Code", "Codex", "Shell"). The host
names chats from their user messages (`auto`), keeps the title a provider gives
(`provider`) and takes names that devices write, for example with Apple Intelligence
(`device`). Terminals are in "Terminals". Advertised as `title` in `chatFeatures`.

Two additions describe every chat's title:

- `titleSource`: `default`, `provider`, `auto` or `device`.
- `titleBasis`: the ID of the newest message the title describes. Omitted when there is
  none, which is always the case for `default` and `provider`.

They appear wherever the host returns a chat's info: every Session in `GET /v1/sessions`
(and the Session answers of `POST /v1/sessions`, `POST /v1/chat/fork` and
`POST /v1/chat/continue`), the event stream's `snapshot.chat` and `chat.updated`, and the
archive's chat records (the change feed's chat payloads, the `chat` of
`GET /v1/archive/chat`, and the JSON exports). `title` keeps its meaning: the title to show,
which is the host's auto title while there is one.

Sources:

- `default`: a placeholder nobody chose: an empty title; an agent's name alone
  ("OpenCode", "Claude", "ChatGPT", "Claude Code", "Codex": the host names Claude Code and
  Codex chats created without a title "Claude Code" and "Codex", as before 2026-10-12, and
  "Claude" and "ChatGPT" for part of that day); the host's "Continued chat"; the apps' "New
  chat", "OpenCode chat", "Claude Code chat" and "Codex chat", and the "Claude chat" and
  "ChatGPT chat" of part of 2026-10-12 (all of these compared ignoring case and
  surrounding white space); and OpenCode's untitled "New session - <time>" and "Child
  session - <time>" (exactly as OpenCode 1.18.31 writes them, the time in ISO 8601 UTC
  with milliseconds). For an ACP chat, also the agent's name or id, alone or followed by
  " chat", when it was created with one ("Agents", ACP chats).
- `provider`: a title AgentLand did not make. For OpenCode chats: OpenCode's own generated
  title, and any other title OpenCode holds that the host did not set (a rename in
  OpenCode's own apps). For every chat: a title it was given when it was created that is
  not a placeholder (by a client or a continue), and the title a Claude Code chat continued
  in a new one passes on, placeholder or not ("Continuing a chat in a new one").
- `auto`: the host's free naming, below.
- `device`: a name a device wrote through `POST /v1/chat/title`.

Rules:

- When a user message is delivered to a chat whose `titleSource` is `default`, `auto` or `device`
  (sent with `POST /v1/messages`, from the queue or by regenerate), the host
  names the chat from that message's own text (not its attachments or a continued chat's
  seed): `titleSource` becomes `auto` and `titleBasis` the message's ID. A message that
  yields no name keeps the current title and basis. A send that failed or whose delivery
  is uncertain names nothing.
- Auto refreshes an older device-generated name on the next substantial prompt. Explicit `provider` titles stay. Short confirmations keep the current subject.
- OpenCode chats: the auto title stays on the host and OpenCode keeps its own title, so
  the host never stops OpenCode's own title generation. OpenCode 1.18.31 generates a
  title after a chat's first message only while its title is the untitled "New session -
  <time>" (a chat created from OpenCode's own apps); a chat created with a title, such as
  the apps' "New chat", keeps it in OpenCode. An OpenCode update that still carries its
  untitled title, a placeholder, or the title held when the host refreshed a device name never replaces an auto title; OpenCode's own generated
  title (any other title the host did not set) replaces it and becomes `provider`. A device name
  is written to OpenCode too (below); OpenCode's echo of it keeps `device`, and so does a
  late update that still carries the title OpenCode had just before the rename. A
  different title OpenCode takes afterwards (a rename in OpenCode's own apps, or its title
  generation finishing later) becomes `provider`.
- Claude Code, Codex and ACP chats keep their title, `titleSource` and `titleBasis` in the
  host's chat registry; only the host's naming and `POST /v1/chat/title` change them.
- A fork made without a `title` keeps its source's title, `titleSource` and `titleBasis`.
- `chat.updated` carries `title` and `titleSource` together whenever the title, its source
  or its basis changes, and `titleBasis` with them when the new title has one: an event
  with `titleSource` and no `titleBasis` means the title has none.
- Persistence: Claude Code and Codex chats keep both fields with their title in
  `<state>.chats.json`. For OpenCode chats the host keeps its auto titles and the device
  names it wrote in `<state>.titles.json` (private, mode 0600; at most 2048 chats, the
  least recently named forgotten first); OpenCode keeps device names itself as their
  titles. A host restart keeps every name and source. The archive's chat rows carry both
  fields as a copy (archive schema version 4) and are not read back for naming.

### Free naming

The host names a chat from one user message's text:

1. Fenced code blocks (from a line starting with three backticks or tildes to the line
   that closes it, or to the end) are dropped, and the backticks of inline code (its text
   stays). A URL (`scheme://…`, or `www.…`) becomes its host name (a `file:` URL its last
   path component), and a file path its last component: a word starting with `/`, `./`,
   `../` or `~/`, or a word with a `/` whose last component has an extension
   (`desktop/host.go`). Punctuation around such a word stays.
2. The text is split into clauses at sentence ends (`.`, `!`, `?` or `…` followed by
   white space or the end), line breaks, semicolons and commas.
3. Leading filler words are dropped from each clause, again and again while one leads,
   ignoring case (’ counts as '): so, ok, okay, now, first, also, then, and, but, hey, hi,
   please, pls, can you, could you, would you, will you, i want to, i'd like to, i would
   like to, lets, let's, let us, we need to, i need to, you need to, make sure, go ahead
   and, just, maybe (a word matches without a trailing `:` or dash). Leading `-`, `*`, `#`,
   `>` and `•` (list and heading marks) go first, and trailing `:`, `;`, `,`, `.`, `!`,
   `?` and dashes last.
4. The name is the first clause with at least three words of three or more letters (a
   word is a run of non-space characters; its Unicode letters are counted).
5. Its first letter is capitalized, unless its first word already holds a capital letter
   ("iOS", "macOS"). A name over 48 characters is cut at the last word boundary that
   leaves room for "…" (trailing punctuation removed), then "…" is added; one word longer
   than that is cut at 47 characters.
6. When no clause qualifies ("yes", "continue", "status?", "keep going") the chat keeps
   its title.

Characters are Unicode scalar values. Examples: "save it, first lets check terminal
interaction and make sure the user can strool in the terminal correctly. i test ed opencode
and i couldnt scrool up and down in the terminal." gives "Check terminal interaction and
make sure the…"; "can you fix the login redirect on safari?" gives "Fix the login redirect
on safari"; "ok" and "yes, keep going" give nothing.

### `POST /v1/chat/title`

A device names a chat, for example with Apple Intelligence after a turn ends. It is a
paired-device route like the other chat routes: bearer authentication, also through the
remote-access tunnel socket and for the Mac's own session.

- Body `{"projectId", "sessionId", "title", "basedOn"}`, all required non-empty strings;
  unknown fields are refused (400 `invalid_request`). `basedOn` is at most 256 bytes.
- The title is cleaned: control characters (Cc) dropped, white space collapsed to single
  spaces and trimmed, surrounding quotes removed (a leading and a trailing `"`, `'`, `` ` ``,
  `“`, `”`, `‘`, `’`, `«`, `»`, `„`, `「` or `」`, again while both are there) and a trailing
  period removed (not the last of an ellipsis). It must then be 1–60 characters (Unicode
  scalar values), else 400 `invalid_request`.
- `basedOn` must be a message the chat shows (not one a rewind hides), else 400
  `invalid_request`. When the chat's messages cannot be read (OpenCode not answering)
  the answer is 502 `upstream_error` and nothing changes.
- Staleness: the name is accepted only when `basedOn` is the chat's current `titleBasis`
  or newer in the chat's message order. Otherwise the answer is 409 `title_stale` with the
  current `title`, `titleSource` and `titleBasis` inside `error`, so two devices never
  overwrite a newer name with an older one. A current basis the chat no longer shows
  (rewound or removed) does not count.
- On success `titleSource` becomes `device` and `titleBasis` `basedOn`. OpenCode chats are
  renamed in OpenCode too, with OpenCode 1.18.31's `session.update`
  (`PATCH /session/{id}` `{"title"}`), which keeps OpenCode's own lists and the TUI's
  "OC | …" title in step; when OpenCode refuses or cannot be reached the answer is 502
  `provider_unavailable` and nothing changes. Claude Code and Codex chats store the name in
  the host's chat registry (a registry write that fails answers 502 `upstream_error`, as
  other host failures do). Every stream of the chat gets `chat.updated` with the new
  `title`, `titleSource` and `titleBasis`, and the archive records the name through its
  capture.
- The answer is 200 `{"title", "titleSource": "device", "titleBasis"}`. Naming a chat
  again with the same title and basis changes nothing and answers the same.
- An unknown project or chat answers 404 `not_found`, as the other chat routes do.

## Chat in workspaces (2026-10-12)

Owner's decision (2026-10-12): Chat is Claude Code and Codex themselves, run by the host in the
workspace the person selected, on the Claude and ChatGPT subscriptions the Mac is signed in to, with
approvals and questions answered in the chat. This replaces Chat in the Chats space ("Plain chats"):
the general-conversation profile, its persona, memory and AgentLand tools are gone for Claude Code
and Codex. Where another section says otherwise, this one wins.

### The capability (`capabilities.workspaceChats`)

```json
"workspaceChats": {"version": 1,
  "providers": [
    {"id": "claude", "name": "Claude Code", "tools": [],
     "features": ["events", "parts", "stop", "clientMessageId", "title", "attachments", "queue",
                  "effort", "rewind", "fork", "regenerate", "approvals", "questions", "modes",
                  "restoreFiles"],
     "attachmentTypes": ["image/png", "image/jpeg", "image/gif", "image/webp", "text/plain",
                         "text/markdown", "text/csv", "application/json", "application/pdf"],
     "auth": {"kind": "subscription", "label": "Claude subscription"}}],
  "unavailableProviders": [
    {"id": "codex", "name": "Codex", "tools": [], "features": [],
     "auth": {"kind": "apiKey", "label": "API key", "reason": "subscription_required",
              "message": "Sign in to Codex with your ChatGPT subscription (codex login)."}}]}
```

- Present on every host that runs Claude Code and Codex chats (`serve`), whatever OpenCode does.
  Both lists are always present, possibly empty; a provider is in at most one. Only `claude` and
  `codex` are listed. Clients read version 1 only.
- `providers` are those Chat can start now: installed in a supported version (Claude Code 2.1.295
  or later within 2.x; Codex 0.162.0 or later within 0.x, not only over `exec`) and signed in with a subscription
  ("Subscriptions only"). A Codex entry has the same shape without `regenerate` and `restoreFiles`,
  with the label `ChatGPT subscription`. `features` are the provider's chat features plus
  `approvals`, `questions` and `modes`; `chatProviderInfo` is sent only while OpenCode streams, so
  clients read a chat's features from here when it is absent. `attachmentTypes` lists every type
  the host takes.
- `unavailableProviders` are installed providers Chat cannot use, with empty `tools` and
  `features` and an `auth` carrying `reason` and `message`, what to do: `subscription_required`
  for a sign-in Chat does not use, `version_unsupported` (2026-10-16) for a version outside the
  supported ones. Clients show them in Settings and never offer them.
- `generalChats` lists no providers and `plainChats` is absent, unless `serve --opencode-chat`
  ("Plain chats"). The pulse's `plainChats` line covers `generalChats` and `workspaceChats`
  together: its revision changes when either does, a changed sign-in included.
- Chat has no memory: nothing from `<state>.memory.json` reaches a Claude Code or Codex chat. The
  file stays on disk untouched, and `/v1/memory` stays for OpenCode chats under `--opencode-chat`.

### Starting and running a chat

- `POST /v1/sessions {"projectId": "<workspace>", "provider": "claude"|"codex", "title"?}` creates
  the chat in that workspace. The apps send no `mode`, so it starts in the provider's default, Ask,
  and title it "Claude Code chat" or "Codex chat"; one created without a title is named `Claude
  Code` or `Codex`. Every older default title ("Claude chat", "ChatGPT chat", the bare names) stays
  a placeholder that the host's naming replaces ("Chat names").
- The chat is an ordinary workspace chat of its provider ("Claude Code chats", "Codex chats"): it
  runs in the workspace's folder as the owner's own CLI, with the user, project and local
  settings, `CLAUDE.md` or `AGENTS.md`, the configured MCP servers and every tool. The provider
  entries' `name`, and the `provider` of their models in `GET /v1/chat/options`, are `Claude Code`
  and `Codex`.
- Modes (`GET /v1/chat/options`; `mode` on `POST /v1/messages`, `/v1/chat/regenerate` and
  `/v1/chat/continue`):
  - Claude Code: `default` "Ask" (the default), `acceptEdits` "Accept edits", `plan` "Plan",
    `auto` "Auto" and `bypassPermissions` "Bypass permissions". `dontAsk` "Don't ask" is still
    taken, so a chat that has it keeps it, but no longer listed.
  - Codex: `ask` "Ask" (the default), `auto-review` "Auto-review", `read-only` "Read only" and
    `full-access` "Full access". Over `exec`, `ask` is not listed and the default is `auto-review`.
  - The apps confirm `bypassPermissions` and `full-access` once per chat, in a system
    confirmation, before sending either, and remember that the chat confirmed; the host does not
    ask. A paired device in those modes runs anything unasked, as a terminal can.
  - The host reports the chat's mode as it changes (`chat.updated`, the snapshot's `mode`).
    Approving a plan returns a Claude Code chat to the mode it had before Plan, which may be
    `bypassPermissions`.
- Approvals and questions arrive as interactions and are answered with
  `POST /v1/permissions/reply`, `/v1/questions/reply` and `/reject` ("Claude Code chats", "Codex
  chats"). A Claude Code process stays running while an approval waits, and counts toward the six.

### Plan approval

- A Claude Code `ExitPlanMode` request is a permission titled "Leave plan mode and start on this
  plan?". Its `detail` is the plan's text, at most 16 KiB, and it has no `input`.
- The plan comes from the CLI's plan-file `input.plan`, else the `plan` of the model's own
  `ExitPlanMode` tool call (Claude Code 2.1.296 sends the request with `input: {}`). Without
  either, `detail` is "Claude Code did not send the plan with this request. Read it in the chat
  above before you approve."

### Subscriptions and refusals

- "Subscriptions only" applies to every Claude Code and Codex chat, in every workspace: no API-key
  variables in their environment, Codex's forced ChatGPT login, and the end of a Claude Code
  process that names an API key (400 `agent_auth_required` at send, or an error reply with `code`
  `agent_auth_required` for a running turn).
- Create, options, send, Run Again and continue answer 400 `agent_auth_required` with the
  provider's `message` while it is signed in otherwise, 503 `agent_unavailable` with its `message`
  while it is installed in a version Chat does not support (`version_unsupported`, never the
  sign-in code), and 503 `agent_unavailable` ("<Name> cannot run Chat now. Check its installation
  and sign-in on the Mac.") while it cannot run Chat at all. OpenCode and ACP chats in workspaces
  are not checked.

### Old Chats-space chats

Claude Code and Codex chats made in the Chats space before 2026-10-12 stay listed and readable, in
the archive too, and take nothing new.

- Every request that would start their agent answers 503 `agent_unavailable` with "Chat now runs in
  your workspaces; this chat stays readable.": `POST /v1/messages`, `/v1/chat/regenerate`,
  `/v1/chat/fork`, `/v1/messages/rewind`, `/v1/queue` and `/v1/attachments`, `GET
  /v1/chat/options` (by `sessionId`, or with `provider` `claude` or `codex`), `POST /v1/sessions`
  with `projectId` `chats` and one of those providers, and a continue into `chats` with them.
- Reads, the list, `POST /v1/messages/restore`, `/v1/queue/remove`, titles and the archive (read,
  search, export, delete) still work. Their queued messages stay `queued`, unsent. Another
  provider in the Chats space still answers 400 `plain_chat_provider`.

### Continue in a workspace

`POST /v1/chat/continue {"projectId": "<workspace>", "sourceSessionId": "<a Chats-space chat>",
"provider": "claude"|"codex", "model"?, "mode"?, "effort"?, "title"?, "contextChars"?,
"throughMessageId"?}` carries a Chats-space chat (Claude Code, Codex or OpenCode) into a new chat in
the workspace, as "Continue with another model" describes. It answers 201 with the Session
(`projectId` the workspace, `parentSessionId` the source) and `seed{included, omitted, chars}`. The
host first reads the source again from its provider in the Chats space. Nothing is sent: the new
chat's first message carries the seed. The workspace's subscription rules apply (400
`agent_auth_required`, 503 `agent_unavailable`), and another target provider answers 400
`plain_chat_scope`. The apps offer it as "Continue in <workspace>".

## Plain chats

### Subscriptions only (2026-10-12)

Owner's decision (2026-10-12): "i dont want the chat featuro to use the api pricing, it needs to
connect via the subscription logged into wit heth mac app for providers, api can come later". Chat
runs only on the subscriptions the Mac is signed in to: Claude Code's claude.ai sign-in and Codex's
ChatGPT sign-in. Where this conflicts with the sections below, it wins. Since Chat moved to the
workspaces ("Chat in workspaces") it applies to every Claude Code and Codex chat.

- **Environment.** Chat processes (Claude Code and Codex chats, the one-shot runs) get none of
  `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, `CLAUDE_CODE_USE_BEDROCK`,
  `CLAUDE_CODE_USE_VERTEX`, `CLAUDE_CODE_USE_FOUNDRY`, `CLAUDE_CODE_USE_ANTHROPIC_AWS`,
  `CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD`, `CLAUDE_CODE_USE_MANTLE`, `CLAUDE_CODE_USE_GATEWAY`,
  `OPENAI_API_KEY`, `CODEX_API_KEY` or `OPENAI_BASE_URL` from the host's environment. Terminal
  programs keep the owner's own environment. Codex chats (app-server and exec) start with
  `-c forced_login_method="chatgpt"`.
- **Sign-in check.** A Claude Code or Codex provider is listed in `providers` only while its CLI
  says it is signed in with a subscription: `claude auth status --json` reports `loggedIn` with
  `authMethod` `claude.ai` (and `apiProvider` `firstParty` or none); `codex login status` prints
  `Logged in using ChatGPT`. The host asks the exact executable its chats use, with their
  environment, in the Chats space's folder (Claude) or the app-server's (Codex), within 5 seconds,
  after the version check.
- **Versions** (2026-10-16, Claude Code widened 2026-10-17). The checks above hold for Claude Code
  2.1.295 and every later 2.x release (2.2.0, 2.10.3) and for Codex 0.162.0 and every later 0.x
  release; Claude Code 3.x, Codex 1.x and later, older versions and a version that does not parse
  as `<major>.<minor>.<patch>` in digits are not supported (owner, 2026-10-17: "Accept Claude Code
  2.1.295 and every later 2.x, the same rule you chose for Codex. A version Chat refuses shows on
  the phone with a reason."). A refused Claude Code is listed with the message "AgentLand’s Chat
  doesn’t support Claude Code <version> yet. Use Claude Code in Terminal." Codex was
  checked with 0.162.1 and 0.163.0 (the same `Logged in using ChatGPT` line on stderr;
  `forced_login_method` a known setting whose `chatgpt` value refuses an API-key login; an
  app-server protocol that only gained methods and fields); later 0.x releases are taken without a
  new check (owner, 2026-10-16: "allow 0.162 and every later 0.x version, like Claude Code's
  rule"). The version is read with `--version` once per installed file (path, size, modification
  time); a check that does not answer keeps the last answer. An installed CLI whose version is
  read but not supported is listed in `unavailableProviders` with `reason` `version_unsupported`
  and is not asked how it is signed in; one whose version no check has read is left out. A subscription answer is kept 5 minutes and any other 10 seconds while
  the executable is unchanged; a check that does not answer keeps the last answer for the same file,
  and is `unknown` without one. The host never reads the CLIs' credentials, and never logs their
  output (Codex's API-key line names part of the key; only the line's start is read).
- **A check now** (2026-10-17). `POST /v1/chat/providers/check`, no body, is local-only: this
  Mac's session alone, every other device 403 `local_only`. The Mac's Sign In… and Check Again use
  it while the person signs Claude Code or Codex in (owner, 2026-10-17: "The row turns green by
  itself within seconds."). The host checks both CLIs at once, asking each how it is signed in
  whatever its last answer's age (the version check keeps its own rule), within the minute check's
  15-second bound and serialized with it, and answers `204` with no body once the lists are
  updated; the app then reads `capabilities.workspaceChats`, and the pulse's `plainChats` line
  changes for every device when the lists did. Explicit checks are at least 2 seconds apart: one
  that comes sooner asks no CLI and answers `204` at once, the lists being at most that old. The
  minute's check for every device is unchanged. A host without Claude Code and Codex chats answers
  404 `not_found`, as an older host without the route does; the app then reads the capabilities as
  they are, so it needs no capability to tell them apart.
- **`auth`** (an addition): every provider entry from such a host has
  `{"kind", "label", "reason"?, "message"?}`. `kind` is `subscription`, `apiKey`, `other` (another
  cloud, or a token AgentLand does not take), `signedOut` or `unknown` (the sign-in is not known:
  the CLI's answer could not be read, or, for an unsupported version, it was not asked); clients
  keep kinds they do not know. `label` is one line to show: `Claude subscription`, `ChatGPT
  subscription`, `API key`, `Not a subscription`, `Not signed in`, `Sign-in not confirmed`,
  `Version not supported`. Only entries Chat cannot use have `reason` and `message`, what to do:
  `subscription_required` for a sign-in ("Sign in to Claude Code with your Claude subscription
  (claude auth login).", "Sign in to Codex with your ChatGPT subscription (codex login)."),
  `version_unsupported` for a version ("AgentLand’s Chat doesn’t support Codex 1.0.0 yet. Use
  Codex in Terminal.", naming the version when it is a plain version string). Clients keep reasons
  they do not know and show the `message`. OpenCode's entry, listed only with `serve --opencode-chat`, has
  `{"kind":"apiKey","label":"API keys"}`.
- **`unavailableProviders`** (an addition) lists, in the same entry shape, installed providers with a
  supported version whose sign-in Chat does not use and, since 2026-10-16, installed providers in a
  version Chat does not support ("Versions"), each with empty `tools` and `features` and an
  `auth` with `reason` and `message`. Clients show them in Settings and never offer them. Since
  2026-10-12 they are listed in `workspaceChats` only; `generalChats` lists no providers (unless
  `--opencode-chat`) and no `unavailableProviders`, and `plainChats` stays absent. The pulse's
  revision covers both members.
- **Refusals.** Create, options, send, Run Again and continue for such a provider answer 400
  `agent_auth_required` with its `message`: the agents' sign-in code, so clients show their sign-in
  notice. A provider listed with `version_unsupported` answers 503 `agent_unavailable` with its
  `message` instead, so no client asks for a sign-in that would not help. A Claude Code chat whose process names an API key is ended: when its `initialize`
  answer's `account` has an `apiKeySource` other than `none` or an `apiProvider` other than
  `firstParty`, before the prompt is written (the send answers 400 `agent_auth_required`); when its
  `system`/`init` line has an `apiKeySource` other than `none`, at once, and the turn ends with an
  error reply whose `code` is `agent_auth_required`; a send still waiting for its echo answers 502
  `agent_auth_required` (the prompt may have reached the CLI). Until 2026-10-12 this applied to
  general chats only; it now applies to every Claude Code chat, in any workspace.
- **OpenCode leaves Chat.** Unless `serve --opencode-chat` (off by default; the Mac app does not pass
  it), the host never asks OpenCode about the Chats space: `plainChats` is absent, `generalChats`
  lists no OpenCode, and creating a chat in the Chats space without a provider or with `opencode`,
  and sending to an OpenCode plain chat, answer 503 `agent_unavailable` ("Chat runs on your Claude
  and ChatGPT subscriptions on this Mac. OpenCode chats stay readable but take no new messages.").
  Saved OpenCode plain chats stay listed and readable, in the archive too, and their queued
  messages wait. OpenCode keeps running for everything else (managed runtime, terminals). API-key
  chat is for later.

### Claude and ChatGPT (2026-10-12)

**Superseded the same day by "Chat in workspaces".** Chat names its providers Claude Code and
Codex again (entries' `name`, models' `provider`, default titles), and Claude Code and Codex chats
run as themselves in a workspace with no persona. The old names stay placeholder titles. Kept as
history:

Owner's request (2026-10-12): "when going to chat in the app for either claude or chatgpt it says
im using the agentland agent powerd by either service, not like im uing the actual app chat, says
using claude code to respond". Chat with Claude is meant to feel like the Claude app, and Chat with
ChatGPT like the ChatGPT app; both still run only on the subscriptions above.

- **Names.** The provider entries' `name` (in `providers` and `unavailableProviders`) is `Claude`
  for `claude` and `ChatGPT` for `codex`; earlier hosts sent `Claude Code` and `Codex`. So is the
  `provider` of these chats' `GET /v1/chat/options` models, and the title of a chat created
  without one ("Chat names"). The `message` of an entry Chat cannot use still names the CLI to
  sign in with. Terminal programs and `agentCatalog` keep `Claude Code` and `Codex`.
- **Persona.** A general chat's instructions say who the model is, then the conversation notes
  and tools above: "You are Claude, an AI assistant made by Anthropic, talking with the user as you
  would in the Claude app", or "You are ChatGPT, an AI assistant made by OpenAI, …in the ChatGPT
  app", with Claude Code or Codex named only as the connection that carries the conversation over
  the subscription, not as what the model is. AgentLand is named only as the app the user is
  chatting through, to mention if they ask. Claude Code still puts its own identity line before
  `--system-prompt` (it cannot be removed); Codex's persona also says that instructions written
  for coding agents, such as its global `AGENTS.md` (`instructionFiles`, below), are not part of
  the conversation. OpenCode's plain-chat persona is unchanged.

### Terminal sign-ins (2026-10-08)

**Superseded for Claude Code and Codex on 2026-10-12 ("Chat in workspaces").** The Chats-space
profile below (restricted mode, the strict MCP configuration, empty settings sources, the
conversation tool allowlist, the persona, the provider entries' `instructionFiles`, the
`websearch`, `fetch` and `memory` tools and shared memory) is removed: Claude Code and Codex chats
run in workspaces as themselves, their Chats-space chats are read-only, and `generalChats` lists no
providers unless `--opencode-chat`. What this section says about OpenCode still applies; the rest
is the history of 2026-10-08 to 2026-10-12.

`capabilities.plainChats.providers` optionally lists `{id, name, tools, features, attachmentTypes?,
instructionFiles?}` for each installed runtime verified for general conversation. Absent means legacy
OpenCode-only; an explicit empty list offers no providers.

`capabilities.generalChats` (2026-10-11) is the same entry, present whenever any provider
can run. `plainChats` keeps its original meaning, present only while OpenCode's `chat`
agent is confirmed: clients from before the provider list read its presence alone as
"OpenCode runs plain chats" and send every chat there. Provider-aware clients read
`generalChats` first and fall back to `plainChats` (older hosts). The pulse's `plainChats`
revision covers `generalChats`. Clients skip a provider entry they cannot read and keep
the rest. The host checks a runtime's version once per installed file (path, size,
modification time), keeps the last answer through a check that does not answer, and
checks a provider again before refusing a request for it. The current CLI profiles
support Claude Code 2.1.295+ within 2.x and Codex 0.162+ within 0.x. Installation is not proof
of a usable sign-in: runtime authentication and account/model-limit errors remain visible.
Since 2026-10-12 a provider is also listed only while its sign-in is a subscription
("Subscriptions only").

Create and options take `provider` in the Chats space. Session identity fixes the
provider thereafter, including continuation. Claude/Codex reuse their runtime's
sign-in in the private Chats directory. Every spawn/start/resume disables coding
tools, workspace instructions, unrelated MCP and customizations; Codex negotiates
experimental API for `environments: []`, disables configured MCP servers explicitly,
and refuses the exec fallback. No credential is copied or requested by mobile/web.

Claude/Codex support streaming, stop, title, delivery receipts, uploads, queue,
model reasoning effort, rewind and fork. Claude advertises `regenerate`; Codex
retries through rewind plus a fresh send. Editing never restores workspace files.
Both advertise `websearch`, plus `fetch` and `memory` when the host tool executable
is available. Shared memory changes reach the next turn, including live sessions.
MCP result metadata is normalized into the existing `sources` and `memory` fields.

A provider's `instructionFiles` (2026-10-11) lists files its runtime gives every general chat
besides AgentLand's own instructions, in the form and limits of the top-level `instructionFiles`;
absent when there are none. Only Codex lists one: Codex 0.162 gives every thread the global
`$CODEX_HOME/AGENTS.override.md`, else `$CODEX_HOME/AGENTS.md` (the first holding more than white
space), as user instructions, and has no supported setting or `thread/start|resume|fork`
parameter to leave it out. The host lists that file while it is there, under the `CODEX_HOME` the
chat runtime runs with (else `~/.codex`), checked with each provider check. Claude's profile loads
no user instruction files and lists none. Clients show it with the other instruction files
("Codex chats also read ~/.codex/AGENTS.md.").

`attachmentTypes` is an optional accepted MIME list. Claude and Codex accept PNG,
JPEG, GIF, WebP, UTF-8 plain text, Markdown, CSV and JSON. Claude also accepts PDF;
Codex's current conversation protocol has no PDF input. Text files are sent as
contents, Claude images/PDFs as native inline blocks, and Codex photos as native
image inputs. Coding tools are never enabled to read an attachment. Existing five
file and per-file limits apply; Claude additionally limits combined attachment
bytes to 20 MiB before base64 encoding. Retrying or editing an uploaded message
requires attaching its files again, as stored transcript records contain names.

Clients consult each provider's features and types. OpenCode retains its existing
operations; top-level tool fields still describe OpenCode for older clients. New
clients also inspect provider tools, so memory settings and Undo remain available
when only Claude or Codex is installed. CLI providers remain independent of an
OpenCode outage. Claude uses restricted mode, a strict explicit MCP configuration,
empty settings sources and a conversation tool allowlist. Codex disables inherited
MCP entries and enables only AgentLand's three tools. Codex also exposes its built-in
MCP resource helpers; the sole enabled server offers no resources. Neither profile
exposes command, file-editing, arbitrary file-reading or app/plugin tools.

Native clients require a workspace before provider selection; its association stays
separate from the Chats API project. Native defaults use host/provider-specific model
choices, retaining the legacy OpenCode key. Missing saved providers require an explicit
new selection. Native and web visibility continues to use the Chats project, never a
CLI session prefix.

The following OpenCode-specific details still apply to the OpenCode profile.


Owner decision (2026-09-27): chats are plain AI chats by default ("standard ai type chats not
programming ones"), and the coding agents stay an option. A plain chat is an OpenCode chat that runs
AgentLand's `chat` agent in the Chats space, a reserved project outside every workspace. It has no
files, terminals or Git. Its tools are web search, reading a web page and a memory that the owner can
see, edit and turn off. Everything here is advertised as `capabilities.plainChats`; clients offer plain
chats, and send the memory routes, only while it is listed.

### The capability (`capabilities.plainChats`)

```json
"plainChats": {"projectId": "chats", "tools": ["websearch", "fetch", "memory"],
               "searchProvider": "exa", "instructionFiles": ["~/AGENTS.md"]}
```

- Present only while the host's OpenCode has the `chat` agent for the Chats space: OpenCode's
  `GET /agent` for the space's folder lists `chat`. The host writes that agent into the folder's own
  `opencode.json`, never into the Mac's global OpenCode configuration. Absent while OpenCode does not
  run or does not answer, and on hosts before this contract.
- `projectId` is always `chats`, the Chats space's reserved ID. Clients send it as `projectId` on the
  chat routes. They may recognize plain chats by it in the archive whether or not the capability is
  listed at the moment.
- `tools` lists what plain chats can use now, each only while it works. Clients ignore values they do
  not know. An empty list means plain chats answer from the model alone.
  - `websearch`: OpenCode's own `websearch` tool. The Mac app starts OpenCode with Exa's search on
    (`OPENCODE_ENABLE_EXA=1`, `OPENCODE_WEBSEARCH_PROVIDER=exa`). That setting is OpenCode-wide, so a
    workspace's OpenCode chats can search too.
  - `fetch`: `agentland_fetch`, the host's tool that reads one public web page ("The chat agent").
    Listed while OpenCode reports the host's tool server, `agentland`, connected (`GET /mcp`).
  - `memory`: `agentland_memory_save`, `agentland_memory_forget` and the memory routes ("Memory"
    below). Listed while the tool server is connected and the host's memory store is open with the
    socket the tool server reaches it through (macOS and Linux only), whether memory is on or off,
    so the switch can always be turned back on.
- `searchProvider` names the service that receives the search queries: `exa`, Exa's hosted search,
  which OpenCode uses without a key. Present with `websearch`, and only when the host knows the
  service: the Mac app runs the host's OpenCode with that service set and says so (`serve
  --websearch-provider exa`). A host whose OpenCode someone else runs leaves it out, since OpenCode
  can pick another service. Clients say so where they describe web search, and describe it without
  a service when the member is absent.
- `instructionFiles` lists the instruction files OpenCode adds to a plain chat besides the `chat`
  agent's own prompt: `AGENTS.md`, `CLAUDE.md` and `CONTEXT.md` files in the Chats space's folder or a
  folder above it, and the owner's global ones, as the host found them when it started. A path under
  the Mac user's home folder reads `~/…`; others are absolute. At most 32 paths, each at most 1,024
  bytes. Absent when there are none. Clients show them, so the owner knows what else the model is
  told. A provider entry may list its runtime's own files the same way ("Terminal sign-ins").
- The pulse (`GET /v1/pulse`) of a host with plain chats sends
  `{"type":"plainChats","revision":"…"}` after `ready` (and after the `remoteAccess` line when
  there is one), and again whenever `capabilities.plainChats` changes: it appears or goes, or lists
  other `tools`, another `searchProvider` or other `instructionFiles`. The revision is opaque.
  Clients read capabilities again when a line names another revision than the one they last saw,
  and after a plain-chat send answers 503 `agent_unavailable` ("The Chats space"). Clients that do
  not know the line ignore it, as every line of a kind they do not know.

### The Chats space

- The Chats space is the reserved project `chats`. Its chats run in a folder private to the host
  (`<state>.chat-home/`, mode 0700), which no route shows. No workspace has its ID: the host's
  workspace IDs end in six hexadecimal digits, and the command line refuses `chats` as a project ID.
  `GET /v1/projects` never lists it, and the workspace routes answer 404 `not_found` for it.
- It is a project on the chat routes only:
  - `GET` and `POST /v1/sessions`, `GET /v1/chat/options`, `GET /v1/chat/status`, `GET` and
    `POST /v1/messages`, `POST /v1/messages/rewind` and `/restore`, `POST /v1/attachments`,
    `POST /v1/abort`, `GET /v1/chat/events`, `GET /v1/chat/messages`, `POST /v1/chat/fork`,
    `POST /v1/chat/regenerate` and `POST /v1/chat/title`;
  - the queue (`GET` and `POST /v1/queue`, `POST /v1/queue/remove`) and the interactions
    (`GET /v1/interactions`, `POST /v1/permissions/reply`, `POST /v1/questions/reply` and `/reject`);
  - `POST /v1/chat/continue` (below);
  - the archive. Plain chats are in the change feed and are served by `GET /v1/archive/chat`,
    `/search` (with `projectId=chats` too), `/export` and `/blob`, and by `POST /v1/archive/delete`,
    like a workspace's chats. The backfill imports them. They are archived whether or not `plainChats`
    is listed, so the archive never changes with OpenCode. The change feed's epoch includes the Chats
    space from the first start of a host with this contract, so every device resyncs once;
  - notices. A plain chat's notices carry `projectId` `chats` and `projectName` `Chats`, and a
    presence `view` may name a plain chat.
- Every other route answers the Chats space as it answers an unknown project. A request that such a
  route refuses earlier (an invalid path, a missing member) keeps that answer.
  - Files (`GET /v1/files`, `GET` and `POST /v1/file`, `POST /v1/files/move`, `/mkdir`, `/upload`
    and `/delete`) and file search (`GET /v1/files/search`): 404 `not_found`.
  - Git (`GET /v1/git/repositories`, `/status`, `/diff` and `/identity`, `POST /v1/git/stage`,
    `/unstage` and `/commit`): 404 `not_found`.
  - Terminals (`GET` and `POST /v1/terminals`, `GET /v1/terminal/output`, `POST /v1/terminal/input`,
    `/resize` and `/close`): 404 `not_found` (a host without terminals answers 403
    `terminal_disabled` first). `GET /v1/archive/terminal-logs?projectId=chats`: 404 `not_found`.
  - The preview routes take no project, so nothing there reaches the Chats space.
- New chats: `POST /v1/sessions` there takes `provider` `opencode` or none. Any other provider
  (an ACP agent) answers 400 `plain_chat_provider`, and so does `GET /v1/chat/options` with such a
  `provider`; Claude Code and Codex answer 503 `agent_unavailable` since 2026-10-12 ("Chat in
  workspaces", Old Chats-space chats). `model`, `mode` and `effort` answer 400
  `unsupported_options`, as for every OpenCode chat. The Session's `projectId` is `chats` and its
  `provider` `opencode`.
- Continue: `POST /v1/chat/continue` from a plain chat into a plain chat works, with `provider`
  `opencode` (another provider answers 400 `plain_chat_provider`). A continue into or out of the
  Chats space answers 400 `plain_chat_scope` and creates nothing: `projectId` `chats` with a
  workspace's chat as the source, or a plain chat as the source with a workspace's `projectId`,
  except a continue into a workspace's Claude Code or Codex chat (2026-10-12, "Chat in
  workspaces", Continue in a workspace).
  Before this contract such a continue answered 404 `not_found`; a source of another workspace still
  does.
- A plain chat is an OpenCode chat everywhere else in this contract: its names follow "Chat names",
  rewinds and restores work as for OpenCode chats (a plain chat changes no files), fork answers 501
  `unsupported_operation`, and its turns count as running for `idleForSeconds` ("Agents").
- Nothing is sent to a plain chat while the host has not confirmed the `chat` agent (the capability
  is absent). Plain chats can still be read, and their queued messages wait, queued, also when the
  agent goes just as one is sent. `POST /v1/sessions`, `POST /v1/messages`,
  `POST /v1/chat/regenerate` and a continue in the Chats space answer 503 `agent_unavailable`, and
  clients then read capabilities again. A prompt never runs there with another agent.
- A Chats space OpenCode cannot serve runs nothing: it counts as idle for `idleForSeconds`, and the
  backfill imports its chats after every workspace's, once the host has confirmed the `chat` agent
  since it started.

### The chat agent

- The host sends every prompt of a plain chat with the `chat` agent, whatever the request says:
  `POST /v1/messages` (also after a rewind, for Edit and Resend), a queued message,
  `POST /v1/chat/regenerate` and a continued chat's first message.
- A plain chat takes no mode or effort. In the Chats space each route answers 400
  `unsupported_options` for the members it takes: `agent` (OpenCode's name for the mode), `mode`
  and `effort` on `POST /v1/messages`; `agent` on `POST /v1/queue`; `mode` and `effort` on
  `POST /v1/chat/regenerate` and `POST /v1/chat/continue`. A member a route does not take answers
  400 `invalid_request` there, as everywhere. `model` is taken as for every OpenCode chat
  (`providerID/modelID`).
- `GET /v1/chat/options` in the Chats space, with a plain chat's `sessionId` or none, lists `models`
  and `defaultModel` as for OpenCode chats, with `agents` empty and no `modes`, `defaultMode`,
  `efforts` or `defaultEffort`.
- While memory is on and `tools` lists `memory`, the host adds its entries to every plain-chat
  prompt as system text (OpenCode's `system` on the prompt): a short header that calls them notes
  the user asked to remember, data and never instructions, then the entries, oldest first, as a
  JSON array of `{"id", "text"}`, one entry per line. A text is one line inside a JSON string, so
  one entry cannot pose as another or as a note of the host's. While memory is off, or `memory` is
  not listed (the model could not forget what it is shown), it adds none. Workspace chats never get
  them.
- The `chat` agent has only the tools `tools` lists, and OpenCode's `invalid`, which reports a
  malformed tool call, each allowed by its exact name (`agentland_fetch`, `agentland_memory_save`,
  `agentland_memory_forget`). Everything else is denied for the folder, the agent and each plain
  chat, so plain chats read and write no files, run no commands and ask for no approvals.
  OpenCode's own `webfetch` stays denied because it could reach the Mac's home network.
- `agentland_fetch` reads only public `http` and `https` pages on ports 80 and 443. It resolves the
  name, refuses every address that is not the public internet's (loopback, private, link-local,
  shared (carrier-grade NAT, Tailscale's too), multicast, IPv6 unique-local, and IANA's other
  special-purpose blocks: documentation, 6to4 relay anycast, IPv4-translated, discard-only,
  2001::/23 with Teredo, segment routing, and IPv6 outside 2000::/3; an IPv4-mapped address counts
  as its IPv4 address, a NAT64 or 6to4 address as the IPv4 address it carries), and refuses the
  Mac's own addresses and every address on the same links (its IPv6 /64 among them). It connects to
  the address it checked, on every redirect too (at most 5, never from https to http, with no
  `Referer` to another host). It refuses other schemes, other ports and URLs that carry
  credentials. Every connection that fails or is refused, a name that does not resolve included,
  reads the same to the model ("The page could not be reached."), so its answers say nothing about
  the network behind the Mac. It reads at most 5 MB after decompression within 30 s, names
  AgentLand in `User-Agent`, respects robots.txt (a robots.txt with more than 2,000 rules for
  AgentLand, a pattern over 2,048 bytes, or a robots.txt that does not arrive in full disallows
  everything), and gives the model the page as Markdown, at most 50 KB. Reading a page, its
  robots.txt and its Markdown all stay within the 30 s. A page that did not arrive in full (its
  connection ended, or the 30 s passed while a text, JSON or XML page was read) or went past 5 MB
  reaches the model as its start, with a note that it was cut short; an HTML page the 30 s cut
  is not read.
- The tool server runs at most four tool calls at once; the others wait for one to end or for
  their cancellation.

### Sources and memory on tool parts

```text
Tool { …, sources?: [{title, url}], memory?: {id, text}, attachments? }   // additions
```

```json
{"name": "websearch", "callId": "call_7", "status": "completed", "title": "tide times lisbon",
 "input": "{\"query\":\"tide times lisbon\"}", "truncated": false,
 "sources": [{"title": "Lisbon tide table", "url": "https://tides.example.com/lisbon"},
             {"title": "example.org", "url": "https://example.org/tides"}]}
```

```json
{"name": "agentland_memory_save", "callId": "call_9", "status": "completed",
 "title": "Prefers metric units", "input": "{\"text\":\"Prefers metric units\"}",
 "output": "Saved to memory.", "truncated": false,
 "memory": {"id": "mem_4f2a9c1e", "text": "Prefers metric units"}}
```

- `sources` (an addition) lists the web pages a tool found or read, in its order, at most 20. Each is
  `{title, url}`. `url` is an `http` or `https` URL of at most 2,048 bytes without user information.
  `title` is one line, cleaned as memory text is ("Memory" below, without the secret check), of at
  most 200 bytes, cut at a character boundary; it is the URL's host name when the page gives none.
  Only a completed tool part that found or read pages carries them:
  - `websearch`: the results OpenCode's search returned, parsed from its output;
  - `agentland_fetch`: one source, the page it read: its address after redirects, and its title.

  Any OpenCode chat's `websearch` part carries them, since workspace chats can search too. Other
  tools carry none.
- `memory` (an addition) is on a completed `agentland_memory_save` part that stored an entry: `{id,
  text}`, the entry as the host keeps it, which `GET /v1/memory` lists. A page the model read can ask
  it to remember something, so the apps show every save ("Memory updated", with its text) and offer
  Undo, which sends `DELETE /v1/memory?id=<id>`. A 404 there means the entry is gone already. A save
  the host refused (memory off, or full) is an `error` part without `memory`. A save that OpenCode
  cancelled after the host stored it is removed again, so every entry the model saved has its part.
- `memory` is also on a completed `agentland_memory_forget` part: the entry it removed, `{id, text}`
  as the host kept it, which `GET /v1/memory` no longer lists. A forget the host refused (memory
  off, or no such entry) is an `error` part without `memory`.
- `attachments` is reserved on tool parts for a later round (images a tool makes). It may appear;
  clients ignore it for now.
- Tool parts carry these members wherever they appear: the event stream, `GET /v1/chat/messages`,
  `GET /v1/messages?parts=1`, and the archive's messages and JSON export. The archive keeps them with
  the part. The legacy `tools[]` of `GET /v1/messages` keeps its exact shape, without them.

### Memory (`/v1/memory`)

| Route | Body / query | Answer |
|---|---|---|
| `GET /v1/memory` | — | `{enabled, entries:[MemoryEntry], limits:{maxEntries, maxTotalChars}}` |
| `PATCH /v1/memory` | `{id, text}` | 200 the entry |
| `DELETE /v1/memory` | `id` | 200 `{removed: true}` |
| `POST /v1/memory/settings` | `{enabled}` | 200 `{enabled}` |

```text
MemoryEntry { id, text, createdAt, updatedAt }
```

```json
{"enabled": true,
 "entries": [{"id": "mem_4f2a9c1e", "text": "Prefers metric units",
              "createdAt": "2026-09-27T18:04:11.000Z", "updatedAt": "2026-09-27T18:04:11.000Z"}],
 "limits": {"maxEntries": 50, "maxTotalChars": 2000}}
```

- Clients send these routes only when `capabilities.plainChats.tools` lists `memory`. They are
  paired-device routes like the chat routes: bearer authentication, also through the remote-access
  tunnel socket and for the Mac's own session.
- Memory is a short list of plain-text facts the model keeps about the owner across plain chats.
  While `enabled`, the host sends every entry to the model as system text on every plain-chat turn
  ("The chat agent"). Memory is on until the owner turns it off. The switch and the entries survive
  host restarts.
- `entries` are oldest first; with none, `entries` is `[]`. `id` is opaque, at most 64 bytes.
  `createdAt` and `updatedAt` are RFC 3339 UTC with milliseconds; `updatedAt` equals `createdAt`
  until an edit.
- An entry's text is one line of plain text that can be seen, and never holds a secret. The host
  makes each run of white space (Unicode White_Space, line breaks included) one space and keeps of
  the rest only letters (L), marks (M), numbers (N), punctuation (P) and symbols (S) that are not
  Default_Ignorable_Code_Point: control (Cc), format (Cf: the bidirectional controls, zero-width
  characters and tag characters among them), private-use (Co), surrogate (Cs) and unassigned (Cn)
  code points, the other default-ignorable characters (variation selectors, U+034F COMBINING
  GRAPHEME JOINER, the Hangul fillers U+115F, U+1160, U+3164 and U+FFA0, the Khmer vowels U+17B4
  and U+17B5) and U+2800 BRAILLE PATTERN BLANK are dropped, so no text hides in characters that
  show nothing (a joined emoji shows its parts). It trims the ends, and replaces what looks like a
  password, token or key with `…` by the rules `alwaysLabel` uses ("Conversation model"). What is
  left must not be empty. Answers and tool parts carry the text as kept. The host cleans its
  entries again this way when it loads the store, so entries an earlier host kept are cleaned too
  (one left empty goes). The apps clean what they show the same way.
- Limits: at most `maxEntries` (50) entries, and at most `maxTotalChars` (2,000) characters (Unicode
  scalar values) of text over all entries.
- The model saves an entry with `agentland_memory_save`: a new entry each time, never a replacement.
  The host refuses a save while memory is off or when it would pass a limit, and the model is told
  why. The model removes an entry with `agentland_memory_forget`, which the host also refuses while
  memory is off (the model sees no entries then; the owner removes them). The host's tool server
  reaches the host over a Unix socket in the state folder (mode 0600, this user's processes only,
  checked with the kernel's peer credentials as the tunnel socket is), and only the host writes the
  store. Devices see changes by reading `GET /v1/memory` again.
- `PATCH` replaces the text of entry `id` and answers the entry as kept. `DELETE` removes entry `id`.
  `POST /v1/memory/settings` turns memory on or off. While it is off, the host sends no entries and
  takes no saves or forgets from the model; the entries stay, and devices can still read, edit and
  delete them.
- Errors:
  - 400 `invalid_request`: a body that is not that object (a member missing or of another type,
    unknown members, an empty `id`, a `text` that is empty once cleaned), or `DELETE` without `id`;
  - 400 `memory_limit`: the edit would take the entries' text past `maxTotalChars`;
  - 404 `not_found`: no entry has that `id` (removed meanwhile, or never there);
  - 503 `memory_unavailable`: the host has no memory store (it could not open it), for `GET` too;
  - 500 `storage_error`: the change could not be saved, and nothing changed.

  Hosts before this contract answer 404 `not_found`, as for any unknown route.
- A change whose answer was lost is not confirmed. The apps read the list again and never send the
  change again by themselves.

## Archive

| Route | Purpose |
|---|---|
| `GET /v1/archive/changes?after=CURSOR&limit≤200&wait≤20000` | `{epoch, changes:[{seq, entity: chat\|message\|terminalLog, op: upsert\|delete, payload}], cursor, hasMore}`, up to 2 MiB per page. `resync: true` when the epoch changed or the cursor is older than retained changes. `wait` (gated by `changesWait`) long-polls when nothing follows the cursor. |
| `GET /v1/archive/chat?chatId&before?&limit≤50` | chat metadata and paged messages, including chats that exist only in the archive |
| `GET /v1/archive/search?q&projectId?&provider?&from?&to?&limit≤50&cursor?` | `{results:[{chatId, messageId, projectId, provider, title, role, createdAt, snippet}], nextCursor}`; `q` ≤ 256 bytes; terms are quoted, not FTS syntax |
| `GET /v1/archive/export?chatId&format=markdown\|json` | streamed attachment; `format=jsonl` without `chatId` is local-only (whole archive) |
| `GET /v1/archive/blob?chatId&messageId&name&sha256?` | one archived attachment's bytes (gated by `blobs`), typed as stored, with `Range` support; at most 64 MiB |
| `GET /v1/archive/terminal-logs?projectId?&after?` | `{logs:[{id, projectId, title, program, startedAt, endedAt?, status, exitCode?, bytes, gapBytes}]}` |
| `GET /v1/archive/terminal-log?id&offset&length≤1MiB&format=raw\|text` | `{data (base64 for raw), offset, next, eof}`; `text` strips ANSI escapes |
| `POST /v1/archive/delete` | `{kind: chat\|terminalLog, id}`; leaves a tombstone in `changes` |
| `GET /v1/archive/stats` (local-only) | sizes, counts, backfill progress, free space, whether terminal and chat capture are paused |

The archive captures every chat message (all providers, including backfilled OpenCode
sessions), attachments, and the raw output of every terminal. Keystrokes are never
recorded. When free disk space runs low, terminal output and attachment bytes stop
being recorded under 2 GiB (`capturePaused`) and chat text only under 256 MiB
(`chatCapturePaused`); stats show both, so the Mac can show a notice.

Details as implemented (host archive v1):

- Times are RFC 3339 UTC with milliseconds (`2026-09-23T12:00:00.000Z`).
- **Visibility.** Every route serves only chats and terminal logs of configured
  projects. Entries of a project removed from the configuration stay in the database
  (and in stats and the local whole-archive export) but read as 404 or are left out.
  The change feed's `epoch` includes the configured project set, so changing it makes
  clients resync; re-adding a project with the same ID brings its entries back.
- **Changes.** Each item is `{seq, entity, op, payload}`. An upsert's payload is the
  entity's current state: a chat (`{id, projectId, provider, title, titleSource,
  titleBasis?, model?, mode?, effort?, parentId?, relation?, createdAt, updatedAt}`;
  `relation` is `continue` for a chat continued from `parentId`; `titleSource` and
  `titleBasis` are those of "Chat names", and a chat archived before them gets the
  `titleSource` its title implies, `default` or `provider`), a message in the conversation model
  plus `hidden: true` for rewound messages, or a terminal log as listed by
  `terminal-logs`. A delete's payload is `{id}` (`{id, chatId}` for a message). With
  `resync: true` the same response already starts over from the beginning; the client
  clears its copy before applying it. A page holds at least one change, so one large
  message (at most about 8 MiB) can exceed 2 MiB. A running terminal's log appears
  when it opens and when it ends, not for every write.
- **Waiting for changes.** Hosts that list `changesWait` in `archive.features` take
  `wait` (0–20000 ms, default 0; other values answer 400 `invalid_request`), as
  `/v1/notices` does. When the page would hold no changes (no `resync`, no `hasMore`),
  the request waits up to `wait` for the next change of a configured project and then
  answers the page as usual; at the end of the wait, or as soon as the host starts
  stopping, it answers the empty page with its cursor. Clients send `wait` only to
  hosts that list `changesWait`: older hosts ignore it and answer at once.
- **Chat.** `{chat, messages, hasMore, oldestId}`: the first page has the newest
  messages, each page is oldest first, and `before=oldestId` fetches the previous one.
  Hidden messages are included and marked.
- **Search.** Each match in `snippet` sits between U+0002 and U+0003 (never present in
  archived text). `from`/`to` are RFC 3339; `nextCursor` is omitted on the last page.
  Hidden messages are not searched. `provider` is the chat's (`opencode`, `claude`,
  `codex`); hosts before it omit the field, so clients treat it as optional.
- **Attachment bytes.** Hosts that list `blobs` in `archive.features` serve
  `GET /v1/archive/blob`: the bytes of the attachment called `name` (as the message's
  attachment part names it) in message `messageId` of archived chat `chatId`, the first
  such attachment with archived bytes, or the one whose `sha256` (the part's
  `attachment.sha256`) the request gives. The chat is read as the other routes read
  it (configured projects only; a deleted chat is gone), the message must be that
  chat's, and a rewound (hidden) message's attachments are served, as chat pages show
  the message. A blob is never served by its hash alone. The answer is 200 (206 for a
  `Range`, 416 for one past the end) with `Content-Length`, `Content-Type` as stored
  (`application/octet-stream` when that does not parse), `Content-Disposition:
  attachment; filename=…`, `X-Content-Type-Options: nosniff`, `ETag: "<sha256>"` and
  `Accept-Ranges: bytes`. Errors: 400 `invalid_request` without `messageId` or
  `name` (at most 256 bytes each) or with a `sha256` that is not 64 lowercase hex
  digits; 404 `not_found` for an unknown chat or one of a project no longer configured
  ("Archived chat not found") or a message without such an attachment ("Attachment not
  found"); 404 `attachment_not_archived` for an attachment archived by name only
  (capture paused under low disk space, or a backfilled OpenCode file part); 500
  `archive_error` for a blob file that changed on disk. Attachments are at most
  64 MiB (the archive keeps nothing larger).
- **Export.** `format` defaults to `markdown`; `jsonl` also works with a `chatId`.
  Markdown leaves out hidden messages; JSON keeps them. The whole-archive JSON Lines
  export has `archive`, `chat`, `message`, `interaction` and `terminalLog` lines and
  ends with `{"type":"end", chats, messages, terminalLogs}`; a transfer cut short has
  no `end` line.
- **Terminal logs.** The list is newest first, `limit≤200` (default 100), and adds
  `nextCursor`, which `after` takes. A read adds `size` and `status`; `eof` is set only
  once the terminal has ended. A `text` read may stop `next` before an escape sequence,
  CR or character cut off by the range. Every paired device may read a configured
  project's logs; live terminals stay limited to the device that opened them.
- **Delete** answers `{deleted: true}`. A deleted chat stays deleted: later capture of
  that chat ID is ignored and the backfill skips it. A running terminal's log answers
  409 `terminal_running`.

Chat capture, backfill and low disk space (M1 chunk B2):

- **Live capture.** The host archives what its chat hub holds, whichever provider
  feeds it: each message when it appears or changes (user messages, finished replies,
  status changes and reads at once; a streaming reply at most once a second), and the
  chat's title, model, mode and effort. Message `ord` and times are the conversation
  model's, so archived messages sort as the live chat does.
- **Before delivery.** `POST /v1/messages` (and a queued message) archives the user
  message with its text and attachments, whose bytes (at most 64 MiB each) go in as
  blobs named by the attachment's `sha256`, and waits (at most 5 s) until that is
  committed before the provider sees it. If the provider certainly did not receive it,
  that copy is removed again (a message tombstone). A send also keeps the chat in the
  hub through its turn, so a chat no device streams is captured; the hub holds at most
  32 chats, and the backfill covers the rest.
- **Attachments** stay with their message: a provider's copy of a sent message, which
  never carries the bytes, keeps the archived blobs, matched by file name.
- **Interactions** are recorded when requested and when resolved, with the outcome
  (`once`, `always`, `reject`, `answered`, `rejected`, or `expired` when one
  disappeared) and a one-line summary: the tool and its patterns, or the questions.
  Answers and tool input are never stored.
- **Rewinds.** A rewind marks the archived messages from its point on `hidden`; a
  restore shows them again. Messages a provider removes stay archived as last seen.
- **Backfill.** When the host starts, and every ten minutes after a finished
  pass, it imports what the archive lacks: each OpenCode
  session of each configured project updated since the last pass (`GET /session`, then
  its messages newest page first), with times, model and tokens (file parts by name and
  type only), messages from a rewind point on hidden and a reply left streaming in an
  idle session as aborted; and each Claude Code and Codex chat in
  `<state>.chats.json`, read only, adding messages the archive does not hold yet
  (records without times get the time of their first import). It makes about four
  OpenCode requests a second and none while a chat runs a turn, keeps its place so a
  restart resumes there, changes nothing when run again, skips deleted chats, and
  retries a failed pass every minute.
- **Stats** adds `chatMinimumFreeBytes` (268435456) and `chatCapturePaused` beside
  `minimumFreeBytes` (2147483648) and `capturePaused`; `backfill` rows `{source:
  opencode|cli, scope: projectId, done, imported, chats, chatsDone, updatedAt}`
  (`chats` found by the last pass, `chatsDone` finished, `imported` messages added or
  changed over all passes); and `backfillState` (`running`, `paused`, `retrying`,
  `done`), absent before the first pass starts.

## Vault

The vault (2026-10-12, phase 1) is a folder of Markdown notes, Obsidian-style, that the
host keeps in step with the archive: a note per chat and per terminal, hubs by workspace
and by provider, a note per day and a README. It is off by default for every user; only
this Mac's app turns it on, and in phase 1 only this Mac's app reads it.

| Route | Purpose |
|---|---|
| `GET /v1/vault` (local-only) | the settings and the writer's status |
| `POST /v1/vault/settings {enabled?, folder?, terminals?, adopt?}` (local-only) | changes the settings; answers the status |
| `POST /v1/vault/rebuild` (local-only) | writes every note again; answers the status |

Details as implemented (vault v1):

- **Capability.** `capabilities.vault` is `{version: 1}`, listed only for the `local-mac`
  session and only on a host that keeps an archive and offers the vault (`serve` offers it
  whenever it keeps the archive). Without it the routes answer 503 `vault_unavailable`;
  paired devices get 403 `local_only`.
- **Off by default.** The state file keeps the settings as `vault: {enabled, folder,
  terminals, id}` (`id` names the folder's vault in the archive). Absent, the vault is off:
  no folder is made and nothing is written. Only `POST /v1/vault/settings` turns it on; it
  stays on across host restarts, and a folder that went missing meanwhile is not made
  again (the vault pauses, `folder_missing`).
- **Status.** `{enabled, folder, defaultFolder, terminals, state, reason?, message?, notes,
  bytes, pending, skipped, backfill: {done, total}, lastWriteAt?, obsidianVault?}`:
  - `folder` is where the vault writes (`defaultFolder`, `~/AgentLand Vault` under
    `serve`, until another is chosen); `terminals` says whether terminals get notes (true
    unless turned off).
  - `state` is `off`, `writing` (notes wait to be written), `current`, or `paused` with a
    `reason`: `folder_missing`, `permission` (the system refused access; on macOS,
    Privacy & Security), `low_space` (under 1 GiB free), `other_archive` (the folder's
    marker names another archive: another Mac writes it) or `error`, and a `message` in
    words. A paused vault tries again every 30 s.
  - `notes` counts the chat and terminal notes written, `bytes` the files in the vault's
    own folders and its README (not `Notes/`, counted again after a write or every
    minute), `pending` the notes waiting, `skipped` the notes left alone (edited without
    their end marker, or another file where they would go); `backfill` is the first
    write's progress in notes; `lastWriteAt` the last file written since the host
    started; `obsidianVault` the Obsidian vault the folder is in (the folder, or the
    nearest folder above it, holding `.obsidian`).
- **Settings.** Every field is optional, but one is needed (400 `invalid_request` "Send
  enabled, folder, terminals or adopt").
  - `folder` must be absolute and neither the disk's top folder, the home folder nor in
    the host's state folder, links followed, and not a file: otherwise 400
    `invalid_folder`. An empty `folder` is the default. While the vault is off a folder is
    only saved.
  - Turning the vault on, or moving it while on, makes the folder (0700) when it is
    missing and writes and removes a file in it; when that fails the answer is 409
    `folder_unwritable` ("AgentLand cannot write in <folder>: <reason>") and nothing is
    saved.
  - `terminals: false` stops writing terminal notes (those written stay); turned on
    again, the vault reads its change feed again from the start, so terminals that ended
    meanwhile get their notes.
  - `adopt: true` lets the vault take over a folder whose marker names another archive,
    once: it is not saved, and if the other archive takes the folder back, this vault
    pauses again.
  - The settings are saved without touching the rest of the state file, and only the
    writer restarts: terminals, chats and their streams go on. Sending `enabled: true`
    again tries a paused vault again.
  - Each folder is a vault of its own: a new folder gets every note, and the folder left
    behind is not touched; turned back to a folder, the vault goes on where it left off
    there. A folder the vault has to make again, or whose marker no longer names its
    vault, gets every note again.
- **Rebuild.** 409 `vault_off` while the vault is off. Otherwise the vault reads its change
  feed again from the start and compares every note with its file: notes and images the
  user deleted come back, notes keep their names, and nothing is deleted; text below a
  note's end marker and `Notes/` stay as they are.
- **Errors.** A state file or archive that cannot be read or written answers 500
  `vault_error`.
- **The folder.** `README.md`, `Chats/<workspace>/` and `Terminals/<workspace>/` notes
  (`YYYY-MM-DD <first title> (<short id>).md`, named once; later titles become the
  heading, `title` and `aliases`), `Workspaces/` and `Providers/` hubs, `Daily/`,
  `Attachments/` (images chats embed), `Notes/` (the user's; never written) and the marker
  `.agentland/vault.json` (`{version, archive, vault}`). Text below a note's
  `%% agentland:end %%` line is the user's and survives rewrites. A streaming chat's note
  is rewritten at most every 5 s and a running terminal's every 30 s. Deleting a chat or
  terminal in AgentLand keeps its note. Text that looks like a key or token is masked
  (hashes and IDs are kept), but the vault is not a secure store.

## Workspaces

A workspace (called a project in the host's code and routes) is a folder on the Mac that
the host works in: chats, terminals, files and Git are scoped to it. Owner decisions
(2026-09-25): any paired device may browse the folders of the Mac user's home folder and
add one as a workspace; closing a workspace on a device closes that device's tabs in it
and ends the terminals that device opened there (chats are kept on the host).

Everything below is advertised as `capabilities.projects.features`; a client uses a route
or field only when its feature is listed. Changes apply at once, without restarting the
host, and are saved in the host's state file with every other part of the state (devices,
pending pairings, other workspaces) preserved.

| Route | Feature | Body / query | Answer |
|---|---|---|---|
| `GET /v1/projects` | `details` | — | `{projects:[{id, name, directory, gitRepository, activity:{busyChats, terminals}}]}`; without the feature only `{id, name}` as before |
| `GET /v1/folders` | `browse` | `path?` (absolute; default the home folder), `hidden?` (`1` to include dot folders) | `{path, displayPath, parent?, roots:[{name, path}], folders:[{name, path, workspaceId?, gitRepository}], truncated}` |
| `POST /v1/projects` | `add` | `{directory, name?}` | 201 the project (as in `details`); 409 `already_workspace` (with `projectId`) |
| `POST /v1/projects/create` | `create` | `{parentDirectory, name, git?}` | 201 the project; 409 `already_exists` |
| `POST /v1/projects/rename` | `rename` | `{id, name}` | 200 the project |
| `POST /v1/projects/remove` | `remove` | `{id, endTerminals?}` | 200 `{removed: true}`; 409 `workspace_busy` `{busyChats, terminals}`; 409 `last_workspace` |

Details:

- **Home folder.** The host's workspace home is the Mac user's home folder (`--workspace-home`
  overrides it for tests). Browsing, adding and creating accept only folders inside it,
  after resolving symbolic links; a link that leads outside is left out of listings and
  refused as a target. Left out and refused as well: the home folder's `Library`, `.Trash`
  and dot folders unless `hidden=1` (never `.Trash`), and anything that is not a directory.
  The home folder itself may be browsed but not added.
- **Listing.** `folders` holds sub-folder names only (never files), sorted case-insensitively,
  at most 2,000 (`truncated: true` beyond that). `displayPath` abbreviates the home folder
  as `~`. `roots` offers the home folder and those of `Developer`, `Desktop`, `Documents` and
  the configured workspaces' parents that exist. `workspaceId` marks a folder that already
  is a workspace; `gitRepository` is true when it holds a `.git` entry. A path outside the
  home folder, missing or not a folder answers 404 `not_found`.
- **Adding** keeps the folder's name as the workspace name unless `name` is given (1–100
  characters, no `=` or line breaks, trimmed). Its `id` is new, except that a folder removed
  earlier gets its old `id` back, so its archived chats and terminal logs show
  again (the archive keeps entries of removed workspaces, hidden).
- **Creating** makes `parentDirectory/name` (a single path component: no `/`, not `.` or
  `..`, not starting with a dot) with mode 0755, runs `git init -b main` in it when `git` is
  true (a failure leaves the folder and answers 500 `git_failed` with the folder added), and
  adds it. An existing file or folder of that name answers 409 `already_exists`.
- **Renaming** changes only the display name.
- **Removing** takes the folder out of the list and never touches its files. A workspace
  with a chat turn running or live terminals (any device) answers 409 `workspace_busy`
  unless `endTerminals` is true, which ends its terminals first (a running chat turn still
  refuses). The last workspace cannot be removed. Removed workspaces' chats stay in the
  archive (hidden).
- **Closing on a device** needs no new route: the client closes that workspace's tabs and
  ends each terminal it opened there with `POST /v1/terminal/close`.
- Adding, creating and removing also move the archive change feed's epoch (devices resync;
  a feed waiting with `wait` answers at once), and removing drops presence views of the
  workspace's chats, as a configuration change does today. A rename keeps the epoch: the
  archive keys chats by workspace `id`, not name.

Details as implemented (workspaces v1; they settle what the list above leaves open):

- **Activity.** `busyChats` counts the chats with a turn running: OpenCode sessions that
  are busy or retrying (OpenCode is waited for at most 2 s; a workspace it has not answered
  for counts none of its OpenCode chats) and Claude Code and Codex chats at work.
  `terminals` counts running terminals, whichever device opened them.
- **Links and hidden folders.** A link to a folder inside the home is listed under its own
  `name` with the resolved `path`; `path`, `parent` and `roots[].path` are always resolved.
  `hidden` applies to browsing only: adding and creating accept dot folders (a device finds
  them with `hidden=1`), never a `.Trash` or the home's `Library`. The home's root is named
  after its folder; a root whose link leads outside the home is left out.
- **Errors.** A relative path, an invalid name and the home folder as a workspace answer
  400 `invalid_request`; a folder outside the home, missing, not a folder or left out, and
  an unknown workspace `id`, answer 404 `not_found`. `already_workspace` names `projectId`
  inside `error`, `workspace_busy` names `busyChats` and `terminals` there, and `git_failed`
  names the added workspace's `projectId`. A folder that cannot be made answers 403
  `file_unavailable` (507 `insufficient_storage` on a full disk).
- **Creating** also uses `name` as the workspace's name, so it follows the name rules of
  adding as well (at most 100 characters, no `=` or line breaks). `git init` gets 15 s.
- **IDs** are the name's slug (lower-case ASCII letters and digits, hyphens between words)
  and six random hex digits, such as `my-app-3f9a2c`. The host remembers the folders of the
  latest 100 removed workspaces.
- **Removing** with `endTerminals` ends the workspace's terminals of every device; its
  exited terminals are dropped as well. A terminal whose start overlaps the removal ends
  with it (its create answers 404).

## Terminals

Terminal routes exist when the host runs with `--enable-terminal` (`capabilities.terminal`;
`terminalPrograms` lists `shell` and the installed `opencode`, `claude` and `codex`, and with
the agent catalog every usable agent that has a terminal command, see "Agents"). Each
terminal runs in AgentLand's terminal keeper, a small process on the Mac that holds the PTYs
so they outlive the host (a host restart, an app update or a crash keeps every terminal
running; the host takes them back at its next start). The host keeps each terminal's output
(2 MiB) and proxies it. Every paired device may list (through `GET /v1/terminals/others`),
read, type into, resize, name and end every terminal on its host (2026-10-15).
`GET /v1/terminals` still lists only the asking device's. Terminal IDs
match `[A-Za-z0-9._:-]{1,128}` (the host's are `term_` and 16 hex digits). The keeper's
attach reply comes before its data frames (internal; devices never see it). A `program` the host does not list answers 400 `terminal_program_unavailable`.

| Route | Body / query | Response |
|---|---|---|
| `GET /v1/terminals` | `projectId` | `{terminals: [Terminal]}` |
| `GET /v1/terminals/others` | | `{terminals: [SharedTerminal]}` (hosts that list `shared` in `terminalFeatures`; see "Terminals from other devices") |
| `POST /v1/terminals` | `{projectId, title, rows, cols, program?, resume?}` | 201 Terminal |
| `GET /v1/terminal/output` | `projectId?, terminalId, cursor, wait?` | `{data, cursor, end, reset, status, exitCode?, ended?}` |
| `POST /v1/terminal/input`, `/v1/terminal/resize`, `/v1/terminal/close` | unchanged, except that `projectId` may be omitted | unchanged |

```text
Terminal { id, title, projectId, status: running|exited|disconnected, exitCode?,
           programTitle?, command?, conversationId?, ended? }
```

`conversationId`, `ended` and `resume` are described in "How terminals end" below.

- `title` is the label given at creation ("Terminal" when it is empty). Its meaning is
  unchanged; it never changes.
- `programTitle` (an addition): the title the terminal's program set last with OSC 0 or
  OSC 2 (`ESC ] 0 ; text BEL`, or the same ended by ST, `ESC \`), cleaned as below. It
  changes when the program sets a new title; a program that sets an empty or generic
  title clears it. Omitted when there is none (so always in the create answer). OpenCode
  1.18.31's TUI sets "OC | <session title>" inside a titled session (a title over 40
  characters cut to 37 and "…") and "OpenCode" on its home screen or in an untitled
  session (`OPENCODE_DISABLE_TERMINAL_TITLE` turns both off); Claude Code sets a short
  topic after a status glyph; shells usually set none.
- `command` (an addition, macOS hosts only): while `programTitle` is absent and a process
  other than the terminal's own runs in its foreground, that process's arguments joined
  with spaces (control characters and white space cleaned as in step 1 below), at most 60
  characters (a longer one is cut to 59 and ends with "…"); never its environment. The
  host reads it from the kernel, never by running a program: `kern.proc.pid` of the PTY's
  process (OpenCode 1.18.31 reports it as the PTY's `pid`) gives the terminal's foreground
  process group, and `kern.procargs2` that group leader's arguments. Only
  `GET /v1/terminals` computes it, at most once every 2 s per terminal. It is omitted while
  the terminal's own process (the shell, or OpenCode, Claude Code or Codex) is in the
  foreground, for a terminal that is not running, on other systems, and when anything
  fails (a process that ended, another user's process, a process ID reused since the
  terminal started).
- Clients show `programTitle`, else `command`, else `title`.
- `end` (an addition) in a terminal output answer: the cursor after the newest byte the
  host held when it answered (`cursor` is where this answer's `data` stops, at most one
  64 KiB chunk on). A client reading a terminal's history from the start for a terminal
  it drew in an earlier run (after a relaunch) draws the bytes before `end` without
  answering their queries again: the cursor position, device attribute and mode reports
  were answered when they were first drawn, and late replies would reach the shell as
  typing. Older hosts omit it.

Reading titles: the host follows each terminal's output as it arrives, where the archive
records it, with a small state machine that keeps its place across chunks. It takes OSC 0
and OSC 2 and skips every other OSC (OSC 1, the icon name, too). CAN, SUB or an ESC not
followed by `\` abandon a title; a title over 1024 raw bytes is ignored (the previous one
stays); 8-bit C1 controls are not read (the stream is UTF-8), and invalid UTF-8 in a title
is dropped.

Cleaning a title (the apps use the same rules; characters are Unicode scalar values):

1. Control characters (Unicode category Cc) and invalid UTF-8 are dropped, runs of
   white space (Unicode White_Space) become one space, and the ends are trimmed.
2. A leading `OC | ` (OpenCode inside a session) is removed; a title that is only `OC |`
   becomes empty.
3. A leading run of characters that are neither Unicode letters nor decimal digits is
   removed: Claude Code's status glyphs (`✳ ✻ ✶ ✢ · *`), braille spinner characters
   (U+2800–U+28FF), dashes and spaces.
4. A leading `user@host:` shell prefix (no spaces, `@` or `:` in either part) is removed,
   keeping what follows, trimmed.
5. A title over 80 characters is cut to 79, trailing white space removed, and "…" added.
6. A title that is then empty, or only a program's own name, is no title. It is compared
   ignoring case with: opencode, claude, claude code, codex, zsh, -zsh, bash, -bash, sh,
   fish, login, the terminal's program and its label (shell and Shell, opencode and
   OpenCode, claude and Claude Code, codex and Codex) and the terminal's `title`.

Examples: "OC | Fix the login redirect" gives "Fix the login redirect"; "✳ Terminal scrolling"
gives "Terminal scrolling"; "⠙ Building" gives "Building"; "s@mini:~/Developer/app" gives
"~/Developer/app"; "OpenCode", "✳ Claude Code" and "-zsh" give no title.

### How terminals end (2026-10-14)

A terminal ends only when its program exits, a host action ends it, or the keeper itself
stops. A host that stops, restarts or loses its attachment detaches and never ends a terminal
(no keepalive is needed: the keeper, not OpenCode, owns the PTYs; the incident of 2026-10-14,
where OpenCode released a folder's services after 60 minutes and killed its PTYs, cannot recur).
A host started without `--enable-terminal` asks a keeper still running for its state to end
every terminal and exit (in the background, within 10 s; it never starts one, and leaves a
keeper it cannot use alone), so no terminal outlives switching terminal access off. The Mac
app applies that switch at once: it ends the running terminals (asking first), then restarts
only the host without `--enable-terminal`. Since 2026-10-15 both release a coding agent typed
in Terminal on the Mac to its Terminal window instead of ending it ("Terminals started in
Terminal on the Mac" below).

- `ended` (an addition) on a Terminal and in an output answer, once `status` is not
  `running`:

  ```text
  TerminalEnd { reason, at, exitCode?, device?, program?, conversationId?, continuedIn? }
  ```

  `reason` is `programExited` (its program exited, with `exitCode`, or the keeper ended it by
  a signal), `endedByDevice` (`POST /v1/terminal/close`; `device` is that device's name),
  `workspaceRemoved`, `hostStopped` (the Mac app's Quit question ended every terminal; the
  host stopping alone never does), `keeperStopped` (the keeper itself stopped, or no longer
  knows the terminal: a restart of the Mac, a logout or a crash), `endedOnMac` (ended in
  AgentLand on the Mac, Settings → Terminals), `deviceRemoved` (its device was removed from
  the Mac, which ends and forgets that device's terminals), `keptInTerminal` (2026-10-15: a
  coding agent typed in Terminal on the Mac was released to its Terminal window, where it runs
  on; `status` is `disconnected`), or, from older hosts only,
  `backendEnded`, `connectionLost` and (only from the archive) `hostInterrupted`, which this
  host no longer produces. It may be empty for a log from before archive v7; clients read a
  reason they do not know as none. `at` is RFC 3339 UTC with milliseconds. Top-level
  `exitCode` is the same value as `ended.exitCode`, for older clients. `program` is the
  program the terminal was opened with; `conversationId` as below. `continuedIn` (2026-10-26)
  is the ID of the terminal a continue started in its place ("Continuing a terminal in a new
  one" below), whatever the reason; it is absent otherwise, and absent from an end read from
  the archive.
- Finished terminals stay listed for 24 hours after they finish, so their device can read how
  they ended; then the host clears them (the keeper forgets them, the host drops them) and
  they stop counting toward the 16-terminal limit. A terminal that finished more than a day
  ago while no host followed it is cleared when the host starts. The archive keeps the log.
  After a clear a device's read answers 404 `terminal_not_found` with `ended` (see the next
  item), from the host's own memory of it for another 24 hours and from the archive after.
  A routed agent (typed in Terminal on the Mac, 2026-10-15) is the exception: once its log
  records the end it is cleared at once, whatever ended it, since no device tab closes it.
- The 16-terminal limit counts every device's terminals and the Mac's routed agents, finished
  ones included. At the limit `POST /v1/terminals` answers 429 `terminal_limit` with "16
  terminals are open on this Mac across all your devices and Terminal windows, including
  finished ones that haven't been closed. Close one, or end or clear one in AgentLand on the
  Mac (Settings → Terminals)."
- Terminal errors: 503 `terminals_unavailable` ("AgentLand's terminal service isn't answering;
  your terminals are still running.") while a keeper runs that this build cannot use, also for
  an ID the host does not know (the keeper may hold it), so the host never answers
  `terminal_not_found` for a terminal a keeper may still hold; 500 `terminal_path_too_long`
  ("AgentLand's terminal service can't start: its socket path is too long.") at the first
  terminal when the state folder's socket path is too long; 409 `terminal_not_running` for
  input to a terminal that has ended; 409 `terminal_input_stalled` ("The program in this
  terminal isn't reading input; nothing was sent.") for input the program did not take within
  10 s (the terminal keeps running).
- A terminal the host no longer has answers output reads with 404 `terminal_not_found`
  ("Terminal not found"; before 2026-10-15 "Terminal not found for this device and project").
  When the host remembers how it ended (every terminal it forgot in the last 24 hours: closed,
  cleared, or ended with its device or workspace) or the archive recorded it (the newest log
  with that `terminal_id` that is no longer running, in the workspace `projectId` names, or in
  any without one), the error carries it: `{error: {code, message, ended: TerminalEnd}}`, with
  `device` naming the device that ended it. Since 2026-10-15 this answers every paired device,
  not only the terminal's own. That covers a terminal a device or workspace removal ended (both
  forget it at once), a routed agent cleared as it ended, and every terminal after the host
  started again. Without either, the answer is unchanged.
- Claude Code conversations: on hosts whose `terminalFeatures` lists `resume`, the host starts
  every `claude` terminal with `--session-id <a UUID it generates>` and returns it as
  `conversationId`. `resume` in `POST /v1/terminals` (only with `program: "claude"`) is a
  conversation's UUID, answered with `claude --resume <id>` (the terminal's `conversationId`
  is that ID, which Claude Code keeps when resuming), or `"pick"`, answered with
  `claude --resume` alone, which opens Claude Code's own session picker in the terminal (for
  an ended terminal whose conversation the host never named; no `conversationId`). Anything
  else, or `resume` with another program, answers 400 `invalid_request`. Devices never send
  arguments; the host builds them. A device resuming an ended terminal the host still lists
  ends it first with `POST /v1/terminal/close`, so the replaced terminal stops counting
  toward the 16-terminal limit and one conversation never runs twice.
- The archive (schema v7) keeps `end_reason`, `ended_by_device_id` and `conversation_id` on
  `terminal_logs` (old rows: empty), with `exit_code` now filled after `programExited`; the
  archive's terminal log JSON adds `endReason?` and `conversationId?`.
- The host logs one line per terminal created (`terminals: created id=… workspace=…
  program=… device=… ("name") conversation=…`) and ended (`terminals: ended id=… workspace=…
  program=… status=… reason=… exit=… device=…`) and each terminal it clears; never terminal
  contents, tokens or passwords. It ignores SIGPIPE, so a write to its output
  pipe after the Mac app went away fails instead of killing it. The Mac app writes the host's and OpenCode's output to
  `~/Library/Logs/AgentLand/host.log` and `opencode.log` (0600, 5 MB with one `.1` copy);
  OpenCode runs with `--print-logs --log-level INFO`.

### Terminals from other devices (2026-10-15)

Owner's decision (2026-10-15):
every paired device sees and controls every terminal on its host, like Safari's tabs from your
other devices. This reverses the per-device ownership of 2026-10-14. Hosts with terminals list
`shared` in `terminalFeatures`.

`GET /v1/terminals/others` (no query) answers `{terminals: [SharedTerminal]}`: the running
terminals the asking device did not open, the other devices' and this Mac's (a coding agent
typed in Terminal on the Mac, a terminal of the Mac's web app). Ended terminals are not listed.
They come most recently active first (`lastActiveAt`), then by `id`. Like every terminal route
it answers 403 `terminal_disabled` while terminal access is off and 401 `unauthorized` without
a valid token; the local web app is not offered it.

```text
SharedTerminal { id, deviceId, deviceName, onMac, program, title, programTitle, contextTitle,
                 folder, displayFolder, projectId, workspace, routed, status, activity,
                 lastOutputAt?, lastActiveAt }
```

- `deviceId` is the device that opened it, `local-mac` for this Mac's own. `onMac` is true for
  those, and their `deviceName` is "" (the apps name them by the host's name); otherwise
  `deviceName` is the paired device's name.
- `program` is its program's ID (`shell`, `claude`, `qwen-code`, …) and `title` its creation
  label; `programTitle` and `contextTitle` are as on a Terminal, "" when there is none.
- `folder` is where it runs on the Mac, an absolute path (a workspace terminal's is its
  workspace's folder); `displayFolder` is the same with this user's home folder written `~`.
- `projectId` and `workspace` (the workspace's name) are `null` for a terminal outside any
  workspace.
- `routed` is true for a coding agent typed in Terminal on the Mac (next section).
- `status` is `running`; `activity` is `working`, `waiting` or `quiet` (below).
- `lastOutputAt` is when its last output arrived, omitted until output arrives while this host
  follows it (output a restore replays doesn't count). `lastActiveAt` is the latest of its last
  output, its last input and its creation. Input is what this host sent
  (`POST /v1/terminal/input`) and the keeper's own time of the last input it passed on, which
  includes typing in a Terminal window; the host waits at most 500 ms for the keeper's times,
  and a keeper that has not answered by then only leaves them out. Times are RFC 3339 UTC with
  milliseconds.

Activity (`desktop/terminal_activity.go`):

- `waiting` (for you): the program asked for attention after the latest input: a BEL outside
  an OSC, an OSC 9 notification with free text, a kitty OSC 99 notification, or an OSC 777
  `notify;…`. An OSC 9 with no text, or whose text starts with a ConEmu command's number (digits
  up to a `;` or the end: `9;4` progress, which Claude Code and others send while they work;
  `9;9`, the folder some prompts report at every prompt; `9;1`, `9;12`, …), is none, and a BEL
  that ends an OSC is never a bell. A sequence split between two reads counts; output a restore
  replays only moves the reader along.
- `working`: output arrived within the last 3 s.
- `quiet`: anything else.

The apps show these as "Working", "Waiting for you" and "Quiet · 5m" (the time since
`lastOutputAt`: `<1m`, minutes, hours or days; "Quiet" alone without it), grouped under
"On <device name>" (the Mac's under the host's name), devices and rows most recently active
first, leaving out their own device's. They read the list again every 4 s while it shows.

Reaching any terminal:

- Output, input, resize, title and close accept any paired device for any terminal (a revoked
  device's token answers 401, as everywhere). `projectId` is optional on them: without it the
  request reaches the terminal by its ID whatever its workspace, and a terminal outside any
  workspace is reached only that way; with it, it must name the terminal's workspace (another
  workspace answers 404 `terminal_not_found`, an unknown one 404 `not_found`). The apps send no
  `projectId` for a terminal outside any workspace.
- `GET /v1/terminals` and `POST /v1/terminals` still need `projectId`, and list or create only
  the asking device's terminals; a device never creates a terminal outside a workspace.
- `POST /v1/terminal/close` ends the terminal for every device (`endedByDevice`, naming the
  device that closed it). The apps close a tab opened from another device's terminal without
  ending it. Removing a device (`POST /v1/terminals/end-device`) still ends only that device's
  terminals, never the Mac's.
- A terminal has one size, and the last resize wins, so the viewer who typed last sets it. The
  apps send their size when the terminal's view lays out, and again before typing after a
  second without typing there; a routed agent's Terminal window sends its size when the window
  resizes, and when it gains focus or takes a keystroke while the terminal has another size.

Terminals outside any workspace:

- Only routed agents are created outside one: a routed agent is placed in the deepest
  workspace whose folder holds its folder, else in none.
- Adding a workspace (`POST /v1/projects`) takes in every running terminal outside any whose
  folder is the workspace's folder or lies under it; their records and archive logs move with
  them, and the archive moves the logs of the terminals outside any that ran there and have
  ended or been forgotten, so the workspace's search and Resume find them. The workspace's folder
  is resolved once (links and letter case); a terminal's folder is compared only as a string and
  never opened.
- A terminal outside any workspace is never ended by a workspace change. A terminal in a
  workspace, routed or not, still ends as `workspaceRemoved` when its workspace is removed.
- The archive (schema v8) files the log of a terminal outside any workspace under the project
  `_none`, with its folder in the new `terminal_logs.folder` column (empty for other rows). An
  older host refuses a v8 archive, as with every earlier migration. The vault shows that
  project as "Outside Workspaces": the hub `Workspaces/Outside Workspaces.md` and the notes
  under `Terminals/Outside Workspaces/`; a note's `workspace-id` front matter stays `_none`.

### Terminals started in Terminal on the Mac

Owner's decision (2026-10-15): with the Mac app's "Open coding agents from Terminal in
AgentLand" on (Settings → Advanced → Connection; off by default; it turns on only while terminal
access is on, and can always be turned off), a coding agent typed in Terminal on the Mac runs as
an AgentLand terminal of this Mac (owner `local-mac`), which every paired device can follow and
drive while the Terminal window shows the same session. Only zsh is covered.

- **The hook**:
  `agentland-host terminals hook <on|off|pause|status> [--state <host.json>] [--executable <path>]`,
  which the Mac app's switch runs (`desktop/internal/shellhook`). `on`
  writes the hook script `agentland.zsh` and the switch file `routing` ("on") into a `shell`
  folder beside the host's state (0700, the files 0600), and adds one marked block at the end of
  `~/.zshrc`, keeping a copy of the file as `~/.zshrc.agentland-backup` the first time:

  ```zsh
  # >>> AgentLand: coding agents from Terminal >>>
  # Added by AgentLand (Settings → Advanced). Turn the switch off there to remove it.
  if [[ -r '<hook>' ]]; then source '<hook>'; fi
  # <<< AgentLand: coding agents from Terminal <<<
  ```

  The script defines a function for each agent command that is installed and not already a
  function (`claude`, `codex`, `gemini`, `qwen`, `goose`, `copilot`, `cursor-agent`, `kimi`,
  `droid`, `amp`, `vibe`, `opencode`). It runs
  `<agentland-host> terminals run --state <host.json> -- <name> <args>` only when the switch
  file reads `on`; stdin, stdout and stderr
  are all terminals (so `claude 2>err.log` is a redirect, never routed); `AGENTLAND_TERMINAL` is
  unset; the `agentland-host` it names is executable; and no argument is a non-interactive use
  (`-p`, `--print`, `--prompt`, `-x`, `--execute`, `--version`, `-v`, `-V`, `--help`, `-h`, or
  `--print=…`/`--prompt=…`, before any `--`; or a first argument that is one of the agent's own
  subcommands such as `update`, `mcp` or `exec`, or `help`, `version`, `completion`; for `claude`
  also `--bg` and `--background`, and its own subcommands `update upgrade mcp doctor config
  install migrate-installer setup-token plugin plugins auth auto-mode agents attach logs stop
  kill rm respawn purge import gateway ultrareview`, which the hook runs as they are; other
  agents' `--bg` still routes). Otherwise it runs the real command. `off` removes the switch first, then the block (also when edited
  inside) with the blank line and any newline `on` added before it, the hook script and the
  emptied folder, so a `.zshrc` nothing else changed is byte for byte as it was before `on`, and
  a `.zshrc` that `on` created is deleted when only the block is in it; `pause` (terminal access
  off) removes only the switch. A damaged block (a start without an end, an end without a
  start, two starts) leaves `.zshrc` and the hook script as they are and names the file to fix
  by hand: `on` changes nothing, while `off` and `pause` first remove the switch file (routing
  is off at once) and then fail with that message (exit 1, on stderr), so `status` then reads
  `on: false`. `on` refuses a `.zshrc` (or, when it is a symbolic link, its target) that is a
  hard link and writes nothing: "<file> is a hard link, which AgentLand's change would break.
  Replace it with a symbolic link or a copy, then try again."; `off`, when it would rewrite
  the block, turns routing off and removes the hook script first and then fails with the same
  words. The edit is an atomic rename of a new file, which can drop extended attributes, ACLs
  and file flags of a single-link `.zshrc`.
  `status` prints `{on, block: present|absent|damaged, zshrc}`. Known limits, accepted
  (the spec's "Edge cases"): only `~/.zshrc` is edited, so with `ZDOTDIR` elsewhere the switch
  shows on and nothing is routed; after Ctrl-Z and `fg` of a routed agent zsh reports `$?` as 0
  and loses the job's name; and an `agentland-host` that is executable but can't run
  `terminals run` (an older AgentLand installed over a newer one, a code-signing kill) makes a
  routed agent fail instead of falling back until the app runs `hook on` or `hook off` or the
  block is removed.
- **`agentland-host terminals run [--state <host.json>] -- <command> [args…]`**
  (`desktop/internal/termrun`). Within 1 s it registers the terminal with the host (below) and
  reaches the keeper. When anything is missing it starts the real command itself, as the shell
  would have, with one dim line on stderr: "AgentLand isn't running — started claude normally."
  (no socket, or a refused or closed connection), "AgentLand didn't answer in time — started
  claude normally." (the host took the connection but did not answer within 1 s), or
  "AgentLand's terminal access is off", "AgentLand has 16 terminals open", "AgentLand's
  terminal service isn't available", "AgentLand couldn't take this terminal"). Otherwise it
  starts the agent itself on a new PTY under a job-control leader of its own, with the shell's
  environment plus `AGENTLAND_TERMINAL=<id>` and in the shell's folder, so the agent stays a
  process of the Terminal window and macOS keeps treating it as Terminal's for privacy
  permissions; it hands the PTY's master to the keeper (the keeper's `adopt`, by descriptor
  passing) and drives the window straight from the keeper, so the window keeps working through
  host restarts and Mac app updates. If the keeper goes away the CLI moves the bytes itself and
  the agent goes on in Terminal, no longer reachable from devices. For `claude` it adds
  `--session-id <uuid>` unless the first argument is one of Claude Code's own subcommands
  above or an argument picks a conversation or runs it elsewhere (`--resume`, `-r`,
  `--continue`, `-c`, `--session-id`, `--from-pr`, `--teleport`, `--cloud`, `--bg`,
  `--background`, also `=`-joined), and the host records that as `conversationId`. Closing
  the window (SIGHUP) hangs up the agent's session, as Terminal would; the agent's exit code
  becomes the CLI's own (`128+n` for a signal). A signal's death is the CLI's too: the leader
  tells the CLI the signal over its link, and once the window is restored the CLI kills itself
  with that signal (core files off, default action), so zsh prints its usual line ("zsh: abort
  claude") and `$?` is `128+n` as with the switch off; if that returns it exits `128+n`. The
  keeper still records the signal (`exit.signal`). A crash then names `agentland-host`. Ctrl-Z typed in the window suspends the job as zsh expects;
  a stop from anywhere else is continued at once.
- **`agentland-host terminals attach [--state <host.json>] <id>`** shows a running terminal in
  the window that runs the command, straight from the keeper, with no fallback: when the keeper
  goes away it prints one line and exits. The Mac app's Terminals pane offers it as Open in Terminal.
- **The registration socket** is not an HTTP route: `terminals-local.sock` beside the keeper's
  `terminals.sock` in the host state's folder, bound 0600, with each connection checked to come
  from this user's own processes (another user's is closed without a word). It is never bound to
  TCP, carried through the tunnel or offered to the browser, and no HTTP route registers or
  continues a terminal. The host serves it with terminal access off too, to refuse at once. One
  connection is one registration, or one continue (`{op: "continue"}`, "Continuing a terminal
  in a new one" below); each message is one JSON object on one line, at most 64 KiB:

  1. The CLI sends `{op: "register", command, folder, rows, cols, conversationId?, version}`
     within 2 s: the command as typed, its folder (the shell's cwd, absolute and canonical; on
     macOS the path `F_GETPATH` gives for `.`), the window's size, the Claude Code conversation
     it chose and its own version.
  2. The host answers `{id, meta}` (the terminal's ID and the record the keeper is to keep)
     and holds a place under the 16-terminal limit, or `{error: {code, message}}` and hangs up.
     Refusals, in this order: `terminal_disabled`, `version_mismatch` (only the host's own
     version is taken), `program_unknown` (a command the hook does not route), `invalid_request`
     (a folder that is not a clean absolute path), `terminals_unavailable` (the keeper is
     unusable, does not answer within 1 s, or does not adopt), `host_stopping`,
     `terminal_limit`.
  3. The CLI has the keeper adopt its PTY with that ID and record, then sends
     `{op: "adopted"}`, or `{op: "cancel"}` when it gave up, within 10 s.
  4. The host follows the terminal once the keeper lists it as adopted and answers
     `{ok: true}`. After "adopted", any other answer, or none, still means the keeper may hold
     it.

  The host reads the folder only as a string and never opens, stats or lists it: on macOS that
  could ask the person to let AgentLand into Downloads, Desktop, Documents or an external drive.
- **The record** (`terminalMeta`, kept in the keeper beside each terminal). V1 names the
  terminal's workspace. V2 (2026-10-15) is written for a terminal outside any workspace or a
  routed one: it names its `folder`, its `project` only when it has one, and `routed: true` for
  a routed agent. A record that fits V1 is still written as V1, and older hosts leave V2 records
  alone (left running and listed to no one). A routed agent's record names owner `local-mac`,
  the deepest workspace holding its folder (or none), the folder as sent, its program ID (from
  the command's name) and label ("Claude Code"), the `conversationId` when the CLI named a valid
  one, and its creation time.
- **Lifecycle** (2026-10-15):
  - A routed agent counts toward the 16-terminal limit while it runs. It is cleared as soon as
    it ends (its log records the end first): `programExited` when the agent exits or its window
    closes. It never waits out the 24 hours.
  - Ending all releases a running routed agent to its Terminal window instead of ending it:
    Quit's End Terminals and turning terminal access off (`POST /v1/terminals/end-all`), a host
    started without `--enable-terminal`, and `agentland-host terminals stop` (the keeper releases
    every terminal it adopted as it stops). The keeper drops its copy, the CLI drives the PTY
    itself, and the terminal ends as `keptInTerminal` (status `disconnected`) and is cleared. The
    Mac app's questions add "Agents open in Terminal keep running there."
  - Ending that one terminal ends it: `POST /v1/terminal/close` from any device, or the Mac's
    `POST /v1/terminals/end`. Removing its workspace ends it as `workspaceRemoved`.
  - Removing a device never touches routed agents, which are the Mac's.
  - A restarted host takes a routed agent back like any terminal. One that ended while no host
    followed it is cleared at once, and one whose record no longer decodes is released, never
    ended.
  - While terminal access is on and the switch file reads `on`, the host keeps a keeper running
    (it checks the switch file every 5 s, and holds a connection that keeps the keeper's idle exit off), so the
    CLI's 1 s setup never waits for a keeper to start.
- **`AGENTLAND_TERMINAL=<id>`** is in the environment of every AgentLand terminal: the host sets
  it in each terminal it starts, and `terminals run` in the agent's. The hook routes nothing
  where it is set, so an agent typed inside an AgentLand terminal is never routed again. Since
  2026-10-26 each terminal the host starts also has `AGENTLAND_HOST` and
  `AGENTLAND_HOST_STATE` (next section); a routed agent's does not.

### Continuing a terminal in a new one (2026-10-26)

The owner's handoff ends a Claude Code session and goes on in a fresh one. In an AgentLand
terminal, viewed on the iPhone, the owner asked for "confirm and then open a new terminal kinda
behavior and close the old one out after a moment", with the tab following the new terminal. So
`agentland-host terminals continue -- <prompt>`, typed in an AgentLand terminal, has the host
start Claude Code with the prompt in a new terminal of the same workspace, for the same device;
the caller then ends the old terminal's program itself (the host never ends it), and the old
terminal's end names the new one.

- **The op**, on the registration socket above (`terminals-local.sock`, this user's processes
  only; no HTTP route continues a terminal). One connection is one exchange: the CLI sends
  `{op: "continue", from, prompt, rows, cols, version}` within 2 s; the host answers `{id}` (the
  new terminal's ID) or `{error: {code, message}}`, and hangs up. `from` is the terminal the
  command runs in (`$AGENTLAND_TERMINAL`); `rows` and `cols` are its window's size, 0 when it
  has no terminal.
- **Checks**, refusing in this order: `terminal_disabled`; `version_mismatch`;
  `invalid_request` for a prompt that is empty once its white space is trimmed, over 4096
  bytes, not UTF-8, holding any control character (Unicode Cc, tab and newline included), or
  starting with `-` once trimmed (so it is never read as an option);
  `terminal_not_continuable` when `from` is not a terminal ID, not a terminal the host follows,
  not running, a coding agent typed in Terminal on the Mac (routed), not Claude Code's, or in no
  workspace (or one since removed). Then the new terminal starts as a device's Claude Code
  terminal does (`POST /v1/terminals` with `program: "claude"` and a new conversation), with
  the same agent update preparation, answering as close as this socket's codes come to that
  route's answers: `program_unknown` when Claude Code is not available,
  `terminals_unavailable` (the keeper cannot be used, or the start failed), `host_stopping`,
  and `terminal_limit` under the 16-terminal limit, which counts it as a device's create does.
  Nothing is recorded on a refusal.
- **The new terminal** is the old one's owner's (its device, or `local-mac`), in its workspace,
  under its creation title, at the request's size when it is valid, else the old terminal's size
  when the host knows it, else 24×80. The host builds the arguments: `--session-id <new
  conversation>`, then the prompt, trimmed, as one final argument. Devices still never send
  arguments or commands; only this same-user socket can pass a prompt. The host logs one line,
  `terminals: created id=… workspace=… program=claude device=… continued from=<old id>`, and
  never the prompt.
- **`continuedIn`**: once the new terminal runs, the old terminal's `TerminalEnd` names it,
  whenever and however the old one ends: in `GET /v1/terminals`, in output answers, and in the
  `ended` of a 404 `terminal_not_found` while the host remembers it. It is the host's memory
  only: the archive does not store it, so a host that restarts between the continue and the old
  terminal's end loses the link.
- **The environment**: each terminal the host starts has, after `AGENTLAND_TERMINAL=<id>`,
  `AGENTLAND_HOST=<the host's own executable>` and `AGENTLAND_HOST_STATE=<the host's state
  file>`, in place of any inherited (a host run inside another host's terminal never passes the
  outer host's on). Routed agents' terminals are unchanged.
- **The CLI**: `agentland-host terminals continue [--state <host.json>] -- <prompt>`. `--state`
  defaults to `$AGENTLAND_HOST_STATE`, else the default state. It waits at most 60 s and prints
  only the new terminal's ID and a newline on stdout. Exit codes: 0 success; 5 when this
  terminal cannot be continued here (no `$AGENTLAND_TERMINAL`, the socket missing or refusing
  the connection, or `terminal_not_continuable`), so the caller goes on its own way; 2 usage;
  1 any other failure, with the host's message on stderr.
- **The apps**: a tab whose terminal ends with `continuedIn` switches to that terminal in
  place.

### Continuing a chat in a new one (2026-10-26)

The owner's handoff skill ends a Claude Code session and goes on in a fresh one, which works in
AgentLand's terminals (above). Owner, 2026-10-26: "handoff needs to work in the chat screen
too". The owner's choices: the new chat keeps the old chat's model, effort and permission mode
(no asking again); it takes the old chat's title ("Same title"); the old chat stays in
history and usable, with its reply stopped and its process freed. So `agentland-host chats
continue -- <prompt>`, run by a Claude Code chat's tool, has the host start a new Claude Code
chat in the same workspace with the prompt as its first message, and the old chat names it.

- **The op**, on the same socket (`terminals-local.sock`, this user's processes only; no HTTP
  route continues a chat this way): the CLI sends `{op: "continueChat", chat, prompt,
  version}` within 2 s; the host answers `{id}` (the new chat's ID) or `{error: {code,
  message}}`, and hangs up. `chat` is the chat whose process runs the command
  (`$AGENTLAND_CHAT`).
- **Checks**, refusing in this order: `terminals_unavailable` when the host runs no Claude
  Code chats; `version_mismatch`; `invalid_request` for a prompt as the terminal continue
  refuses it (empty once trimmed, over 4096 bytes, not UTF-8, any control character, or
  starting with `-`); `chat_not_continuable` when `chat` is not a chat ID, not a Claude Code
  chat (Codex chats share one app-server process and are not continued), a chat the host does
  not have, a plain chat of the Chats space, in a workspace since removed, or deleted from the
  archive; then, while Claude Code cannot run Chat (subscriptions only, "Chat in workspaces",
  Subscriptions and refusals), `terminals_unavailable` with the provider's message. Then the
  new chat is made and its prompt sent as `POST /v1/sessions` and `POST /v1/messages` do:
  `terminal_limit` (here: six Claude Code chats are working, the 429 `agent_capacity` of a
  send), `host_stopping`, else `terminals_unavailable` (Claude Code reported an API key, did
  not confirm the prompt in time, or did not start). On any refusal nothing is recorded, and a
  new chat already made is removed (from the chats, the event stream and the archive, whose
  change feed then carries its delete).
- **The new chat** is a Claude Code chat of the old chat's workspace, titled with the old
  chat's current title with `titleSource` `provider`, so the host's free naming never renames
  it (a device can still rename it). Its model, mode and effort are the old chat's, as a create
  with them sets them. The prompt, trimmed, is its first user message, delivered as a device's
  send is (no device, no attachments; archived and in its event stream as usual). The host logs
  one line, `chats: continued id=<old> in id=<new> workspace=<workspace>`, and never the
  prompt.
- **`continuedIn` and `continuedAt`** on the old chat's `ChatInfo`: the new chat's ID and when
  (UTC RFC 3339 with milliseconds), saved in the chat's record so they outlive host restarts,
  in its `snapshot`, and sent at once to anyone following it as `chat.updated`. A chat
  continued again names the newest. Omitted until a chat has continued.
- **The close-out**, after the answer and never holding it up: the old chat's turn (the one
  whose tool ran the command) has 10 s to end on its own; if it has not, it is stopped as
  `POST /v1/abort` does (its reply ends `aborted`). Then the old chat's process stops, freeing
  its place among the six; its next send starts one again. A turn that began meanwhile (someone
  sent to the old chat) is left alone.
- **The CLI**: `agentland-host chats continue [--state <host.json>] -- <prompt>`. `--state`
  defaults to `$AGENTLAND_HOST_STATE`, else the default state. It waits at most 90 s (the host
  may check the sign-in, start Claude Code and wait for the prompt's echo first) and prints
  only the new chat's ID and a newline on stdout. Exit codes: 0 success; 5 when this chat
  cannot be continued here (no `$AGENTLAND_CHAT`, the socket missing or refusing the
  connection, or `chat_not_continuable`), so the caller goes on its own way; 2 usage; 1 any
  other failure, with the host's message on stderr.
- **The apps**: a tab that was showing the chat when it continued follows it; a chat opened
  from history afterwards does not redirect.

### Mac-only terminal routes

These routes see every device's terminals, for the Mac app's Quit question, its Terminals
settings pane and device removal. They answer only this Mac's own session (a device token gets
403 `local_only`), are refused through the remote-access tunnel (403 `tunnel_refused`) and are
never offered to the web app. Without `--enable-terminal` they answer 403 `terminal_disabled`.

| Route | Body | Response |
|---|---|---|
| `GET /v1/terminals/running` | | `{running: n, routed: n}`, running terminals across all devices, and how many of them are routed agents typed in Terminal on the Mac (2026-10-15; `end-all` keeps those running there). Answered from the host, never waits for the keeper; 503 `terminals_unavailable` while the terminal service can't be used, so a count is never read as none |
| `POST /v1/terminals/end-all` | `{}` | `{ended: n, released: n}`. Ends every running terminal in parallel as `hostStopped`, within 10 s (those not ended by then are not counted); the terminals stay listed, ended. A running routed agent is released to its Terminal window instead (`keptInTerminal`, counted in `released`, 2026-10-15) and cleared |
| `GET /v1/terminals/all` | | `{keeper: {state: running\|none\|unavailable, reason?, adopts?}, terminals: [MacTerminal]}`, oldest first |
| `POST /v1/terminals/end` | `{terminalId}` | `{ended: true}`. Ends it as `endedOnMac`; it stays listed so its device sees the end (a routed agent is cleared at once). 404 `terminal_not_found`, 409 `terminal_not_running` |
| `POST /v1/terminals/clear` | `{terminalId}` | `{cleared: true}`. The keeper forgets a finished terminal and the host drops it. 404 `terminal_not_found`, 409 `terminal_running` |
| `POST /v1/terminals/end-device` | `{deviceId}` | `{ended: n}`. Ends that device's running terminals as `deviceRemoved`, then forgets and drops all its terminals, running or finished. The device itself is removed separately. 400 `invalid_request` for `local-mac` ("This Mac's terminals are never ended with a device's") |

```text
MacTerminal { id, deviceId, deviceName, deviceRemoved, projectId, workspace, program,
              title, status: running|exited|disconnected, startedAt, endedAt?, reason?,
              routed, rows?, cols?, cursor, contextTitleSource? }
```

`title` is the display title (`contextTitle`, else `programTitle`, else `title`).
`routed` (2026-10-15) is true for a coding agent typed in Terminal on the Mac; its `deviceName`
is "This Mac", like every terminal the Mac opened, and `projectId` and `workspace` are "" when it
runs outside any workspace.
`rows`, `cols`, `cursor` and `contextTitleSource` (2026-10-16) are what the Mac app reads to
name every terminal ("Contextual terminal names"): the size a device created or last resized the
terminal to (omitted while the host has seen none: a terminal restored after a host restart, a
routed agent), the output cursor after its newest byte, and where its `contextTitle` came from
(`program` or `device`, omitted without one). Older hosts list none of them.
`deviceRemoved` is true when the Mac has no such device or it was revoked. Times are RFC 3339
UTC with milliseconds; `reason` is the `ended.reason`. `keeper.state` is `none` when no keeper
runs (its terminals are gone) and `unavailable`, with a short `reason`, while the keeper cannot
be used. In that state `end`, `clear`, `end-device` and `end-all` answer 503
`terminals_unavailable`; `running` and `all` still answer from the host's own list.
`keeper.adopts` is present only with `state: running`: true when the keeper takes routed
agents' terminals, false for a keeper from an AgentLand before that which still holds
terminals. The host leaves such a keeper alone and routing cannot start until those terminals
end (or `terminals stop`, or Quit's End Terminals); an idle one is stopped and replaced at once
while the switch is on, so false is only seen with terminals in it. The Mac's routing switch
says so while it is on.

### Agent terminal preparation

With automatic updates enabled, creating a new named agent terminal first updates the agent:
supported native Codex/Claude Code through their own updaters, or, for a managed agent, a fresh
bounded, ETag-aware registry read and an install of a newer version. Shell terminals keep their
existing behavior. Since 2026-10-17 (owner: "Update at most once an hour when a terminal starts
the agent. If the update fails or takes too long, start the version already installed and show a
short notice."):

- **At most hourly.** A launch updates the agent only when no automatic attempt for it (one made
  before a launch or by the background run, whatever its result) started in the last hour; the
  same rule holds for a managed agent's registry read. A manual Update Now does not count. The
  record is kept in memory, so a host start may update once more.
- **Never refused for an update.** The launch waits at most 30 seconds for the update, its own or
  one already running that it joins. When the update fails, the terminal starts with the version
  already installed and `TerminalInfo.updateNotice` says so ("Couldn't update Codex; started the
  installed version."). When it has not finished in time, the terminal starts the installed
  version too ("Couldn't update Codex in time; started the installed version."): an update that
  rewrites the agent in place (Codex's own updater, Claude Code outside its native `versions`
  folder) is stopped first, its process group ended within a second, so nothing changes the agent
  while the terminal starts, and the next attempt runs the updater again; an update installed
  beside the running version (managed registry installs, Claude Code's native installer) goes on in
  the background ("Claude Code is still updating; started the installed version."), and the
  terminal keeps the version it started with. After an update that finished, the launch resolves
  the updated executable.
- `agent_update_failed` and `agent_update_timeout` (409) are no longer sent; clients keep reading
  them for older hosts. Creation is refused only when the request ends (no answer), the host stops
  (503 `host_stopping`), or the agent is being installed, uninstalled or rolled back (409
  `agent_busy`, "No terminal was created" in the clients' words).

Authenticated named-agent creation requests extend their HTTP read/write deadlines through
preparation (its wait plus 30 seconds) and restore the normal write window afterwards, so the
listener's 35-second write limit does not lose the creation response. The per-agent reservation
remains held until PTY registration, except after a slow update left running beside the installed
version.

A running chat turn of the agent defers its update. A running terminal of the agent defers it
only when its updater replaces the agent in place (Codex's own updater; Claude Code outside its
native `versions` layout). Agents installed beside the running version (registry installs,
managed OpenCode, Claude Code's native installer with its `versions` folder) update while their
terminals run, and those terminals keep the version they started with. While the terminal
service can't be read, every agent with terminals defers. A deferred update launches the
installed version, returning optional `TerminalInfo.updateNotice` explaining the deferral. Unsupported updaters also
return a notice. Existing terminals and working chat processes are never stopped for this
preparation. Managed OpenCode switches its current install without restarting the daemon.
A canceled preparation creates no PTY. Explicit manual updates remain independent of policy.

**The switch decides.** While it is on, AgentLand updates Claude Code and Codex whatever their own
settings say (owner, 2026-10-17: "AgentLand's switch"): the host never reads `~/.claude.json` or
Codex's configuration for this. Only the environment opt-outs `DISABLE_AUTOUPDATER` and
`CLAUDE_CODE_DISABLE_AUTOUPDATER`, set for the host, still turn Claude Code's updater off (it then
counts as unsupported).

**Update log.** Every update attempt, automatic or manual, writes one line to the host's log (its
stderr, which the Mac app keeps in `~/Library/Logs/AgentLand/host.log`): the agent, what started
it (`pre-launch`, `background` or `manual`), its version before and after, and the result:
`updated`, `already current`, `failed: <reason>`, or `skipped: <why>` (an attempt within the
hour, the agent busy, no supported updater). For example
`agents: codex update (pre-launch): 0.162.1 → 0.163.0, updated`. A launch that skips or defers
its update logs why; the background run logs a busy agent once a run. The line never holds the updater's
output, an environment or a path; a reason is the host's own words, and a version that is not a
plain version word shows as `unknown`.

## Agents

Owner decisions (2026-09-26, docs/AGENT-CATALOG-PLAN.md): every agent of the Agent Client
Protocol (ACP) registry can be installed on tap; installed agents update themselves daily and
at launch, each only while it is idle, after a check that uses no model; agents already on
the Mac show without installing; OpenCode's providers are listed from OpenCode itself. The
host keeps the catalog, installs, updates and runs ACP chats; devices never contact the
registry or its CDN. Everything here is advertised as `capabilities.agents` (below); `serve`
keeps the catalog unless it runs with `--no-agents`, and a host without it answers the routes
of this section with 501 `agents_unavailable`.

| Route | Body / query | Answer |
|---|---|---|
| `GET /v1/agents` | — | `{registry{fetchedAt?, error?}, agents:[Agent]}` |
| `GET /v1/agents/icon` | `id` | the agent's icon (SVG or PNG); 404 `not_found`; 503 `icon_unavailable` |
| `POST /v1/agents/install` | `{id, allowUnverified?}` | 202 Agent |
| `POST /v1/agents/uninstall` | `{id}` | 202 Agent |
| `POST /v1/agents/update` | `{id, allowUnverified?}` | 202 Agent |
| `GET /v1/providers` | — | `{providers:[{id, name, connected, models, env}]}`; 503 `provider_catalog_unavailable` |
| `POST /v1/agents/opencode/failed` | `{version, reason?}` | `{rolledBack, current}`; the Mac's own session only |

They are paired-device routes like the chat routes: bearer authentication, also through the
remote-access tunnel socket and for the Mac's own session. Two fields of the `opencode` entry
are for the Mac's own session only (below), and so is `POST /v1/agents/opencode/failed`
("When the managed OpenCode does not start" below): other callers get 403 `local_only`.

### The catalog (`GET /v1/agents`)

```json
{
  "registry": {"fetchedAt": "2026-09-26T20:00:00.000Z", "error": "The registry could not be reached."},
  "agents": [{
    "id": "gemini", "name": "Gemini CLI", "description": "Google's official CLI for Gemini",
    "website": "https://geminicli.com", "license": "Apache-2.0",
    "source": "registry", "state": "installed",
    "installedVersion": "0.61.0", "latestVersion": "0.62.0", "previousVersion": "0.60.1",
    "updatedAt": "2026-09-26T20:02:11.000Z",
    "chat": true, "terminal": true, "verified": true
  }]
}
```

```text
Agent { id, name, description?, website?, license?, source: registry|local|bundled,
        state: notInstalled|installing|installed|updating|uninstalling|failed,
        installedVersion?, latestVersion?, previousVersion?, updatedAt?, lastError?, autoUpdates?, supportsUpdates?,
        chat, terminal, verified, supported?,   // supported: only ever false
        updateWaitingTerminals?,                // int, omitted when 0
        restartWanted?, idleForSeconds? }       // the opencode entry, the Mac's own session
```

- `registry.fetchedAt` is when the host last read the registry (a `304 Not Modified` counts),
  absent before the first read. `registry.error` is present only when the last attempt failed;
  the list then comes from the last copy the host kept.
- `id` is the name every other part of the API uses for the agent: `chatProviders`,
  `terminalPrograms`, a chat's `provider` and `agentCatalog`. Registry ids are used as they
  are, except that `claude-acp`, `codex-acp` and `opencode` are the native `claude`, `codex`
  and `opencode` (next), never listed twice.
- `source`: `registry` (AgentLand installs and updates it) or `local` (found on the Mac; for
  supported Codex and Claude Code installs AgentLand runs the CLI's own updater). `bundled` is sent only by older hosts, for the OpenCode the Mac
  app used to ship (owner's decision, 2026-09-27: the Mac app ships none, and this host never
  sends it); clients keep decoding it.
- `state`: `notInstalled`; `installing` while a first install runs; `installed`; `updating`
  while an update runs (the current version keeps working); `uninstalling` while an uninstall
  runs (afterwards the agent is `notInstalled`, or no longer listed when the registry does not
  list it, or has `lastError` when its files could not all be removed); `failed` when the last
  install of an agent that has no version failed. A failed update or check leaves the agent
  `installed` with `lastError`.
- `installedVersion` is the version in use; `latestVersion` the registry's; `previousVersion`
  the version kept for going back (registry installs only). Each is omitted when absent; so
  are `description`, `website` (the registry's website, else its repository) and `license`
  when the registry gives none, and `updatedAt` (when a registry version was installed, or
  when a local native updater last completed successfully; a local timestamp means it checked
  for updates, not necessarily that it installed a new release) and
  `lastError` (present only after a failed install, update or check, until the next one
  succeeds).
- `chat`: it can run chats: through ACP, or AgentLand's own adapter for OpenCode, Claude Code
  and Codex. `terminal`: it has a command for a terminal tab (below). Both describe the agent
  whether or not it is installed; `agentCatalog` lists the usable ones.
- `verified`: the download this Mac uses is checked against the registry's `sha256`, or is an
  npm or uv package pinned to its version. `false` for a binary without `sha256`, and for an
  agent with `supported: false`. `local` agents are `true` (AgentLand downloads nothing for
  them).
- `supported`: present only as `false`, on a registry agent that is not installed and whose
  registry entry offers nothing that runs on this Mac (no `npx`, no `uvx`, no `binary` for
  this platform). Its `verified` is then `false`, install answers 400
  `unsupported_platform`, and the apps offer no Install. Absent on every other agent, so
  older clients see nothing new.
- `supportsUpdates`: optional updater capability, independent of policy; true for installed
  managed agents and supported local Codex or Claude Code native updaters. Manual Update Now
  remains available while automatic updates are off. Claude updater opt-outs are honored.
- `autoUpdates`: true only when this host's automatic-update setting is enabled and the
  installed agent supports updates; absence means false.
- `updateWaitingTerminals`: while an automatic update of an in-place updater waits, how many of
  the agent's terminals still run; omitted when 0. Older hosts never send it.
- Top-level `automaticUpdates` is this host's persisted Boolean, off by default. Older hosts
  omit it. `capabilities.agents` advertises `updateSettings` when supported.
- `POST /v1/agents/settings` accepts the required Boolean `{ "automaticUpdates": true }`
  and responds 200 with that Boolean. Missing, null, or non-Boolean input is 400
  `invalid_request`. It requires the same authentication as other agents routes, including
  paired devices. Saving preserves projects, pairing, device authentication and other state.
  Clients refresh the catalog after saving; unavailable older hosts receive no settings POST.
- Paths, commands and environments never leave the host. The list is sorted by name,
  ignoring case.

Which agents are listed:

- **Registry agents**: every valid entry of the registry (below). A managed install of one is
  `source: registry`; an agent the registry no longer lists stays listed while it is installed.
- **Local agents**, found on the Mac in `/opt/homebrew/bin`, `/usr/local/bin`,
  `~/.local/bin` and `PATH`, then in the folders of Node.js and tool version managers:
  `~/.volta/bin`, `~/.asdf/shims`, `~/.local/share/mise/shims`, fnm's default alias
  (`~/.local/share/fnm/aliases/default/bin`, then `~/Library/Application
  Support/fnm/aliases/default/bin`) and nvm's default version (the version
  `~/.nvm/alias/default` names under `~/.nvm/versions/node/`, following nvm's aliases, else
  the highest version there). Only regular executable files count (links followed), and in
  the version managers' folders only folders this user owns. The ids:

  | Command | `id` | `chat` |
  |---|---|---|
  | `claude` | `claude` | AgentLand's Claude Code chats |
  | `codex` | `codex` | AgentLand's Codex chats |
  | `gemini` | `gemini` | ACP |
  | `qwen` | `qwen-code` | ACP |
  | `goose` | `goose` | ACP |
  | `copilot` | `github-copilot-cli` | ACP |
  | `cursor-agent` | `cursor` | ACP |
  | `kimi` | `kimi` | ACP |
  | `droid` | `factory-droid` | ACP |
  | `amp` | `amp` | none (the registry's `amp-acp` is a separate adapter) |
  | `vibe` | `vibe` | none (the registry's `mistral-vibe` runs `vibe-acp`) |

  A local agent marked ACP runs chats with the arguments and environment the registry gives its
  id for this Mac, so it chats only once the registry has been read and lists that id. Its
  `installedVersion` is the first version-like word of `<command> --version` (5 s, 4 KiB of
  output, cached per file and modification time); Claude Code's is read from its path, as its
  chats do, and it is never run for it. When a registry install of the same id exists, it is
  listed instead (`source: registry`).
- **`claude` and `codex`** are always `local`: `installed` when the command is on the Mac,
  else `notInstalled`. They take the registry's icon of `claude-acp` and `codex-acp` but
  nothing else of those entries (the adapter's version and license are not the CLI's).
  Install and uninstall answer 409 `not_managed`. Update is accepted only when the installed
  CLI's own `update --help` identifies that native command; older unsupported installs answer
  `not_managed` and are never run with a bare `update` argument.
- **`opencode`** is always listed, and always a registry agent (`source: registry`), installed
  or not: `installed` once a managed OpenCode is installed; `installing` while the host
  installs it ("OpenCode without a managed install" below); `failed` with `lastError` when
  that failed; else `notInstalled`. An `opencode` command found on the Mac is not its entry
  (the OpenCode terminals may still use one for `opencode attach` until a managed OpenCode is
  installed). Its `latestVersion` is the registry's. Install and update work as for every
  registry agent; uninstall answers 409 `agent_required`.

The two fields for the Mac's own session, on the `opencode` entry only:

- `restartWanted`: `true` when a managed OpenCode is current and it is newer than the OpenCode
  the host talks to (the version it last reported), so the Mac app should restart OpenCode and
  the host when nothing runs; otherwise `false`.
- `idleForSeconds`: how long nothing has run: no running OpenCode terminal (only OpenCode's
  own terminals share its process and storage; shells and other agents' terminals don't
  count), no chat turn running or waiting for an answer (OpenCode, Claude Code, Codex and ACP chats), and no device viewing a
  chat (a presence `view` reported in the last 45 s). `0` while something runs. OpenCode's
  chats count as running while its session status query fails or takes longer than 2 s for
  any workspace, since a stuck OpenCode may be in the middle of a turn. The host samples this
  every 15 s and at each request, so it is accurate to about 15 s.

### When the managed OpenCode does not start

The Mac app tells the host, with its own session only (a paired device, and anything through
the tunnel socket, gets 403 `local_only`):

```json
POST /v1/agents/opencode/failed
{"version": "1.18.33", "reason": "it exited with status 1"}
```

- `version` is the managed OpenCode's version that did not start (a registry version: 1–64
  letters, digits, `.`, `_`, `+` and `-`); `reason` is optional text of at most 600 bytes that
  the owner reads in `lastError` (line breaks become spaces, paths under the home folder show
  as `~/…`). Anything else answers 400 `invalid_request`.
- When `version` is the current managed version (`current.json`, compared without case):
  - if a previous version is kept and intact (its folder is there and its program still
    passes the checks in "OpenCode" above, its `sha256` included), `current.json` goes back to
    it, with no `previous` of its own;
  - the version is remembered (`opencode/failed.json`), and automatic updates skip it until
    the registry offers another version; then it is forgotten. The owner's Install and Update
    Now still install it;
  - the `opencode` entry's `lastError` says so: "OpenCode 1.18.33 did not start on this Mac:
    it exited with status 1. Back to 1.18.32." ("Back to …" only after going back);
  - `restartWanted` then follows from the running version as usual.
- The answer is 200 `{"rolledBack": true|false, "current": "<the current version after it, or
  empty with none>"}`. For a version that is not current it is 200 with `rolledBack: false`
  and nothing changes. 409 `agent_busy` while another change of OpenCode runs (an install or
  update): report it again when that ends. 501 `agents_unavailable` without the catalog.

### The registry

- The host reads `https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json` with
  `User-Agent: AgentLand-host/<host version>` and `Accept: application/json`, and with
  `If-None-Match` when it holds a copy; no cookies and nothing about the owner or the Mac.
  Redirects are followed only to `https` (5 at most); the answer is at most 4 MiB and 30 s.
- It is read at each automatic update run (below), and when `GET /v1/agents`, an install or
  an update finds the kept copy older than an hour (in the background: the answer comes from
  the copy). A request that finds no copy at all waits up to 10 s for the first read. After a
  failed read the host waits a minute before it tries again.
- The last good document is kept in `<state>.agents/registry.json` (mode 0600, the state
  folder's `.agents` folder is 0700) with its ETag, and read at start. A document whose
  `version` is not `1.x`, or that is not a JSON object with an `agents` array, is refused and
  the copy kept.
- Each entry is checked; one that fails is left out, the rest are kept:
  - `id`: 1–64 characters of lowercase letters, digits, `.`, `_` and `-`, starting with a
    letter or digit, and not ending in `.json`, so no id names a file the host keeps beside
    the agents' folders (`registry.json`); every route, chat ID and folder of the host follows
    the same rule. A repeated id is left out. `name`: 1–100 characters without control
    characters. `version`: 1–64 letters, digits, `.`, `_`, `+` and `-`, starting with a letter
    or digit.
  - `description` is cut to 1000 characters; `website`, `repository` and `icon` must be
    `https` URLs of at most 512 bytes without user information (else dropped); `license` is
    dropped over 100 characters.
  - `distribution` needs at least one valid kind:
    - `npx {package, args?, env?}`: an npm package name (optionally scoped) and a full
      version: three numbers with optional pre-release or build parts
      (`@google/gemini-cli@0.61.0`, `1.2.3-beta.1`). `1`, `1.2` and `1.x` are ranges to npm
      and are refused. A package without a version is pinned to the entry's `version`, which
      must then be such a version.
    - `uvx {package, args?, env?}`: `name==version` or `name@version` with an exact version
      (a package without one is pinned to the entry's `version`).
    - `binary {<platform>: {archive, cmd, args?, sha256?, env?}}`: `archive` an `https` URL
      whose path ends in `.zip`, `.tar.gz`, `.tgz`, `.tar.bz2` or `.tbz2`; `cmd` a relative
      path without `..`; `sha256` 64 hexadecimal digits.
    - `args`: at most 32 non-empty strings of at most 1024 bytes; `env`: at most 32 names
      (`[A-Za-z_][A-Za-z0-9_]*`, at most 128 bytes) with values of at most 4096 bytes, never
      NUL.
- At most 2,000 entries are kept: the first valid ones in the document's order (the registry
  listed 41 on 2026-09-26). Later entries are not read.
- **Distribution choice.** The platform is `darwin-aarch64` or `darwin-x86_64` for the host's
  architecture (`linux-…` and `windows-…` for the command-line builds). In order: this
  platform's `binary` with `sha256`; `npx`; `uvx`; this platform's `binary` without `sha256`
  (not verified). An agent with none of these for this Mac is listed with `supported: false`
  while it is not installed, and answers install with 400 `unsupported_platform`.
- **Icons.** The host fetches each listed agent's `icon` (after a registry read, one at a time,
  and on demand when `GET /v1/agents/icon` finds none, waiting up to 5 s) under the same rules
  (https only, at most 256 KiB and 15 s) and keeps it in `<state>.agents/.icons/`, at most
  64 MiB in all: an icon that would pass that is not kept, and none is fetched once it is
  reached. After each registry read the icons of ids it no longer lists are removed. Only SVG
  (text that holds `<svg`) and PNG (by its signature) are kept. `GET /v1/agents/icon?id=` serves
  it with `Content-Type: image/svg+xml` or `image/png`, `X-Content-Type-Options: nosniff`,
  `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; sandbox`,
  `Cache-Control: private, max-age=86400` and an `ETag`; `claude` and `codex` serve the icons of
  `claude-acp` and `codex-acp`.
- **404 `not_found`** means there is no icon to give, and devices may take it as final for the
  connection: an unknown agent; one whose registry entry names no icon, or that the registry
  no longer lists; or an icon the server answered with a 4xx status other than 408 and 429,
  that is neither SVG nor PNG or is over 256 KiB, or that the full cache cannot keep.
- **503 `icon_unavailable`** means the icon could not be fetched in time: no answer within
  5 s, a network failure, or a 5xx, 408 or 429 answer. A read not finished goes on and keeps
  the icon; the device asks again later.

### Installs, updates and uninstalls

`POST /v1/agents/install`, `/v1/agents/uninstall` and `/v1/agents/update` take
`{"id": "…"}`; install and update also take `allowUnverified` (a boolean). They answer 202 with
the Agent as it is then (`installing`, `updating` or `uninstalling` when the change started):
the work runs in the background and `GET /v1/agents` shows its `state` until it ends. Errors:

- 400 `invalid_request`: a body that is not that object (unknown members included).
- 404 `unknown_agent`: an id neither the registry, the Mac nor the managed installs have.
- 409 `agent_busy`: an update or uninstall while one of the agent's chat turns runs or waits
  for an answer, or one of its terminals runs (automatic updates wait for idle instead), or
  any change while another change of the same agent runs. A repeated install while one runs,
  or a repeated update while one runs, answers 202 instead. An install of an agent already
  installed at another version is an update, by the update's rules (this 409 among them), and
  answers `updating`.
- 409 `not_managed`: an install or uninstall of a `local` agent; an update of one other than
  Codex or Claude Code; or an installed Codex/Claude Code whose native updater is unavailable
  or disabled.
- 409 `agent_required`: an uninstall of `opencode`, installed or not. AgentLand's chats need
  OpenCode, so it can be installed and updated but never uninstalled.
- 400 `unsupported_platform`: nothing the registry offers runs on this Mac (see the choice
  above). An npm or uv install for which `npm` (with `node` beside it) or `uv` cannot be found
  (they are found like the local agents) is accepted and fails, with `lastError` saying which
  tool is missing.
- 400 `unverified_download`: the download chosen is a binary without `sha256`. It installs only
  when the body has `"allowUnverified": true`, which the apps send after a confirmation that
  names the source. An agent installed that way keeps updating automatically (`current.json`
  records the consent); an update that would switch a verified agent to an unverified download
  needs the same.
- Install of an agent already installed at the registry's version, update of one already
  current, and uninstall of a registry agent that is not installed answer 202 and do nothing.

Where and how:

- Each registry install lives in `<state>.agents/<id>/<version>/` (folders 0700, files 0600
  or 0700 when executable). `<state>.agents/<id>/current.json` (0600) names the version in use,
  and the Mac app reads it for OpenCode:

  ```json
  {"version": "1.18.32", "command": "/…/host.json.agents/opencode/1.18.32/opencode",
   "args": ["acp"], "sha256": "<SHA-256 of the file command names>",
   "installedAt": "2026-09-26T20:02:11.000Z", "kind": "binary", "name": "OpenCode",
   "env": {"NAME": "value"}, "unverified": false,
   "previous": {"version": "1.18.31", "command": "…", "args": ["acp"], "sha256": "…",
                "installedAt": "…", "kind": "binary"}}
  ```

  `command` is an absolute path inside that folder; `args` are the distribution's (ACP)
  arguments; `sha256` is present for binary installs only and is the SHA-256 of the file
  `command` names (not of the archive); `kind` is `binary`, `npx` or `uvx`; `env` is the
  distribution's own environment (omitted when none); `previous` is the version kept for going
  back. Two versions are kept, the current and the previous; older folders are removed.
  OpenCode also keeps the version the host's OpenCode reports running, until the Mac app
  restarts it; when the host starts, before it can ask, every OpenCode version folder stays
  (only unfinished downloads and checks go).
  Versions that differ only by case are one version (macOS names their folders alike). An
  install or update to the current version does nothing; one to the previous version checks
  the kept folder and makes it current again, the current one becoming the previous. An
  install never removes the current or the previous version's folder.
  `<state>.agents/<id>/status.json` (0600) keeps `lastError` across restarts.
- **binary**: downloaded over HTTPS only (every redirect too), at most 500 MiB and 30 minutes,
  into the agent's folder; its SHA-256 is checked against the registry's before anything is
  unpacked. Unpacking (zip, tar.gz, tar.bz2) goes through a handle on the new folder that no
  path can leave, and refuses an absolute path, a `..` component, a symbolic link whose target
  is absolute or leaves the folder, a hard link to anything but an earlier entry, device and
  pipe entries, more than 100,000 entries or 4 GiB unpacked. Links are checked by name
  (without case on macOS and Windows), then every link of the finished tree is resolved again
  on disk through that handle, as the system resolves it, so another spelling of a name
  (case, Unicode form) cannot lead out: a link that leaves the folder or loops refuses the
  archive, one that leads nowhere is kept. Set-user-ID and similar bits are
  dropped. `cmd` must then resolve, links followed, to a regular file inside the folder, which
  is made executable (0700) when the archive kept no mode for it.
- **npx**: `npm install --prefix <folder> --no-audit --no-fund <package@version>`, at most 10
  minutes. The command is `<folder>/node_modules/.bin/<bin>`, where `<bin>` is the package's
  only bin, or the one named like the package (without its scope). The agent never runs
  through `npx`. It runs with the found `node`'s folder first in `PATH`.
- **uvx**: `uv tool install <package>` with `UV_TOOL_DIR=<folder>/tools` and
  `UV_TOOL_BIN_DIR=<folder>/bin`, at most 10 minutes; the command is the only executable in
  `<folder>/bin`, or the one named like the package.
- Installers run in the folder with a clean environment: `PATH` (the tool's folder first),
  `HOME`, `USER`, `LOGNAME`, `TMPDIR` and `LANG`, nothing else: no provider keys and none of
  AgentLand's secrets. Only one change of an agent runs at a time; stopping the host cancels
  them and removes their unfinished folder. What npm, uv or the download said is kept only as
  the last 4 KiB for `lastError`, which says what failed in one line and never includes
  environment values: for npm its first error line that gives a reason (not its code, errno,
  syscall or path lines, nor the notice of its log file), else the tool's last line. Paths
  under the Mac user's home folder (and the installers' `HOME`) show as `~/…` in `lastError`.
- **The check.** Before a new version becomes current, the host starts it and checks it: an
  ACP agent is sent `initialize` (`protocolVersion` 1, no client capabilities:
  `{"fs": {"readTextFile": false, "writeTextFile": false}, "terminal": false}`), and must
  answer with `protocolVersion` 1 within 20 s; no session is made and no model is called.
  OpenCode's check is stronger: `opencode serve --pure --hostname 127.0.0.1 --port <free
  port>` with throwaway `HOME`, `XDG_*` and `TMPDIR` folders (`OPENCODE_TEST_HOME` too) and a
  random password (`OPENCODE_SERVER_PASSWORD`), `OPENCODE_DISABLE_AUTOUPDATE=true`; it must
  answer `GET /global/health` healthy with the version being installed within 30 s, then
  `GET /session` and `GET /provider`; no model is called, and the process and the folders are
  removed afterwards. First installs are checked the same way. A version that fails is
  removed, the agent keeps its current version (or stays not installed: `failed`), and
  `lastError` says why.
- **Uninstall** stops the agent's idle chat processes and removes `<state>.agents/<id>/`
  whole. Its chats stay; sending to them answers 503 `agent_unavailable` until it is installed
  again (or found on the Mac).
- **Automatic updates.** Updates are off by default and require the persisted host setting.
  Essential first managed OpenCode installation and explicit installs/updates work while off.
  When enabled, the first run is 2 minutes after the host starts, then every 24 hours
  plus a random 0–60 minutes. The same run includes installed local Codex and Claude Code,
  independently of whether the registry read succeeds. For each it first runs the exact
  executable with `update --help` for at most 5 s and requires its command-specific usage
  (`codex update` or `claude update|upgrade`); the result is cached by the resolved executable
  identity. Claude's updater opt-out is honored. A supported updater runs as the exact path
  with the literal `update` argument, a clean allowlisted environment, its own process group,
  bounded output that is never exposed in errors, a 10-minute limit, and host-shutdown
  cancellation. Success sets local `updatedAt` and clears `lastError`; failure keeps the
  install and records a bounded error without command output.

  A run also reads the registry, then, for each registry install whose
  version differs from the registry's: it waits until the agent is idle (looked at every
  minute until the next run: none of its chat turns running or waiting for an answer, none of
  its terminals running; for OpenCode also no OpenCode chat turn, and an OpenCode whose session
  status query fails or takes longer than 2 s is busy), installs the new version
  beside the current one, checks it, points `current.json` at it keeping the current one as
  `previous`, and removes older folders. A failure keeps the current version, removes the new
  folder, sets `lastError` and is tried again at the next run. The same idle and one-operation
  rules cover native updates, including native chat turns and terminals. After a successful
  native update, idle Claude processes and Codex's idle app-server retire; their saved
  sessions and threads resume through the existing reload path. The Codex janitor also
  notices an externally replaced executable and retires the old app-server at the next safe
  idle boundary, without requiring a host restart.
- **OpenCode without a managed install.** Owner's decision (2026-09-27): the Mac app ships no
  OpenCode; it runs only the managed one. While no managed OpenCode is valid (no
  `opencode/current.json`, or one that fails the checks below), the host installs the
  registry's `opencode` at once: when `serve` starts, with no 2-minute wait and no wait for
  idle (nothing of OpenCode's can run yet), then at each automatic update run until it has
  one. It installs only a binary checked by the registry's `sha256`; any other download (and
  a registry that offers nothing for this Mac) waits for the owner's Install, with
  `lastError` on the entry. A record that fails the checks is installed again from the
  registry. It goes through Install's path with OpenCode's check (above); the entry shows
  `installing` meanwhile. A failure sets `lastError` (the registry could not be reached, the
  download or its check failed) and is tried again at the next run; the owner's Install works
  at any time. Before it starts OpenCode, the Mac app runs `agentland-host install-opencode`,
  which does the same ("install-opencode" below). Once installed, OpenCode updates as every
  registry agent does (above).
- **OpenCode.** A managed OpenCode takes effect when the Mac app restarts OpenCode and the
  host, which it does when `restartWanted` is true and `idleForSeconds` is at least 600, or at
  its next launch (a host that gives no `idleForSeconds` counts as never idle). The Mac app
  runs the managed one, with `serve` (it ignores `args`), only when all of this holds; the
  host's own checks of a managed OpenCode (at start, in the update runs and in
  `install-opencode`) are the same:
  - `<state>.agents` and every folder under it down to the version folder belong to this
    user, are 0700 and are not links (the host makes them so);
  - `opencode/current.json` is a small regular file (at most 64 KiB) that group and others
    cannot write;
  - its `command` resolves, links followed, to a regular executable inside `opencode/`, owned
    by this user and not writable by group or others, at most 1 GiB (`command` may be
    absolute, or relative to `opencode/<version>/` or `opencode/`; the host writes it
    absolute);
  - `sha256` matches that file. The host always records it for OpenCode (every binary
    install), also when the download was checked against the registry.

### install-opencode

The Mac app ships no OpenCode, and it starts OpenCode before it starts the host. So on a first
launch, and whenever the managed OpenCode is missing or damaged (it fails the checks above), it
first runs the host's one-shot command:

```text
agentland-host install-opencode --state <path to host.json>
```

- **What it does.** With a managed OpenCode that passes every check above (the program's
  `sha256` included), it reports `ready` at once and downloads nothing, even when the registry
  offers a newer version (`serve` updates it). Otherwise it reads the registry and installs the
  registry's `opencode` through Install's path: a binary checked by the registry's `sha256`
  only (any other download is refused), then OpenCode's check, then `current.json`. A record
  that fails the checks is installed again. It keeps the catalog's limits (the registry 4 MiB
  and 30 s, the download 500 MiB and 30 minutes, the check 30 s) and the check's clean
  environment, fetches no icons, and first removes what an install stopped midway left
  (unfinished downloads and checks). SIGINT or SIGTERM stops it; the unfinished version is
  removed. A failure is kept as OpenCode's `lastError`, which the host shows when it runs.
- **Before `init`.** It never reads or writes `host.json`: on a first launch the Mac app runs
  it before `agentland-host init`, when only the state's folder exists (it is made, 0700, when
  missing). It makes only `<state>.agents/` and `<state>.serve.lock`; `init` and `serve` on the
  same path take both as they are.
- **The state's lock.** `serve` holds `<state>.serve.lock` (a private 0600 file, locked with
  `flock`, `LockFileEx` on Windows) for as long as it runs, and `install-opencode` for as long
  as it installs. Each fails at once while the other holds it: `install-opencode` with `busy`,
  `serve` with an error that names the state. The system lets go of the lock when the process
  ends. The Mac app never runs `install-opencode` while its host runs.
- **Output**: one JSON object per line on stdout, and nothing else there:

  ```text
  {"event":"registry"}                                          reading the registry
  {"event":"downloading","version":"1.18.32","received":N,"total":M}
  {"event":"checking","version":"1.18.32"}                      OpenCode's check
  {"event":"ready","version":"1.18.32"}                         exit status 0
  {"event":"failed","code":"…","error":"…"}                     exit status 1
  ```

  `downloading` comes when the download starts (`received` 0), then at most every half second,
  and when it ends; `total` is omitted when the server gives no length. The last line is
  `ready` or `failed`, and only one of them is written. `error` is one line for the owner, at
  most 1000 characters; it never holds secrets or environment values, and paths under the
  home folder show as `~/…`. Clients skip event kinds they do not know.
- **Codes** of `failed`:

  | `code` | Meaning |
  |---|---|
  | `busy` | another process holds the state's lock: a host runs on this state |
  | `offline` | the registry (with no copy kept) or the download could not be reached: no answer in time, a name that did not resolve, a connection refused or cut |
  | `registry_unavailable` | with no copy kept, the registry answered with an error or a document this host cannot read; or it lists no OpenCode |
  | `unsupported_platform` | the registry's OpenCode offers nothing for this Mac |
  | `unverified_download` | its download for this Mac is not a binary with `sha256`; the owner's Install, with its confirmation, can install it once the host runs |
  | `download_failed` | the download answered with an error, was over 500 MiB, was sent to an address that is not https or did not match its `sha256`, or its archive was refused |
  | `check_failed` | OpenCode's check failed: it did not start, did not answer within 30 s, reported another version, or did not list its sessions and providers |
  | `storage_error` | the state's folders, its lock or the record could not be made or written |
  | `cancelled` | SIGINT or SIGTERM stopped it |
  | `invalid_arguments` | a command line it does not take |

### Terminals for agents

`terminalPrograms` (when the host runs terminals) is `shell` and every usable agent with a
terminal command. Clients still send only the `id` as `program`:

- a registry install: its `command` without its ACP arguments, only when the distribution has
  arguments (a binary or package whose command is itself only an ACP server, with no arguments,
  has no terminal), with the distribution's `env` and, for npm, the `node` folder first in
  `PATH`;
- a local agent: its command, without arguments;
- `opencode`: `opencode attach` to the host's OpenCode (unchanged), with the managed OpenCode's
  command when one is installed.

A terminal records its program, so updates and uninstalls know which terminals are the
agent's.

### ACP chats

Chats with any agent whose `chat` is through ACP (the registry installs, and the local agents
marked ACP above). They are kept in the host's chats registry (`<state>.chats.json`) like
Claude Code and Codex chats: the session ID is the agent's catalog id, a colon and 32
hexadecimal digits (`gemini:0f3a…`, as Claude Code's and Codex's are `claude:…` and
`codex:…`), `provider` is the agent's `id`, and the chat's folder is its workspace. Clients may
take a chat's agent from the part of its ID before the colon (as for Claude Code and Codex)
when the session is not at hand.

- **Create**: `POST /v1/sessions` with `provider` set to the id → 201 Session. 503
  `agent_unavailable` when the agent is not usable now; `model`, `mode` and `effort` answer
  400 `unsupported_options` as for Codex. A chat created without a title gets the agent's name
  with `titleSource` `default`, and so does one created with the agent's name, its id, or
  either followed by " chat".
- **Process.** One process per chat, started when the chat first sends, from the agent's
  `current.json` command and arguments (or the local command and the registry's arguments), in
  the workspace folder, in its own process group, with a clean environment: the agent's own
  `env`, the owner's `PATH` (with `node`'s folder first for npm installs), `HOME`, `USER`,
  `LOGNAME`, `SHELL`, `TMPDIR`, `LANG` and `LC_*`, and nothing of AgentLand's (no
  `AGENTLAND_*`, no OpenCode password, no provider key). It stops after 10 idle minutes, never
  while an approval waits; stopping ends a running turn (`session/cancel`), closes its input,
  then after 5 s sends SIGTERM to the group and after 5 more SIGKILL. When the host shuts
  down, the input closes and the group gets SIGTERM at once and SIGKILL 1 s later; on macOS
  the next host also ends an agent that a killed host left running (npm installs, which run
  as `node`, too), as it ends a Claude Code or Codex process a killed host left, only when it
  is certainly that process (desktop/README.md, `serve`). Output is JSON-RPC 2.0,
  one message per line of at most 4 MiB; only the last 64 KiB of its stderr is kept, for
  diagnosis, never shown.
- **Protocol.** `initialize` as in the check (30 s here), then `session/new {cwd, mcpServers:
  []}` (60 s), or `session/load {sessionId, cwd, mcpServers: []}` when the agent lists
  `agentCapabilities.loadSession` and the chat has a session ID from an earlier process (what
  it replays is not shown again; a load it refuses falls back to a new session, and the reply
  gets the notice "The agent started a new session and does not remember the earlier
  messages."). The agent's session ID and modes are kept with the chat.
- **Send**: `POST /v1/messages` records the user message and answers `202 {accepted,
  messageId, turnId}` before the agent is contacted, as for Codex; the prompt goes out as
  `session/prompt` with a text block, and an image block (base64, `mimeType`) for each image
  attachment when the agent lists `promptCapabilities.image`. Other attachments are named in
  the text with their host paths, as for Claude Code ("Attached files (read them with your
  tools):"). 409 `agent_busy` while a turn runs; 503 `agent_unavailable` when the agent is not
  usable (nothing is recorded); `model` must be absent or `<id>/default`; `effort` answers 400
  `unsupported_options`; `mode` is taken only when the chat lists modes (400
  `unsupported_options` when it lists none, 400 `invalid_agent_options` for one it does not
  list) and is set with `session/set_mode` before the prompt. Each send ends with one reply;
  nothing is ever sent again.
- **Options**: `GET /v1/chat/options` for an ACP chat, or with `provider=<id>` for a new one:
  `models` is `[{id: "<id>/default", name: "Default", provider: <agent name>}]`,
  `defaultModel` `<id>/default`, `agents` `["build"]`, `modes` the modes the agent listed last
  for the chat (for a new one, for any chat of that agent since the host started) and
  `defaultMode` its current mode; both are absent while none are known, as for OpenCode.
- **Streaming**: each `session/update` maps onto the reply of the running turn (one assistant
  message per turn; at 256 parts it continues in another message of the same turn):
  - `agent_message_chunk`: a text part, with `part.delta`; a new part starts after any other
    kind. Non-text content shows as `[image]`, `[audio]` or `[resource <uri>]`.
  - `agent_thought_chunk`: a reasoning part, likewise.
  - `tool_call` and `tool_call_update`: a tool part per `toolCallId`: `name` the tool's `kind`
    (`read`, `edit`, `delete`, `move`, `search`, `execute`, `think`, `fetch`, `switch_mode`,
    `other`), `title` its title, `status` `pending`, `running` (`in_progress`), `completed` or
    `error` (`failed`), `input` its `rawInput` as compact JSON, or `{"locations": [{"path",
    "line"?}]}` when it has none, `output` its content as text (text blocks; a diff as a
    unified diff of the changed lines of `path`; a failed tool's text goes to `error`) or its
    `rawOutput`. Paths inside the workspace are shown relative to it; others by name only.
    An update replaces only the fields it carries.
  - `plan`: one tool part per turn named `Plan`, a checklist (`[x]` completed, `[~]` in
    progress, `[ ]` pending), as Codex's plan; it completes with the turn.
  - `current_mode_update`: the chat's `mode` (`chat.updated`).
  - `user_message_chunk` (replays), `available_commands_update` and anything unknown are
    ignored.
- **Turn end**: the `session/prompt` answer ends the turn. `stopReason` `end_turn` completes
  it; `cancelled` ends it `aborted`; `max_tokens`, `max_turn_requests` and `refusal` complete
  it with a notice ("The reply reached the model's output limit.", "The agent reached its
  limit of model requests for this turn.", "The model declined to continue this reply.").
  Tools still pending or running then end as errors. Errors end the turn with an error reply
  (`error.code`):
  - `agent_auth_required`: the agent answered `session/new`, `session/load` or
    `session/prompt` with JSON-RPC error `-32000` ("Authentication required"). The error has
    `authMethods`, the names of the agent's `authMethods` from `initialize` (an addition to the
    error object, only here), and its message names them and says to sign in by opening the
    agent in a terminal. The apps offer Open in Terminal with the agent's terminal program.
  - `agent_exited`: the process ended, or did not start or initialize (the message says
    which).
  - `protocol_error`: a line over 4 MiB, or an `initialize` answer without `protocolVersion`
    1; the process is ended.
  - `agent_error`: any other JSON-RPC error; its message is the agent's, at most 4 KiB.
- **Approvals**: `session/request_permission` becomes a permission interaction. Its choices
  are the agent's options: `allow_once` → `once`, `allow_always` → `always`, `reject_once`
  (else `reject_always`) → `reject`; `reject` is always offered, and without a reject option
  it answers `cancelled`. `alwaysLabel` is the agent's own name for its `allow_always` option
  (at most 200 characters) and `alwaysDetail` "<agent name> decides what this allows and for
  how long." `permission.tool` is the tool's `kind`, `title` its title, `detail` its
  locations, `input` its `rawInput` (at most 16 KiB). The answer goes back as `{"outcome":
  {"outcome": "selected", "optionId": "<the option chosen>"}}`. Stop answers every pending
  one `{"outcome": {"outcome": "cancelled"}}` and they resolve `gone`, as do those of a turn
  that ends. There are no question interactions.
- **Stop**: `POST /v1/abort` sends `session/cancel`; the turn ends when the agent answers the
  prompt (`cancelled`), or after 10 s the process is ended and the turn ends `aborted`.
- **Requests the host does not serve.** No client capabilities are advertised, so `fs/*`,
  `terminal/*` and any other request from the agent are answered with JSON-RPC error `-32601`.
- **Not in this round**: rewind and restore (400 `unsupported_operation`), regenerate and fork
  (501 `unsupported_operation`), questions, model pickers.
- Chat names follow "Chat names" as for Claude Code and Codex chats (the registry keeps them);
  the archive, notices, the queue and `POST /v1/chat/continue` treat ACP chats like the
  others.

### Providers (`GET /v1/providers`)

```json
{"providers": [{"id": "anthropic", "name": "Anthropic", "connected": true, "models": 18,
                "env": ["ANTHROPIC_API_KEY"]}]}
```

- Built from the running OpenCode's `GET /provider` (OpenCode 1.18.31 answers `{all:
  [{id, name, source, env, options, models}], default, connected}`, about 6 MiB for 223
  providers; the host reads at most 32 MiB within 15 s, asking for the first workspace). Every
  provider is listed, sorted by name ignoring case: `connected` says whether it is in
  OpenCode's `connected` list, `models` counts its models, `env` lists the environment
  variable names that give it a key (from models.dev), as OpenCode lists them.
- It never includes a key or anything of a provider's `options`.
- 503 `provider_catalog_unavailable` when OpenCode does not answer, or answers something else.

## Files

| Route | Contract |
|---|---|
| `POST /v1/files/move` | `{projectId, from, to}` → 200 entry at `to`; never replaces: 409 `file_exists` with `suggestedName` |
| `POST /v1/files/mkdir` | `{projectId, path}` → 201 entry; 409 `file_exists` with `suggestedName` |
| `POST /v1/files/upload?projectId&path` | raw body with Content-Length → 201 entry; up to 256 MiB; 2 concurrent per device; never overwrites (409 `file_exists` with `suggestedName`); 507 `insufficient_storage` |
| `POST /v1/files/delete` | `{projectId, path, permanent?, confirmPath?}` → `{path, trashed, trashName?}`; moves to the Trash by default; 409 `trash_unavailable {permanentDeleteAllowed}` on another volume; `permanent` requires `confirmPath == path`; the project root is refused |
| `GET /v1/files/search` | `projectId, q, path?, regex?, caseSensitive?, include?` → `{results:[{path, matches:[{line, column, preview}], truncated?}], truncatedReason?}`; bounded to 20k files, 64 MiB, 500 matches (20 per file), 5 s |

- Paths follow the file routes: relative, `/`-separated, at most 1024 bytes, without `..`,
  `\`, `:` or NUL. The project folder itself (`.` or empty) is refused with 400
  `invalid_path`. An entry is `{name, path, isDirectory, size}`, as `GET /v1/files` lists.
- Changes are made through the project's `os.Root`, renaming or linking one name inside
  directories opened through it, so a symlink swapped into a path cannot redirect a change
  outside the project. A symlink is moved or deleted itself, never followed. Changes
  serialize with editor saves.
- `suggestedName` is a free name in the same folder ("name 2.txt", "name 3.txt" …,
  continuing a number the name already ends with). It is advice, not a reservation.
- Move uses `renameatx_np(RENAME_EXCL)` on macOS and `renameat2(RENAME_NOREPLACE)` on Linux.
  On Windows it is best effort (the destination is checked, then renamed). Case-only
  renames work. Other answers: 400 `invalid_move` (a folder into itself), 409
  `cross_volume`, 404 `file_not_found` (source or destination folder missing).
- Upload: 411 `length_required` without a Content-Length (chunked), 413 `file_too_large`
  (the limit is the host option `FileUploadLimit`), 429 `upload_limit`, 400
  `upload_incomplete` when the body ends early (nothing is saved), 507 when less than
  1 GiB would stay free. The body goes to `.agentland-upload-<random>` beside the target,
  is fsynced, then published with a hard link (an exclusive rename on volumes without hard
  links); a host crash mid-upload can leave that temporary file. New files get mode 0644
  limited by the umask. The read deadline is 2 minutes plus 1 second per 256 KiB.
- Delete: the Trash is `~/.Trash` on macOS, used only when it is a real folder owned by the
  user; a taken name becomes "name 2", "name 3" …. `trash_unavailable` also covers hosts
  without a Trash (Linux, Windows; `files` then omits `trash`) and a Trash the host may not
  use. Finder's Put Back does not work for items the host moved. `permanent: true` without
  `confirmPath == path` is 400 `confirmation_required`.
- Search matches each line on its own. `q` is 1–512 bytes on one line; plain text unless
  `regex=true` (Go RE2 syntax, 400 `invalid_pattern` when invalid); case-insensitive unless
  `caseSensitive=true`. `include` takes up to 16 comma-separated globs (256 bytes): one
  without `/` matches the file name, one with `/` the project path (`*` does not cross
  `/`). There is one result entry per matching line: `line` and `column` count from 1,
  `column` in Unicode characters of the first match, and `preview` is at most 240 bytes of
  the line around the match (whole characters, no trailing CR). `truncated: true` marks a
  file with more than 20 matching lines; `truncatedReason` is `files`, `bytes`, `matches`
  or `time`.
- Search lists files with `git ls-files --cached --others --exclude-standard` in a
  repository whose `.git` is inside the project (nested repositories use their own
  ignore rules) and walks other folders. It skips `.git`, symlinks, special files, files
  over 1 MiB, files with NUL bytes or invalid UTF-8, and names the file routes cannot open.
  A device runs one search at a time: a newer one ends the older with 409
  `search_superseded`. A search stops when its client disconnects.

## Git

- `GET /v1/git/status` adds `index`, `worktree`, `conflicted`, `untracked` per change.
- `GET /v1/git/diff?…&staged=1` returns the staged diff (index against HEAD);
  `&against=index` returns the unstaged changes (working tree against the index,
  untracked files as new files); the default stays the working tree against HEAD.
- `GET /v1/git/identity?projectId&path` → `{name, email, source: repository|user|none}`.
- `POST /v1/git/stage`, `POST /v1/git/unstage` → `{projectId, path, files[≤500]}`.
- `POST /v1/git/commit` → `{projectId, path, message ≤16 KiB, author?{name, email}}` →
  `{commit, hooksSkipped: true}`.
- Error codes: `git_busy`, `git_index_locked`, `git_nothing_to_commit`,
  `git_identity_missing`, `git_conflict`, `git_filter_unsupported`,
  `git_signing_required`, `git_path_invalid`, `git_timeout` (504, outcome unknown, never
  retried), `git_failed`.

Details:

- Every Git process drops inherited `GIT_*` variables and runs with system and global
  configuration hidden, hooks, fsmonitor, automatic gc and maintenance off, literal
  pathspecs (`GIT_LITERAL_PATHSPECS=1`), `GIT_EDITOR=:`, no prompts and the C locale. Git's
  own output only chooses an error code and is never returned.
- Status: `index` and `worktree` are porcelain v1's two columns with a space as `""` (an
  untracked file is `"?"`, `"?"`). `conflicted` covers `DD AU UD UA DU AA UU`. A rename
  or copy also has `originalPath`; unstaging a whole rename takes both paths.
- Diff without `staged` is unchanged (working tree against `HEAD`), except that an
  untracked text file up to 256 KiB now comes back as a new-file diff (binary: "Binary
  files … differ"). `staged=1` compares the index with `HEAD`, or with nothing before
  the first commit. Text conversion filters are not run.
- Identity reads the repository's configuration, then the user's global configuration for
  what is missing. That single query reads global configuration, in the repository so
  conditional includes apply. `source` is `repository` when both values come from the
  repository, `user` when the user's configuration supplies either, and `none` when one
  is missing (known values are still returned).
- Stage and unstage take files relative to the repository, validated like file paths (a
  trailing `/`, as status shows an untracked folder, is accepted); the body may be up to
  640 KiB. They answer `{staged: n}` or `{unstaged: n}`. Staging is refused with
  `git_filter_unsupported` when any file the paths cover has a `filter` attribute (such as
  Git LFS). Unstaging uses `git restore --staged`, and before the first commit removes the
  index entries only.
- Commit: `commit` is the full hash. The message (not blank, no NUL) goes on stdin with
  `--cleanup=whitespace`, so lines starting with `#` are kept. `author`, or the resolved
  identity, must be one line of at most 200 bytes without `<` or `>` for each of name and
  email (400 `invalid_request`); it is passed as `GIT_AUTHOR_*`/`GIT_COMMITTER_*` in the
  environment. Hooks do not run (`--no-verify`, hooks disabled). Commits are never signed:
  `commit.gpgsign` set to true in the repository or the user's configuration is
  `git_signing_required`. `git_nothing_to_commit` means the index matches `HEAD` outside a
  merge.
- One Git change runs per repository; another waits up to 5 s, then gets 409 `git_busy`.
  Stage and unstage have 30 s, commit 60 s; a timeout is 504 `git_timeout` with
  `error.outcome: "unknown"`. A leftover `.git/index.lock` is 409 `git_index_locked`
  before Git runs. Other statuses: 409 for `git_index_locked`, `git_nothing_to_commit`,
  `git_identity_missing`, `git_conflict`, `git_filter_unsupported` and
  `git_signing_required`; 400 `git_path_invalid`; 500 `git_failed`.

### Git management tree

The host additionally lists `branches`, `history`, `remotes`, `stashes`, `discard` and
`untrackedFiles` in `capabilities.git`. Clients hide unsupported controls and send new
queries only to hosts advertising the corresponding feature. All routes are authenticated
and resolve `projectId` plus repository `path` through the same workspace boundary as
stage/commit. Mutations take the existing repository lock and refuse a leftover index lock.

| Feature | Route | Request or query | Answer |
| --- | --- | --- | --- |
| `untrackedFiles` | `GET /v1/git/status` | `projectId`, `path`, `untracked=all` | Individual untracked files, with `truncated` when only the first 500 changes fit the list |
| `branches` | `GET /v1/git/branches` | `projectId`, `path` | `{branches:[{name,current,remote,upstream?,ahead,behind}]}`; local and remote tracking refs |
| `branches` | `POST /v1/git/branch` | `{projectId,path,action: create\|switch\|delete\|track,name,source?}` | `{changed:true}`; `track` names a remote tracking ref such as `origin/feature`, and `name` is the new local branch |
| `history` | `GET /v1/git/history` | `projectId`, `path`, `cursor?` | `{commits:[{hash,subject,author,timestamp}],nextCursor?}`; 30 commits per page, Unix timestamps in seconds, cursor offsets bounded to 0–5000 |
| `history` or `stashes` | `GET /v1/git/commit` | `projectId`, `path`, `commit`, `stash?` | `{hash,files:[{path,status}],truncated}`; first-parent changes, renames shown as delete/add, at most 500 files |
| `history` or `stashes` | `GET /v1/git/commit/diff` | `projectId`, `path`, `commit`, `file`, `stash?` | `{path,diff}`; bounded to 256 KiB, with external diffs and text conversion disabled |
| `remotes` | `GET /v1/git/remotes` | `projectId`, `path` | `{remotes:[{name,url,supported}]}`; URL credentials and query strings are omitted |
| `remotes` | `POST /v1/git/remote` | `{projectId,path,action: fetch\|pull\|push,remote}` | `{changed:true}`; configured remote names only |
| `stashes` | `GET /v1/git/stashes` | `projectId`, `path` | `{stashes:[{hash,message,timestamp}]}`; newest 100 entries, identified by full hash |
| `stashes` | `POST /v1/git/stash` | `{projectId,path,action: save\|apply\|drop,hash?,message?,includeUntracked?}` | `{changed:true}`; save's optional message is one line of at most 1 KiB |
| `discard` | `POST /v1/git/discard` | `{projectId,path,files,confirmed:true}` | `{changed:true}`; 1–500 individual tracked files; restores working files from the index |

- Branch names are validated with Git and limited to 200 bytes. Switching and checking
  out a remote branch require a clean working tree, including untracked files. Delete
  refuses the current branch and any branch with commits outside the current branch;
  it never forces removal. Tracking checkout creates a local branch and its upstream.
- History and stash previews require a full lowercase 40- or 64-character commit hash,
  never an arbitrary revision expression. `stash=1` requires that the hash still names a
  listed stash and includes its separately saved untracked files when present.
- Fetch updates remote tracking refs without changing working files. Pull requires a
  configured upstream on the chosen remote and a clean working tree; it fetches and
  advances only by fast-forward. Divergence is `git_diverged`, with the local branch and
  files kept. Push uses one explicit branch refspec, without force, tags or submodule
  recursion. A first push establishes an upstream when the branch has none; an existing
  upstream is respected. Merge, rebase and conflict resolution remain operations for the Mac.
- Network operations allow configured HTTP, HTTPS, SSH and Git URLs only, including all
  effective URL rewrites and push destinations. Local file transports, executable helpers,
  remote VCS helpers, repository credential/askpass/proxy programs and custom SSH commands
  are disabled. SSH uses noninteractive system SSH without user SSH configuration; HTTPS
  credential helpers do not run. A host that cannot authenticate this way refuses the
  operation; the client does not prompt for credentials or change remote configuration.
- Stash save uses the resolved commit identity, disables signing of the internal snapshot,
  and keeps untracked files unless `includeUntracked` is true. It refuses an empty selected
  set (`git_nothing_to_stash`). Apply restores the staged/unstaged split, requires no tracked
  changes, and keeps the stash. Apply conflicts report `git_stash_conflict`: files may have
  changed and must be inspected on the Mac. Drop resolves the hash to its current reflog
  position while holding the repository lock; a stale selection is `git_stash_missing`.
  The native tree confirms save, apply and drop.
- Discard requires explicit confirmation, restores only the working copy, keeps staged
  changes and never deletes untracked files. Checkout, pull, stash save/apply and discard
  refuse configured Git clean/smudge/process filters (`git_filter_unsupported`).
- Branch, stash and discard commands use the existing 30-second deadline; network commands
  use 60 seconds. Git timeouts report `git_timeout` with `outcome:"unknown"`. A network
  failure that cannot confirm the outcome reports `git_remote_failed` with the same unknown
  outcome. Clients retain the warning, refresh status, and never retry the mutation by
  themselves. Other management refusals include `git_changes_present`, `git_branch_invalid`,
  `git_branch_missing`, `git_branch_exists`, `git_current_branch`, `git_branch_unmerged`,
  `git_commit_invalid`, `git_commit_missing`, `git_remote_invalid`, `git_remote_unsupported`,
  `git_upstream_missing`, `git_detached_head` and `git_confirmation_required`.

## Preview (browser tab)

- `GET /v1/preview/ports` → `{ports:[{port, address, process}]}` (process name only).
- `POST /v1/preview/sessions` `{port}` →
  `{sessionId, previewPort, cookie{name, value, maxAgeSeconds}}`.
- `GET /v1/preview/sessions`, `POST /v1/preview/sessions/revoke {sessionId}` or `{all: true}`
  (gated by `revokeAll`).
- The preview listener (`https://<host>:<previewPort>/`) proxies every path to
  `127.0.0.1:<port>` for the session's cookie. Paths under `/__agentland/` are reserved.
  Sessions last 30 min idle, 12 h at most, and end when the device is revoked or the
  host restarts.

Details as implemented:

- The routes work only when the host runs `serve --enable-preview`; otherwise they answer
  403 `preview_disabled` and capabilities have no `preview`.
- **Ports.** `address` is `127.0.0.1`, `::1` or `*` (every address); `process` is the
  executable name, left out when unknown. The list has one entry per port, sorted, at most
  256: this user's TCP listeners the proxy can reach. It never has the host's API and
  preview ports, the configured OpenCode port or the host process's own sockets. Ports 22,
  631, 2375, 2376, 3306, 5432, 6379, 9200 and 27017 are left out unless the host allows
  them. Windows lists nothing (no discovery there), so no session can be created. A failed
  scan is 503 `port_discovery_failed`.
- **Create** answers 201. `cookie.name` is `__Host-agentland-preview`, `value` is 32
  random bytes in unpadded base64url, `maxAgeSeconds` is 43200. The client stores it for
  the preview origin only (Secure, HttpOnly, SameSite=Strict, Path=/, no Domain) and never
  puts it in a URL; the host keeps only its SHA-256. Errors: 400 `invalid_request` (port
  outside 1–65535), 403 `port_not_allowed` (an excluded port), 404 `port_not_listening`
  (discovery runs again and does not list it), 403 `preview_unavailable` (the `local-mac`
  session, which opens ports directly), 429 `preview_session_limit` (8 per device, 64 per
  host), 503 `port_discovery_failed`, 503 `host_stopping`.
- **List** → `{sessions:[{sessionId, port, createdAt, lastUsedAt, expiresAt}]}`: the
  caller's sessions, oldest first, without secrets. `expiresAt` is the 12-hour end. Times
  are formatted as in the archive.
- **Revoke** → `{revoked: true}`; 404 `preview_session_not_found` for another device's
  session or one that ended.
- **Revoke all.** Hosts that list `revokeAll` take `{all: true}`: every session of the
  caller's device ends, as a revoke ends one, and the answer is `{revoked: true, count}`,
  the number that were live (0 when none). With a `sessionId` as well it answers 400
  `invalid_request`; older hosts refuse the unknown member the same way. Other devices'
  sessions are untouched.
- **Cleanup after an app restart.** A device's sessions outlive the app that opened them,
  which no longer knows their IDs, and count toward its 8 until they idle out. The app sends
  a revoke of all the first time a browser tab starts after launch (shown, or asked to open
  a port) on a host that lists `revokeAll`, once per host each launch. Every preview it opens
  there waits for that answer, and it is never sent again that launch, so it never ends a
  session the running app opened. A revoke that provably did not reach the host is tried
  again before the next preview, which is not asked for until then.
- **Origin.** The app opens the preview at `<scheme>://<host>:<port>/` with the advertised
  scheme and port (the session's `previewPort`) and the host name it connected to; it opens
  nothing for a scheme other than https.
- **Ending.** An open request, stream or WebSocket keeps a session from idling out. Revoking
  a session, revoking its device (noticed within about 5 s) or stopping the host closes its
  WebSockets and streams.
- **Proxy.** Requests go to `127.0.0.1:<port>`, or `[::1]:<port>` when nothing answers
  there, whatever their Host or URI say, with `Host: localhost:<port>`,
  `X-Forwarded-Proto: https`, the session cookie removed from `Cookie`, and an `Origin` or
  `Referer` of the preview origin rewritten to `http://localhost:<port>`. A `Location` to
  `localhost`, `127.0.0.1` or `::1` at that port becomes a path; `Set-Cookie` loses
  `Domain` and can never set the session cookie; `Strict-Transport-Security` is dropped.
  WebSockets pass through.
- **Refusals by the proxy** carry the header `X-AgentLand-Preview-Error: <code>`, which a
  previewed server cannot send, and the usual JSON error: 400 `bad_request` (absolute URI,
  CONNECT), 401 `preview_session_required` (no, unknown or ended session: open a new one
  and reload), 403 `cross_site_rejected` (a method other than GET and HEAD, or a
  WebSocket, with an `Origin` other than the preview origin), 404 `not_found` (reserved
  paths), 408 `request_timeout` (body slower than 2 min plus 1 s per 256 KiB), 413
  `request_too_large` (body over 64 MiB), 429 `preview_busy` (64 requests in progress for
  the session, WebSockets included), 502 `upstream_unavailable`, 504 `upstream_timeout`
  (no response headers within 2 min), 503 `host_stopping`.
- Responses may stream without a total time limit; each write must finish within 60 s.
  The previewed server must speak plain HTTP. Pages that build absolute
  `http://localhost:<port>` URLs in their HTML or scripts do not load those through the
  proxy.

## Presence and notices

- `POST /v1/device/presence` adds `view?{projectId, sessionId}` (gated by
  `presence: ["views"]`), held in memory only.
- `GET /v1/notices?after&wait≤20000` (local-only long-poll) →
  `{notices:[{seq, id, kind, projectId, projectName, sessionId?, title,
  mayContainContent, createdAt}], cursor}`.
- `POST /v1/notices/ack {through}` (local-only).
- Kinds: `chat.turn.finished`, `chat.turn.failed`, `chat.approval.needed`,
  `chat.question.needed`. A notice never contains message text. It is not issued when a present device reported viewing that
  chat in the last 45 s.

Details as implemented (notices v1):

- **Views.** `view` names the chat the device shows now; each heartbeat replaces it,
  and one without `view`, or with `active: false`, clears it. Both members are required
  (at most 256 bytes each, else 400 `invalid_request`). Views are kept in memory only,
  never in host state, and lapse 45 s after the heartbeat that reported them or when the
  device is revoked.
- **Who keeps notices.** Only a host running with this Mac's local session keeps them
  (for the Mac app to relay): in the archive's `notices` table, or in memory when the
  host keeps no archive. Either way the newest 1000 of the last 7 days.
- **What issues them.** The chat hub, for every chat it holds (a device streams it, or a
  send keeps it through its turn): `chat.turn.finished` when a turn ends normally,
  `chat.turn.failed` when it ends in an error (a turn someone stopped gives none),
  `chat.approval.needed` and `chat.question.needed` when an approval or question
  appears. Hosts before 2026-10-06 also issued `schedule.run.*` notices (with
  `scheduleId` and `runId`); a newer host leaves any it kept out at start.
- **Rules.** One notice per turn, approval and question. A chat notice is left out
  while a present, non-revoked device reported viewing that chat within 45 s. An approval notice for a chat within 10 s of the previous approval
  notice for that chat is left out (questions likewise, counted apart).
- **Fields.** `title` is the chat's title. `mayContainContent` is true for every chat
  title (providers and apps may name a chat after its first message; the host cannot
  tell). `projectName` is the
  project's name when the notice was made. `createdAt` is formatted as in the archive.
- **Reading.** `after` is a `cursor` from an earlier answer; without it the answer
  starts after the acknowledged notices. At most 100 notices per answer (`hasMore`
  says more are waiting; ask again with the new `cursor`). With nothing to return and
  `wait` (0–20000 ms, default 0) the request waits for the next notice, or until the
  host starts stopping. A cursor from another epoch (a new archive, or a restart of a
  host that keeps notices in memory) starts over from the oldest kept notice with
  `resync: true`. The answer is `{notices, cursor, hasMore, resync}`.
- **Acknowledging.** `through` is the `seq` of the newest notice the app has handled
  → `{acked}`. The acknowledgement never moves back; a `seq` not issued yet is 400
  `invalid_request`. With an archive it survives restarts, like the notices and their
  numbering.
- Both routes are local-only (403 `local_only` for paired devices); 501
  `notices_unavailable` on a host that keeps no notices; 500 `storage_error` when the
  acknowledgement cannot be saved.

## Routes

`capabilities.routes` lists the ways a paired device can reach this host. It appears
only when `serve` runs with `--advertised-host NAME` (the Mac app passes its Bonjour
name); without it the key is absent and devices use the address they paired with.

- Each entry is `{kind, host, addresses?, port}`. `host` is a DNS name in lower case
  without a trailing dot, or an IP address; `addresses` (at most 4, IP addresses) are
  other ways to the same route; `port` is the listener's.
- `kind: "local"` is the advertised name (`host`) on the local network, always first.
- `kind: "tailscale"` is present only while Tailscale runs on the host's computer:
  `host` is its MagicDNS name (`Self.DNSName` without the trailing dot, or its first
  address when it has none) and `addresses` its Tailscale addresses that the listener
  accepts (all of them for a wildcard listener, none for a listener on another
  address, in which case there is no Tailscale route).
- The host reads Tailscale with `tailscale status --json --peers=false` only — this
  computer's status (`BackendState`, `Self`, `TailscaleIPs`), never the other devices of
  the tailnet, never another subcommand, and it never changes Tailscale — at start and
  every 5 minutes, with a 4 s timeout, at most 1 MiB of output and an environment
  without the host's secrets. The command line is `--tailscale-cli PATH` or the first of
  `/Applications/Tailscale.app/Contents/MacOS/Tailscale`,
  `~/Applications/Tailscale.app/Contents/MacOS/Tailscale`, `/opt/homebrew/bin/tailscale`
  and `/usr/local/bin/tailscale`. No command line, a non-zero exit, a `BackendState`
  other than `Running` or a listener Tailscale cannot reach removes the route; a
  reading that times out or cannot be parsed keeps the last route and state. The first
  capabilities answer after start waits for the first reading.
- `tailscale` (present with `routes`) is what the last reading said: `running` (the
  Tailscale route is listed), `notListening` (Tailscale runs, but the listener is bound
  to an address Tailscale does not have), `off` (not running, or the command line could
  not reach it), `notFound` (no command line in those places) or `unknown` (no reading
  has succeeded yet). The Mac's This Mac row words its advice by it.
- A route is a way to the same host, not a new identity: clients connect to any route
  only with the certificate fingerprint they paired with, and validate the certificate
  for the name they paired with (not the route's `host`). A client that paired without
  a fingerprint uses only the address it paired with.
- Clients remember the routes (see the app's `SavedHost`) and learn them again on every
  successful connection, so devices paired before routes existed learn them the next
  time they connect. QR invitations carry them too (`AgentLandPairing`, `routes`).
- Clients try, in this order: the address that answered last, the paired address, each
  route's `host` then `addresses`, and for a host paired at `NAME.local` the short name
  `NAME` (Tailscale's MagicDNS search domain resolves it while Tailscale is on, so a
  device reaches the Mac away from home before it has learned the routes). The first to
  answer `GET /v1/health` through the pinned connection carries every request. An
  address that fails is tried again (after 0.5, 1, 1, then every 2 s) while the others
  are still being tried, so a hung address holds up nothing; the host shows as
  unreachable as soon as the address in use fails.
- The remote-access tunnel is not one of these addresses: it is a candidate of its own kind,
  tried after all of them and never saved as the address that answered last ("Remote access
  (iroh)", "The phone's routes").

## Pairing again (2026-10-17)

The owner (2026-10-17): "Mac: a device that pairs again replaces its old entry, and the old login
stops working. Phone: the new pairing takes over the old row, keeping its tabs, workspace and cached
chats."

- `POST /v1/pair` stays a public route with the same body. A device that already holds a token for
  this host sends it as the request's bearer token (`Authorization: Bearer <token>`). Hosts before
  this ignore the header on this route (it carries no new body member, which they would refuse), so
  it needs no capability, and devices before this send none.
- With a valid pairing code, the host picks the record of a device that pairs again: the record, not
  revoked, whose token hash matches the bearer token (compared in constant time against every record),
  else the record, not revoked, that has the node ID the request proved it holds ("Pairing with a node
  ID"). That record keeps its `deviceId`, so its terminals stay its own, its `createdAt`, its presence
  and, when the request gives no node ID, its node ID; it takes the new `deviceName` and a new token,
  and records `pairedAt`. The old token stops working at once: requests with it answer 401, event
  streams end with `unauthorized` at their next check, and its tunnel connections close, as a
  revocation's do. The answer is the usual `{token, deviceId}` with that record's `deviceId`.
- A bearer token that matches no record that is not revoked (a revoked device's, a wrong one, this
  Mac's own session, one over 256 bytes) or another scheme is ignored: the pairing adds a record, as a
  first pairing does. The proof never refuses a pairing, and an invalid, expired or spent code answers
  401 `invalid_pairing_code` with or without it. Single use, expiry, the per-client and shared attempt
  limits, the Origin rejection and the refusal through the tunnel are unchanged.
- `agentland-host devices` prints the last pairing (`pairedAt`, else `createdAt`) in its third column,
  so the Mac's Pair a Device window sees a device pair again ("Paired again with <name>") as well as a
  new one ("Paired with <name>").
- The iPhone and iPad (`AppModel.previousPairing`, `savingPairing`) send the token of the saved host
  with the invitation's certificate fingerprint at the same address in any form (host name without case
  or a trailing dot, the port, 443 when none; the selected host first, else the one paired last), only
  as a plain token (AgentLandCore's `pair(code:deviceName:node:previousToken:)`). When the host answers
  that row's `deviceId`, the row takes the pairing in place with its address as saved, so its ID and
  everything kept under it (tabs, workspace, the device copy) stay, and the token in its Keychain item
  is overwritten. Any other `deviceId` (a host before this) adds a row as before.

## Remote access (iroh)

Owner decision (2026-09-26): a paired device reaches its Mac from anywhere peer to peer
through iroh. There is no relay on the Mac. The Mac app's iroh endpoint binds one fixed UDP
port (38842, `RemoteAccessPorts.endpointUDP`). With "Reach this Mac from anywhere" on (off by
default) the app maps that one port on the router itself (`PortMapper`, PCP or NAT-PMP;
removed when the switch goes off and on quit), learns the external address and reports it to
the host, which advertises it to paired devices; phones connect directly to it. For networks
where no direct path can be made there is an opt-in fallback through one of n0's public relays
(off by default), which carries the same end-to-end encrypted traffic. The host (`desktop/`)
never speaks iroh: the Mac app admits only the node IDs of paired devices (`IrohPeerGate`) and
bridges each of their streams to the host's tunnel socket. Inside, every request is the same
pinned-certificate HTTPS with device bearer tokens as on the host's TCP listener. A device away
from home that meets a changed address finds the new one in the owner's own iCloud ("When the
Mac's address changes").

```text
phone: APIClient ──HTTP CONNECT with the bridge's secret──▶ 127.0.0.1:<ephemeral> bridge
       bridge ──iroh (UDP 38842, or the one n0 relay of the fallback)──▶ Mac app
Mac app: IrohPeerGate (paired node IDs only) ──Unix socket <state folder>/tunnel.sock──▶ Go host
         each stream: an 84-byte preamble naming the peer, then the phone's TLS bytes unchanged
```

### Node IDs, keys and proofs

- A node ID is an iroh endpoint ID, the 32-byte Ed25519 public key, written as 64 lowercase
  hexadecimal characters: the hex of `EndpointId.toBytes()` (`SecretKey.public().toBytes()` for
  one's own). Every member below that holds a node ID takes exactly this form; the host refuses
  upper case and iroh's base32 or `fmtShort()` forms (400 `invalid_request`). Do not build it
  from `EndpointId.description`.
- Each iPhone, iPad and Mac keeps one iroh secret key (32 bytes, made once with
  `SecretKey.generate()`) in its own Keychain, for this device only
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, never synchronizable). Its node ID stays
  the same across launches, updates and reinstalls, and no two devices share one. A Keychain
  that does not come along (Migration Assistant, a reset) means a new node ID ("When the Mac's
  address changes"). On the Mac the key goes to the data protection Keychain
  (`kSecUseDataProtectionKeychain`), whose "this device only" items Migration Assistant leaves
  behind; it needs the app's signed application identifier, and an ad-hoc build, which lacks one,
  keeps the key in the login Keychain instead (AgentLandDesktopCore's
  `KeychainRemoteAccessKeyStore`).
- A device proves that it holds the key of a node ID it gives the host. `proof` is
  `SecretKey.sign(message:)` (Ed25519, RFC 8032) as 128 lowercase hex characters, over the UTF-8
  bytes of four lines joined by `\n` with no final line feed: `agentland-iroh-node/1`; the
  purpose, `pair` or `register`; the binding, which for `pair` is the pairing code exactly as
  sent in `code` and for `register` the device's `deviceId` (as `POST /v1/pair` answered it);
  and the node ID. Example: `agentland-iroh-node/1\nregister\n9c1e44d0a7b2c35f8e016d42\n<node
  ID>`. AgentLandCore's `IrohNodeProof.message(purpose:binding:nodeID:)` builds these bytes. A
  proof that does not verify with the node ID as the public key answers 400
  `invalid_node_proof`.
- A node ID must be a key a device can hold. A cofactorless Ed25519 check (Go's
  `crypto/ed25519`) takes a signature made without any private key for a key of small order: the
  identity key with R the identity and S zero verifies for every message. So the host refuses,
  before it verifies a proof, a non-canonical encoding (y at or above 2^255 − 19) and the eight
  points of small order (y = 1, 2^255 − 20, 0 and the two y of order 8, with either sign of x):
  at pairing and registering 400 `invalid_node_proof`, in the Mac's endpoint report 400
  `invalid_request`. A device record that holds one from before is not listed as a peer.
  AgentLandCore's `IrohNodeID` refuses the same keys; iroh's own check (`verify_strict`) never
  completes a handshake with one.

### The tunnel socket

- `serve --tunnel-socket PATH` serves the same `/v1` API, with the same certificate and key,
  on a Unix domain socket as well as on the TCP listener. It needs the HTTPS listener (not
  `--dev-http`) and the Mac's local session (`--local-session-env`). `PATH` is absolute, lies
  directly in the folder of the state file and is at most 103 bytes, its folder at most 92 (the
  socket is bound first in a private folder inside it). The Mac app passes
  `<state folder>/tunnel.sock` (`~/Library/Application Support/agentland/tunnel.sock`) at every
  HTTPS start, whether or not remote access is on, so the switch never restarts the host
  (`HostCommandBuilder.tunnelSocketPath(statePath:)`; a state folder whose socket path would pass
  103 bytes gets no tunnel socket, and the app offers no remote access).
- The host binds the socket inside a new private folder (0700) in the state folder, sets it to
  0600, checks that it belongs to the user the host runs as and only then moves it to `PATH`,
  so no other user can reach it at any moment. A socket already at `PATH` that accepts no
  connection (left by a host that crashed) is replaced; a socket that accepts connections
  (another host) and anything that is not a socket fail the start. The host removes the socket
  when it stops, if the file at `PATH` is still its own.
- Every connection must come from a process of the same user, checked with the kernel's peer
  credentials (`LOCAL_PEERCRED` on macOS, `SO_PEERCRED` on Linux); any other is closed at once.
  On other systems (Windows) `--tunnel-socket` fails the start.
- **Preamble.** Before the TLS bytes, the Mac app writes exactly 84 bytes: the ASCII line
  `agentland-tunnel/1 <nodeId>\n`, that is the literal `agentland-tunnel/1`, one space, the
  remote node ID iroh verified (`Connection.remoteId()`) and one line feed. The TLS
  ClientHello is the 85th byte. The host reads exactly 84 bytes, within 5 s of accepting, and
  nothing more before TLS starts. AgentLandCore's `RemoteAccessTunnel.preamble(nodeID:)` builds
  it.
- **Refusals.** The host closes the connection without writing anything when the preamble is
  late, short or not exactly that line (a later version's included); when the node ID is not
  the `irohNodeId` of a paired device that is not revoked; when that device has 16 tunnel
  connections open already or opened 60 in the last minute; when 128 tunnel connections are
  open in all (connections still sending their preamble count); and while the host stops. The
  Mac app turns such a close into a stream reset with code 2 ("The two apps"), so the phone can
  tell it from a network failure.
- **Audit.** The host writes one line to standard error for each tunnel connection it accepts
  (the device ID and the node ID's first 8 characters) or refuses (the reason and, when there
  is one, the node ID's first 8 characters). Never request content, tokens or device names. A
  tunnel connection's remote address is `iroh/` and the node ID's first 8 characters, so the
  lines net/http writes itself (a TLS handshake that fails through the bridge) carry no more.
- After the preamble the connection is the host's ordinary TLS (HTTP/1.1 or HTTP/2) with the
  TCP listener's timeouts, header and body limits, Origin refusal and authentication.

### What is different through the tunnel

Requests through the tunnel socket are never this Mac's own:

- The local session token is not accepted there (401 `unauthorized`), so no local-only route is
  reachable through the tunnel.
- A bearer token must belong to the device whose node ID the preamble named. Another paired
  device's token answers 403 `tunnel_device_mismatch` (what the phone then does: "The two apps",
  Refusals). `GET /v1/health` answers as usual.
- `POST /v1/pair` and `POST /v1/remote-access/device` answer 403 `tunnel_refused`: pairing and
  registering happen over the TCP listener (the home network, or Tailscale), never through the
  tunnel. A refused pairing request does not count toward the pairing limits.
- `GET /v1/capabilities` leaves out `preview` (the preview listener is not bridged) and
  `POST /v1/preview/sessions` answers 403 `preview_unavailable`.
- When a device is revoked, registers another node ID or loses its node ID to another device
  record, the host closes the tunnel connections that carried its old node ID: at once for
  changes made through the host, and within 250 ms of another process writing the state file
  (the `agentland-host revoke` command the Mac app runs). Pulses, event streams and long-polls
  on those connections end with them.
- Everything else works as it does over TCP: chats and their event streams, terminals, files,
  Git, the archive and the pulse.

### Pairing with a node ID

- QR invitations of a host that takes node IDs carry `remoteAccess: {"version": 1}`
  (AgentLandPairing's `PairingInvitation.remoteAccess`); the Mac app adds it when its host lists
  `remoteAccess` in the capabilities it read last (at each host start and every minute while the host
  runs; `HostController.noteCapabilities`, `HostController.invitation`). A `remoteAccess` of another version is left out when the
  invitation is read, and the invitation still pairs.
- `POST /v1/pair` takes `irohNodeId` and `irohNodeProof` (purpose `pair`), both or neither. A
  device sends them only when its invitation carries `remoteAccess` version 1. A device that
  pairs without an invitation (Bonjour and a PIN), or with an invitation without it, sends
  neither and registers afterwards. Hosts before this contract refuse the unknown members with
  400 `invalid_request`.
- The two members are checked before the code, and a refusal leaves the code unused (the
  request still counts toward the pairing limits): only one of them, or a malformed one,
  answers 400 `invalid_request`; a proof that does not verify, or a node ID no device can hold,
  400 `invalid_node_proof`; the Mac endpoint's own node ID, 409 `node_id_in_use`.
- A pairing that succeeds answers as before (`{token, deviceId}`) and keeps the node ID in the
  device record. The proof shows that the pairing holds the key, as an app reinstalled on the same
  phone does, so since 2026-10-17 a record that is not revoked and has that node ID is the same
  device pairing again and is replaced ("Pairing again"): same `deviceId`, new token, the old token
  refused. Only when the bearer token names another record does that one take the node ID, and the
  record that had it loses it (keeping its token).

### Registering a node ID later

`POST /v1/remote-access/device` `{nodeId, proof}` (purpose `register`), from a paired device
over the TCP listener, on hosts that list `remoteAccess`:

- It sets the calling device's node ID, replacing the one it had; another device record that
  had this node ID loses it. It answers 200 `{"nodeId": "…"}`. Sending the node ID the device
  already has changes nothing and answers the same.
- A device registers whenever it reached the host over a route other than the tunnel and
  `capabilities.remoteAccess.deviceNodeId` is absent or differs from its own node ID. Devices
  paired before remote access existed register this way the next time they connect at home or
  over Tailscale.
- Errors: 400 `invalid_request` (a malformed body), 400 `invalid_node_proof` (also a node ID no
  device can hold), 403
  `tunnel_refused` (through the tunnel), 403 `device_only` (the Mac's own session), 409
  `node_id_in_use` (the Mac endpoint's node ID), 501 `remote_access_unavailable` (a host without
  `--tunnel-socket`).
- Revoking a device removes its node ID from its record.

### Routes for the Mac app (local-only)

| Route | Query / body | Answer |
|---|---|---|
| `GET /v1/remote-access/peers` | `after?` (a `version`, at most 64 bytes), `wait?` (0–20000 ms, default 0) | `{version, peers:[{deviceId, nodeId}]}` |
| `POST /v1/remote-access/endpoint` | `{enabled, nodeId?, udpPort?, directAddresses?, fallbackRelay?, relayUrl?}` | 200 the `remoteAccess` object as devices see it (its `sequence` included), without `deviceNodeId` |

Both routes take only the Mac's local session over the TCP listener. A paired device's token
answers 403 `local_only`, the token of the device whose tunnel carries the request included.
Through the tunnel the local session token is never accepted, so it answers 401
`unauthorized` there, as a request without a token does, and another paired device's token
answers 403 `tunnel_device_mismatch` ("What is different through the tunnel"). A host without
`--tunnel-socket` answers 501 `remote_access_unavailable`.

Peers:

- `peers` are the paired devices that are not revoked and have a node ID, sorted by `nodeId`.
  They are the only node IDs the Mac's `IrohPeerGate` admits. With none, `peers` is `[]`, never
  `null`.
- `version` is opaque (at most 64 characters) and depends only on the list: the same list has
  the same version, across host restarts too.
- With `after` equal to the current version and `wait` above 0, the answer waits until the list
  changes, `wait` passes or the host starts stopping, then answers the current list (the same
  one when nothing changed). Otherwise it answers at once. Pairing, registering and revoking
  through the host wake it at once; a state file written by another process (the `revoke`
  command) is read again within 250 ms.
- The Mac app keeps one such request open while its endpoint runs (`wait=20000`, sent again at
  once after each answer and 1 s after an error), gives `setAllowed` the answer's node IDs, and
  closes its iroh connections from node IDs no longer listed. The first request after the
  endpoint starts has no `after`, so it is answered at once: until then the gate has no list and
  answers every connection with 503 ("The Mac endpoint").

Endpoint report:

- `enabled` (required) is true while the switch "Reach this Mac from anywhere" is on.
- `nodeId` is the Mac endpoint's node ID, a key it holds ("Node IDs, keys and proofs"):
  required with `enabled: true`, allowed without it.
- `udpPort` is the endpoint's UDP port (the one it binds, 38842), 1–65535: required with
  `enabled: true`, allowed without it.
- `directAddresses` are the external `ip:port` addresses of the router mapping (its external
  address with the external port the router granted), at most 8 and no duplicates, an IPv6
  address in brackets without a zone. Each IP is global unicast: not unspecified, loopback,
  link-local, multicast or broadcast; not private (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16,
  fc00::/7) or shared (100.64.0.0/10: carrier-grade NAT, and Tailscale's addresses); not in
  0.0.0.0/8, 192.0.0.0/24, 192.0.2.0/24, 198.18.0.0/15, 198.51.100.0/24, 203.0.113.0/24 or
  240.0.0.0/4; and an IPv6 address lies in 2000::/3 outside 2001::/23, 2001:db8::/32 and
  3fff::/20. An IPv4-mapped IPv6 address is checked as its IPv4 address. AgentLandCore's
  `RemoteAccessDirectAddress.isDialable` is the same rule. (The examples in this document use
  documentation addresses, which a report cannot carry.) Only with `enabled: true`; default
  none.
- `fallbackRelay` is true while the n0 fallback is on. Only with `enabled: true`; default false.
- `relayUrl` is the fallback's relay, the one n0 relay the Mac endpoint uses ("The two apps"):
  an `https` URL with a host, without user, query or fragment, its path empty or `/`, at most
  256 bytes. Only with `fallbackRelay: true`.
- Anything else answers 400 `invalid_request` (a missing `enabled`, a member `enabled: false`
  does not allow, an unknown member). A `nodeId` that is a paired device's answers 409
  `node_id_in_use`; a report the host cannot keep, 500 `storage_error`.
- A report replaces the one before it as a whole, and the host keeps it in its state file. A
  host that starts again advertises the last report until the Mac app reports again; a kept
  report that the rules above no longer take, or whose node ID a paired device now has, is
  dropped at start. Only a report turns `enabled` off.
- The host numbers the reports devices see (`sequence` in capabilities): a kept report gets the
  last kept one's number plus one when anything devices read changes (every member but
  `udpPort`), and the same number otherwise. The number is kept in the state file with the report
  and never goes back, also when a kept report is dropped at start (devices then see 0 until the
  next report); a report kept by a host before this rule counts as 0. The answer carries it, and
  the Mac writes it into the address record ("When the Mac's address changes").

The Mac app reports:

- After every host start (a new local session), whether or not the switch is on, with its node
  ID (made from its Keychain key, whether or not the endpoint runs), so every device learns the
  Mac's node ID at its next connection, also before the switch is first turned on.
- With `enabled: true` only once the mapping attempt of that start or network has finished
  (mapped, refused or timed out), never while it runs, so a device never learns a report whose
  addresses are still to come. A mapping's report has its external addresses that are global
  unicast, and none when the router's external address is not (an inner router behind another,
  carrier-grade NAT).
- When an attempt made no mapping, the report keeps the addresses of the last mapping the app
  made (kept in its preferences with the router and the end of its lease) only while all of this
  holds; otherwise it has none:
  - the router did not answer in time, or answered that it cannot map just now (NAT-PMP's network
    failure or out of resources, PCP's `NETWORK_FAILURE` or `NO_RESOURCES`). A router that
    answers without a mapping (refused, not authorized, a version or request it does not take)
    has not opened the port. A router with only UPnP, or with PCP and NAT-PMP turned off, does
    not answer; the two rules below bound how long it keeps the last addresses.
  - it is the same router: the same gateway address and, when both are known, the same
    link-layer (MAC) address, which the app reads from the Mac's ARP table after the attempt
    (`DefaultGateway.hardwareAddress(of:)`). A gateway address alone does not tell routers apart
    (192.168.1.1, 192.168.0.1 and 10.0.0.1 are most routers' defaults), so a replaced router or
    another network with the same default gets none.
  - the mapping's lease has not ended: its last grant or renewal plus the lifetime the router
    gave, at most 2 hours (the lifetime `PortMapper` asks for), on the Mac's clock, and the clock
    has not gone back more than a minute past that grant.

  Devices replace their kept entry with every report and the app rewrites the address record
  after every report whose revision changed, so one exchange the router did not answer in time
  (right after a wake or a router restart) never takes away the addresses they hold, and an
  address whose mapping is gone is never reported for longer than its lease. The app says which
  ("The Mac switches").
- While the switch is on and it holds no mapping, the app tries again after 15 s, 30 s, 1, 2 and 5
  minutes and then every 10 minutes, never later than the end of the kept mapping's lease, and at
  once after a network change or a wake (the delays start over). A mapping it holds is renewed by
  `PortMapper`, which retries failed renewals itself; each renewal starts the lease again and
  changes no report. A held mapping whose renewals failed until its lease ended
  (`PortMappingEvent.expired`) is reported with no addresses, and with them again once a renewal
  works. AgentLandDesktopCore's `RemoteAccessMappingPlan` holds these rules.
- Whenever the switch, the fallback, the mapping's external address or port, or the fallback's
  relay changes.
- With `enabled: false` only when the owner turns the switch off. Quitting the app, Disconnect,
  sleep and a host restart send no report: the host keeps the last one, so a device away from
  home keeps its way back.

### Capabilities

```json
"remoteAccess": {"version": 1, "revision": "5d41402abc4b2a76b9719d911017c592", "enabled": true,
                 "nodeId": "<the Mac endpoint's node ID>",
                 "directAddresses": ["203.0.113.7:38842"],
                 "fallbackRelay": false, "sequence": 12,
                 "deviceNodeId": "<the calling device's node ID>"}
```

- Present for every caller when the host runs with `--tunnel-socket`. Its presence also means
  the host serves `POST /v1/remote-access/device`.
- `revision` is opaque (at most 64 characters). It changes whenever any member here but
  `deviceNodeId` changes, and is the same for the same report, across host restarts too.
- `enabled` is the last report's (kept across restarts; false before the first one). `nodeId` is
  present once the Mac app has reported one. `directAddresses` is always present, empty unless
  `enabled`. `fallbackRelay` is always present. `relayUrl` is present only with `fallbackRelay`
  and a reported relay.
- `sequence` is always present: the number of the last report ("Endpoint report"), 0 before the
  first one. It orders what devices see, so a device can tell whether the address record follows
  a later report than the entry it keeps. Clients read a missing or negative one as 0.
- `deviceNodeId` is the calling device's registered node ID; absent when it has none, and for
  the Mac's session.
- Clients read `remoteAccess` only when `version` is 1. An entry of another version, or one they
  cannot read, counts as absent: no registration and no tunnel route.
- The pulse (`GET /v1/pulse`) of a host that lists `remoteAccess` sends
  `{"type":"remoteAccess","revision":"…"}` right after `ready`, and again whenever the revision
  changes. Clients ignore it, as every line of a kind they do not know, until they read remote
  access.

What a device keeps, and when it reads again:

- A device keeps the last `remoteAccess` it read with the saved host, like routes. It reads
  capabilities again on every successful connection (through the tunnel too), on every return
  to the foreground, and whenever a pulse's `remoteAccess` line names another revision than the
  entry it keeps.
- It replaces the kept entry with each entry the host lists: that entry is the host's kept
  report, so `enabled: false` means that the owner turned the switch off (or never on). When the
  host lists no `remoteAccess` it keeps the entry it has, as it keeps a known Tailscale route
  when the host briefly lists none.
- The Mac's `nodeId`, learned over the pinned connection of any route, is the only node ID the
  tunnel dials; another one learned the same way replaces it.
- The tunnel is a way to the host while the kept entry has `enabled` true, a `nodeId`, and at
  least one direct address or a `relayUrl` (AgentLandCore's
  `RemoteAccessCapabilities.offersTunnel`, which also drops addresses that are not global
  unicast, and a `relayUrl` whose host is not one a device may dial: a global unicast address by
  the rule of direct addresses, or a public DNS name; `RemoteAccessCapabilities.isDialableRelayURL`,
  "Reading it"). A device whose kept entry has the Mac's `nodeId` also reads the address record once
  every address of a race has failed, whatever else the entry says. A record whose `sequence` is
  above the kept entry's replaces the entry for dialing, and the tunnel is then a way to the host
  while the record gives an address or a relay (a record's relay counts only when it is one of n0's,
  `RemoteAccessCapabilities.isN0RelayURL`); any other record changes nothing ("When the Mac's
  address changes"; `fetchesAddressRecord` and `tunnelRoute(record:)`).

### When the Mac's address changes

The Mac's external address or the port the router grants can change (the provider hands out
another address, the router restarts), the fallback's relay can change, and a Mac whose Keychain
lost its iroh key (Migration Assistant, a Keychain reset) has a new node ID. A device at home or
on Tailscale learns each change at its next connection. A device away from home learns new
addresses from the owner's own iCloud, with no AgentLand server:

- **The record.** Container `iCloud.dev.agentland`, private database, custom zone
  `RemoteAccess`, record type `RemoteAccessAddress`, record name the host's `hostId`
  (`NoticeHostID` of its certificate fingerprint, as notices use). Its fields are CloudKit
  encrypted values (`CKRecord.encryptedValues`), so iCloud's servers do not read the Mac's
  address: `nodeId` (String), `directAddresses` (list of String), `relayUrl` (String, only with
  the fallback), `revision` (String, the report's) and `sequence` (Int64, the `sequence` of the
  host's answer to that report). The Mac app writes it after every report with `enabled: true`
  whose revision differs from the record's (as far as this run of the app knows: the first such
  report after a launch writes it), never after the switch went off, and deletes it when the switch
  goes off. It makes its `CKContainer` only as the notices do (`NoticeCloudKit.unavailability()`:
  the entitlement check, `AGENTLAND_CLOUDKIT=0`; `CloudKitRemoteAccessAddressDatabase.make()`) and
  never holds up a report to the host for it. One change at a time goes to iCloud, and only the
  latest wanted state counts:
  - A failed write or delete is retried with the notice relay's backoff until it succeeds or
    something newer is wanted. A delete of a record that is not there counts as done.
  - When the switch goes off, a pending write (one waiting for its retry) is dropped, and a write
    in flight finishes (or fails) before the delete is sent, so no write lands after the delete.
  - At each launch while the switch is off, the app deletes any record left for its host (the
    Mac was offline, or quit, when the owner turned the switch off), retried like any delete. It
    keeps in its preferences the host whose record it may have written, from before the write until
    a delete is confirmed, so a Mac that never wrote one sends nothing to iCloud at launch.
  Even so, a record the Mac has not updated or deleted yet never outranks what a device learned
  later: a device takes a record only when it is newer than its kept entry ("Reading it").
- **Reading it.** A device that has the Mac's node ID from a pinned connection fetches the record
  by record ID once every address of a race has failed, whatever its kept entry says: off, on
  without an address, or on with addresses that no longer answer. It fetches at most once per race
  and at most every 30 s; a race that may not fetch (the last fetch was less than 30 s ago) uses
  what that fetch found, kept in memory only. When the kept entry gives the tunnel nothing to dial,
  the tunnel's probe waits for that record before it decides. The record counts only when its
  `sequence` is above the kept entry's:
  it follows a report the device has not seen, as when the owner turned the switch on while the
  phone was suspended, the Mac's mapping had failed when the phone last connected, or the Mac's
  address changed since. Then, when the record's `nodeId` is the node ID it learned over a pinned
  connection, the tunnel dials the record's addresses and relay in place of the kept ones (a
  record with neither means there is no way in); a record with another `nodeId` is "A new Mac node
  ID" below. A record that is not newer (the Mac has not rewritten it yet, or has not deleted it
  yet after the switch went off) changes nothing: the kept entry decides, as without a record, so
  a device that learned the switch is off, or the Mac's new node ID, over a pinned connection
  never dials a stale record. It takes only direct addresses that
  `RemoteAccessDirectAddress.isDialable` takes (at most 8), a `relayUrl` that is one of n0's relays
  and a `sequence` of at least 1 (a record without one is no record). n0's relays are the only ones
  the Mac's fallback uses (`RelayMode.defaultMode()` until it has a home relay, then that one), so
  the record's relay must be `https://<one label>.relay.n0.iroh.link/` (iroh 1.2's defaults are
  `use1-1`, `usw1-1`, `euc1-1` and `aps1-1`; the final dot optional, no port or 443) in the host's
  form (`RemoteAccessCapabilities.isN0RelayURL`). A rule on the host name alone is not enough: a
  public DNS name can resolve to an address on the phone's network (or rebind to one), and a relay
  whoever wrote the record runs would see the phone's address and both node IDs; n0 answers for its
  own names. `relayUrl` in capabilities, which the Mac itself gives over a pinned connection, is read
  with the wider rule of direct addresses: a global unicast IP address, or a public DNS name (at
  least two labels, the last starting with a letter, none of the special-use names `localhost`,
  `local`, `test`, `invalid`, `example`, `internal`, `home.arpa`, `onion`, `alt` or `arpa`), with a
  port of 1–65535 when it names one (`RemoteAccessCapabilities.isDialableRelayURL`). It takes nothing
  else from the record and never saves the record's values as the host's entry: the kept entry
  changes only when the host lists one. AgentLandCore's
  `RemoteAccessAddressRecord` is what a device takes from the record, and
  `RemoteAccessCapabilities.tunnelRoute(record:)` where the tunnel dials.
- **Why that is safe.** Whoever can write the owner's private database (the owner's Apple ID)
  can point a device at other addresses or keep it from connecting, but cannot be the Mac: the
  QUIC handshake succeeds only with the pinned node ID, and the TLS inside only with the pinned
  certificate, and the device sends its token only inside that TLS.
- **A new Mac node ID.** A newer record whose `nodeId` is not the one the device learned means the
  Mac has a new key. The device does not dial it, and its offline banner says "Connect to <Mac> at
  home or over Tailscale once to reach it from anywhere again." It learns the new node ID at
  that connection. A record that still names the old node ID after that (the Mac could not write
  its record yet: iCloud not signed in after Migration Assistant, `AGENTLAND_CLOUDKIT=0`, a write
  still retrying) is older than the entry that brought the new one, so the device dials its kept
  route and does not ask again.
- **Another Apple ID.** A device signed in to another Apple ID than the Mac's (a family
  member's) does not see the record. For it a changed address needs one connection at home or
  over Tailscale, and its offline banner says so when the tunnel fails.

### The two apps

The host sees only the tunnel socket. For the Mac app and the phone to meet:

- **Streams.** ALPN `agentland/tunnel/1`. One bidirectional QUIC stream carries one connection
  of the phone's `APIClient`: the phone's bridge opens a stream (`openBi`) for each connection
  it has let through (below); the Mac accepts each stream (`acceptBi`), opens one new
  connection to the tunnel socket for it, writes the preamble with that iroh connection's
  `remoteId()`, and copies bytes both ways in chunks of at most 64 KiB (never a whole body).
- **Ending a stream.** Each direction ends on its own, a reset means an abort, never a normal
  end, and a failure in one direction never resets the other (AgentLandCore's
  `RemoteAccessTunnel.StreamEnds` holds these rules and `StreamCode` the codes):
  - Normal end. When a socket reads its end of file (the host or `APIClient` closed its
    connection or its sending side), the bridge finishes the stream's send side (`finish()`).
    When the stream's receive side reaches its end, the bridge shuts down the socket's sending
    side (`shutdown(SHUT_WR)`; a TCP FIN on the phone). So the last bytes the host writes before
    it closes (a response with `Connection: close`, an HTTP/2 GOAWAY, TLS close_notify, the
    pulse's `stopping` line) arrive: they are retransmitted as long as the path allows, never
    dropped by a reset.
  - A failed write, code 1. A write to a socket that fails (`EPIPE`: the phone's bytes, a new
    request, a WINDOW_UPDATE or its close_notify, reach a host socket that has just closed) stops
    the stream's receive side (`stop(errorCode: 1)`) and leaves the send side alone: one that has
    finished stays finished, so QUIC still delivers the host's last bytes it carries, and one
    that is open still ends with the socket's own end of file or failed read.
  - A failed read, code 1. A read from a socket that fails (`ECONNRESET`) means the socket is
    gone: the bridge resets the stream's send side unless it has finished
    (`reset(errorCode: 1)`), and stops its receive side (`stop(errorCode: 1)`).
  - A reset that arrives aborts the socket: on the phone a TCP reset (`SO_LINGER` 0, then
    `close()`), on the Mac `close()` of the Unix socket; the send side is then reset with code 1
    unless it has finished. A stop that arrives (the peer's write to its socket failed) ends the
    send side: the bridge reads what the socket still sends and drops it until the socket's end
    of file, so it never closes a socket with unread input (on TCP that sends a reset, which can
    make `APIClient` drop response bytes it has received and not yet read), and the receive side
    goes on to its own end.
  - Refused, code 2. When the tunnel socket ends before the host has sent a single byte (the
    host refused the preamble or a limit, or is stopping), or the Mac cannot connect to the
    socket at all (the host is not running), the Mac resets and stops the stream with code 2
    instead of finishing it. A write to the socket that fails before the host has sent a byte (the
    phone's ClientHello meets the socket the host just closed) is not yet a failed write: the Mac
    waits for the socket's end, and stops the stream with code 2 when nothing came, with code 1
    once the host has sent bytes. The phone's bridge then aborts its connection and tells the phone's
    route logic that the host refused, unless `APIClient` had already ended that connection (its
    sending side finished). The stop and the reset arrive in either order: over iroh the stop
    usually comes first, as the failed write of `APIClient`'s ClientHello, and the reset with code
    2 that follows still counts as the refusal.
  - Once both directions have ended, both sides let go of the stream, without resetting a send
    side that has finished, and close the socket.
- **The gate's answers.** The Mac's `IrohPeerGate` closes a connection whose node ID it does not
  admit with application code 403 (reason `not paired`) once its handshake completes, on a direct
  path and through the relay alike, and a connection it cannot hand over with 503: the app is not
  taking connections, or the gate has no peer list yet (`RemoteAccessTunnel.ConnectionCode`). A
  403 therefore always comes from a list the host gave. The gate's handshake limits refuse a
  connection before its handshake, a QUIC refusal without an application code that the phone sees
  as a dial that fails: 2 handshakes at once from one source (an IPv4 address, a global IPv6 /64,
  or the sender the relay names), 64 at once on direct paths, and 8 at once through the relay from
  senders it does not list (keys anyone can make, so these have slots of their own that listed
  senders and direct paths never wait for). A phone dials one connection at a time, so on its own
  it never meets its source's limit.
- **The Mac endpoint.** `presetMinimal()` with its Keychain key, the ALPN above and `bindPort`
  38842 on every address. No relay (`RelayMode.disabled()`) unless the fallback is on. With the
  fallback on, one n0 relay, never all of them: when the owner turns the fallback on, the
  endpoint runs with `RelayMode.defaultMode()` only until it has a home relay; the app keeps
  that relay's URL in its preferences and from then on runs with
  `RelayMode.customFromUrls([that URL])`, so `relayUrl` stays the same and the idle traffic is
  one relay's (n0's four default relays cost about 4 GB a month, iroh #4523). It picks again
  only when the owner turns the fallback off and on, or when the kept relay has been unreachable
  for 10 minutes (`watchHomeRelay` has not listed it for that long); while it picks, the report has
  `fallbackRelay: true` and no `relayUrl`. The minimal preset stays, so nothing is published to
  n0's DNS. The mapped external addresses that the report carries (global unicast) go to
  `addExternalAddr`, and a changed one replaces the last (`removeExternalAddr`). The endpoint and the
  mapping follow the switch, not the host: Disconnect and a host restart leave them running, and a
  stream that arrives meanwhile finds no tunnel socket and ends with code 2. Each endpoint gets a gate with no
  list (`IrohPeerGate(endpoint:)`), not an empty one: until the first peers answer it cannot tell
  a paired device from another, so it closes every connection it completes with 503, never 403,
  and a phone that dials during a start (the app's launch, an update, the switch turned on, the
  restart that pins the fallback's relay) comes back instead of giving up. The first peers answer
  comes at once ("Routes for the Mac app (local-only)"), and the gate then follows the peers
  route.
- **The Mac switches.** "Reach this Mac from anywhere", off by default: turning it on starts the
  endpoint, maps UDP 38842 and reports `enabled: true` once the mapping attempt has finished;
  turning it off reports `enabled: false`, removes the mapping, deletes the address record and
  closes the endpoint; quitting removes the mapping and closes the endpoint without a report
  (waiting at most 10 s for the router). Quit waits also when the switch is off but a change is
  still under way (the switch turned off a moment before, its delete not yet answered; the launch's
  cleanup), and it shuts remote access down only once the app is sure to end: a Quit that is
  cancelled (the host or the managed runtime could not be stopped) leaves remote access running as
  the switch says. An address record whose delete has not gone through by then is deleted at the
  next launch (below). The switch's row (in the sidebar's This Mac and in Settings → Remote Access)
  says in plain words that it opens one port on the router, and shows off, opening the port,
  reachable at the reported address, reachable through the relay, or what failed and why; while the
  kept relay is unreachable it says within how many minutes (rounded up) the app picks another, and
  the row reads the time again while it shows. When a report has no direct address while the endpoint has its port (the mapping's
  external address is not global unicast, the router answered without a mapping, another router,
  or the last mapping's lease ended while the router made no new one), the switch's row says "Your
  network does not let other networks reach this Mac directly. Turn on “Use a public relay if a
  direct connection fails” to reach it anyway." When an attempt made no mapping and the report
  kept the last mapping's addresses, the row says that the router did not open the port this time,
  that AgentLand keeps trying, and that devices keep the last address until the mapping's lease
  ends (at most 2 hours). When the endpoint cannot bind its port (another program holds UDP 38842),
  nothing is mapped (the router would forward to that program), the report has no addresses and
  no relay (`fallbackRelay: false`), the row says the port is in use, and the bind is tried again
  after 15 s, 30 s, 1, 2 and 5 minutes and then every 10 minutes, and at once after a network
  change or a wake. The app reads the endpoint's key from the Keychain once and keeps it in memory
  until it quits, so an endpoint that starts again (the fallback turned on or off, a relay picked, the
  kept relay unreachable) and a host start never read the Keychain again. Until the Keychain gives the
  key in a run (the owner denied the access prompt an ad-hoc build brings up, or the Keychain cannot
  be read), the endpoint does not start, nothing is mapped or reported (a report needs the node ID),
  and the row says what failed. The key is read again after 10 minutes and then every hour, not on the
  bind's schedule, since each read can bring the prompt back; at once after a network change or a
  wake; when the owner turns a switch or the connection mode back to trusted HTTPS; and at a host
  start, for the report's node ID. Whichever of these reads gives the key, with the switch on the
  endpoint starts then (and is reported once its mapping attempt has finished), so an owner who allows
  the prompt a host start brings up does not wait for the next timed read. "Use a public relay if a
  direct connection fails", off by default, is offered only while the first is on; it uses one of
  n0's public relays, which the row names.
  The tunnel carries the host's HTTPS, so while the Mac app's connection mode is local development
  HTTP (a host without a tunnel socket) the endpoint and the mapping stay off whatever the switch
  says, and nothing is reported (devices keep the last report). The switch keeps its setting, its row
  stays and says so, and it can be turned on only with trusted HTTPS; back in trusted HTTPS both start
  again as after a launch. Every change of the mode goes to remote access in the order it is made, and
  the last one counts: a change back made while the one before still waits behind other work is never
  dropped because a status reported in between shows the old mode.
  After a network change to another router at the same gateway address (the link-layer address
  differs: a replaced router, another network with the same default), the old mapping is not
  deleted: its delete would reach the new router, which may confirm it for a mapping it never had.
  `PortMapper` keeps its records per router (the gateway and its link-layer address, when known), so
  the old mapping stays recorded and is deleted (or taken over) the next time the Mac is on that
  router, or ends with its lease.
- **The phone's endpoint.** It runs only while the phone tries or uses the tunnel in the
  foreground: `presetMinimal()` with its Keychain key. It dials the route
  `RemoteAccessCapabilities.tunnelRoute(record:)` gives, `.dial(nodeID, directAddresses,
  relayURL)`: `EndpointAddr(id: nodeID, relayUrl: relayURL, addresses: directAddresses)`, from the
  kept entry or from a newer address record alike. Its relay mode comes from that route too,
  never from the kept entry's `fallbackRelay`: `RelayMode.customFromUrls([relayURL])` when the
  route has a relay, `RelayMode.disabled()` otherwise (`RemoteAccessTunnelRoute.endpointRelayURLs`).
  iroh dials through a relay only from an endpoint that runs with it ("listening and dialing via
  relay are both disabled" without one), so a record that carries only a relay (the Mac behind
  carrier-grade NAT, the switch and the fallback turned on while the phone was away) is reached
  only this way; and without a relay on the route the endpoint talks to none. When the route's
  relay differs from the relays the running endpoint was built with (the record brought one, the
  Mac picked another, the route has none), the endpoint is closed and started again with the
  route's before it dials (`needsEndpointRestart(runningWith:)`). The handshake succeeds only with
  the Mac that holds that node ID.
- **The phone's bridge.** Every app on the phone can reach 127.0.0.1, so the bridge opens a
  stream only for connections that prove they are `APIClient`'s:
  - It listens on 127.0.0.1 on an ephemeral port while the tunnel is in use in the foreground.
    It is an HTTP CONNECT proxy with a secret made each time it starts (32 random bytes,
    base64url without padding, kept in memory only). `APIClient`'s tunnel transport is a
    `URLSession` whose `proxyConfigurations` is `[ProxyConfiguration(httpCONNECTProxy:
    .hostPort(host: "127.0.0.1", port: <port>), tlsOptions: nil)]`, with
    `applyCredential(username: "agentland", password: <secret>)`. URLSession answers the bridge's
    407 with that credential on its own; its delegate never sees the proxy's challenge, so every
    challenge the delegate sees gets the pinned check. Each start of the bridge gets a new session.
  - Its requests go to the paired address itself (`https://<paired host>:<port>`): URLSession
    sends `CONNECT <paired host>:<port> HTTP/1.1` to the bridge and does not resolve the name.
    The TLS inside is the pinned TLS of every route (`PinnedTrustEvaluator` with the paired
    fingerprint, validated for the paired name), with the device's bearer token.
  - For each connection it accepts, the bridge reads a request head of at most 4 KiB within
    250 ms, and after its 407 the second head within 250 ms again
    (`RemoteAccessTunnel.Bridge`). URLSession writes the first about 0.1 ms after it connects and
    the second about 0.3 ms after the 407 (macOS 26 over loopback), so the deadline bounds only
    connections that send nothing. URLSession's first `CONNECT` carries no credential; the
    bridge answers `HTTP/1.1 407 Proxy Authentication Required` with `Proxy-Authenticate: Basic
    realm="agentland"` and `Content-Length: 0`, and URLSession sends the `CONNECT` again on the
    same connection with `Proxy-Authorization: Basic` and the base64 of `agentland:<secret>`.
    With that credential (compared in constant time) and the paired host and port as its
    target, the bridge opens one stream and answers `HTTP/1.1 200 Connection Established`; the
    phone's TLS follows. A second head without the credential, another method or target, or a
    malformed, longer or late head closes the connection. Nothing reaches the Mac before the
    credential has been checked.
  - It opens at most 8 streams at once and 30 in any minute, half the host's limits for one
    device (16 and 60); above them it answers `HTTP/1.1 503 Service Unavailable` and closes,
    without a stream.
  - At most 16 connections wait for a head at once (`RemoteAccessTunnel.Bridge.WaitingRoom`). A
    connection that arrives while 16 wait takes the place of the one that has waited longest,
    which the bridge closes, so connections that send nothing (another app holding the places)
    never keep `APIClient`'s out. A connection that has shown the credential no longer waits and
    is never closed for room.
  - So an app that finds the port gets 407 or 503 and nothing more: none of its connections
    reaches the Mac, counts toward the device's limits there or appears in the host's audit.
    What is left: an app that runs in the background and keeps opening connections faster than
    `APIClient` sends its two heads (well under a millisecond) can push `APIClient`'s connections
    out while it runs. The phone then sees its tunnel probes fail and backs off as for a dial that
    fails (Refusals).
- **The phone's routes.** The tunnel is a candidate of its own kind, never an address
  (`HostEndpoint`):
  - It is a candidate only as "What a device keeps" says.
  - It is always tried last, 250 ms after the last address of "Routes" starts (at once when all
    of them have failed), even when the tunnel answered last, so a phone that comes home uses
    the home network.
  - It is never saved as `lastEndpoint`. It is one endpoint for `epochEndpoint` whatever the
    bridge's port, so coming back to the foreground on a new port is not a recovery by itself.
  - Its probe starts the endpoint, dials the Mac, starts the bridge and asks `GET /v1/health`
    through it, within 10 s: a dial through a relay can take several seconds longer than the 4 s
    an address gets.
  - While it carries the connection, the phone races the addresses again (without the tunnel)
    on every network path change and every 60 s, and moves to the first that answers, which is
    a recovery (a new `connectionEpoch`). Capabilities through the tunnel leave out `preview`,
    so the Browser comes back when an address answers: a move between the tunnel and an address
    reads the projects and capabilities again.
  - When an address wins a race, when a race has nothing to dial (the kept entry and a newer record
    give no way in, or name a new Mac key) and when the app goes to the background, the phone closes
    its endpoint and bridge; the next try binds the endpoint again with the same key. When the tunnel
    carried the connection as the app went to the background, the connection counts as down from then
    on: back in the foreground the banner says "Reconnecting to <Mac>…" ("Through remote access.
    Nothing is sent until the connection is back."), Settings → Connection's tunnel row says
    "Reconnecting…" (never "Connected" while nothing is connected, also while the tunnel's probe waits
    for the addresses and the address record) and typing is refused, until a route answers, which
    is a recovery (a new `connectionEpoch`). A dial still in
    flight then (iroh's calls cannot be cancelled) is closed when it ends, and never holds up the
    race.
  - The phone never pairs or registers through it.
- **Refusals.** What the phone sees through the tunnel, and what it does:
  - The gate closes with 403 (on a direct path or through the relay), or a request answers 403
    `tunnel_device_mismatch` (another device record holds this device's node ID, as after the app
    was reinstalled and paired again): the Mac does not admit this device's node ID for this
    saved host. The phone stops dialing the tunnel for it (kept with the saved host, so a relaunch
    does not dial it either). While no address answers, its offline banner ("Can’t reach <Mac>")
    gives the addresses' own advice first (the Mac may be asleep or on another network, or to check
    Tailscale when a Tailscale route is known: the refusal is kept, so it also shows at home while
    the Mac sleeps), then "Remote access doesn’t let this device in: connect to <Mac> at home or over
    Tailscale to turn it back on, or pair again if <Mac> removed this device.", after a relaunch too
    (the kept refusal is the reason the tunnel is not tried). The gate cannot tell a node ID it was
    never given from a device the owner removed; the removed one meets 401 at home and pairs again.
    At that connection it registers when `deviceNodeId` is not its own, and the tunnel is a candidate
    again once the host has its node ID.
  - 401 `unauthorized` with the device's token: the device was removed, handled as on every
    route.
  - A stream reset with code 2, a gate close with 503 (the Mac app is starting or stopping), or a
    dial that fails (also a refusal before the handshake, from the gate's limits): the Mac or the
    host cannot take the connection now. The tunnel is tried again after 2, 4, 8, 16 and 32 s and
    then every 60 s, each with up to a quarter more at random, not on the addresses' 2 s
    schedule. A network path change, a return to the foreground (from the background; iOS comes
    back through the inactive phase) and the banner's Retry start the schedule over; Retry then
    dials the tunnel with the addresses at once.


### Contextual terminal names (2026-10-08)

Hosts advertise `terminalFeatures: ["title"]` (later hosts add `"resume"`, and `"keep"` when
terminals run in the keeper: they survive the host, end only as "How terminals end" says, and
answer 503 `terminals_unavailable` and 409 `terminal_input_stalled` as above, and `"shared"`
when every paired device reaches every terminal, "Terminals from other devices"). Terminal records add optional
`contextTitle`, the latest useful description, ahead of `programTitle`, `command`
and the original `title` launch label for display, and `contextTitleSource`, where it
came from: `"program"` (an OSC title) or `"device"` (`POST /v1/terminal/title`); it is
omitted without a `contextTitle`, and older hosts omit it. A meaningful OSC title always
becomes `programTitle`; it replaces `contextTitle` only while that did not come from a
device (or there is none yet). A device's name stays until a device names the terminal
again (2026-10-16: a program's routine retitle used to replace a device's better name
and turn names on their way into `title_stale`). An idle/default OSC title clears only
`programTitle`. The terminal log's title and archive change feed retain the description,
and the keeper's record its source, including after exit and host restart (a record
from an older host restores its description as the program's).
The original program remains separately recorded for Start Again.
`GET /v1/terminals/others` lists `contextTitleSource` beside `contextTitle`. Clients show
the same name everywhere: `contextTitle`, else `programTitle`, else the command or the
program's name, for tabs, "On <device>" rows and Resume alike, and an open terminal's
live OSC titles leave a device's name in place as the host does.

`POST /v1/terminal/title` takes `{projectId?, terminalId, title, basedOn}`. Since
2026-10-15 any paired device may name any terminal, and `projectId` is optional as on the
other routes that address one terminal ("Terminals from other devices"); before, only the
terminal's own device could. `title` is a cleaned 1–60 character string;
`basedOn` is a nonzero output byte cursor. Future cursors fail with 400; cursors
older than the saved description fail with 409 `title_stale`; success returns
`{accepted:true}` and makes the description the device's. Only a description that
was actually replaced (by a device, or by an OSC title while the program's was the
description) moves the cursor a name must not be older than. Repeating a successful
name does not change output or execute input.

Native clients describe the rendered screen (the last 60 rows) with the on-device
naming model, under a terminal's own instructions rather than a chat's (2026-10-16).
The model reads, in order, the latest requests typed into the program (prompt lines
such as `❯ `, `› `, `> `, `$ `, `% ` and `user@host … % `, inside TUI box borders too;
the input box still being typed in and its placeholder are not requests), the recent
meaningful output with spinner and status chrome removed (spinner lines, "esc to
interrupt", timers, token counters, key hints, box rules, blank lines), and the current
name, which it returns unchanged while it still fits. Lines that look like secrets are
left out. A name must share a content word with the requests or output (prefixes
cover simple inflections), so a name the screen does not show ("JSON format task") is
rejected; an idle screen (no request and little output) names nothing. Without Apple
Intelligence, or when the model's name is rejected, a typed request of three or more
words, cut to six, or a known shell command (never its arguments) supplies a
conservative title; otherwise the previous title stays. A name equal to the current one
but for case or punctuation is not sent. The model is asked again for one terminal only
when its newest request changed, or at most every 30 s while its meaningful output
changes (a redrawn spinner or timer is no change), after output settled for five
seconds. Naming runs only for the active terminal in an unlocked foreground app,
outside Low Power Mode. It reads no keystrokes, makes no paid model request, and sends
only the resulting title and cursor to the paired host. Old hosts do not receive this
route. The normal terminal output and input paths are unchanged.

Apple Intelligence switch (2026-10-16): each device's Settings → Apple Intelligence (the
Mac's Settings → General) turns the on-device model on or off for its quips, chat names and
terminal names; off, the rules above name terminals and the host's own naming names chats. The
Mac app also names every terminal on its host while the switch is on, the model can run and
Low Power Mode is off: every device's, its own and routed agents, whether or not a device shows
them. Every 15 s it lists them with `GET /v1/terminals/all` (the Mac's own session only; the
web app is never offered it). For each running terminal whose `cursor` moved since its screen
was last read, it reads the newest 256 KB of output (`GET /v1/terminal/output`, `wait=0`),
renders it in a headless terminal at the listed `cols` × `rows` (160 × 50 when the host lists
no size) and names the visible screen as devices do, on the same schedule, one terminal and one
model call at a time. A name goes to `POST /v1/terminal/title` with `basedOn` the cursor the
read ended at; `title_stale` is taken and nothing is sent again. It never types into or resizes
a terminal, and the output goes only to the model on the Mac. Devices that show a terminal may
name it too; the cursor guard settles which name stays.
