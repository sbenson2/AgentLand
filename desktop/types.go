package host

import "errors"

var ErrNotFound = errors.New("not found")

type Project struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Directory string `json:"directory,omitempty"`
}

type Session struct {
	ID        string `json:"id"`
	Title     string `json:"title"`
	ProjectID string `json:"projectId"`
	Directory string `json:"-"`
	Provider  string `json:"provider,omitempty"`
	// RewindMessageID is OpenCode's revert point. That message and every later
	// one are hidden until the chat is restored or a new prompt replaces them.
	RewindMessageID string `json:"-"`

	// Chat fork (chat_fork.go): the chat a forked chat was copied from, in
	// the POST /v1/chat/fork response.
	ParentSessionID string `json:"parentSessionId,omitempty"`

	// Chat names (chat_title.go): where the title came from and the newest
	// message it describes. Every Session the host answers carries a
	// source; the chats registry keeps both for Claude Code and Codex chats.
	TitleSource string `json:"titleSource,omitempty"`
	TitleBasis  string `json:"titleBasis,omitempty"`
	// providerTitle is OpenCode's own title, which Title replaces while the
	// host shows a name of its own (nameSession).
	providerTitle string
}

// Message is the legacy GET /v1/messages shape. Its JSON must not change.
type Message struct {
	ID          string           `json:"id"`
	Role        string           `json:"role"`
	Text        string           `json:"text"`
	Tools       []ToolCall       `json:"tools,omitempty"`
	Reasoning   []ReasoningPart  `json:"reasoning,omitempty"`
	Attachments []AttachmentInfo `json:"attachments,omitempty"`
	Error       string           `json:"error,omitempty"`
	// Unified is the same message in the unified chat model, when the agent
	// provides one; it is never part of the legacy encoding.
	Unified *ChatMessage `json:"-"`
}

type ReasoningPart struct {
	Text       string `json:"text"`
	DurationMs int64  `json:"durationMs,omitempty"`
}

// AttachmentInfo is display metadata only. File contents, data URLs and host
// paths are never returned to clients.
type AttachmentInfo struct {
	Name string `json:"name"`
	MIME string `json:"mime"`
}

type ToolCall struct {
	ID        string `json:"id"`
	CallID    string `json:"callId"`
	Name      string `json:"name"`
	Status    string `json:"status"`
	Title     string `json:"title"`
	Input     string `json:"input"`
	Output    string `json:"output"`
	Error     string `json:"error"`
	Truncated bool   `json:"truncated"`
}

type Agent interface {
	ListSessions(Project) ([]Session, error)
	CreateSession(Project, string) (Session, error)
	GetSession(Project, string) (Session, error)
	Messages(Project, string) ([]Message, error)
	Prompt(Project, string, string) error
	Abort(Project, string) error
}

// AttachmentAgent accepts uploaded files with a prompt.
type AttachmentAgent interface {
	PromptAttachments(Project, string, string, PromptOptions, []ChatAttachment) error
}

// RewindableAgent hides a chat's latest turn and can restore it.
type RewindableAgent interface {
	Rewind(Project, string, string) error
	Restore(Project, string) error
}
