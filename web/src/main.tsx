import { useEffect, useState, useSyncExternalStore } from "react";
import { createRoot } from "react-dom/client";
import { api, query } from "./api";
import { workspace } from "./workspace";
import { chatAgents, chatProviderName, chatProviderOf, supportsTab, withGeneralChats } from "./chat-policy";
import type { Capabilities, Project, Tab } from "./types";
import { TerminalPanel, forgetTerminal } from "./TerminalPanel";
import { ChatPanel } from "./ChatPanel";
import { FilesPanel, FileEditor, DiffPanel } from "./FilesPanel";
import { Launcher } from "./Launcher";
import "./styles.css";
const mark = (kind: string) =>
  kind === "terminal"
    ? "›_"
    : kind === "chat"
      ? "○"
      : kind === "diff"
        ? "±"
        : "≡";

function App() {
  const { state, ready, dirty, saving, error, conflict } = useSyncExternalStore(
    workspace.subscribe,
    workspace.getSnapshot,
  );
  const [projects, setProjects] = useState<Project[]>([]),
    [capabilities, setCapabilities] = useState<Capabilities>({}),
    // A chat waits for the host's capabilities: they decide its agent,
    // modes and whether it is read-only.
    [capabilitiesLoaded, setCapabilitiesLoaded] = useState(false);
  const [bootError, setBootError] = useState(""),
    [expired, setExpired] = useState(false),
    [connection, setConnection] = useState("Connecting…");
  const [panel, setPanel] = useState<"files" | "git" | null>(null),
    [sessionsOpen, setSessionsOpen] = useState(false);
  const visibleTabs = state.tabs.filter((tab) => supportsTab(tab, capabilities, projects));
  const active = visibleTabs.find((tab) => tab.id === state.activeTabId),
    // A workspace chat's Files and Git are its own workspace's; a Chats-space
    // chat has none, so they follow the workspace in use.
    selectedProject =
      active?.kind === "chat" && !projects.some((p) => p.id === active.projectId)
        ? state.projectId
        : active?.projectId || state.projectId;
  const refreshProjects = async () => {
    const result = await api.request<{ projects: Project[] }>("/v1/projects");
    setProjects(result.projects);
    if (!workspace.getSnapshot().state.projectId && result.projects[0])
      workspace.update((s) => ({ ...s, projectId: result.projects[0].id }));
  };
  useEffect(() => {
    let stopped = false;
    const expiredSession = () => setExpired(true);
    window.addEventListener("agentland-auth-expired", expiredSession);
    void (async () => {
      try {
        await api.bootstrap();
        await workspace.load();
        const [caps] = await Promise.all([
          api.request<Capabilities>("/v1/capabilities"),
          refreshProjects(),
        ]);
        if (!stopped) {
          setCapabilities(withGeneralChats(caps));
          setCapabilitiesLoaded(true);
          setConnection("Connected to this Mac");
        }
      } catch (e) {
        if (!stopped)
          setBootError(
            e instanceof Error ? e.message : "Could not open AgentLand.",
          );
      }
    })();
    return () => {
      stopped = true;
      window.removeEventListener("agentland-auth-expired", expiredSession);
    };
  }, []);
  useEffect(() => {
    if (!ready || expired || bootError) return;
    let stopped = false;
    const check = async () => {
      try {
        await api.request("/v1/capabilities", {
          signal: AbortSignal.timeout(8000),
        });
        if (!stopped) setConnection("Connected to this Mac");
      } catch {
        if (!stopped) setConnection("Connection interrupted");
      }
    };
    const timer = setInterval(() => {
      void check();
    }, 15000);
    return () => {
      stopped = true;
      clearInterval(timer);
    };
  }, [ready, expired, bootError]);
  useEffect(() => {
    const leave = (event: BeforeUnloadEvent) => {
      if (workspace.getSnapshot().dirty) {
        event.preventDefault();
        event.returnValue = "";
      }
    };
    const save = () => {
      if (document.visibilityState === "hidden") void workspace.flush();
    };
    window.addEventListener("beforeunload", leave);
    document.addEventListener("visibilitychange", save);
    return () => {
      window.removeEventListener("beforeunload", leave);
      document.removeEventListener("visibilitychange", save);
    };
  }, []);
  useEffect(() => {
    const trapModalFocus = (event: KeyboardEvent) => {
      if (event.key !== "Tab") return;
      const dialogs =
        document.querySelectorAll<HTMLElement>(".overlay .dialog");
      const dialog = dialogs[dialogs.length - 1];
      if (!dialog) return;
      const controls = [
        ...dialog.querySelectorAll<HTMLElement>(
          'button:not(:disabled), input:not(:disabled), select:not(:disabled), textarea:not(:disabled), [tabindex="0"]',
        ),
      ].filter((el) => el.getClientRects().length);
      if (!controls.length) return;
      const first = controls[0],
        last = controls[controls.length - 1];
      if (
        !dialog.contains(document.activeElement) ||
        (!event.shiftKey && document.activeElement === last)
      ) {
        event.preventDefault();
        first.focus();
      } else if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      }
    };
    document.addEventListener("keydown", trapModalFocus);
    return () => document.removeEventListener("keydown", trapModalFocus);
  }, []);
  const open = (incoming: Omit<Tab, "id"> & { id?: string }) => {
    if (incoming.kind === "chat" && !supportsTab(
      {
        kind: "chat",
        projectId: typeof incoming.projectId === "string" ? incoming.projectId : "",
        resourceId: incoming.resourceId,
        agent: incoming.agent,
      },
      capabilities, projects,
    )) return;
    workspace.update((s) => {
      const existing = [...s.tabs, ...s.detachedTabs].find(
        (t) =>
          t.kind === incoming.kind &&
          t.projectId === incoming.projectId &&
          t.resourceId === incoming.resourceId &&
          (t.kind !== "diff" ||
            (t.repository === incoming.repository && t.base === incoming.base)),
      );
      const tab =
        existing ||
        ({ ...incoming, id: incoming.id || crypto.randomUUID() } as Tab);
      return {
        ...s,
        tabs: s.tabs.some((t) => t.id === tab.id) ? s.tabs : [...s.tabs, tab],
        detachedTabs: s.detachedTabs.filter((t) => t.id !== tab.id),
        activeTabId: tab.id,
      };
    });
    setSessionsOpen(false);
  };
  const changeTab = (id: string, changes: Partial<Tab>) =>
    workspace.update((s) => ({
      ...s,
      tabs: s.tabs.map((t) => (t.id === id ? { ...t, ...changes } : t)),
      detachedTabs: s.detachedTabs.map((t) =>
        t.id === id ? { ...t, ...changes } : t,
      ),
    }));
  const close = (id: string, ended = false) => {
    workspace.update((s) => {
      const tab = s.tabs.find((t) => t.id === id),
        index = s.tabs.filter((t) => supportsTab(t, capabilities, projects)).findIndex((t) => t.id === id),
        tabs = s.tabs.filter((t) => t.id !== id),
        supported = tabs.filter((t) => supportsTab(t, capabilities, projects));
      return {
        ...s,
        tabs,
        detachedTabs: [
          ...s.detachedTabs.filter((t) => t.id !== id),
          ...(tab && !ended ? [tab] : []),
        ],
        activeTabId:
          s.activeTabId === id
            ? supported[Math.min(index, supported.length - 1)]?.id || null
            : s.activeTabId,
      };
    });
    forgetTerminal(id); // Disposes the browser view; the host retains the process.
  };
  const move = (id: string, offset: number) =>
    workspace.update((s) => {
      const tabs = [...s.tabs],
        visible = tabs.filter((t) => supportsTab(t, capabilities, projects)),
        index = tabs.findIndex((t) => t.id === id),
        neighbor = visible[visible.findIndex((t) => t.id === id) + offset],
        target = neighbor ? tabs.findIndex((t) => t.id === neighbor.id) : -1;
      if (index >= 0 && target >= 0)
        [tabs[index], tabs[target]] = [tabs[target], tabs[index]];
      return { ...s, tabs };
    });
  const rename = () => {
    if (active) {
      const name = prompt("Tab name", active.title);
      if (name?.trim())
        changeTab(active.id, { title: name.trim().slice(0, 100) });
    }
  };
  if (!ready || bootError)
    return (
      <main className="boot">
        <strong>AgentLand</strong>
        <h1>
          {bootError
            ? "Open your workspace from the menu bar"
            : "Opening your workspace…"}
        </h1>
        <p role={bootError ? "alert" : "status"}>
          {bootError || "Connecting to the AgentLand server on this Mac."}
        </p>
        {bootError && (
          <button onClick={() => location.reload()}>Try again</button>
        )}
      </main>
    );
  return (
    <div className="app">
      <header className="topbar">
        <button
          className="brand"
          onClick={() => workspace.update((s) => ({ ...s, activeTabId: null }))}
        >
          AgentLand
        </button>
        <label className="workspace-picker">
          <span>Workspace</span>
          <select
            aria-label="Workspace"
            value={state.projectId}
            onChange={(e) =>
              workspace.update((s) => ({
                ...s,
                projectId: e.target.value,
                activeTabId: null,
              }))
            }
          >
            <option value="" disabled>
              Choose a folder
            </option>
            {projects.map((p) => (
              <option key={p.id} value={p.id}>
                {p.name}
              </option>
            ))}
          </select>
        </label>
        <span className="grow" />
        <button
          onClick={() => setSessionsOpen((v) => !v)}
          aria-expanded={sessionsOpen}
        >
          Running Sessions
        </button>
        <button
          onClick={() =>
            workspace.update((s) => ({ ...s, helpDismissed: !s.helpDismissed }))
          }
          aria-label="Toggle help"
        >
          Help
        </button>
      </header>
      <div className="tabs-row">
        <div className="tab-strip" role="tablist" aria-label="Workspace tabs">
          <button
            role="tab"
            aria-selected={!active}
            className={!active ? "tab selected" : "tab"}
            onClick={() =>
              workspace.update((s) => ({ ...s, activeTabId: null }))
            }
          >
            New session
          </button>
          {visibleTabs.map((tab) => (
            <div
              className={
                tab.id === active?.id ? "tab-item selected" : "tab-item"
              }
              key={tab.id}
            >
              <button
                role="tab"
                aria-selected={tab.id === active?.id}
                className="tab"
                onClick={() =>
                  workspace.update((s) => ({ ...s, activeTabId: tab.id }))
                }
              >
                <span className="tab-symbol" aria-hidden>
                  {mark(tab.kind)}
                </span>
                {tab.title}
                {tab.kind === "file" &&
                tab.draft !== undefined &&
                tab.draft !== tab.original
                  ? " •"
                  : ""}
              </button>
              <button
                className="tab-close"
                aria-label={`Close ${tab.title} tab`}
                title="Close tab; keep session and draft"
                onClick={() => close(tab.id)}
              >
                ×
              </button>
            </div>
          ))}
        </div>
        <button
          className="new-tab"
          aria-label="New tab"
          onClick={() => workspace.update((s) => ({ ...s, activeTabId: null }))}
        >
          +
        </button>
      </div>
      {error && (
        <div className="notice error" role="alert">
          <span>
            {conflict
              ? "Another browser window saved changes. Your tabs and drafts are still here."
              : error}
          </span>
          <button onClick={() => workspace.downloadRecovery()}>
            Download drafts
          </button>
          {conflict ? (
            <>
              <button
                onClick={() => {
                  if (
                    confirm(
                      "Replace the saved workspace with this window’s tabs and drafts? Download a copy first if you need both.",
                    )
                  )
                    void workspace
                      .keepThisWindow()
                      .catch((e) => alert(e.message));
                }}
              >
                Keep this window
              </button>
              <button
                onClick={() => {
                  if (
                    confirm(
                      "Load the saved workspace? Download this window’s unsaved drafts first.",
                    )
                  )
                    location.reload();
                }}
              >
                Load saved workspace
              </button>
            </>
          ) : (
            <button onClick={() => void workspace.flush()}>Retry save</button>
          )}
        </div>
      )}
      <div className="workspace-body">
        <nav className="tool-rail" aria-label="Workspace tools">
          <button
            aria-pressed={panel === "files"}
            disabled={!selectedProject}
            onClick={() => setPanel(panel === "files" ? null : "files")}
          >
            <span aria-hidden>≡</span>Files
          </button>
          <button
            aria-pressed={panel === "git"}
            disabled={!selectedProject}
            onClick={() => setPanel(panel === "git" ? null : "git")}
          >
            <span aria-hidden>±</span>Git
          </button>
        </nav>
        {panel && (
          <div className="explorer">
            <div className="explorer-title">
              <strong>
                {projects.find((p) => p.id === selectedProject)?.name ||
                  "Workspace"}
              </strong>
              <button
                aria-label="Close side panel"
                onClick={() => setPanel(null)}
              >
                ×
              </button>
            </div>
            <FilesPanel
              key={`${selectedProject}:${panel}`}
              projectId={selectedProject}
              mode={panel}
              onOpen={open}
            />
          </div>
        )}
        <main className="surface" id="workspace-surface">
          {active && (
            <div className="context-bar">
              <span>
                {projects.find((p) => p.id === active.projectId)?.name ||
                  "Chats"}
              </span>
              <span className="path">
                {active.kind === "file" || active.kind === "diff"
                  ? active.resourceId
                  : active.kind === "chat"
                    ? chatProviderName(chatProviderOf(active), capabilities)
                    : active.agent || active.kind}
              </span>
              <span className="grow" />
              <button
                onClick={() => move(active.id, -1)}
                disabled={visibleTabs[0]?.id === active.id}
                aria-label="Move tab left"
              >
                ←
              </button>
              <button
                onClick={() => move(active.id, 1)}
                disabled={visibleTabs.at(-1)?.id === active.id}
                aria-label="Move tab right"
              >
                →
              </button>
              <button onClick={rename}>Rename tab</button>
            </div>
          )}
          {!active ? (
            <Launcher
              projects={projects}
              capabilities={capabilities}
              projectId={state.projectId}
              lastAgent={state.lastAgent}
              lastChatProvider={state.lastChatProvider}
              onChatProvider={(provider) => workspace.update((s) => ({ ...s, lastChatProvider: provider }))}
              onProject={(id) =>
                workspace.update((s) => ({ ...s, projectId: id }))
              }
              onRefresh={refreshProjects}
              onOpen={open}
              onAgent={(agent) =>
                workspace.update((s) => ({ ...s, lastAgent: agent }))
              }
            />
          ) : active.kind === "terminal" ? (
            <TerminalPanel
              key={active.id}
              tab={active}
              onEnd={() => close(active.id, true)}
            />
          ) : active.kind === "chat" && !capabilitiesLoaded ? (
            <p className="empty-chat" role="status">Loading conversation…</p>
          ) : active.kind === "chat" ? (
            <ChatPanel
              key={active.id}
              tab={active}
              capabilities={capabilities}
              projects={projects}
              continueWorkspace={projects.find((p) => p.id === state.projectId)}
              onChange={(changes) => changeTab(active.id, changes)}
              onOpen={open}
            />
          ) : active.kind === "file" ? (
            <FileEditor
              key={active.id}
              tab={active}
              onChange={(changes) => changeTab(active.id, changes)}
            />
          ) : (
            <DiffPanel key={active.id} tab={active} />
          )}
        </main>
      </div>
      {!state.helpDismissed && (
        <aside className="help-bar">
          <p>
            Start an agent terminal to work by describing what you need. Close a
            tab to put it away; use <b>End Session</b> to stop its process. Your
            sessions keep running when you close the browser.
          </p>
          <button
            aria-label="Dismiss help"
            onClick={() =>
              workspace.update((s) => ({ ...s, helpDismissed: true }))
            }
          >
            ×
          </button>
        </aside>
      )}
      <footer className="status-bar">
        <span
          className={
            connection.startsWith("Connected") ? "connected" : "offline"
          }
        >
          {connection}
        </span>
        <span>
          {saving
            ? "Saving workspace…"
            : dirty
              ? "Unsaved changes"
              : "Workspace saved on this Mac"}
        </span>
      </footer>
      {sessionsOpen && (
        <SessionShelf
          projects={projects}
          capabilities={capabilities}
          detached={state.detachedTabs.filter((tab) => supportsTab(tab, capabilities, projects))}
          onOpen={open}
          onClose={() => setSessionsOpen(false)}
        />
      )}
      {expired && (
        <div className="overlay">
          <section
            className="dialog"
            role="alertdialog"
            aria-modal="true"
            aria-label="Session expired"
          >
            <h2>Reconnect from the menu bar</h2>
            <p>
              Choose Open AgentLand on your Mac. Your running sessions remain on
              the server.
            </p>
            <p>Download any unsaved drafts before leaving this page.</p>
            <button onClick={() => workspace.downloadRecovery()}>
              Download drafts
            </button>
          </section>
        </div>
      )}
    </div>
  );
}

function SessionShelf({
  projects,
  capabilities,
  detached,
  onOpen,
  onClose,
}: {
  projects: Project[];
  capabilities: Capabilities;
  detached: Tab[];
  onOpen: (tab: Omit<Tab, "id">) => void;
  onClose: () => void;
}) {
  const [items, setItems] = useState<Array<Omit<Tab, "id">>>([]),
    [error, setError] = useState(""),
    [loading, setLoading] = useState(true);
  useEffect(() => {
    let stopped = false;
    const spaces = [
      ...projects,
      ...(capabilities.plainChats?.projectId
        ? [{ id: capabilities.plainChats.projectId, name: "Chats" }]
        : []),
    ];
    // Claude Code and Codex chats run in workspaces (2026-10-12).
    const workspaceChats =
      !!capabilities.workspaceChats ||
      !!capabilities.chatProviders?.some((p) => chatAgents.includes(p));
    void (async () => {
      const found: Array<Omit<Tab, "id">> = [],
        errors: string[] = [];
      for (const project of spaces) {
        const space = project.id === capabilities.plainChats?.projectId;
        const requests = [
          ...(space || workspaceChats
            ? [{ kind: "chat" as const, path: "/v1/sessions", field: "sessions" }]
            : []),
          ...(capabilities.terminal &&
          project.id !== capabilities.plainChats?.projectId
            ? [
                {
                  kind: "terminal" as const,
                  path: "/v1/terminals",
                  field: "terminals",
                },
              ]
            : []),
        ];
        const results = await Promise.allSettled(
          requests.map((r) =>
            api.request(r.path + "?" + query({ projectId: project.id })),
          ),
        );
        results.forEach((result, index) => {
          if (result.status === "rejected") {
            errors.push(`${project.name}: ${result.reason.message}`);
            return;
          }
          for (const item of result.value[requests[index].field] || []) {
            // A workspace lists only its Claude Code and Codex chats.
            if (
              requests[index].kind === "chat" &&
              !space &&
              !chatAgents.includes(chatProviderOf({ resourceId: item.id, agent: item.provider }))
            )
              continue;
            found.push({
              kind: requests[index].kind,
              projectId: project.id,
              resourceId: item.id,
              title:
                item.contextTitle ||
                item.programTitle ||
                item.command ||
                item.title ||
                "Untitled session",
              status: item.status || "",
              agent: item.provider,
            });
          }
        });
      }
      if (!stopped) {
        setItems(found);
        setError(errors.join(" "));
        setLoading(false);
      }
    })();
    return () => {
      stopped = true;
    };
  }, []);
  const all = [
    ...items,
    ...detached.filter(
      (t) =>
        !items.some(
          (i) =>
            i.kind === t.kind &&
            i.projectId === t.projectId &&
            i.resourceId === t.resourceId,
        ),
    ),
  ];
  return (
    <div
      className="overlay"
      onKeyDown={(e) => {
        if (e.key === "Escape") onClose();
      }}
    >
      <section
        className="dialog session-shelf"
        role="dialog"
        aria-modal="true"
        aria-label="Running Sessions"
      >
        <div className="dialog-title">
          <h2>Running Sessions</h2>
          <button
            autoFocus
            onClick={onClose}
            aria-label="Close Running Sessions"
          >
            ×
          </button>
        </div>
        <p>Reopen a terminal, conversation, or saved draft.</p>
        {loading && <p role="status">Loading sessions…</p>}
        {error && (
          <p role="alert" className="error">
            {error}
          </p>
        )}
        {!loading && all.length === 0 && (
          <p>No sessions yet. Start one from New session.</p>
        )}
        <div className="session-list">
          {all.map((tab, index) => (
            <button
              key={`${tab.kind}:${tab.projectId}:${tab.resourceId}:${index}`}
              onClick={() => onOpen(tab)}
            >
              <span className="tab-symbol" aria-hidden>
                {mark(String(tab.kind))}
              </span>
              <span>
                <b>{String(tab.title)}</b>
                <small>
                  {projects.find((p) => p.id === tab.projectId)?.name ||
                    "Chats"}{" "}
                  · {String(tab.kind)}
                  {tab.status ? ` · ${tab.status}` : ""}
                </small>
              </span>
              <span className="grow" />
              Open
            </button>
          ))}
        </div>
      </section>
    </div>
  );
}
createRoot(document.getElementById("root")!).render(<App />);
