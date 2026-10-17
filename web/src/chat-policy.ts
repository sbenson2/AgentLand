import type { Capabilities, PlainChatProvider, Project, Tab } from "./types";

// Chat = Claude Code and Codex in the selected workspace (owner, 2026-10-12).
export const chatAgents = ["claude", "codex"];
const agentNames: Record<string, string> = { claude: "Claude Code", codex: "Codex", opencode: "OpenCode" };

// A chat's agent: its session ID names it (`claude:…`, `codex:…`, an ACP
// agent's `<agent>:…`; OpenCode's have none), else the tab's own record.
export function chatProviderOf(tab: { resourceId?: unknown; agent?: unknown }): string {
  const id = typeof tab.resourceId === "string" ? tab.resourceId : "";
  const colon = id.indexOf(":");
  if (colon > 0) return id.slice(0, colon);
  return typeof tab.agent === "string" && tab.agent ? tab.agent : "opencode";
}

export function chatProviderName(id: string, capabilities: Capabilities = {}) {
  return (
    workspaceChatProviders(capabilities).find((p) => p.id === id)?.name ||
    plainChatProviders(capabilities).find((p) => p.id === id)?.name ||
    agentNames[id] ||
    id
  );
}

// The Chats space: the host's plain chats project, else "chats" unless a
// legacy workspace of that name exists.
export function chatsSpace(capabilities: Capabilities, projects: Project[]) {
  return capabilities.plainChats?.projectId ??
    (projects.some((project) => project.id === "chats") ? undefined : "chats");
}

// Chats-space chats stay listed; in a workspace only Claude Code and Codex
// chats are Chat (OpenCode and ACP agents' workspace chats stay saved but
// hidden). Workspace chats show on any host: they ran before 2026-10-08.
export function supportsTab(
  tab: Pick<Tab, "kind" | "projectId"> & { resourceId?: unknown; agent?: unknown },
  capabilities: Capabilities,
  projects: Project[],
): boolean {
  if (tab.kind !== "chat") return true;
  if (tab.projectId === chatsSpace(capabilities, projects)) return true;
  // A removed workspace's chat stays listed; its reads say what happened.
  return chatAgents.includes(chatProviderOf(tab));
}

// The agents Chat starts in a workspace, only on hosts that list
// workspaceChats (version 1), each once.
export function workspaceChatProviders(capabilities: Capabilities): PlainChatProvider[] {
  return workspaceList(capabilities, "providers");
}

// Claude Code or Codex installed but signed in otherwise: never offered.
export function unavailableWorkspaceChatProviders(capabilities: Capabilities): PlainChatProvider[] {
  const offered = new Set(workspaceChatProviders(capabilities).map((p) => p.id));
  return workspaceList(capabilities, "unavailableProviders").filter((p) => !offered.has(p.id));
}

function workspaceList(capabilities: Capabilities, key: "providers" | "unavailableProviders") {
  const chats = capabilities.workspaceChats;
  if (chats?.version !== 1 || !Array.isArray(chats[key])) return [];
  const seen = new Set<string>();
  return chats[key]!.filter((p) =>
    typeof p?.id === "string" && chatAgents.includes(p.id) && !seen.has(p.id) && !!seen.add(p.id),
  );
}

// The Chats space's own providers (OpenCode under --opencode-chat), with the
// legacy OpenCode fallback for hosts that list no providers.
export function plainChatProviders(capabilities: Capabilities) {
  const plain = capabilities.plainChats;
  if (!plain) return [];
  return plain.providers ?? [{ id: "opencode", name: "OpenCode", tools: [], features: ["attachments", "rewind", "regenerate"], attachmentTypes: undefined }];
}

// A chat's provider entry: the workspace's for a workspace chat, the Chats
// space's for a Chats-space chat.
export function chatProviderEntry(tab: Pick<Tab, "projectId"> & { resourceId?: unknown; agent?: unknown }, capabilities: Capabilities, projects: Project[]) {
  const id = chatProviderOf(tab);
  return tab.projectId === chatsSpace(capabilities, projects)
    ? plainChatProviders(capabilities).find((p) => p.id === id)
    : workspaceChatProviders(capabilities).find((p) => p.id === id);
}

// On hosts with workspaceChats, a Chats-space chat whose provider the space no
// longer offers (Claude Code and Codex, and OpenCode without --opencode-chat)
// stays readable but takes no messages; it can continue in a workspace.
export function isReadOnlyChat(tab: Pick<Tab, "kind" | "projectId"> & { resourceId?: unknown; agent?: unknown }, capabilities: Capabilities, projects: Project[]) {
  return tab.kind === "chat" &&
    capabilities.workspaceChats?.version === 1 &&
    tab.projectId === chatsSpace(capabilities, projects) &&
    !plainChatProviders(capabilities).some((p) => p.id === chatProviderOf(tab));
}

export const readOnlyChatNotice = "Chat now runs in your workspaces; this chat stays readable.";

// Modes that run without asking: confirmed once per chat before use.
export const unattendedModes = ["bypassPermissions", "full-access"];

export function modeConfirmation(mode: { id: string; name: string }, agent: string) {
  if (mode.id === "bypassPermissions")
    return `Switch this chat to ${mode.name}?\n\n${agent} will edit files, run commands and use its tools without asking you first. This chat won’t ask again.`;
  if (mode.id === "full-access")
    return `Switch this chat to ${mode.name}?\n\n${agent} will run commands and edit files anywhere on your Mac, with network access, without asking you first. This chat won’t ask again.`;
  return "";
}

// The mode a message carries: the chat's choice, else the host's default,
// only when listed, and an unattended one only once this chat confirmed it.
export function modeToSend(
  tab: Pick<Tab, "mode" | "modeConfirmed">,
  options: { modes?: Array<{ id: string }>; defaultMode?: string },
): string | undefined {
  const modes = options.modes || [];
  const chosen = tab.mode && modes.some((m) => m.id === tab.mode) ? tab.mode : options.defaultMode;
  if (!chosen || !modes.some((m) => m.id === chosen)) return undefined;
  if (unattendedModes.includes(chosen) && !tab.modeConfirmed) return undefined;
  return chosen;
}

// The provider's name with its sign-in: "Claude Code (Claude subscription)".
export function chatProviderLabel(provider: { name: string; auth?: { label: string } }) {
  return provider.auth ? `${provider.name} (${provider.auth.label})` : provider.name;
}

// Hosts with Terminal sign-ins list every provider in generalChats and keep
// plainChats, the key older clients read, for OpenCode alone.
export function withGeneralChats(capabilities: Capabilities): Capabilities {
  return capabilities.generalChats ? { ...capabilities, plainChats: capabilities.generalChats } : capabilities;
}
