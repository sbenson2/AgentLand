import { test, expect, type Page } from "@playwright/test";

// A host of 2026-10-12: Chat runs Claude Code and Codex in workspaces
// (workspaceChats); the Chats space offers nothing new.
const workspaceChatProvider = (id: "claude" | "codex") => ({
  id,
  name: id === "claude" ? "Claude Code" : "Codex",
  tools: [],
  features: ["events", "attachments", "effort", "rewind", "approvals", "questions", "modes", "queue", ...(id === "claude" ? ["regenerate", "restoreFiles"] : [])],
  attachmentTypes: ["image/png", "text/plain"],
  auth: { kind: "subscription", label: id === "claude" ? "Claude subscription" : "ChatGPT subscription" },
});
const chatModes = {
  claude: { modes: [{ id: "default", name: "Ask" }, { id: "acceptEdits", name: "Accept edits" }, { id: "plan", name: "Plan" }, { id: "auto", name: "Auto" }, { id: "bypassPermissions", name: "Bypass permissions" }], defaultMode: "default" },
  codex: { modes: [{ id: "ask", name: "Ask" }, { id: "auto-review", name: "Auto-review" }, { id: "read-only", name: "Read only" }, { id: "full-access", name: "Full access" }], defaultMode: "ask" },
};

async function host(page: Page, options: { legacy?: boolean; conversation?: boolean; tabs?: any[] } = {}) {
  const data = {
    revision: 0,
    state: options.tabs
      ? { version: 1, projectId: "p", lastAgent: "", activeTabId: options.tabs[0].id, tabs: options.tabs, detachedTabs: [], helpDismissed: true }
      : options.legacy
      ? {
          legacy: {
            tabs: [
              {
                id: "old",
                kind: "editor",
                projectID: "p",
                resourceID: "src/main.ts",
                title: "main.ts",
                editorDirty: true,
                draft: "",
                editorBaseRevision: "r1",
              },
            ],
            selectedTabID: "old",
            projectID: "p",
          },
        }
      : ({} as any),
    creates: [] as any[],
    inputs: [] as any[],
    closes: 0,
    messages: [] as any[],
    replies: [] as any[],
    saves: [] as any[],
    content: "const answer = 42;\n",
    fileRevision: "r1",
    conflict: false,
    expired: false,
    uncertain: false,
    aborts: 0,
    uploads: [] as any[],
    rewound: false,
    regenerated: 0,
    chatCreates: [] as any[],
    optionRequests: [] as string[],
    continues: [] as any[],
    eventRequests: 0,
    hostMode: "",
  };
  const terminals: any[] = [],
    sessions: any[] = [];
  const projects = [
    {
      id: "p",
      name: "AgentLand demo",
      directory: "/Users/demo/Developer/agentland",
    },
  ];
  await page.route("**/web/**", async (route) => {
    const path = new URL(route.request().url()).pathname,
      method = route.request().method();
    if (path === "/web/session")
      return route.fulfill({
        json: {
          token: "browser-fixture-token",
          expiresAt: "2099-01-01T00:00:00Z",
        },
      });
    if (method === "PUT") {
      const input = route.request().postDataJSON();
      if (data.conflict || input.revision !== data.revision)
        return route.fulfill({
          status: 409,
          json: { revision: ++data.revision, state: data.state },
        });
      data.state = input.state;
      data.revision++;
    }
    return route.fulfill({
      json: { revision: data.revision, state: data.state },
    });
  });
  await page.route("**/api/v1/**", async (route) => {
    const req = route.request(),
      url = new URL(req.url()),
      path = url.pathname.replace("/api", ""),
      body =
        req.postData() && req.headers()["content-type"]?.includes("json")
          ? req.postDataJSON()
          : {};
    if (data.expired)
      return route.fulfill({
        status: 401,
        json: { error: { code: "unauthorized", message: "Session expired" } },
      });
    const ok = (json: any, status = 200) => route.fulfill({ status, json });
    if (path === "/v1/capabilities")
      return ok({
        terminal: true,
        terminalPrograms: ["shell", "codex"],
        chatProviders: ["claude", "codex"],
        chatFeatures: ["attachments", "events"],
        generalChats: { projectId: "chats", providers: [], tools: [] },
        workspaceChats: { version: 1, providers: [workspaceChatProvider("claude"), workspaceChatProvider("codex")], unavailableProviders: [] },
      });
    if (path === "/v1/projects")
      return req.method() === "GET" ? ok({ projects }) : ok(projects[0], 201);
    if (path === "/v1/folders")
      return ok({
        path: "/Users/demo/Developer",
        displayPath: "~/Developer",
        parent: "/Users/demo",
        roots: [{ name: "Developer", path: "/Users/demo/Developer" }],
        folders: [
          {
            name: "agentland",
            path: "/Users/demo/Developer/agentland",
            workspaceId: "p",
          },
        ],
        truncated: false,
      });
    if (path === "/v1/terminals") {
      if (req.method() === "GET") return ok({ terminals });
      data.creates.push(body);
      const terminal = {
        id: `t${terminals.length + 1}`,
        title: body.title,
        projectId: body.projectId,
        status: "running",
      };
      terminals.push(terminal);
      return ok(terminal, 201);
    }
    if (path === "/v1/terminal/output") {
      await new Promise((r) => setTimeout(r, 150));
      return ok({
        data: Number(url.searchParams.get("cursor"))
          ? ""
          : Buffer.from("Welcome to AgentLand\r\n日本語 ✓\r\n$ ").toString(
              "base64",
            ),
        cursor: 1,
        reset: false,
        status: "running",
      });
    }
    if (path === "/v1/terminal/input") {
      data.inputs.push(body);
      return ok({ accepted: true });
    }
    if (path === "/v1/terminal/resize") return ok({ accepted: true });
    if (path === "/v1/terminal/close") {
      data.closes++;
      return ok({ accepted: true });
    }
    if (path === "/v1/files")
      return ok({
        entries:
          url.searchParams.get("path") === "src"
            ? [{ name: "main.ts", path: "src/main.ts", isDirectory: false }]
            : [{ name: "src", path: "src", isDirectory: true }],
      });
    if (path === "/v1/file") {
      if (req.method() === "POST") {
        data.saves.push(body);
        if (body.revision !== data.fileRevision)
          return ok(
            {
              error: {
                code: "file_conflict",
                message:
                  "The file changed. Reload and compare before saving again",
              },
            },
            409,
          );
        data.content = body.content;
        data.fileRevision = "r" + (Number(data.fileRevision.slice(1)) + 1);
      }
      return ok({
        path: "src/main.ts",
        content: data.content,
        revision: data.fileRevision,
      });
    }
    if (path === "/v1/git/repositories")
      return ok({ repositories: [{ name: "agentland", path: "." }] });
    if (path === "/v1/git/status")
      return ok({
        branch: "main",
        changes: [
          { path: "src/main.ts", index: "", worktree: "M", untracked: false },
        ],
        truncated: false,
      });
    if (path === "/v1/git/diff")
      return ok({
        path: "src/main.ts",
        diff: "@@ -1 +1 @@\n-old line\n+new line\n",
      });
    if (path === "/v1/sessions") {
      if (req.method() === "GET") return ok({ sessions });
      data.chatCreates.push(body);
      const session = {
        id: `${body.provider}:c1`,
        title: body.title || "Claude Code",
        projectId: body.projectId,
        provider: body.provider,
      };
      sessions.push(session);
      return ok(session, 201);
    }
    if (path === "/v1/chat/continue") {
      data.continues.push(body);
      const session = { id: `${body.provider}:c2`, title: "Units chat", projectId: body.projectId, provider: body.provider, parentSessionId: body.sourceSessionId };
      sessions.push(session);
      return ok({ ...session, seed: { included: 2, omitted: 0, chars: 40 } }, 201);
    }
    if (path === "/v1/chat/options") {
      const provider = (url.searchParams.get("sessionId") || "").split(":")[0];
      data.optionRequests.push(url.searchParams.get("sessionId") || "");
      return ok({
        models: [{ id: "claude/test", name: "Test model", efforts: ["low"] }],
        ...(chatModes as any)[provider],
        agents: [],
      });
    }
    if (options.conversation && path === "/v1/messages/rewind") { data.rewound = true; return ok({ rewound: true }); }
    if (options.conversation && path === "/v1/messages/restore") { data.rewound = false; return ok({ restored: true }); }
    if (options.conversation && path === "/v1/chat/regenerate") { data.regenerated++; return ok({ accepted: true }, 202); }
    if (options.conversation && path === "/v1/chat/events") {
      return route.fulfill({ contentType: "application/x-ndjson", body: JSON.stringify({ type: "ready", cursor: "e.0" }) + "\n" + JSON.stringify({ type: "snapshot", seq: 0, chat: { id: url.searchParams.get("sessionId") }, status: { state: "idle" }, rewind: data.rewound ? { messageId: "u1" } : undefined, messages: data.rewound ? [] : [
        { id: "u1", role: "user", parts: [{ id: "p1", kind: "text", text: "Use metric units" }] },
        { id: "a1", role: "assistant", parts: [{ id: "p2", kind: "tool", tool: { name: "agentland_memory_save", status: "completed", memory: { id: "mem_fixture", text: "Prefers metric units" } } }, { id: "p3", kind: "tool", tool: { name: "agentland_fetch", status: "completed", sources: [{ title: "Source page", url: "https://example.org/units" }] } }] }
      ], queue: [], interactions: [] }) + "\n" });
    }
    if (path === "/v1/chat/events") {
      data.eventRequests++;
      await new Promise((r) => setTimeout(r, 150));
      return route.fulfill({
        contentType: "application/x-ndjson",
        body:
          [
            { type: "ready", cursor: "epoch.0" },
            {
              type: "snapshot",
              seq: 0,
              chat: { id: url.searchParams.get("sessionId"), ...(data.hostMode ? { mode: data.hostMode } : {}) },
              status: { state: data.replies.length >= 2 ? "idle" : "waiting" },
              messages: [
                {
                  id: "m1",
                  role: "assistant",
                  ord: 1,
                  parts: [
                    {
                      id: "part1",
                      kind: "text",
                      text: "Host response",
                      ord: 1,
                    },
                    {
                      id: "tool1",
                      kind: "tool",
                      ord: 2,
                      tool: {
                        name: "Read",
                        status: "completed",
                        output: "actual file output",
                      },
                    },
                  ],
                },
              ],
              interactions: [
                {
                  id: "approval",
                  kind: "permission",
                  choices: ["once", "reject"],
                  permission: { title: "Run command?", detail: "printf hello" },
                },
                {
                  id: "question",
                  kind: "question",
                  questions: [
                    {
                      text: "Which folder?",
                      multiple: false,
                      custom: true,
                      secret: false,
                      options: [{ label: "src" }],
                    },
                  ],
                },
              ].filter((i) => !data.replies.some((r) => r.requestId === i.id)),
              hasMore: false,
            },
            {
              type: "part.delta",
              seq: 1,
              messageId: "m1",
              partId: "part1",
              field: "text",
              offset: 13,
              delta: " ✓",
            },
            { type: "end", cursor: "epoch.1" },
          ]
            .map((e) => JSON.stringify(e))
            .join("\n") + "\n",
      });
    }
    if (path === "/v1/messages") {
      data.messages.push(body);
      return data.uncertain
        ? ok(
            {
              error: {
                code: "delivery_uncertain",
                message: "Delivery uncertain",
              },
            },
            503,
          )
        : ok({ accepted: true }, 202);
    }
    if (path === "/v1/permissions/reply" || path === "/v1/questions/reply") {
      data.replies.push(body);
      return ok({ accepted: true });
    }
    if (path === "/v1/attachments") {
      data.uploads.push({
        projectId: url.searchParams.get("projectId"),
        sessionId: url.searchParams.get("sessionId"),
        name: url.searchParams.get("name"),
        body: req.postData(),
      });
      return ok(
        {
          id: "a1",
          name: url.searchParams.get("name"),
          mime: "text/plain",
          size: req.postDataBuffer()?.length,
        },
        201,
      );
    }
    if (path === "/v1/abort") {
      data.aborts++;
      return ok({ aborted: true });
    }
    return ok(
      { error: { code: "not_found", message: `Unmocked route ${path}` } },
      404,
    );
  });
  await page.goto("/#launch=fixture");
  await expect(page.getByText("Connected to this Mac")).toBeVisible();
  return data;
}

test("agent terminals survive switching, closing, reopening and browser reload without duplication", async ({
  page,
}) => {
  const data = await host(page);
  await page.screenshot({ path: "test-results/launcher.png" });
  await page.getByRole("button", { name: "Start Codex", exact: true }).click();
  await expect.poll(() => data.creates.length).toBe(1);
  expect(data.creates[0]).toMatchObject({ program: "codex", projectId: "p" });
  await expect(page.getByRole("status")).toHaveText("Running");
  await page.locator(".xterm-helper-textarea").focus();
  await page.keyboard.type("echo hello");
  await expect
    .poll(() =>
      data.inputs.map((i) => Buffer.from(i.data, "base64").toString()).join(""),
    )
    .toBe("echo hello");
  await page.getByRole("tab", { name: "New session", exact: true }).click();
  await page.getByRole("tab", { name: "Codex", exact: false }).click();
  expect(data.creates).toHaveLength(1);
  await page.getByRole("button", { name: "Close Codex tab" }).click();
  expect(data.closes).toBe(0);
  await page
    .getByRole("button", { name: "Running Sessions", exact: true })
    .click();
  await page.getByRole("dialog").getByRole("button", { name: /Codex/ }).click();
  await expect(page.getByRole("status")).toHaveText("Running");
  await expect(page.getByText("Workspace saved on this Mac")).toBeVisible();
  await page.reload();
  await expect(
    page.getByRole("button", { name: "End Session", exact: true }),
  ).toBeVisible();
  expect(data.creates).toHaveLength(1);
  await page.screenshot({ path: "test-results/terminal.png" });
  page.once("dialog", (d) => d.accept());
  await page.getByRole("button", { name: "End Session", exact: true }).click();
  await expect.poll(() => data.closes).toBe(1);
});

test("terminal keeps its cursor across a 503", async ({ page }) => {
  await host(page);
  const reads: Array<string | null> = [];
  const text = (data: string, cursor: number) => ({
    data: Buffer.from(data).toString("base64"),
    cursor,
    reset: false,
    status: "running",
  });
  // Registered after host(), so it answers the output route first.
  await page.route("**/api/v1/terminal/output*", async (route) => {
    reads.push(new URL(route.request().url()).searchParams.get("cursor"));
    const n = reads.length;
    if (n === 1) return route.fulfill({ status: 200, json: text("one", 3) });
    if (n === 2)
      return route.fulfill({
        status: 503,
        json: { error: { code: "terminals_unavailable" } },
      });
    if (n === 3) return route.fulfill({ status: 200, json: text("two", 6) });
    await new Promise((r) => setTimeout(r, 300));
    return route.fulfill({ status: 200, json: { ...text("", 6) } });
  });
  await page.getByRole("button", { name: "Start Codex", exact: true }).click();
  await expect(page.locator(".xterm-rows")).toContainText("onetwo", { timeout: 15000 });
  expect(reads.slice(0, 3)).toEqual(["0", "3", "3"]);
  await expect(page.locator(".xterm-rows")).not.toContainText("Earlier output is no longer available");
});

test("folder chooser, nested files, persistent empty drafts, save revisions and conflicts", async ({
  page,
}) => {
  const data = await host(page);
  await page.getByRole("button", { name: "Choose folder…" }).click();
  await expect(
    page.getByRole("dialog").getByText("agentland", { exact: true }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Close folder picker" }).click();
  await page.getByRole("button", { name: "Files", exact: true }).click();
  await page.getByRole("button", { name: "▸ src", exact: true }).click();
  await page.getByRole("button", { name: "· main.ts", exact: true }).click();
  const editor = page.locator(".cm-content");
  await expect(editor).toContainText("const answer = 42;");
  await editor.fill("");
  await expect(page.getByText("Workspace saved on this Mac")).toBeVisible();
  await page.getByRole("tab", { name: "New session", exact: true }).click();
  await page.getByRole("tab", { name: /main.ts/ }).click();
  await expect(editor).toHaveText("");
  await editor.fill("first save");
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect.poll(() => data.content).toBe("first save");
  await editor.fill("second save");
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect.poll(() => data.content).toBe("second save");
  expect(data.saves[1].revision).toBe("r2");
  data.fileRevision = "r99";
  data.content = "external edit";
  await editor.fill("keep this draft");
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect(
    page.getByText("The host file changed. Your draft is retained."),
  ).toBeVisible();
  await expect(editor).toHaveText("keep this draft");
  page.once("dialog", (d) => d.accept());
  await page.getByRole("button", { name: "Reload host file" }).click();
  await expect(editor).toHaveText("external edit");
  await page.getByRole("button", { name: "Git", exact: true }).click();
  await page
    .getByRole("button", { name: "M src/main.ts", exact: true })
    .click();
  await expect(page.locator(".diff")).toContainText("+new line");
});

test("native migration keeps an empty editor draft and original conflict revision", async ({
  page,
}) => {
  const data = await host(page, { legacy: true });
  await expect(page.locator(".cm-content")).toHaveText("");
  await expect.poll(() => data.state.legacyImported).toBe(true);
  expect(data.state.legacy.tabs[0].draft).toBe("");
  await page.reload();
  await expect(page.locator(".cm-content")).toHaveText("");
  expect(data.state.tabs).toHaveLength(1);
});

test("Chat starts Claude Code or Codex in the selected workspace", async ({ page }) => {
  const data = await host(page);
  const agent = page.getByRole("combobox", { name: "Chat agent" });
  await expect(agent).toHaveValue("claude");
  await expect(agent.locator("option")).toHaveText(["Claude Code (Claude subscription)", "Codex (ChatGPT subscription)"]);
  await page.getByRole("button", { name: "Open chat", exact: true }).click();
  await expect.poll(() => data.chatCreates.length).toBe(1);
  expect(data.chatCreates[0]).toEqual({ projectId: "p", provider: "claude", title: "Claude Code chat" });
  await expect(page.getByText("Host response ✓", { exact: true })).toBeVisible();
  // New chats start in Ask, from the host's modes.
  await expect(page.getByRole("combobox", { name: "Mode", exact: true })).toHaveValue("default");
  await expect(page.getByRole("combobox", { name: "Mode", exact: true }).locator("option")).toHaveText(["Ask", "Accept edits", "Plan", "Auto", "Bypass permissions"]);
  await expect(page.locator(".context-bar")).toContainText("AgentLand demo");
  await expect(page.locator(".context-bar")).toContainText("Claude Code");
  await expect(page.getByRole("combobox", { name: "Workspace", exact: true })).toHaveValue("p");
  // Running Sessions lists the workspace's Claude Code and Codex chats only.
  await page.getByRole("tab", { name: "New session", exact: true }).click();
  await page.getByRole("combobox", { name: "Chat agent" }).selectOption("codex");
  await page.getByRole("button", { name: "Open chat", exact: true }).click();
  await expect.poll(() => data.chatCreates.length).toBe(2);
  expect(data.chatCreates[1]).toEqual({ projectId: "p", provider: "codex", title: "Codex chat" });
  await expect(page.getByRole("combobox", { name: "Mode", exact: true })).toHaveValue("ask");
});

test("Bypass permissions asks once per chat and the chat follows the host's mode", async ({ page }) => {
  const data = await host(page);
  data.replies.push({ requestId: "question" }, { requestId: "approval" });
  data.hostMode = "default";
  const dialogs: string[] = [], answers = ["dismiss", "accept"];
  page.on("dialog", (dialog) => {
    dialogs.push(dialog.message());
    return answers.shift() === "accept" ? dialog.accept() : dialog.dismiss();
  });
  await page.getByRole("button", { name: "Open chat", exact: true }).click();
  const mode = page.getByRole("combobox", { name: "Mode", exact: true });
  await expect(mode).toHaveValue("default");
  // Claude Code leaving Plan reports its mode; the chat follows.
  await expect(page.getByText("Host response ✓", { exact: true })).toBeVisible();
  data.hostMode = "acceptEdits";
  await expect(mode).toHaveValue("acceptEdits");
  // A switch to Bypass reported before this chat confirmed it is not taken up.
  const later = data.eventRequests;
  data.hostMode = "bypassPermissions";
  await expect.poll(() => data.eventRequests).toBeGreaterThan(later + 2);
  await expect(mode).toHaveValue("acceptEdits");
  await mode.selectOption("bypassPermissions");
  await expect.poll(() => dialogs.length).toBe(1);
  await expect(mode).toHaveValue("acceptEdits");
  await mode.selectOption("bypassPermissions");
  await expect.poll(() => dialogs.length).toBe(2);
  expect(dialogs[1]).toContain("Switch this chat to Bypass permissions?");
  expect(dialogs[1]).toContain("Claude Code will edit files, run commands and use its tools without asking you first.");
  await expect(mode).toHaveValue("bypassPermissions");
  await page.getByRole("textbox", { name: "Message", exact: true }).fill("tidy the README");
  await page.getByRole("button", { name: "Send", exact: true }).click();
  await expect.poll(() => data.messages.length).toBe(1);
  expect(data.messages[0]).toMatchObject({ projectId: "p", sessionId: "claude:c1", text: "tidy the README", mode: "bypassPermissions" });
  // Confirmed once: later switches don't ask, and the answer is saved with the tab.
  await mode.selectOption("default");
  await mode.selectOption("bypassPermissions");
  await expect(mode).toHaveValue("bypassPermissions");
  expect(dialogs).toHaveLength(2);
  await expect.poll(() => data.state.tabs?.[0]?.modeConfirmed).toBe(true);
});

test("old Chats-space chats stay readable and continue in the workspace without sending", async ({ page }) => {
  const data = await host(page, {
    conversation: true,
    tabs: [{ id: "old", kind: "chat", projectId: "chats", resourceId: "claude:old", title: "Units", agent: "claude" }],
  });
  await expect(page.getByText("Use metric units")).toBeVisible();
  await expect(page.getByText("Chat now runs in your workspaces; this chat stays readable.")).toBeVisible();
  await expect(page.getByRole("textbox", { name: "Message", exact: true })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Run again" })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Edit and resend" })).toHaveCount(0);
  // Memory is gone from Chat; old transcripts keep their sources.
  await expect(page.getByRole("button", { name: "Undo", exact: true })).toHaveCount(0);
  await expect(page.getByRole("link", { name: "Source page" })).toBeVisible();
  await expect(page.getByRole("combobox", { name: "Continue with" })).toHaveValue("claude");
  await page.getByRole("button", { name: "Continue in AgentLand demo", exact: true }).click();
  await expect.poll(() => data.continues.length).toBe(1);
  expect(data.continues[0]).toEqual({ projectId: "p", sourceSessionId: "claude:old", provider: "claude" });
  await expect(page.getByRole("tab", { name: /Units chat/ })).toHaveAttribute("aria-selected", "true");
  await expect(page.getByRole("textbox", { name: "Message", exact: true })).toHaveValue("");
  await expect.poll(() => data.optionRequests).toEqual(["claude:c2"]);
  expect(data.messages).toHaveLength(0);
});

test("chat renders host events, tool output, permissions, questions, stop and drafts", async ({
  page,
}) => {
  const data = await host(page);
  await page.getByRole("button", { name: "Open chat", exact: true }).click();
  await expect(
    page.getByText("Host response ✓", { exact: true }),
  ).toBeVisible();
  await page.getByText("Read completed", { exact: false }).click();
  await expect(page.getByText("actual file output")).toBeVisible();
  await page.getByRole("radio", { name: "src", exact: true }).check();
  await page.getByRole("button", { name: "Send answers", exact: true }).click();
  await expect.poll(() => data.replies.length).toBe(1);
  expect(data.replies[0]).toMatchObject({
    projectId: "p",
    sessionId: "claude:c1",
    requestId: "question",
    answers: [["src"]],
  });
  await page.getByRole("button", { name: "Stop", exact: true }).click();
  await expect.poll(() => data.aborts).toBe(1);
  await page.getByRole("button", { name: "Allow once", exact: true }).click();
  await expect.poll(() => data.replies.length).toBe(2);
  expect(data.replies[1]).toMatchObject({
    projectId: "p",
    sessionId: "claude:c1",
    requestId: "approval",
    reply: "once",
  });
  await expect(page.getByText("Stop was not confirmed.")).toHaveCount(0);
  await page
    .getByLabel("Attach files", { exact: true })
    .setInputFiles({
      name: "note.txt",
      mimeType: "text/plain",
      buffer: Buffer.from("fixture attachment"),
    });
  await expect.poll(() => data.uploads.length).toBe(1);
  expect(data.uploads[0]).toMatchObject({
    projectId: "p",
    sessionId: "claude:c1",
    name: "note.txt",
    body: "fixture attachment",
  });
  await page
    .getByRole("textbox", { name: "Message", exact: true })
    .fill("a request");
  await page.getByRole("button", { name: "Send", exact: true }).click();
  await expect.poll(() => data.messages.length).toBe(1);
  expect(data.messages[0]).toMatchObject({
    attachments: ["a1"],
    text: "a request",
    projectId: "p",
    sessionId: "claude:c1",
    mode: "default",
  });
  await expect(
    page.getByRole("textbox", { name: "Message", exact: true }),
  ).toHaveValue("");
  await page
    .getByRole("textbox", { name: "Message", exact: true })
    .fill("my persisted draft");
  await expect(page.getByText("Workspace saved on this Mac")).toBeVisible();
  await page.reload();
  await expect(
    page.getByRole("textbox", { name: "Message", exact: true }),
  ).toHaveValue("my persisted draft");
});

test("state conflict retains local drafts and session expiry blocks the workspace", async ({
  page,
}) => {
  const data = await host(page);
  data.conflict = true;
  await page.getByRole("button", { name: "Toggle help" }).click();
  await expect(
    page.getByText(
      "Another browser window saved changes. Your tabs and drafts are still here.",
    ),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Download drafts" }),
  ).toBeVisible();
  data.expired = true;
  await page.getByRole("button", { name: "Start Codex", exact: true }).click();
  await expect(
    page.getByRole("alertdialog", { name: "Session expired" }),
  ).toBeVisible();
});

test("launcher fits a narrow browser window", async ({ page }) => {
  await page.setViewportSize({ width: 600, height: 820 });
  await host(page);
  await expect(
    page.getByRole("button", { name: "Start Codex", exact: true }),
  ).toBeVisible();
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBe(true);
  await page.screenshot({ path: "test-results/narrow.png" });
});

test("uncertain chat delivery retains the draft and never retries automatically", async ({
  page,
}) => {
  const data = await host(page);
  data.replies.push({ requestId: "question" }, { requestId: "approval" });
  data.uncertain = true;
  await page.getByRole("button", { name: "Open chat", exact: true }).click();
  await page
    .getByRole("textbox", { name: "Message", exact: true })
    .fill("keep this request");
  await page.getByRole("button", { name: "Send", exact: true }).click();
  await expect(
    page.getByRole("button", {
      name: "I checked the conversation",
      exact: true,
    }),
  ).toBeVisible();
  await expect(
    page.getByRole("textbox", { name: "Message", exact: true }),
  ).toHaveValue("keep this request");
  await expect(
    page.getByRole("button", { name: "Send", exact: true }),
  ).toBeDisabled();
  await expect(page.getByText("Workspace saved on this Mac")).toBeVisible();
  await page.reload();
  await expect(
    page.getByRole("textbox", { name: "Message", exact: true }),
  ).toHaveValue("keep this request");
  expect(data.messages).toHaveLength(1);
});

for (const provider of ["claude", "codex"] as const) {
  test(`${provider} workspace chat controls edit, restore and retry`, async ({ page }) => {
    const data = await host(page, { conversation: true });
    await page.getByRole("combobox", { name: "Chat agent" }).selectOption(provider);
    await page.getByRole("button", { name: "Open chat", exact: true }).click();
    await expect(page.getByLabel("Attach files")).toHaveAttribute("accept", "image/png,text/plain");
    await expect(page.getByRole("link", { name: "Source page" })).toHaveAttribute("href", "https://example.org/units");
    await expect(page.getByRole("button", { name: "Undo", exact: true })).toHaveCount(0);
    await expect(page.getByRole("combobox", { name: "Mode", exact: true })).toHaveValue(provider === "claude" ? "default" : "ask");
    await page.getByRole("button", { name: "Edit and resend" }).click();
    await expect(page.getByRole("textbox", { name: "Message", exact: true })).toHaveValue("Use metric units");
    await page.getByRole("button", { name: "Cancel edit" }).click();
    await expect.poll(() => data.rewound).toBe(false);
    await page.getByRole("button", { name: "Run again" }).click();
    if (provider === "claude") await expect.poll(() => data.regenerated).toBe(1);
    else {
      await expect.poll(() => data.messages.length).toBe(1);
      expect(data.messages[0]).toMatchObject({ projectId: "p", sessionId: "codex:c1", mode: "ask" });
    }
  });
}
