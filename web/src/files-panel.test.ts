import { describe, expect, it } from "vitest";
import { fileSavePayload, statusGroups } from "./FilesPanel";
describe("file and git wire contracts", () => {
  it("keeps host content and revision field names for saves", () =>
    expect(
      fileSavePayload(
        {
          projectId: "p",
          resourceId: "src/a.ts",
          revision: "base",
          id: "x",
          kind: "file",
          title: "a.ts",
          draft: "old",
        },
        "new",
      ),
    ).toEqual({
      projectId: "p",
      path: "src/a.ts",
      content: "new",
      revision: "base",
    }));
  it("groups porcelain changes by index, worktree and untracked fields", () => {
    const c: any[] = [
      { path: "a", index: "M", worktree: "", untracked: false },
      { path: "b", index: "", worktree: "M", untracked: false },
      { path: "c", index: "", worktree: "?", untracked: true },
    ];
    const g = statusGroups(c as any);
    expect(g.staged).toHaveLength(1);
    expect(g.unstaged).toHaveLength(1);
    expect(g.untracked).toHaveLength(1);
  });
});
