import { describe, expect, it } from "vitest";
import {
  chatProviderLabel,
  chatProviderName,
  chatProviderOf,
  isReadOnlyChat,
  modeConfirmation,
  modeToSend,
  plainChatProviders,
  supportsTab,
  unavailableWorkspaceChatProviders,
  withGeneralChats,
  workspaceChatProviders,
} from "./chat-policy";
import type { Capabilities, PlainChatProvider } from "./types";

const claude: PlainChatProvider = { id: "claude", name: "Claude Code", tools: [], features: ["modes", "approvals"], auth: { kind: "subscription", label: "Claude subscription" } };
const codex: PlainChatProvider = { id: "codex", name: "Codex", tools: [], features: ["modes"], auth: { kind: "subscription", label: "ChatGPT subscription" } };
// A host of 2026-10-12: Chat in workspaces, the Chats space with no providers.
const host: Capabilities = withGeneralChats({
  generalChats: { projectId: "chats", providers: [] },
  workspaceChats: { version: 1, providers: [claude, codex], unavailableProviders: [] },
});

describe("Chat policy", () => {
  it("lists Claude Code and Codex workspace chats and keeps other agents' workspace chats hidden", () => {
    expect(supportsTab({ kind: "chat", projectId: "app", resourceId: "claude:s1" }, host, [])).toBe(true);
    expect(supportsTab({ kind: "chat", projectId: "app", resourceId: "codex:s2" }, host, [])).toBe(true);
    // The tab's own agent when the ID names none.
    expect(supportsTab({ kind: "chat", projectId: "app", resourceId: "c1", agent: "claude" }, host, [])).toBe(true);
    expect(supportsTab({ kind: "chat", projectId: "app", resourceId: "ses_1" }, host, [])).toBe(false);
    expect(supportsTab({ kind: "chat", projectId: "app", resourceId: "gemini:s3" }, host, [])).toBe(false);
    expect(supportsTab({ kind: "chat", projectId: "chats", resourceId: "ses_1" }, host, [])).toBe(true);
    expect(supportsTab({ kind: "terminal", projectId: "app" }, host, [])).toBe(true);
    // Workspace chats ran before workspaceChats existed: they show on any host.
    expect(supportsTab({ kind: "chat", projectId: "app", resourceId: "claude:s1" }, { plainChats: { projectId: "chats" } }, [])).toBe(true);
  });
  it("does not mistake a legacy workspace named chats for the Chats space", () => {
    expect(supportsTab({ kind: "chat", projectId: "chats" }, {}, [{ id: "chats", name: "App" }])).toBe(false);
    expect(supportsTab({ kind: "chat", projectId: "chats", resourceId: "codex:s" }, {}, [{ id: "chats", name: "App" }])).toBe(true);
  });
  it("names a chat's agent from its session ID first", () => {
    expect(chatProviderOf({ resourceId: "claude:abc", agent: "bypassPermissions" })).toBe("claude");
    expect(chatProviderOf({ resourceId: "ses_1" })).toBe("opencode");
    expect(chatProviderOf({ resourceId: "c1", agent: "codex" })).toBe("codex");
    expect(chatProviderName("claude", host)).toBe("Claude Code");
    expect(chatProviderName("codex")).toBe("Codex");
  });
});

it("offers Claude Code and Codex only from workspaceChats version 1, each once", () => {
  expect(workspaceChatProviders(host).map((p) => p.id)).toEqual(["claude", "codex"]);
  expect(workspaceChatProviders({})).toEqual([]);
  expect(workspaceChatProviders({ workspaceChats: { version: 2, providers: [claude] } })).toEqual([]);
  const opencode = { id: "opencode", name: "OpenCode", tools: [], features: [] };
  expect(workspaceChatProviders({ workspaceChats: { version: 1, providers: [opencode, claude, claude] } }).map((p) => p.id)).toEqual(["claude"]);
  // The Chats space offers nothing new on these hosts.
  expect(plainChatProviders(host)).toEqual([]);
  expect(plainChatProviders({ plainChats: { projectId: "chats" } }).map((p) => p.id)).toEqual(["opencode"]);
});

it("lists agents Chat cannot use apart, with their sign-in", () => {
  const apiKey = { ...codex, features: [], auth: { kind: "apiKey", label: "API key", reason: "subscription_required", message: "Sign in to Codex with your ChatGPT subscription (codex login)." } };
  const caps: Capabilities = { workspaceChats: { version: 1, providers: [claude], unavailableProviders: [apiKey, claude] } };
  expect(workspaceChatProviders(caps).map((p) => p.id)).toEqual(["claude"]);
  expect(unavailableWorkspaceChatProviders(caps).map((p) => p.id)).toEqual(["codex"]);
  expect(chatProviderLabel(claude)).toBe("Claude Code (Claude subscription)");
  expect(chatProviderLabel({ name: "OpenCode" })).toBe("OpenCode");
});

it("keeps Chats-space Claude Code, Codex and OpenCode chats read-only on hosts with workspaceChats", () => {
  expect(isReadOnlyChat({ kind: "chat", projectId: "chats", resourceId: "claude:old" }, host, [])).toBe(true);
  expect(isReadOnlyChat({ kind: "chat", projectId: "chats", resourceId: "ses_old" }, host, [])).toBe(true);
  expect(isReadOnlyChat({ kind: "chat", projectId: "app", resourceId: "claude:new" }, host, [])).toBe(false);
  // OpenCode under --opencode-chat keeps its Chats-space chats.
  const opencodeChat = withGeneralChats({ ...host, generalChats: { projectId: "chats", providers: [{ id: "opencode", name: "OpenCode", tools: [], features: [] }] } });
  expect(isReadOnlyChat({ kind: "chat", projectId: "chats", resourceId: "ses_old" }, opencodeChat, [])).toBe(false);
  // Older hosts behave as before.
  expect(isReadOnlyChat({ kind: "chat", projectId: "chats", resourceId: "ses_old" }, { plainChats: { projectId: "chats" } }, [])).toBe(false);
});

it("sends the chosen or default mode, and Bypass or Full access only once confirmed", () => {
  const options = { modes: [{ id: "default" }, { id: "plan" }, { id: "bypassPermissions" }], defaultMode: "default" };
  expect(modeToSend({}, options)).toBe("default");
  expect(modeToSend({ mode: "plan" }, options)).toBe("plan");
  expect(modeToSend({ mode: "gone" }, options)).toBe("default");
  expect(modeToSend({ mode: "bypassPermissions" }, options)).toBeUndefined();
  expect(modeToSend({ mode: "bypassPermissions", modeConfirmed: true }, options)).toBe("bypassPermissions");
  expect(modeToSend({}, { modes: [] })).toBeUndefined();
  expect(modeConfirmation({ id: "full-access", name: "Full access" }, "Codex")).toMatch(/^Switch this chat to Full access\?/);
  expect(modeConfirmation({ id: "bypassPermissions", name: "Bypass permissions" }, "Claude Code")).toContain("Claude Code will edit files");
  expect(modeConfirmation({ id: "plan", name: "Plan" }, "Claude Code")).toBe("");
});
