# Agent catalog, automatic updates and providers — plan (2026-09-26)

## The owner's decisions

The owner asked for three things: CLI agents that update themselves, every CLI agent available, and an open way to connect model providers. They chose:

- **Updates:** automatic, with a safety check.
  - Daily and at launch, each agent updates when it is not running a task.
  - A handshake that uses no model checks the new version.
  - The old version is kept, and the update rolls back if the check fails.
  - OpenCode moves out of the app bundle so it can update too.
- **Agents:** all of them, installed on tap.
  - An Agents list shows every agent in the ACP registry; tapping one installs it.
  - Installed agents appear in New Chat and New Terminal and update automatically.
  - Agents already on the Mac show without installing.
- **Providers:** OpenCode's catalog.
  - AgentLand lists the providers OpenCode speaks (models.dev) in Settings.
  - Keys stay in the Keychain. No extra server.

## Sources

- **Agent Client Protocol (ACP)**, an open standard from Zed (Apache-2.0): JSON-RPC 2.0 over an agent's stdio. https://agentclientprotocol.com, https://github.com/agentclientprotocol/agent-client-protocol
- **ACP registry** (41 agents on 2026-09-26): https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json
  - Each agent has `id`, `name`, `version`, `description`, `repository`, `website`, `license`, `icon` and `distribution`.
  - `distribution` is one of `npx {package, args}`, `uvx {package, args}`, or `binary {<platform>: {archive, cmd, args, sha256}}`. Platforms are named like `darwin-aarch64`.
  - Versions are refreshed hourly.
  - Examples: `claude-acp` = `@agentclientprotocol/claude-agent-acp`; `codex-acp` = `@agentclientprotocol/codex-acp`; `gemini` = `@google/gemini-cli --acp`; `github-copilot-cli` = `@github/copilot --acp`; `opencode` = binary `opencode acp`; `goose` = binary `goose acp`; `cursor` = binary `cursor-agent acp`, without `sha256`.
- **Self-updating CLIs already on the Mac.** Claude Code and Codex expose native update commands. AgentLand schedules those commands for supported installed CLIs while preserving the owner's install and updater settings; it does not replace them with registry adapters.
- **OpenCode speaks 75+ providers** through models.dev and the AI SDK, including any OpenAI-compatible base URL, OpenRouter and Ollama. Its server lists them with their models and key variables.
- **Open WebUI** is a clean-room reference only (AGENTS.md). Its idea of OpenAI-compatible connections is what OpenCode's catalog already covers.

## Host contract (docs/HOST-API.md "Agents"; the host agent writes it there first)

### `GET /v1/agents`

The catalog, for paired devices and the Mac's local session:

```json
{
  "registry": {"fetchedAt": "2026-09-26T20:00:00Z", "error": "optional text when the last fetch failed"},
  "agents": [{
    "id": "gemini",
    "name": "Gemini CLI",
    "description": "…",
    "website": "https://…",
    "license": "Apache-2.0",
    "source": "registry",
    "state": "notInstalled",
    "installedVersion": "0.61.0",
    "latestVersion": "0.62.0",
    "previousVersion": "0.60.1",
    "updatedAt": "…",
    "lastError": "…",
    "autoUpdates": true,
    "chat": true,
    "terminal": true,
    "verified": true
  }]
}
```

- `source` is `registry` (AgentLand installs and updates it), `local` (found on the Mac; supported Codex and Claude Code installs can be updated by AgentLand through their native updater) or `bundled` (the app's OpenCode, until a managed one takes over).
- `state` is one of `notInstalled`, `installing`, `installed`, `updating` or `failed`.
- `lastError` is present only after a failed install, update or check.
- `chat`: it can run chats (ACP, or AgentLand's own adapter for OpenCode, Claude Code and Codex).
- `terminal`: it has a command for a terminal tab.
- `verified`: the download is checked against the registry's `sha256`, or it is an npm/uv package pinned to its version.
- `supportsUpdates` is optional updater capability, independent of policy. `autoUpdates`
  is true only for a supported installed agent while the persisted host-wide setting is on.
  Top-level `automaticUpdates` defaults off; older hosts omit it. Hosts advertise
  `updateSettings`; authenticated `POST /v1/agents/settings` accepts and returns the required
  Boolean. Manual updates stay available while off.
- `installedVersion`, `latestVersion` and `previousVersion` are omitted when absent.
- Paths, commands and environments never leave the host.
- `GET /v1/agents/icon?id=…` serves the registry icon the host cached, so devices never contact the CDN.

### Changes

`POST /v1/agents/install`, `/v1/agents/uninstall` and `/v1/agents/update`, with body `{"id": "…"}`:

- **Answers:** 202 with the agent (the work runs in the background and `GET` shows its state).
- **Errors:**
  - 404 `unknown_agent`;
  - 409 `agent_busy` (a chat turn or terminal of that agent is running; updates wait for idle);
  - 409 `not_managed` (install/uninstall of a local agent, or update when that local CLI has no supported native updater);
  - 400 `unsupported_platform`;
  - 400 `unverified_download`: a binary without `sha256`. It installs only when the body has `"allowUnverified": true`, which the apps send after a confirmation that names the source.
- **Access:** paired devices and the local session, like the other management routes. They also work through the tunnel, since the owner is often away from home.

### Capabilities

- `agents: ["catalog", "install", "acp"]`.
- `agentCatalog: [{"id", "name", "chat", "terminal"}]`: the usable ones (installed, local or bundled), so the apps can build New Chat and New Terminal without another request.
- `chatProviders` and `terminalPrograms` list those ids too. Registry ids are used as they are, except these map onto the native agents and are not listed twice:
  - `claude-acp` → `claude`
  - `codex-acp` → `codex`
  - `opencode` → `opencode`

### Installs

- **Location:** `<state>.agents/<id>/<version>/`, with folders 0700 and files 0600 or executable, and `<state>.agents/<id>/current.json` holding `{version, command, args, sha256?, installedAt}`. Two versions are kept: current and previous.
- **By distribution:**
  - `binary`: download over HTTPS only. The size is bounded (500 MiB). Check `sha256` before unpacking, then unpack zip, tar.gz or tar.bz2 with no absolute paths, `..` or links outside the folder. `cmd` must resolve inside the folder.
  - `npx`: `npm install --prefix <folder> --no-audit --no-fund <package@version>`, then run the package's bin from `<folder>/node_modules/.bin`. The agent never runs through `npx` itself.
  - `uvx`: `uv tool install` into the folder (`UV_TOOL_DIR`/`UV_TOOL_BIN_DIR`), pinned to the version.
- **Tools:** `node`/`npm` and `uv` are found like the CLIs (Homebrew, `~/.local/bin`, PATH). Without them, those agents say so (`lastError`).
- **Process:** installs run with a clean environment: no provider keys and no AgentLand secrets. Each has a time limit, is cancelled on shutdown, and never runs twice for one agent.

### Automatic updates

- **When:** only while the host setting is enabled (off by default), at host start (after 2 minutes), then every 24 hours with jitter. The registry is fetched with a size cap and ETag.
- **Local Codex and Claude Code:** before the host invokes a native updater it checks the exact executable with bounded `update --help` and requires command-specific usage. The result is cached by executable identity. Updates use the exact path plus literal `update`, a clean allowlisted environment, process-group cancellation and a finite timeout; updater output never enters errors. Opt-outs stay effective. Registry availability and adapter versions do not gate these updates.
- **What:** for each installed registry agent whose `latestVersion` differs:
  1. Wait until the agent is idle: no running chat turn and no open terminal of it.
  2. Install the new version beside the current one.
  3. Check it: start its ACP command and send `initialize` (protocol version 1, no client capabilities). A valid answer within 20 s passes. No session is made and no model is called.
  4. Point `current.json` at the new version and keep the old one as `previous`.
  5. If the install or check fails, keep the current version, set `lastError`, and try again at the next run.
- **Chats:** running chats keep their process; new chats and new terminals use the new version.
- **Adoption:** a successful native update retires idle agent processes. Codex also detects an external executable replacement and retires its old app-server when active work has ended, preserving its stored threads and history.

### OpenCode

- The host installs and updates the registry's `opencode` binary into `<state>.agents/opencode/`, like the others.
- Its check is stronger:
  - Start `opencode serve` on a free loopback port with a throwaway data and config folder and a random password.
  - Wait for `/global/health`, read its version, and call `GET /session` and `GET /provider`.
  - No model is called.
- The Mac app launches the managed `current.json` OpenCode when it passes its own checks: the path is inside the agents folder and the file's SHA-256 matches. Otherwise it uses the bundled one.
- A new OpenCode takes effect when OpenCode and the host restart. The Mac app does that on its own when the host reports `restartWanted: true` for `opencode`, and:
  - nothing has been running for 10 minutes: no open terminals, no running turn, no device viewing a chat; or
  - at the next launch.
- A failing managed OpenCode (it will not start) falls back to the bundled one, and the host records `lastError`.

### What the Mac app reads (the local session only)

The `opencode` entry of `GET /v1/agents` also has two fields:
- `restartWanted: true` when a managed version newer than the running one is current.
- `idleForSeconds`: how long nothing has run. That means no open terminal, no running chat turn and no device viewing a chat; a device views a chat while its presence reports `viewingSessionId`.

The Mac app polls it every 5 minutes while the host runs.

### Providers (`GET /v1/providers`, paired devices and the local session)

`{"providers": [{"id": "anthropic", "name": "Anthropic", "connected": true, "models": 12, "env": ["ANTHROPIC_API_KEY"]}]}`

- The host builds it from the running OpenCode's `GET /provider`: all providers, whether each is connected, and the key variable names from models.dev.
- It never includes a key.
- The host answers 503 `provider_catalog_unavailable` when OpenCode does not answer.

### ACP chats (`desktop/acp_*.go`)

- **Registry and process:** chats of an ACP agent are kept in the host's chat registry, like Claude Code and Codex chats (provider = agent id, cwd = the workspace). There is one process per chat, started lazily. It stops after 10 minutes idle, never while a permission request waits.
- **Protocol:**
  - `initialize`, then `session/new {cwd, mcpServers: []}`, or `session/load` when the agent advertises `loadSession` and the chat has a session ID.
  - `session/prompt` with text (and images, when `promptCapabilities.image`).
  - `session/cancel` for Stop.
  - `session/set_mode` when the agent lists modes.
- **Streaming:** `session/update` maps onto the hub's parts:
  - `agent_message_chunk` → text
  - `agent_thought_chunk` → reasoning
  - `tool_call` and `tool_call_update` → tool parts (title, kind, status, content and locations)
  - `plan` → a plan part (or text)
  - `current_mode_update` → mode
  - `available_commands_update` is ignored.
- **Approvals:** `session/request_permission` becomes an approval card with the agent's options (allow once, allow always, reject). The answer is the chosen `optionId`; Stop cancels.
- **Auth:** when `session/new` fails because the agent needs a sign-in (its `authMethods`), the chat shows `agent_auth_required` with the method names. The app offers to open the agent in a terminal to sign in.
- **Client capabilities:** none are advertised at first (no `fs`, no `terminal`), so agents use their own tools.
- **Bounds:** lines up to 4 MiB, a stderr ring, a clean environment except the agent's own and the owner's PATH and HOME, and the process group killed on stop.

### Terminals

A terminal program for:
- an installed registry agent whose distribution runs a CLI: the binary's `cmd` without its ACP arguments, or the npm package's main bin;
- known CLIs found on the Mac: `claude`, `codex`, `opencode`, `gemini`, `qwen`, `goose`, `copilot`, `cursor-agent`, `amp`, `kimi`, `droid`, `vibe`.

The allowlist of names becomes this list; clients still send a name, never a command.

## The apps

- **Settings → Agents** (shared pane: iPhone, iPad, Mac):
  - Installed agents, with version, "Updated automatically" and the last update or error. Update Now and Uninstall for registry agents.
  - Available agents, with name, description and Install. A confirmation names the source for an unverified download.
  - Icons come through the host.
  - The pane shows only with `agents` in capabilities.
- **New Chat and New Terminal list the host's `agentCatalog`** (names from the host).
  - `AgentProvider` and `TerminalProgram` accept any id the host lists, with its name. The known ones keep their order first; unknown ids are no longer dropped.
  - ACP chats use the same chat screen. Features come from the provider's info: no rewind or fork for ACP at first.
- **Sign-in needed:** a notice with Open in Terminal (the agent's terminal program).

## The Mac app

- **Managed OpenCode** as above: `current.json`, validated, with the bundled one as fallback. It restarts when idle after an update, and falls back on failure.
- **Settings → AI Providers** lists OpenCode's providers (models.dev, from the running OpenCode's `GET /provider`) with a search.
  - A key is saved to the Keychain under its provider's variable (`<X>_API_KEY` or `_TOKEN`, as now) and applies at OpenCode's next restart. It restarts at once when nothing is running, otherwise when idle.
  - Connected providers show which of their models appear in OpenCode chats.
  - On iPhone and iPad the list is read-only for now: which providers are connected, and "Add keys in AgentLand on your Mac".

## Not in this round

- Keys entered on the phone.
- Sign-in flows inside the app (agents sign in in a terminal).
- ACP client capabilities (`fs`, `terminal`).
- Model pickers for ACP agents.
- Replacing the native OpenCode, Claude Code and Codex adapters with ACP.

## Verification

- **Host:**
  - Unit and table tests: registry parsing, distribution choice, sha256 and archive safety (zip-slip, links), npm and uv argument building, the update state machine (idle wait, check, switch, rollback), ACP JSON-RPC framing, update mapping and permissions. A fake ACP agent is a test binary.
  - An opt-in live test installs `goose` or `opencode` from the registry into a temporary state folder and runs the `initialize` check. It needs network and spends no model credits. It is never run against the owner's state.
- **Apps:** package tests. UI tests use a fixture catalog. The simulator installs nothing.
- **Mac:** package tests (managed OpenCode choice and fallback, the provider list).
- **Installs** as usual.

New named agent terminals prepare updates before PTY launch, joining any ongoing update and
reserving the agent through registration. Native updater support is probed with cancelable
waits; managed agents read a fresh registry. Busy agents defer with optional `updateNotice`,
unsupported updaters launch with a notice, and shells launch as before. Since 2026-10-17
(owner: "Hourly, never blocks"; docs/HOST-API.md "Agent terminal preparation") a launch updates
an agent, registry agents' refresh included, only when no automatic attempt for it started in
the last hour, waits for it at most 30 seconds, and is never refused for it: a failed or slow
update starts the installed version with an `updateNotice`. A slow update in place (Codex,
Claude Code outside its `versions` folder) is stopped, its process group ended, before the
terminal starts; one installed beside the running version (registry installs, Claude Code's
native installer) goes on in the background. Each attempt is logged to the host's log. This
replaces the 90-second bound and the 409 refusal (`agent_update_failed`, `agent_update_timeout`)
of the first version. Cancellation/shutdown stops preparation; no automatic replay follows
uncertainty. Essential first OpenCode installation remains available with the setting off.
