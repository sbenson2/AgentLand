import { useEffect, useRef, useState } from "react";
import { EditorView, basicSetup } from "codemirror";
import { EditorState } from "@codemirror/state";
import { api } from "./api";
import type { Tab } from "./types";
type Entry = { name: string; path: string; isDirectory: boolean; size: number };
type Repo = { name: string; path: string };
type Change = {
  path: string;
  status: string;
  index: string;
  worktree: string;
  conflicted: boolean;
  untracked: boolean;
  originalPath?: string;
};
const q = (v: string) => encodeURIComponent(v);
export function statusGroups(changes: Change[]) {
  return {
    staged: changes.filter((c) => !!c.index && !c.untracked),
    unstaged: changes.filter((c) => !!c.worktree && !c.untracked),
    untracked: changes.filter((c) => c.untracked),
  };
}
export function fileSavePayload(tab: Tab, content: string) {
  return {
    projectId: tab.projectId,
    path: tab.resourceId,
    content,
    revision: tab.revision || "",
  };
}
export function FilesPanel({
  projectId,
  onOpen,
  mode,
}: {
  projectId: string;
  onOpen: (tab: Omit<Tab, "id">) => void;
  mode: "files" | "git";
}) {
  const [path, setPath] = useState(""),
    [entries, setEntries] = useState<Entry[]>([]),
    [repos, setRepos] = useState<Repo[]>([]),
    [repo, setRepo] = useState("."),
    [changes, setChanges] = useState<Change[]>([]),
    [error, setError] = useState("");
  useEffect(() => {
    if (!projectId) return;
    setError("");
    if (mode === "files")
      api
        .request<{ entries: Entry[] }>(
          `/v1/files?projectId=${q(projectId)}&path=${q(path)}`,
        )
        .then((d) => setEntries(d.entries))
        .catch((e) => setError(e.message));
    else
      api
        .request<{ repositories: Repo[] }>(
          `/v1/git/repositories?projectId=${q(projectId)}`,
        )
        .then((d) => {
          setRepos(d.repositories);
          setRepo(d.repositories[0]?.path || ".");
        })
        .catch((e) => setError(e.message));
  }, [projectId, mode, path]);
  useEffect(() => {
    if (mode !== "git" || !projectId) return;
    api
      .request<{ changes: Change[] }>(
        `/v1/git/status?projectId=${q(projectId)}&path=${q(repo)}&untracked=all`,
      )
      .then((d) => setChanges(d.changes))
      .catch((e) => setError(e.message));
  }, [projectId, mode, repo]);
  return (
    <aside className="side-panel">
      <div className="side-head">
        <div>
          <span className="eyebrow">
            {mode === "files" ? "Browse" : "Review"}
          </span>
          <h3>{mode === "files" ? "Files" : "Git"}</h3>
        </div>
      </div>
      {error && <p className="muted">{error}</p>}
      {mode === "files" ? (
        <>
          <button
            className="rail-button"
            disabled={!path}
            onClick={() => setPath(path.split("/").slice(0, -1).join("/"))}
          >
            ↑ Parent
          </button>
          {entries.map((e) => (
            <button
              className="rail-button"
              key={e.path}
              onClick={() =>
                e.isDirectory
                  ? setPath(e.path)
                  : onOpen({
                      kind: "file",
                      projectId,
                      resourceId: e.path,
                      title: e.name,
                    })
              }
            >
              {e.isDirectory ? "▸" : "·"} {e.name}
            </button>
          ))}
        </>
      ) : (
        <>
          <select value={repo} onChange={(e) => setRepo(e.target.value)}>
            {repos.map((r) => (
              <option value={r.path} key={r.path}>
                {r.name}
              </option>
            ))}
          </select>
          <div className="side-list">
            <strong>Staged</strong>
            {changes
              .filter((c) => c.index && !c.untracked)
              .map((c) => (
                <button
                  className="rail-button"
                  key={`s-${c.path}`}
                  onClick={() =>
                    onOpen({
                      kind: "diff",
                      projectId,
                      resourceId: c.path,
                      title: c.path,
                      draft: "",
                      repository: repo,
                      base: "staged",
                    })
                  }
                >
                  {c.index} {c.path}
                </button>
              ))}
            <strong>Unstaged</strong>
            {changes
              .filter((c) => c.worktree && !c.untracked)
              .map((c) => (
                <button
                  className="rail-button"
                  key={`u-${c.path}`}
                  onClick={() =>
                    onOpen({
                      kind: "diff",
                      projectId,
                      resourceId: c.path,
                      title: c.path,
                      draft: "",
                      repository: repo,
                      base: "index",
                    })
                  }
                >
                  {c.worktree} {c.path}
                </button>
              ))}
            <strong>Untracked</strong>
            {changes
              .filter((c) => c.untracked)
              .map((c) => (
                <button
                  className="rail-button"
                  key={`n-${c.path}`}
                  onClick={() =>
                    onOpen({
                      kind: "diff",
                      projectId,
                      resourceId: c.path,
                      title: c.path,
                      draft: "",
                      repository: repo,
                      base: "head",
                    })
                  }
                >
                  ?? {c.path}
                </button>
              ))}
          </div>
        </>
      )}
    </aside>
  );
}
export function FileEditor({
  tab,
  onChange,
}: {
  tab: Tab;
  onChange: (changes: Partial<Tab>) => void;
}) {
  const mount = useRef<HTMLDivElement>(null),
    view = useRef<EditorView>();
  const [message, setMessage] = useState("Loading…"),
    [conflict, setConflict] = useState(false),
    loaded = useRef(false),
    request = useRef(0);
  const load = async (force = false) => {
    const token = ++request.current;
    setMessage("Loading…");
    setConflict(false);
    try {
      const doc = await api.request<{ content: string; revision: string }>(
        `/v1/file?projectId=${q(tab.projectId)}&path=${q(tab.resourceId)}`,
      );
      if (token !== request.current || !mount.current) return;
      const content = force ? doc.content : (tab.draft ?? doc.content);
      view.current?.destroy();
      view.current = new EditorView({
        state: EditorState.create({
          doc: content,
          extensions: [
            basicSetup,
            EditorView.updateListener.of((u) => {
              if (u.docChanged) onChange({ draft: u.state.doc.toString() });
            }),
          ],
        }),
        parent: mount.current,
      });
      loaded.current = true;
      onChange({
        original: force ? doc.content : (tab.original ?? doc.content),
        revision: force ? doc.revision : tab.revision || doc.revision,
        draft: content,
      });
      setMessage("");
    } catch (e) {
      if (token === request.current)
        setMessage(e instanceof Error ? e.message : "File unavailable");
    }
  };
  useEffect(() => {
    void load();
    return () => {
      request.current++;
      view.current?.destroy();
    };
  }, [tab.resourceId]);
  const saving = useRef(false);
  const save = async () => {
    if (!view.current || saving.current) return;
    saving.current = true;
    setMessage("Saving…");
    try {
      const content = view.current.state.doc.toString();
      const result = await api.request<{ revision: string }>("/v1/file", {
        method: "POST",
        body: JSON.stringify({
          projectId: tab.projectId,
          path: tab.resourceId,
          content,
          revision: tab.revision || "",
        }),
      });
      onChange({
        draft: view.current?.state.doc.toString() ?? content,
        original: content,
        revision: result.revision,
      });
      setMessage("Saved");
      setConflict(false);
    } catch (e) {
      if ((e as any)?.status === 409) {
        setConflict(true);
        setMessage("The host file changed. Your draft is retained.");
      } else setMessage(e instanceof Error ? e.message : "Save failed");
    } finally {
      saving.current = false;
    }
  };
  return (
    <section
      className="files-view"
      onKeyDown={(e) => {
        if ((e.metaKey || e.ctrlKey) && e.key === "s") {
          e.preventDefault();
          void save();
        }
      }}
    >
      <div className="surface-head">
        <div>
          <p className="eyebrow">File</p>
          <h2>{tab.title}</h2>
        </div>
        <button
          onClick={() => void save()}
          disabled={!loaded.current || saving.current}
        >
          Save
        </button>
      </div>
      {conflict && (
        <div className="notice error">
          Draft retained.{" "}
          <button
            onClick={() => {
              if (
                window.confirm("Discard this draft and reload the host file?")
              )
                void load(true);
            }}
          >
            Reload host file
          </button>
          <button onClick={() => setConflict(false)}>Review draft</button>
        </div>
      )}
      <div className="editor" ref={mount} />
      <div className="terminal-foot">{message}</div>
    </section>
  );
}
export function DiffPanel({ tab }: { tab: Tab }) {
  const [diff, setDiff] = useState("Loading diff…");
  useEffect(() => {
    const base = (tab as any).base || "head";
    const staged = base === "staged" ? "&staged=1" : "";
    const against = base === "index" ? "&against=index" : "";
    api
      .request<{ diff: string }>(
        `/v1/git/diff?projectId=${q(tab.projectId)}&path=${q(String((tab as any).repository || "."))}&file=${q(tab.resourceId)}${staged}${against}`,
      )
      .then((d) => setDiff(d.diff))
      .catch((e) => setDiff(e.message));
  }, [tab.projectId, tab.resourceId, (tab as any).base]);
  return (
    <section className="files-view">
      <div className="surface-head">
        <div>
          <p className="eyebrow">Diff</p>
          <h2>{tab.title}</h2>
        </div>
      </div>
      <pre className="diff">{diff}</pre>
    </section>
  );
}
