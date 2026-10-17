package host

// Plain chats (docs/HOST-API.md "Plain chats"): the shared types of the
// contract: capabilities.plainChats, the members plain chats add to tool
// parts, and the bodies and answers of the memory routes. Field names and tags
// are the contract's; plain_chat_types_test.go checks them against the
// document's examples. Nothing here is wired into a route yet.

// The Chats space, its agent and the names plain chats use on the wire.
const (
	// plainChatsProjectID is the Chats space's reserved project ID, the
	// projectId of every plain chat.
	plainChatsProjectID = "chats"
	// plainChatsProjectName is the Chats space's projectName in notices.
	plainChatsProjectName = "Chats"
	// plainChatAgent is the OpenCode agent every plain-chat prompt runs with.
	plainChatAgent = "chat"

	// The tools capabilities.plainChats.tools lists.
	plainChatToolWebsearch = "websearch"
	plainChatToolFetch     = "fetch"
	plainChatToolMemory    = "memory"

	// plainChatSearchExa is capabilities.plainChats.searchProvider when
	// OpenCode's web search goes to Exa.
	plainChatSearchExa = "exa"

	// The tool part names (ChatTool.Name) that carry sources or memory.
	chatToolWebsearch    = "websearch"
	chatToolFetch        = "agentland_fetch"
	chatToolMemorySave   = "agentland_memory_save"
	chatToolMemoryForget = "agentland_memory_forget"
)

// The contract's limits.
const (
	// capabilities.plainChats.instructionFiles holds at most this many paths,
	// each at most this many bytes.
	plainChatInstructionFiles     = 32
	plainChatInstructionFileBytes = 1024

	// A tool part names at most chatToolSourcesLimit sources, each with a
	// title of at most chatToolSourceTitleLimit bytes and an http or https
	// url of at most chatToolSourceURLLimit bytes.
	chatToolSourcesLimit     = 20
	chatToolSourceTitleLimit = 200
	chatToolSourceURLLimit   = 2048

	// Memory holds at most memoryMaxEntries entries and memoryMaxTotalChars
	// characters (Unicode scalar values) of text over all entries. An entry's
	// ID is at most memoryIDLimit bytes.
	memoryMaxEntries    = 50
	memoryMaxTotalChars = 2000
	memoryIDLimit       = 64
)

// The error codes the contract adds.
const (
	// plainChatProviderCode (400): a provider other than OpenCode in the
	// Chats space.
	plainChatProviderCode = "plain_chat_provider"
	// plainChatScopeCode (400): a continue into or out of the Chats space.
	plainChatScopeCode = "plain_chat_scope"
	// memoryLimitCode (400): an edit that would take the entries' text past
	// memoryMaxTotalChars.
	memoryLimitCode = "memory_limit"
	// memoryUnavailableCode (503): the host has no memory store.
	memoryUnavailableCode = "memory_unavailable"
)

// plainChatsCapability is capabilities.plainChats, present only while the
// host's OpenCode has the chat agent for the Chats space, and the value of
// capabilities.generalChats (generalChatsCapability). Tools must not be nil,
// so an empty list encodes as [].
type plainChatsCapability struct {
	Providers []plainChatProvider `json:"providers,omitempty"`
	// UnavailableProviders are installed providers whose sign-in Chat does
	// not use (chat_subscription.go), each with its auth's reason and
	// message; clients show them in Settings and never offer them.
	UnavailableProviders []plainChatProvider `json:"unavailableProviders,omitempty"`
	ProjectID            string              `json:"projectId"`
	Tools                []string            `json:"tools"`
	SearchProvider       string              `json:"searchProvider,omitempty"`
	InstructionFiles     []string            `json:"instructionFiles,omitempty"`
}

// generalChatsCapability is plainChatsCapability as capabilities.generalChats
// encodes it: providers is always present, [] when general Chat has none.
// Clients read a missing list as legacy OpenCode-only Chat, so an empty one
// must stay. The fields match plainChatsCapability's, so one converts to the
// other.
type generalChatsCapability struct {
	Providers            []plainChatProvider `json:"providers"`
	UnavailableProviders []plainChatProvider `json:"unavailableProviders,omitempty"`
	ProjectID            string              `json:"projectId"`
	Tools                []string            `json:"tools"`
	SearchProvider       string              `json:"searchProvider,omitempty"`
	InstructionFiles     []string            `json:"instructionFiles,omitempty"`
}

// workspaceChatsCapability is capabilities.workspaceChats (owner, 2026-10-12:
// Chat is Claude Code and Codex in the selected workspace): the providers
// whose chats can run in the host's workspaces now, each signed in with a
// subscription, and the installed ones signed in otherwise, with their
// auth's reason and message. It follows the Mac's sign-ins, not OpenCode.
// Neither list is ever nil, so both encode as [] when empty.
type workspaceChatsCapability struct {
	Version              int                 `json:"version"`
	Providers            []plainChatProvider `json:"providers"`
	UnavailableProviders []plainChatProvider `json:"unavailableProviders"`
}

// workspaceChatsVersion is capabilities.workspaceChats.version.
const workspaceChatsVersion = 1

// ChatToolSource is one web page a tool part names: a result of websearch, or
// the page agentland_fetch read.
type ChatToolSource struct {
	Title string `json:"title"`
	URL   string `json:"url"`
}

// ChatToolMemory is the entry an agentland_memory_save tool part stored, as
// the host keeps it.
type ChatToolMemory struct {
	ID   string `json:"id"`
	Text string `json:"text"`
}

// ChatToolResults are the members plain chats add to a tool part: the web
// pages the tool found or read, and the memory entry a save stored. It is
// meant to be embedded in ChatTool (chat_model.go), so its fields encode
// beside the tool's own, after truncated; both are left out when empty.
// Tool parts reserve attachments for a later round, with no field yet.
type ChatToolResults struct {
	Sources []ChatToolSource `json:"sources,omitempty"`
	Memory  *ChatToolMemory  `json:"memory,omitempty"`
}

// memoryEntry is one entry of GET /v1/memory, and the answer of
// PATCH /v1/memory. The times are RFC 3339 UTC with milliseconds.
type memoryEntry struct {
	ID        string `json:"id"`
	Text      string `json:"text"`
	CreatedAt string `json:"createdAt"`
	UpdatedAt string `json:"updatedAt"`
}

// memoryLimits are the limits GET /v1/memory reports.
type memoryLimits struct {
	MaxEntries    int `json:"maxEntries"`
	MaxTotalChars int `json:"maxTotalChars"`
}

// memoryList is the answer of GET /v1/memory, entries oldest first. Entries
// must not be nil, so an empty list encodes as [].
type memoryList struct {
	Enabled bool          `json:"enabled"`
	Entries []memoryEntry `json:"entries"`
	Limits  memoryLimits  `json:"limits"`
}

// memoryUpdateInput is the body of PATCH /v1/memory. The pointers tell a
// missing member from an empty one; either answers 400 invalid_request.
type memoryUpdateInput struct {
	ID   *string `json:"id"`
	Text *string `json:"text"`
}

// memoryRemoved is the answer of DELETE /v1/memory.
type memoryRemoved struct {
	Removed bool `json:"removed"`
}

// memorySettingsInput is the body of POST /v1/memory/settings. A missing
// enabled answers 400 invalid_request.
type memorySettingsInput struct {
	Enabled *bool `json:"enabled"`
}

// memorySettings is the answer of POST /v1/memory/settings.
type memorySettings struct {
	Enabled bool `json:"enabled"`
}
