package host

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

// The unified conversation model of docs/HOST-API.md. Every provider maps its
// transcript into these types; the chat hub streams them and the paged routes
// return them. Field names are the contract's.

// Bounds on what one message may hold in the unified model. Tool fields follow
// the contract (64 KiB each); reasoning keeps the legacy bound.
const (
	chatToolFieldLimit  = 64 << 10
	chatReasoningLimit  = 64 << 10
	chatTextLimit       = 512 << 10
	chatErrorLimit      = 4 << 10
	chatShortLimit      = 1 << 10
	chatPartsPerMessage = 256
	chatPatchFiles      = 200
)

type ChatMessage struct {
	ID          string     `json:"id"`
	ChatID      string     `json:"chatId"`
	TurnID      string     `json:"turnId"`
	Role        string     `json:"role"`
	Status      string     `json:"status"`
	Ord         int64      `json:"ord"`
	CreatedAt   string     `json:"createdAt"`
	CompletedAt string     `json:"completedAt,omitempty"`
	Provider    string     `json:"provider"`
	Model       string     `json:"model,omitempty"`
	Usage       *ChatUsage `json:"usage,omitempty"`
	Error       *ChatError `json:"error,omitempty"`
	Parts       []ChatPart `json:"parts"`
	// createdMs is the provider's creation time; OpenCode pages by it.
	createdMs int64
}

type ChatError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	// AuthMethods names an ACP agent's sign-in methods, with code
	// agent_auth_required (acp_chat.go); absent otherwise.
	AuthMethods []string `json:"authMethods,omitempty"`
}

// ChatPart is one ordered piece of a message. Text, reasoning, notice, patch
// and context parts carry text; tool and attachment parts carry their object.
type ChatPart struct {
	ID         string          `json:"id"`
	Kind       string          `json:"kind"`
	Ord        int64           `json:"ord"`
	Text       string          `json:"text,omitempty"`
	Tool       *ChatTool       `json:"tool,omitempty"`
	Attachment *AttachmentInfo `json:"attachment,omitempty"`
	Start      string          `json:"start,omitempty"`
	End        string          `json:"end,omitempty"`
	// Truncated says the host shortened this part's text.
	Truncated bool `json:"truncated,omitempty"`
}

type ChatTool struct {
	Name      string `json:"name"`
	CallID    string `json:"callId"`
	Status    string `json:"status"`
	Title     string `json:"title,omitempty"`
	Input     string `json:"input,omitempty"`
	Output    string `json:"output,omitempty"`
	Error     string `json:"error,omitempty"`
	Truncated bool   `json:"truncated"`
	// Plain chats (plain_chat_results.go): the web pages the tool found or
	// read, and the memory entry a save stored; left out when there are none.
	ChatToolResults
}

type ChatUsage struct {
	Input      int64  `json:"input"`
	Output     int64  `json:"output"`
	Reasoning  int64  `json:"reasoning"`
	CacheRead  int64  `json:"cacheRead"`
	CacheWrite int64  `json:"cacheWrite"`
	CostMicros *int64 `json:"costMicros,omitempty"`
}

type ChatInteraction struct {
	ID        string   `json:"id"`
	ChatID    string   `json:"chatId"`
	Kind      string   `json:"kind"`
	CreatedAt string   `json:"createdAt"`
	Choices   []string `json:"choices,omitempty"`
	// What "always" grants, in words (interaction_always.go); only when
	// Choices offers always.
	AlwaysLabel  string          `json:"alwaysLabel,omitempty"`
	AlwaysDetail string          `json:"alwaysDetail,omitempty"`
	Permission   *ChatPermission `json:"permission,omitempty"`
	Questions    []ChatQuestion  `json:"questions,omitempty"`
}

type ChatPermission struct {
	Tool   string `json:"tool"`
	Title  string `json:"title"`
	Detail string `json:"detail"`
	Input  string `json:"input,omitempty"`
}

type ChatQuestion struct {
	ID       string               `json:"id"`
	Text     string               `json:"text"`
	Header   string               `json:"header,omitempty"`
	Options  []ChatQuestionOption `json:"options"`
	Multiple bool                 `json:"multiple"`
	Custom   bool                 `json:"custom"`
	Secret   bool                 `json:"secret"`
}

type ChatQuestionOption struct {
	Label       string `json:"label"`
	Description string `json:"description,omitempty"`
}

// ChatStatusInfo is the stream's status: idle, running, waiting (an
// interaction is pending), retry or error (the last turn failed).
type ChatStatusInfo struct {
	State string     `json:"state"`
	Retry *ChatRetry `json:"retry,omitempty"`
}

type ChatRetry struct {
	Attempt int    `json:"attempt"`
	NextAt  string `json:"nextAt,omitempty"`
	Message string `json:"message,omitempty"`
}

// ChatInfo describes the chat in a snapshot. A provider's read gives its own
// title; the hub turns it into the name the host shows (chat_title.go), with
// its source and basis.
type ChatInfo struct {
	ID          string `json:"id"`
	Title       string `json:"title"`
	TitleSource string `json:"titleSource,omitempty"`
	TitleBasis  string `json:"titleBasis,omitempty"`
	Provider    string `json:"provider"`
	Model       string `json:"model,omitempty"`
	Mode        string `json:"mode,omitempty"`
	Effort      string `json:"effort,omitempty"`
}

// chatTime formats a millisecond timestamp as UTC RFC 3339 with milliseconds;
// zero or negative means unknown.
func chatTime(ms float64) string {
	if ms <= 0 {
		return ""
	}
	return time.UnixMilli(int64(ms)).UTC().Format("2006-01-02T15:04:05.000Z")
}

func chatTimeOf(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format("2006-01-02T15:04:05.000Z")
}

// openCodeIDValue returns the 48 bits OpenCode encodes after an ID prefix:
// the low bits of milliseconds × 4096 plus a per-millisecond counter.
func openCodeIDValue(id string) (uint64, bool) {
	_, rest, ok := strings.Cut(id, "_")
	if !ok || len(rest) < 12 {
		return 0, false
	}
	value, err := strconv.ParseUint(rest[:12], 16, 64)
	return value, err == nil
}

// openCodeMessageOrd orders messages like OpenCode does: by creation time,
// then by ID. The ID's counter bits break ties within one millisecond.
func openCodeMessageOrd(id string, createdMs float64) int64 {
	value, ok := openCodeIDValue(id)
	if createdMs > 0 {
		return int64(createdMs)*4096 + int64(value&0xfff)
	}
	if ok {
		return int64(value)
	}
	return 0
}

// openCodePartOrd orders parts by their ascending ID, as OpenCode stores them;
// fallback keeps the transcript position for IDs in another format.
func openCodePartOrd(id string, fallback int) int64 {
	if value, ok := openCodeIDValue(id); ok {
		return int64(value)
	}
	return int64(fallback)
}

var openCodeIDClock struct {
	sync.Mutex
	last    int64
	counter uint64
}

const base62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

// newOpenCodeMessageID creates a message ID in OpenCode 1.18.31's ascending
// format: "msg_", 12 hex digits of (milliseconds × 4096 + counter) truncated
// to 48 bits, then 14 base62 characters. OpenCode accepts it as the
// prompt's messageID, so the host knows the user message's ID before sending.
func newOpenCodeMessageID(now time.Time) string {
	ms := now.UnixMilli()
	openCodeIDClock.Lock()
	if ms != openCodeIDClock.last {
		openCodeIDClock.last = ms
		openCodeIDClock.counter = 0
	}
	openCodeIDClock.counter++
	value := uint64(ms)*4096 + openCodeIDClock.counter
	openCodeIDClock.Unlock()
	var random [14]byte
	if _, err := rand.Read(random[:]); err != nil {
		panic(err)
	}
	suffix := make([]byte, len(random))
	for index, b := range random {
		suffix[index] = base62[int(b)%len(base62)]
	}
	return fmt.Sprintf("msg_%012x%s", value&(1<<48-1), suffix)
}

// openCodePageCursor builds OpenCode 1.18.31's message page cursor: base64url
// JSON of the oldest returned message's ID and creation time. OpenCode returns
// the same value in X-Next-Cursor; the host builds it to page from any
// message it has shown.
func openCodePageCursor(id string, createdMs int64) string {
	data, _ := json.Marshal(struct {
		ID   string `json:"id"`
		Time int64  `json:"time"`
	}{id, createdMs})
	return base64.RawURLEncoding.EncodeToString(data)
}

// clipText keeps at most limit bytes of value, cut on a character boundary.
func clipText(value string, limit int) (string, bool) {
	if len(value) <= limit {
		return value, false
	}
	end := limit
	for end > 0 && !utf8.RuneStart(value[end]) {
		end--
	}
	return value[:end], true
}

// jsonStringSize is the length of value encoded as a JSON string without its
// quotes, as marshalJSONLine writes it (HTML characters are not escaped).
func jsonStringSize(value string) int {
	size := 0
	for index := 0; index < len(value); {
		r, width := utf8.DecodeRuneInString(value[index:])
		size += jsonRuneSize(r, width)
		index += width
	}
	return size
}

// invalidUTF8JSONSize is what the encoder writes for one invalid byte: Go
// 1.26 escapes it as � (6 bytes), Go 1.27 writes U+FFFD itself (3).
var invalidUTF8JSONSize = len(marshalJSONLine(string([]byte{0xff}))) - 2

func jsonRuneSize(r rune, width int) int {
	switch {
	case r == utf8.RuneError && width == 1:
		return invalidUTF8JSONSize
	case r == '"' || r == '\\' || r == '\n' || r == '\r' || r == '\t':
		return 2
	case r < 0x20 || r == '\u2028' || r == '\u2029':
		return 6
	default:
		return width
	}
}

// clipJSON returns the longest prefix of value, cut on a character boundary,
// whose JSON-encoded size is at most limit.
func clipJSON(value string, limit int) string {
	size := 0
	for index := 0; index < len(value); {
		r, width := utf8.DecodeRuneInString(value[index:])
		cost := jsonRuneSize(r, width)
		if size+cost > limit {
			return value[:index]
		}
		size += cost
		index += width
	}
	return value
}

// marshalJSONLine encodes v without HTML escaping and without a newline.
func marshalJSONLine(v any) []byte {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(v); err != nil {
		panic(err)
	}
	return bytes.TrimSuffix(buffer.Bytes(), []byte{'\n'})
}

// chatErrorCode maps OpenCode's error names to stable codes.
func chatErrorCode(name string) string {
	switch name {
	case "MessageAbortedError":
		return "aborted"
	case "ProviderAuthError":
		return "provider_auth"
	case "APIError":
		return "provider_error"
	case "MessageOutputLengthError":
		return "output_length"
	case "ContextOverflowError":
		return "context_overflow"
	case "ContentFilterError":
		return "content_filter"
	case "StructuredOutputError":
		return "structured_output"
	default:
		return "agent_error"
	}
}

const chatDefaultError = "The agent could not complete this request. Check its provider settings on the host."

// chatHeaderFromOC maps OpenCode message info to a unified message without parts.
func chatHeaderFromOC(info ocInfo) ChatMessage {
	message := ChatMessage{ID: info.ID, ChatID: info.SessionID, Role: info.Role, Provider: "opencode", Parts: []ChatPart{}, createdMs: int64(info.Time.Created)}
	message.Ord = openCodeMessageOrd(info.ID, info.Time.Created)
	message.CreatedAt = chatTime(info.Time.Created)
	if info.Role == "user" {
		message.TurnID = info.ID
		message.Status = "complete"
		if info.Model.ProviderID != "" && info.Model.ModelID != "" {
			message.Model = info.Model.ProviderID + "/" + info.Model.ModelID
		}
		return message
	}
	message.TurnID = info.ParentID
	if info.ProviderID != "" && info.ModelID != "" {
		message.Model = info.ProviderID + "/" + info.ModelID
	}
	message.Usage = chatUsageFromOC(info.Tokens, info.Cost)
	message.CompletedAt = chatTime(info.Time.Completed)
	switch {
	case info.Error != nil && info.Error.Name == "MessageAbortedError":
		message.Status = "aborted"
	case info.Error != nil:
		message.Status = "error"
		text := strings.TrimSpace(info.Error.Data.Message)
		if text == "" {
			text = chatDefaultError
		}
		text, _ = clipText(text, chatErrorLimit)
		message.Error = &ChatError{Code: chatErrorCode(info.Error.Name), Message: text}
	case info.Time.Completed > 0:
		message.Status = "complete"
	default:
		message.Status = "streaming"
	}
	return message
}

func chatUsageFromOC(tokens ocTokens, cost float64) *ChatUsage {
	if tokens.Input == 0 && tokens.Output == 0 && tokens.Reasoning == 0 && tokens.Cache.Read == 0 && tokens.Cache.Write == 0 && cost == 0 {
		return nil
	}
	micros := int64(cost*1e6 + 0.5)
	return &ChatUsage{Input: int64(tokens.Input), Output: int64(tokens.Output), Reasoning: int64(tokens.Reasoning), CacheRead: int64(tokens.Cache.Read), CacheWrite: int64(tokens.Cache.Write), CostMicros: &micros}
}

// chatPartFromOC maps one OpenCode part. It reports false for parts a chat
// does not show: steps, snapshots and the file text OpenCode adds to a prompt.
// root turns patch paths into project-relative ones.
func chatPartFromOC(part ocPart, index int, root string) (ChatPart, bool) {
	result := ChatPart{ID: part.ID, Ord: openCodePartOrd(part.ID, index), Start: chatTime(part.Time.Start), End: chatTime(part.Time.End)}
	switch part.Type {
	case "text":
		if part.Synthetic {
			return ChatPart{}, false
		}
		result.Kind = "text"
		result.Text, result.Truncated = clipText(part.Text, chatTextLimit)
	case "reasoning":
		// A finished reasoning part with no text is noise; a live one is kept
		// so its deltas have somewhere to go.
		if strings.TrimSpace(part.Text) == "" && part.Time.End > 0 {
			return ChatPart{}, false
		}
		result.Kind = "reasoning"
		result.Text, result.Truncated = clipText(part.Text, chatReasoningLimit)
	case "file":
		name := part.Filename
		if name == "" {
			name = "attachment"
		}
		result.Kind = "attachment"
		result.Attachment = &AttachmentInfo{Name: name, MIME: part.Mime}
	case "tool":
		result.Kind = "tool"
		result.Start, result.End = chatTime(part.State.Time.Start), chatTime(part.State.Time.End)
		result.Tool = chatToolFromOC(part)
	case "patch":
		if len(part.Files) == 0 {
			return ChatPart{}, false
		}
		result.Kind = "patch"
		result.Text = patchFileList(part.Files, root)
	case "retry":
		var failure struct{ Data struct{ Message string } }
		_ = json.Unmarshal(part.RetryError, &failure)
		message := strings.TrimSpace(failure.Data.Message)
		if message == "" {
			message = "The provider did not answer."
		}
		message, _ = clipText(message, chatShortLimit)
		result.Kind = "notice"
		result.Text = fmt.Sprintf("Retrying after a provider error (attempt %d): %s", int(part.Attempt), message)
		result.Start = chatTime(part.Time.Created)
	case "compaction":
		result.Kind = "notice"
		result.Text = "The conversation was compacted to fit the model's context."
	case "subtask":
		description, _ := clipText(strings.TrimSpace(part.Description), chatShortLimit)
		result.Kind = "notice"
		result.Text = "Subtask for " + part.Agent + ": " + description
	case "agent":
		result.Kind = "notice"
		result.Text = "Agent: " + part.Name
	case "step-finish":
		switch part.Reason {
		case "length":
			result.Kind = "notice"
			result.Text = "The reply reached the model's output limit."
		case "content-filter":
			result.Kind = "notice"
			result.Text = "The provider's content filter stopped the reply."
		default:
			return ChatPart{}, false
		}
	default:
		return ChatPart{}, false
	}
	return result, true
}

func chatToolFromOC(part ocPart) *ChatTool {
	input, inputCut := boundedToolText(string(part.State.Input))
	output, outputCut := boundedToolText(part.State.Output)
	failure, errorCut := boundedToolText(part.State.Error)
	title, _ := clipText(part.State.Title, chatShortLimit)
	status := part.State.Status
	switch status {
	case "pending", "running", "completed", "error":
	default:
		status = "running"
	}
	if input == "{}" || input == "null" {
		input = ""
	}
	tool := &ChatTool{Name: part.Tool, CallID: part.CallID, Status: status, Title: title, Input: input, Output: output, Error: failure, Truncated: inputCut || outputCut || errorCut}
	// Plain chats: the pages a completed search or fetch used, and the entry a
	// memory save stored or a forget removed.
	if status == "completed" {
		tool.ChatToolResults = chatToolResults(part.Tool, part.State.Output, part.State.Metadata.AgentLand)
		// OpenCode gives an MCP tool's part no title: the entry saved or
		// forgotten, or the page read, names it.
		if tool.Title == "" && tool.Memory != nil {
			tool.Title, _ = clipText(tool.Memory.Text, chatShortLimit)
		} else if tool.Title == "" && part.Tool == chatToolFetch && len(tool.Sources) == 1 {
			tool.Title = tool.Sources[0].Title
		}
	}
	return tool
}

// patchFileList lists changed files one per line, relative to the project.
func patchFileList(files []string, root string) string {
	lines := make([]string, 0, min(len(files), chatPatchFiles))
	for _, file := range files {
		if len(lines) == chatPatchFiles {
			break
		}
		name := file
		if root != "" && filepath.IsAbs(file) {
			if relative, err := filepath.Rel(root, file); err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
				name = relative
			} else {
				name = filepath.Base(file)
			}
		}
		lines = append(lines, filepath.ToSlash(name))
	}
	text, _ := clipText(strings.Join(lines, "\n"), chatToolFieldLimit)
	return text
}

// chatMessageFromLegacy builds the unified form of a message that only has
// legacy fields (Claude Code and Codex chats, agents without part data).
func chatMessageFromLegacy(message Message, provider, chatID, turnID string, ord int64, created time.Time) ChatMessage {
	result := ChatMessage{ID: message.ID, ChatID: chatID, TurnID: turnID, Role: message.Role, Status: "complete", Ord: ord, CreatedAt: chatTimeOf(created), Provider: provider, Parts: []ChatPart{}, createdMs: created.UnixMilli()}
	if message.Role == "user" {
		result.TurnID = message.ID
	}
	next := func(kind string) ChatPart {
		part := ChatPart{ID: fmt.Sprintf("%s:%d", message.ID, len(result.Parts)), Kind: kind, Ord: int64(len(result.Parts) + 1)}
		return part
	}
	for _, reasoning := range message.Reasoning {
		part := next("reasoning")
		part.Text = reasoning.Text
		result.Parts = append(result.Parts, part)
	}
	for _, tool := range message.Tools {
		part := next("tool")
		if tool.ID != "" {
			part.ID = tool.ID
		}
		status := tool.Status
		switch status {
		case "pending", "running", "completed", "error":
		default:
			status = "completed"
		}
		part.Tool = &ChatTool{Name: tool.Name, CallID: tool.CallID, Status: status, Title: tool.Title, Input: tool.Input, Output: tool.Output, Error: tool.Error, Truncated: tool.Truncated}
		result.Parts = append(result.Parts, part)
	}
	if message.Text != "" {
		part := next("text")
		part.Text, part.Truncated = clipText(message.Text, chatTextLimit)
		result.Parts = append(result.Parts, part)
	}
	for _, attachment := range message.Attachments {
		part := next("attachment")
		info := attachment
		part.Attachment = &info
		result.Parts = append(result.Parts, part)
	}
	if message.Error != "" {
		result.Status = "error"
		text, _ := clipText(message.Error, chatErrorLimit)
		result.Error = &ChatError{Code: "agent_error", Message: text}
	}
	return result
}

// unifiedMessages returns each message's unified form, deriving it from the
// legacy fields where the agent did not supply one. Turn IDs follow the most
// recent user message.
func unifiedMessages(items []Message, provider, chatID string, created func(int, Message) time.Time) []ChatMessage {
	result := make([]ChatMessage, 0, len(items))
	turn := ""
	for index, item := range items {
		if item.Role == "user" {
			turn = item.ID
		}
		if item.Unified != nil {
			result = append(result, *item.Unified)
			continue
		}
		result = append(result, chatMessageFromLegacy(item, provider, chatID, turn, int64(index+1), created(index, item)))
	}
	return result
}
