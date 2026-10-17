export type Tab = {
  id: string;
  kind: "terminal" | "chat" | "file" | "diff";
  projectId: string;
  resourceId: string;
  title: string;
  agent?: string;
  draft?: string;
  revision?: string;
  original?: string;
  model?: string;
  status?: string;
  // Claude Code and Codex chats: the mode chosen in this browser, and whether
  // this chat confirmed a mode that runs without asking (Bypass permissions,
  // Full access). Asked once per chat.
  mode?: string;
  modeConfirmed?: boolean;
  [key: string]: unknown;
};

export type Project = { id: string; name: string; directory?: string };
export type Capabilities = {
  terminal?: boolean;
  terminalPrograms?: string[];
  chatProviders?: string[];
  plainChats?: PlainChats;
  // Every Chat provider; plainChats is OpenCode's alone on these hosts.
  generalChats?: PlainChats;
  // Chat in workspaces (2026-10-12): Claude Code and Codex in a workspace.
  workspaceChats?: WorkspaceChats;
  [key: string]: unknown;
};
// How a provider is signed in for Chat (2026-10-12): Chat runs on the Mac's
// Claude and ChatGPT subscriptions; providers signed in otherwise are listed
// in unavailableProviders, with reason and message.
export type PlainChatAuth = { kind: string; label: string; reason?: string; message?: string };
export type PlainChatProvider = { id: string; name: string; tools: string[]; features: string[]; attachmentTypes?: string[]; auth?: PlainChatAuth };
export type WorkspaceChats = { version: number; providers?: PlainChatProvider[]; unavailableProviders?: PlainChatProvider[] };
export type PlainChats = { projectId: string; providers?: PlainChatProvider[]; unavailableProviders?: PlainChatProvider[] };
export type Workspace = {
  version: 1;
  projectId: string;
  lastAgent: string;
  lastChatProvider?: string;
  activeTabId: string | null;
  tabs: Tab[];
  detachedTabs: Tab[];
  helpDismissed: boolean;
  legacyImported?: boolean;
  [key: string]: unknown;
};
