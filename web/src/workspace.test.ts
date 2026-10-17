import { afterEach, describe, expect, it, vi } from "vitest";
import { api, APIError } from "./api";
import { restoreWorkspace, WorkspaceStore } from "./workspace";
afterEach(() => {
  vi.restoreAllMocks();
  vi.useRealTimers();
});
describe("workspace recovery", () => {
  it("imports native drafts once while preserving original migration and unknown fields", () => {
    const legacy = {
      tabs: [
        {
          id: "f",
          kind: "editor",
          projectID: "p",
          resourceID: "file",
          title: "file",
          draft: "",
          editorDirty: true,
          editorBaseRevision: "r1",
        },
      ],
      selectedTabID: "f",
    };
    const first = restoreWorkspace({ legacy, future: { kept: true } }),
      second = restoreWorkspace(first);
    expect(second.tabs).toHaveLength(1);
    expect(second.tabs[0]).toMatchObject({ draft: "", revision: "r1" });
    expect(second.legacy).toEqual(legacy);
    expect(second.future).toEqual({ kept: true });
  });
  it("serializes overlapping saves and preserves edits arriving in flight", async () => {
    vi.useFakeTimers();
    const store = new WorkspaceStore();
    let resolve!: (result: any) => void;
    const request = vi
      .spyOn(api, "request")
      .mockResolvedValueOnce({ revision: 0, state: {} })
      .mockImplementationOnce(
        () =>
          new Promise((r) => {
            resolve = r;
          }),
      )
      .mockResolvedValueOnce({ revision: 2 });
    await store.load();
    store.update((s) => ({ ...s, projectId: "first" }));
    const flight = store.flush();
    store.update((s) => ({ ...s, projectId: "second" }));
    await store.flush();
    expect(request).toHaveBeenCalledTimes(2);
    resolve({ revision: 1 });
    await flight;
    await Promise.resolve();
    expect(request).toHaveBeenCalledTimes(3);
    expect(
      JSON.parse((request.mock.calls[2][1] as RequestInit).body as string),
    ).toMatchObject({ revision: 1, state: { projectId: "second" } });
    expect(store.getSnapshot().state.projectId).toBe("second");
  });
  it("keeps local drafts and stops autosaving on CAS conflicts", async () => {
    vi.useFakeTimers();
    const store = new WorkspaceStore();
    const request = vi
      .spyOn(api, "request")
      .mockResolvedValueOnce({ revision: 3, state: {} })
      .mockRejectedValueOnce(new APIError("Conflict", 409));
    await store.load();
    store.update((s) => ({ ...s, lastAgent: "codex" }));
    await store.flush();
    await store.flush();
    expect(request).toHaveBeenCalledTimes(2);
    expect(store.getSnapshot()).toMatchObject({
      dirty: true,
      conflict: true,
      state: { lastAgent: "codex" },
    });
  });
});
