package host

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"slices"
	"strings"
	"sync"
	"time"
)

// agentland-host chat-tools (docs/HOST-API.md "The chat agent"): the plain
// chats' tool server, which OpenCode starts from the Chats space's
// opencode.json as the local MCP server "agentland". It speaks MCP over
// stdio, JSON-RPC 2.0 one message per line (the host's own JSON-RPC wire of
// acp_rpc.go and its bounded line reader, no SDK): initialize, ping,
// tools/list and tools/call, and the notifications initialized and
// cancelled. It holds no state: agentland_fetch reads a page itself, and the
// memory tools ask the host through its memory socket (memory.go), which
// only the host writes.
//
// A tool's result carries metadata beside its text: OpenCode 1.18.31 copies a
// result's metadata member into the tool part's state.metadata
// (session/tools.ts), where the host reads the page a fetch read and the
// entry a save stored (plain_chat_results.go). MCP results may carry members
// of their own.

const (
	// chatToolsLineLimit bounds one message from OpenCode.
	chatToolsLineLimit = 4 << 20
	// JSON-RPC error codes.
	chatToolsParseError    = -32700
	chatToolsInvalidParams = -32602
	// chatToolsCallWait bounds one memory call.
	chatToolsCallWait = 15 * time.Second
	// chatToolsCalls tool calls run at once; the others wait for one to end
	// or for their own cancellation.
	chatToolsCalls = 4
)

// chatToolsProtocols are the MCP versions the server answers in: the one the
// client asks for when it is one of them, the first otherwise.
var chatToolsProtocols = []string{"2025-06-18", "2025-11-25", "2025-03-26", "2024-11-05"}

// ChatToolsOptions runs the tool server of a host's state.
type ChatToolsOptions struct {
	StatePath string
	Version   string
	Input     io.Reader
	Output    io.Writer
}

type chatToolServer struct {
	socket  string
	version string
	fetcher *webFetcher
	out     io.Writer

	writeMu sync.Mutex
	mu      sync.Mutex
	calls   map[string]context.CancelFunc
	slots   chan struct{}
	work    sync.WaitGroup
}

// RunChatTools serves OpenCode until its input ends or ctx is done.
func RunChatTools(ctx context.Context, options ChatToolsOptions) error {
	server := &chatToolServer{socket: memorySocketPath(options.StatePath), version: options.Version, fetcher: newWebFetcher(options.Version), out: options.Output}
	return server.serve(ctx, options.Input)
}

func (s *chatToolServer) serve(ctx context.Context, input io.Reader) error {
	s.calls = map[string]context.CancelFunc{}
	s.slots = make(chan struct{}, chatToolsCalls)
	ctx, cancel := context.WithCancel(ctx)
	defer func() {
		cancel()
		s.work.Wait()
	}()
	lines := make(chan []byte)
	failed := make(chan error, 1)
	go func() {
		defer close(lines)
		reader := newCodexLineReader(input, chatToolsLineLimit)
		for {
			line, skipped, err := reader.next()
			if skipped > 0 {
				line = []byte{}
			} else if err != nil {
				if !errors.Is(err, io.EOF) {
					failed <- err
				}
				return
			}
			select {
			case lines <- append([]byte(nil), line...):
			case <-ctx.Done():
				return
			}
		}
	}()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case err := <-failed:
			return err
		case line, open := <-lines:
			if !open {
				return nil
			}
			if len(line) > 0 {
				s.handle(ctx, line)
			}
		}
	}
}

// write sends one message on its own line.
func (s *chatToolServer) write(message any) {
	data, err := json.Marshal(message)
	if err != nil {
		return
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_, _ = s.out.Write(append(data, '\n'))
}

func (s *chatToolServer) reply(id json.RawMessage, result any) {
	data, err := json.Marshal(result)
	if err != nil {
		s.fail(id, -32603, "The answer could not be encoded")
		return
	}
	s.write(acpReply{JSONRPC: "2.0", ID: id, Result: data})
}

func (s *chatToolServer) fail(id json.RawMessage, code int64, message string) {
	if len(id) == 0 {
		id = json.RawMessage("null")
	}
	s.write(acpReply{JSONRPC: "2.0", ID: id, Error: &acpRPCError{Code: code, Message: message}})
}

// handle answers one message. Requests are answered in order, except tool
// calls, which run on their own and answer when they end.
func (s *chatToolServer) handle(ctx context.Context, line []byte) {
	var message struct {
		ID     json.RawMessage `json:"id"`
		Method string          `json:"method"`
		Params json.RawMessage `json:"params"`
	}
	if json.Unmarshal(line, &message) != nil {
		s.fail(nil, chatToolsParseError, "Parse error")
		return
	}
	if message.Method == "" {
		return // an answer; the server sends no requests
	}
	request := len(message.ID) > 0 && string(message.ID) != "null"
	if !request {
		// Notifications: a cancelled call stops; the rest need nothing.
		if message.Method == "notifications/cancelled" {
			var params struct {
				RequestID json.RawMessage `json:"requestId"`
			}
			if json.Unmarshal(message.Params, &params) == nil {
				s.mu.Lock()
				stop := s.calls[string(params.RequestID)]
				s.mu.Unlock()
				if stop != nil {
					stop()
				}
			}
		}
		return
	}
	switch message.Method {
	case "initialize":
		var params struct {
			ProtocolVersion string `json:"protocolVersion"`
		}
		_ = json.Unmarshal(message.Params, &params)
		version := chatToolsProtocols[0]
		if slices.Contains(chatToolsProtocols, params.ProtocolVersion) {
			version = params.ProtocolVersion
		}
		s.reply(message.ID, map[string]any{
			"protocolVersion": version,
			"capabilities":    map[string]any{"tools": map[string]bool{"listChanged": false}},
			"serverInfo":      map[string]string{"name": plainChatServer, "title": "AgentLand", "version": s.version},
		})
	case "ping":
		s.reply(message.ID, map[string]any{})
	case "tools/list":
		s.reply(message.ID, map[string]any{"tools": chatToolDefinitions()})
	case "tools/call":
		var params struct {
			Name      string          `json:"name"`
			Arguments json.RawMessage `json:"arguments"`
		}
		if json.Unmarshal(message.Params, &params) != nil || !slices.ContainsFunc(chatToolDefinitions(), func(tool chatToolDefinition) bool { return tool.Name == params.Name }) {
			s.fail(message.ID, chatToolsInvalidParams, "Unknown tool")
			return
		}
		call, stop := context.WithCancel(ctx)
		key := string(message.ID)
		s.mu.Lock()
		s.calls[key] = stop
		s.mu.Unlock()
		s.work.Add(1)
		go func() {
			defer s.work.Done()
			defer stop()
			result := s.run(call, params.Name, params.Arguments)
			s.mu.Lock()
			delete(s.calls, key)
			s.mu.Unlock()
			// A cancelled call gets no answer.
			if call.Err() == nil {
				s.reply(message.ID, result)
			}
		}()
	default:
		s.fail(message.ID, acpMethodNotFound, "Method not found")
	}
}

type chatToolDefinition struct {
	Name        string         `json:"name"`
	Title       string         `json:"title"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`
	Annotations map[string]any `json:"annotations"`
}

func chatToolDefinitions() []chatToolDefinition {
	input := func(name, description string) map[string]any {
		return map[string]any{"type": "object", "properties": map[string]any{name: map[string]string{"type": "string", "description": description}},
			"required": []string{name}, "additionalProperties": false}
	}
	return []chatToolDefinition{
		{Name: "fetch", Title: "Read a web page", Description: "Read one public web page (http or https) and get its text as Markdown, with its title and address. Use it for a page the user names or a search found, and cite the address when you use what it says. It does not reach local or private addresses, and it respects the site's robots.txt.",
			InputSchema: input("url", "The page's full http or https address"), Annotations: map[string]any{"readOnlyHint": true, "openWorldHint": true}},
		{Name: "memory_save", Title: "Save to memory", Description: "Keep one short fact about the user across chats, such as a preference they asked you to remember. Each call adds a new entry. Never save passwords, keys or other secrets.",
			InputSchema: input("text", "The fact to keep, in one short line"), Annotations: map[string]any{"readOnlyHint": false, "destructiveHint": false, "openWorldHint": false}},
		{Name: "memory_forget", Title: "Forget a memory", Description: "Remove one entry from memory by its id, which the memory in your instructions shows in brackets.",
			InputSchema: input("id", "The entry's id, such as mem_0123456789abcdef"), Annotations: map[string]any{"readOnlyHint": false, "destructiveHint": true, "openWorldHint": false}},
	}
}

// chatToolResult is an MCP tools/call result with the host's metadata.
type chatToolResult struct {
	Content  []map[string]string     `json:"content"`
	IsError  bool                    `json:"isError,omitempty"`
	Metadata *chatToolResultMetadata `json:"metadata,omitempty"`
}

func chatToolText(text string) chatToolResult {
	return chatToolResult{Content: []map[string]string{{"type": "text", "text": text}}}
}

func chatToolError(text string) chatToolResult {
	result := chatToolText(text)
	result.IsError = true
	return result
}

// run waits for one of the chatToolsCalls slots, or for ctx, and runs the
// tool in it. A tool that panics answers as a failed call and the server
// goes on.
func (s *chatToolServer) run(ctx context.Context, name string, raw json.RawMessage) (result chatToolResult) {
	select {
	case s.slots <- struct{}{}:
	case <-ctx.Done():
		return chatToolError("The call was cancelled.")
	}
	defer func() { <-s.slots }()
	defer func() {
		if recover() != nil {
			result = chatToolError("The tool failed; try again.")
		}
	}()
	return s.call(ctx, name, raw)
}

// call runs one tool.
func (s *chatToolServer) call(ctx context.Context, name string, raw json.RawMessage) chatToolResult {
	var arguments map[string]json.RawMessage
	if json.Unmarshal(raw, &arguments) != nil {
		arguments = map[string]json.RawMessage{}
	}
	argument := func(key string) (string, bool) {
		var value string
		if json.Unmarshal(arguments[key], &value) != nil || strings.TrimSpace(value) == "" {
			return "", false
		}
		return value, true
	}
	switch name {
	case "fetch":
		address, ok := argument("url")
		if !ok {
			return chatToolError("Give the page's address as url.")
		}
		page, err := s.fetcher.fetch(ctx, address)
		if err != nil {
			return chatToolError(err.Error())
		}
		// The page is the part's source; an address too long to be one
		// (over 2,048 bytes) is read without it.
		source, ok := plainChatSource(page.Title, page.URL)
		if !ok {
			return chatToolText(fetchToolText(page, plainChatTitle(page.Title)))
		}
		result := chatToolText(fetchToolText(page, source.Title))
		result.Metadata = &chatToolResultMetadata{AgentLand: &chatToolAgentLand{Source: &source}}
		return result
	case "memory_save", "memory_forget":
		request := memorySocketRequest{Op: "save"}
		if name == "memory_save" {
			text, ok := argument("text")
			if !ok {
				return chatToolError("Give the fact to keep as text.")
			}
			request.Text = text
		} else {
			id, ok := argument("id")
			if !ok {
				return chatToolError("Give the entry's id as id.")
			}
			request.Op, request.ID = "forget", id
		}
		call, cancel := context.WithTimeout(ctx, chatToolsCallWait)
		defer cancel()
		// Once sent, a request is answered within memorySocketWait whether
		// or not OpenCode cancels the call meanwhile.
		answer, err := callMemorySocket(call, s.socket, request)
		switch {
		case err != nil:
			return chatToolError("AgentLand's memory cannot be reached now; nothing changed.")
		case answer.Error != "" || answer.Entry == nil:
			return chatToolError(answer.Error)
		case request.Op == "save" && ctx.Err() != nil:
			// OpenCode cancelled the call after the host saved the entry, so
			// no tool part will show the save: it is forgotten again.
			undo, cancel := context.WithTimeout(context.WithoutCancel(ctx), chatToolsCallWait)
			defer cancel()
			_, _ = callMemorySocket(undo, s.socket, memorySocketRequest{Op: "forget", ID: answer.Entry.ID})
			return chatToolError("The call was cancelled; nothing was saved.")
		}
		// The part shows the entry saved or removed (plain_chat_results.go).
		result := chatToolText("Saved to memory.")
		if request.Op == "forget" {
			result = chatToolText("Removed from memory.")
		}
		result.Metadata = &chatToolResultMetadata{AgentLand: &chatToolAgentLand{Memory: answer.Entry}}
		return result
	}
	return chatToolError("Unknown tool.")
}
