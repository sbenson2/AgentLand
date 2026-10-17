import { useEffect, useRef, useState } from "react";
import { api, APIError, post, query } from "./api";
import { chatProviderLabel, unavailableWorkspaceChatProviders, workspaceChatProviders } from "./chat-policy";
import type { Capabilities, Project, Tab } from "./types";
const labels: Record<string, string> = {
  opencode: "OpenCode",
  claude: "Claude Code",
  codex: "Codex",
  shell: "Shell",
};
const label = (id: string) => labels[id] || id;
type Props = {
  projects: Project[];
  capabilities: Capabilities;
  projectId: string;
  lastAgent: string;
  lastChatProvider?: string;
  onChatProvider: (provider: string) => void;
  onProject: (id: string) => void;
  onRefresh: () => Promise<void>;
  onOpen: (tab: Omit<Tab, "id">) => void;
  onAgent: (agent: string) => void;
};
export function Launcher({
  projects,
  capabilities,
  projectId,
  lastAgent,
  lastChatProvider,
  onChatProvider,
  onProject,
  onRefresh,
  onOpen,
  onAgent,
}: Props) {
  const programs = (capabilities.terminalPrograms || []).filter(
    (p) => p !== "shell",
  );
  const [agent, setAgent] = useState(
    programs.includes(lastAgent) ? lastAgent : programs[0] || "",
  );
  // Chat starts Claude Code or Codex in the selected workspace, only on hosts
  // that list workspaceChats (2026-10-12).
  const chatProviders = workspaceChatProviders(capabilities);
  const signInNeeded = unavailableWorkspaceChatProviders(capabilities);
  const [chatProvider, setChatProvider] = useState(lastChatProvider ?? "");
  // The last agent chosen, else the host's first (Claude Code).
  const selectedChatProvider = chatProviders.some((p) => p.id === chatProvider)
    ? chatProvider
    : chatProviders[0]?.id ?? "";
  const [busy, setBusy] = useState(""),
    [error, setError] = useState(""),
    [uncertain, setUncertain] = useState(false),
    [browse, setBrowse] = useState(false);
  const flight = useRef(false);
  useEffect(() => {
    if (!agent && programs.length)
      setAgent(programs.includes(lastAgent) ? lastAgent : programs[0]);
  }, [capabilities]);
  const start = async (
    kind: "terminal" | "chat",
    program: string,
  ) => {
    const target = projectId;
    if (flight.current || !target || !program || uncertain) return;
    flight.current = true;
    setBusy(`${kind}:${program}`);
    setError("");
    try {
      const chatName = chatProviders.find((p) => p.id === program)?.name || label(program);
      const title =
        kind === "chat"
          ? `${chatName} chat`
          : program === "shell"
            ? "Terminal"
            : label(program);
      const created = await api.request<{ id: string; title: string }>(
        kind === "terminal" ? "/v1/terminals" : "/v1/sessions",
        post({
          projectId: target,
          title,
          ...(kind === "terminal"
            ? { program, rows: 30, cols: 100 }
            : { provider: program }),
        }),
      );
      if (!created.id)
        throw new APIError(
          "The server did not return a session. Check Running Sessions before starting another.",
        );
      if (kind === "terminal" && program !== "shell") onAgent(program);
      if (kind === "chat") onChatProvider(program);
      onOpen({
        kind,
        projectId: target,
        resourceId: created.id,
        title: created.title || title,
        agent: program,
      });
    } catch (e) {
      const ambiguous = !(e instanceof APIError) || e.uncertain;
      setUncertain(ambiguous);
      setError(
        `${e instanceof Error ? e.message : "Could not start a session."}${ambiguous ? " Check Running Sessions before starting another session." : ""}`,
      );
    } finally {
      flight.current = false;
      setBusy("");
    }
  };
  const chosen = projects.find((p) => p.id === projectId);
  return (
    <section className="launcher">
      <div className="launcher-heading">
        <span className="prompt-mark" aria-hidden>
          ›_
        </span>
        <h1>Start a session</h1>
        <p>Choose a folder, then open an agent or a terminal.</p>
      </div>
      <div className="folder-choice">
        <label htmlFor="start-workspace">Working folder</label>
        <div className="field-row">
          <select
            id="start-workspace"
            value={projectId}
            onChange={(e) => onProject(e.target.value)}
          >
            <option value="" disabled>
              Choose a workspace
            </option>
            {projects.map((p) => (
              <option key={p.id} value={p.id}>
                {p.name}
              </option>
            ))}
          </select>
          <button onClick={() => setBrowse(true)}>Choose folder…</button>
        </div>
        <p className="path">
          {chosen?.directory ||
            "Add an existing folder or create a new one on this Mac."}
        </p>
      </div>
      {error && (
        <div className="notice error" role="alert">
          <p>{error}</p>
          {uncertain && (
            <button
              onClick={() => {
                setUncertain(false);
                setError("");
              }}
            >
              I checked Running Sessions
            </button>
          )}
        </div>
      )}
      <div className="start-options">
        <section className="start-option featured">
          <div>
            <h2>Agent terminal</h2>
            <p>
              Describe your task in an installed agent’s terminal. AgentLand
              starts it in your working folder.
            </p>
          </div>
          <div className="field-row">
            <select
              aria-label="Terminal agent"
              value={agent}
              onChange={(e) => setAgent(e.target.value)}
              disabled={!programs.length}
            >
              {!programs.length && (
                <option value="">No terminal agents available</option>
              )}
              {programs.map((p) => (
                <option key={p} value={p}>
                  {label(p)}
                </option>
              ))}
            </select>
            <button
              className="primary"
              disabled={!projectId || !agent || !!busy || uncertain}
              onClick={() => void start("terminal", agent)}
            >
              {busy === `terminal:${agent}`
                ? "Starting…"
                : `Start ${agent ? label(agent) : "agent"}`}
            </button>
          </div>
          {!programs.length && (
            <small>
              Install an agent from AgentLand’s Mac Settings, then reopen this
              page.
            </small>
          )}
        </section>
        <section className="start-option">
          <div>
            <h2>Terminal</h2>
            <p>A shell for commands, scripts, and development tools.</p>
          </div>
          <button
            disabled={
              !projectId ||
              !capabilities.terminalPrograms?.includes("shell") ||
              !!busy ||
              uncertain
            }
            onClick={() => void start("terminal", "shell")}
          >
            {busy === "terminal:shell" ? "Starting…" : "Open terminal"}
          </button>
        </section>
        <section className="start-option">
          <div>
            <h2>Chat</h2>
            <p>
              Claude Code or Codex in your working folder, with its own tools
              and settings. It asks in the chat before it acts.
            </p>
          </div>
          {chatProviders.length > 1 && (
            <label>
              Agent
              <select aria-label="Chat agent" value={selectedChatProvider} onChange={(event) => setChatProvider(event.target.value)}>
                {chatProviders.map((provider) => <option key={provider.id} value={provider.id}>{chatProviderLabel(provider)}</option>)}
              </select>
            </label>
          )}
          {chatProviders.length === 1 && chatProviders[0].auth && (
            <p>Uses {chatProviderLabel(chatProviders[0])}.</p>
          )}
          {signInNeeded.map((provider) => (
            <p key={provider.id}>
              {provider.auth?.message ?? `${provider.name} can’t run Chat on this Mac now.`}
            </p>
          ))}
          {!chatProviders.length && !signInNeeded.length && (
            <small>Claude Code and Codex are unavailable on this Mac.</small>
          )}
          <button
            disabled={!projectId || !chatProviders.some((provider) => provider.id === selectedChatProvider) || !!busy || uncertain}
            onClick={() => void start("chat", selectedChatProvider)}
          >
            {busy === `chat:${selectedChatProvider}` ? "Starting…" : "Open chat"}
          </button>
        </section>
      </div>
      {browse && (
        <FolderPicker
          onClose={() => setBrowse(false)}
          onChoose={async (id) => {
            await onRefresh();
            onProject(id);
            setBrowse(false);
          }}
        />
      )}
    </section>
  );
}
type Folders = {
  path: string;
  displayPath: string;
  parent?: string;
  roots: Array<{ name: string; path: string }>;
  folders: Array<{ name: string; path: string; workspaceId?: string }>;
  truncated: boolean;
};
function FolderPicker({
  onClose,
  onChoose,
}: {
  onClose: () => void;
  onChoose: (id: string) => Promise<void>;
}) {
  const [listing, setListing] = useState<Folders>(),
    [path, setPath] = useState(""),
    [error, setError] = useState(""),
    [busy, setBusy] = useState(false),
    [name, setName] = useState("");
  const flight = useRef(false);
  useEffect(() => {
    const abort = new AbortController();
    setError("");
    void api
      .request<Folders>("/v1/folders?" + query({ path }), {
        signal: abort.signal,
      })
      .then(setListing)
      .catch((e) => {
        if (!abort.signal.aborted) setError(e.message);
      });
    return () => abort.abort();
  }, [path]);
  const choose = async (create: boolean) => {
    if (!listing || flight.current) return;
    flight.current = true;
    setBusy(true);
    setError("");
    try {
      const project = await api.request<Project>(
        create ? "/v1/projects/create" : "/v1/projects",
        post(
          create
            ? { parentDirectory: listing.path, name }
            : { directory: listing.path },
        ),
      );
      await onChoose(project.id);
    } catch (e) {
      const existing =
        e instanceof APIError && (e.details as any)?.error?.projectId;
      if (existing) await onChoose(existing);
      else
        setError(e instanceof Error ? e.message : "Could not add this folder.");
    } finally {
      flight.current = false;
      setBusy(false);
    }
  };
  return (
    <div
      className="overlay"
      onKeyDown={(e) => {
        if (e.key === "Escape" && !busy) onClose();
      }}
    >
      <section
        className="dialog folder-picker"
        role="dialog"
        aria-modal="true"
        aria-label="Choose a folder"
      >
        <div className="dialog-title">
          <h2>Choose a folder</h2>
          <button
            autoFocus
            disabled={busy}
            onClick={onClose}
            aria-label="Close folder picker"
          >
            ×
          </button>
        </div>
        {error && (
          <p role="alert" className="error">
            {error}
          </p>
        )}
        <div className="folder-roots">
          {listing?.roots.map((root) => (
            <button
              key={root.path}
              disabled={busy}
              onClick={() => setPath(root.path)}
            >
              {root.name}
            </button>
          ))}
        </div>
        <div className="folder-location">
          <button
            disabled={!listing?.parent || busy}
            onClick={() => setPath(listing!.parent!)}
          >
            Up
          </button>
          <span className="path">
            {listing?.displayPath || "Loading folders…"}
          </span>
        </div>
        <div className="folder-list">
          {listing?.folders.map((folder) => (
            <button
              key={folder.path}
              disabled={busy}
              onClick={() => setPath(folder.path)}
            >
              <span>{folder.name}</span>
              <small>{folder.workspaceId ? "Workspace" : "Folder"} ›</small>
            </button>
          ))}
          {listing && !listing.folders.length && <p>No subfolders.</p>}
        </div>
        {listing?.truncated && (
          <p>The folder list was shortened. Open a subfolder to continue.</p>
        )}
        <button
          className="primary"
          disabled={!listing || !listing.parent || busy}
          onClick={() => void choose(false)}
        >
          Use this folder
        </button>
        <form
          className="create-folder"
          onSubmit={(e) => {
            e.preventDefault();
            void choose(true);
          }}
        >
          <label htmlFor="new-folder">Or create a folder here</label>
          <div className="field-row">
            <input
              id="new-folder"
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="Folder name"
              maxLength={100}
            />
            <button disabled={!listing || !name.trim() || busy} type="submit">
              Create folder
            </button>
          </div>
        </form>
      </section>
    </div>
  );
}
