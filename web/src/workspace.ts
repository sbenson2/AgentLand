import { api, APIError } from "./api";
import type { Tab, Workspace } from "./types";

export const emptyWorkspace = (): Workspace => ({
  version: 1,
  projectId: "",
  lastAgent: "",
  activeTabId: null,
  tabs: [],
  detachedTabs: [],
  helpDismissed: false,
});

export function restoreWorkspace(value: Record<string, any>): Workspace {
  const result = { ...emptyWorkspace(), ...value } as Workspace;
  result.tabs = Array.isArray(value.tabs) ? value.tabs.filter(isTab) : [];
  result.detachedTabs = Array.isArray(value.detachedTabs)
    ? value.detachedTabs.filter(isTab)
    : [];
  const legacy = value.legacy;
  if (legacy && !result.legacyImported) {
    const existing = new Set(
      [...result.tabs, ...result.detachedTabs].map((t) => t.id),
    );
    for (const old of legacy.tabs || []) {
      const kind = old.kind === "editor" ? "file" : old.kind;
      if (!["terminal", "chat", "file"].includes(kind) || existing.has(old.id))
        continue;
      result.tabs.push({
        id: old.id,
        kind,
        projectId: old.projectID,
        resourceId: old.resourceID,
        title: old.title,
        ...(old.kind === "chat" || old.editorDirty ? { draft: old.draft } : {}),
        revision: old.editorBaseRevision,
        model: old.chatModelID,
        agent: old.chatAgent,
        dirty: old.editorDirty,
        legacy: old,
      });
    }
    result.projectId ||= legacy.projectID || "";
    result.activeTabId ||= legacy.selectedTabID || result.tabs[0]?.id || null;
    result.legacyImported = true;
  }
  if (!result.tabs.some((tab) => tab.id === result.activeTabId))
    result.activeTabId = result.tabs[0]?.id || null;
  return result;
}

function isTab(value: any): value is Tab {
  return (
    value &&
    typeof value.id === "string" &&
    typeof value.projectId === "string" &&
    typeof value.resourceId === "string" &&
    ["terminal", "chat", "file", "diff"].includes(value.kind)
  );
}

type Snapshot = {
  state: Workspace;
  ready: boolean;
  saving: boolean;
  dirty: boolean;
  error: string;
  conflict: boolean;
};
export class WorkspaceStore {
  private revision = 0;
  private listeners = new Set<() => void>();
  private timer?: ReturnType<typeof setTimeout>;
  private changed = 0;
  private flight = false;
  private snapshot: Snapshot = {
    state: emptyWorkspace(),
    ready: false,
    saving: false,
    dirty: false,
    error: "",
    conflict: false,
  };
  getSnapshot = () => this.snapshot;
  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };
  private publish(patch: Partial<Snapshot>) {
    this.snapshot = { ...this.snapshot, ...patch };
    this.listeners.forEach((listener) => listener());
  }
  async load() {
    const result = await api.request<{
      revision: number;
      state: Record<string, any>;
    }>("/web/state");
    this.revision = result.revision;
    const state = restoreWorkspace(result.state);
    this.publish({ state, ready: true });
    if (state.legacyImported && !result.state.legacyImported)
      this.update((s) => s);
  }
  update(change: (state: Workspace) => Workspace) {
    if (!this.snapshot.ready) return;
    this.changed++;
    this.publish({ state: change(this.snapshot.state), dirty: true });
    clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      void this.flush();
    }, 150);
  }
  async flush() {
    if (this.flight || !this.snapshot.dirty || this.snapshot.conflict) return;
    this.flight = true;
    this.publish({ saving: true });
    const generation = this.changed;
    try {
      const result = await api.request<{ revision: number }>("/web/state", {
        method: "PUT",
        body: JSON.stringify({
          revision: this.revision,
          state: this.snapshot.state,
        }),
      });
      this.revision = result.revision;
      this.publish({
        dirty: generation !== this.changed,
        error: "",
        saving: false,
      });
    } catch (error) {
      this.publish({
        saving: false,
        error:
          error instanceof Error ? error.message : "Could not save workspace.",
        conflict: error instanceof APIError && error.status === 409,
      });
    } finally {
      this.flight = false;
    }
    if (this.snapshot.dirty && !this.snapshot.error) void this.flush();
  }
  async keepThisWindow() {
    // Explicit resolution only; never silently overwrite a newer browser window.
    const latest = await api.request<{ revision: number }>("/web/state");
    this.revision = latest.revision;
    this.publish({ conflict: false, error: "" });
    await this.flush();
  }
  downloadRecovery() {
    const url = URL.createObjectURL(
      new Blob([JSON.stringify(this.snapshot.state, null, 2)], {
        type: "application/json",
      }),
    );
    const link = document.createElement("a");
    link.href = url;
    link.download = "agentland-workspace-recovery.json";
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
}
export const workspace = new WorkspaceStore();
