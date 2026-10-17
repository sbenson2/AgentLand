package host

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

// The plain chats' tool server (chat_tools.go): MCP over stdio as OpenCode's
// MCP client speaks it (initialize, notifications/initialized, tools/list,
// tools/call, notifications/cancelled), with the host's memory socket and
// agentland_fetch behind it.

type mcpSession struct {
	t      *testing.T
	input  *io.PipeWriter
	output *bufio.Reader
}

// startChatTools runs a tool server on pipes until the test ends.
func startChatTools(t *testing.T, server *chatToolServer) *mcpSession {
	t.Helper()
	inputReader, inputWriter := io.Pipe()
	outputReader, outputWriter := io.Pipe()
	server.out = outputWriter
	if server.calls == nil {
		server.calls = map[string]context.CancelFunc{}
	}
	done := make(chan error, 1)
	go func() {
		done <- server.serve(context.Background(), inputReader)
		outputWriter.Close()
	}()
	session := &mcpSession{t: t, input: inputWriter, output: bufio.NewReader(outputReader)}
	t.Cleanup(func() {
		inputWriter.Close()
		go io.Copy(io.Discard, outputReader)
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			t.Error("the tool server did not stop when its input ended")
		}
	})
	return session
}

func (s *mcpSession) send(line string) {
	s.t.Helper()
	if _, err := io.WriteString(s.input, line+"\n"); err != nil {
		s.t.Fatal(err)
	}
}

// read returns the server's next message.
func (s *mcpSession) read() map[string]any {
	s.t.Helper()
	type result struct {
		line string
		err  error
	}
	next := make(chan result, 1)
	go func() {
		line, err := s.output.ReadString('\n')
		next <- result{line, err}
	}()
	select {
	case got := <-next:
		if got.err != nil {
			s.t.Fatalf("read: %v", got.err)
		}
		var message map[string]any
		if err := json.Unmarshal([]byte(got.line), &message); err != nil {
			s.t.Fatalf("not JSON: %q", got.line)
		}
		if message["jsonrpc"] != "2.0" {
			s.t.Fatalf("not JSON-RPC 2.0: %q", got.line)
		}
		return message
	case <-time.After(10 * time.Second):
		s.t.Fatal("the tool server did not answer")
		return nil
	}
}

// call sends a tools/call and returns its result.
func (s *mcpSession) call(id int, tool string, arguments any) map[string]any {
	s.t.Helper()
	data, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "method": "tools/call", "params": map[string]any{"name": tool, "arguments": arguments, "_meta": map[string]any{"progressToken": id}}})
	s.send(string(data))
	message := s.read()
	if message["id"] != float64(id) || message["result"] == nil {
		s.t.Fatalf("tools/call %s: %v", tool, message)
	}
	return message["result"].(map[string]any)
}

func resultText(t *testing.T, result map[string]any) string {
	t.Helper()
	content := result["content"].([]any)
	if len(content) != 1 || content[0].(map[string]any)["type"] != "text" {
		t.Fatalf("content %v", content)
	}
	return content[0].(map[string]any)["text"].(string)
}

// asOpenCodePart is the tool part OpenCode 1.18.31 makes from an MCP result:
// its text as output, its metadata with OpenCode's own truncated flag.
func asOpenCodePart(t *testing.T, tool string, result map[string]any) *ChatTool {
	t.Helper()
	metadata := map[string]any{"truncated": false}
	if extra, ok := result["metadata"].(map[string]any); ok {
		for key, value := range extra {
			metadata[key] = value
		}
	}
	status := "completed"
	if result["isError"] == true {
		status = "error"
	}
	part, ok := chatPartFromOC(ocToolPart(t, tool, status, resultText(t, result), metadata), 0, "")
	if !ok {
		t.Fatal("no part")
	}
	return part.Tool
}

func TestChatToolsSpeakMCPOverStdio(t *testing.T) {
	session := startChatTools(t, &chatToolServer{version: "1.2.3", fetcher: newWebFetcher("1.2.3")})
	session.send(`{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"roots":{}},"clientInfo":{"name":"opencode","version":"1.18.31"}}}`)
	initialized := session.read()
	result := initialized["result"].(map[string]any)
	if initialized["id"] != float64(0) || result["protocolVersion"] != "2025-11-25" || result["capabilities"].(map[string]any)["tools"] == nil ||
		!reflect.DeepEqual(result["serverInfo"], map[string]any{"name": "agentland", "title": "AgentLand", "version": "1.2.3"}) {
		t.Fatalf("initialize: %v", initialized)
	}
	// A version it does not know is answered with its own.
	session.send(`{"jsonrpc":"2.0","id":"init-2","method":"initialize","params":{"protocolVersion":"2099-01-01","capabilities":{}}}`)
	if again := session.read(); again["id"] != "init-2" || again["result"].(map[string]any)["protocolVersion"] != "2025-06-18" {
		t.Fatalf("initialize with an unknown version: %v", again)
	}
	// Notifications and answers get no reply; the next message is the ping's.
	session.send(`{"jsonrpc":"2.0","method":"notifications/initialized"}`)
	session.send(`{"jsonrpc":"2.0","id":41,"result":{}}`)
	session.send(`{"jsonrpc":"2.0","id":1,"method":"ping"}`)
	if pong := session.read(); pong["id"] != float64(1) || !reflect.DeepEqual(pong["result"], map[string]any{}) {
		t.Fatalf("ping: %v", pong)
	}
	session.send(`{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}`)
	listed := session.read()["result"].(map[string]any)["tools"].([]any)
	var names []string
	for _, tool := range listed {
		definition := tool.(map[string]any)
		names = append(names, definition["name"].(string))
		schema := definition["inputSchema"].(map[string]any)
		if schema["type"] != "object" || len(schema["required"].([]any)) != 1 || definition["description"] == "" {
			t.Fatalf("tool %v", definition)
		}
	}
	// OpenCode names them agentland_fetch, agentland_memory_save and
	// agentland_memory_forget.
	if !reflect.DeepEqual(names, []string{"fetch", "memory_save", "memory_forget"}) {
		t.Fatalf("tools %v", names)
	}
	// Errors.
	session.send(`{"jsonrpc":"2.0","id":3,"method":"resources/list"}`)
	if refused := session.read(); refused["id"] != float64(3) || refused["error"].(map[string]any)["code"] != float64(-32601) {
		t.Fatalf("unknown method: %v", refused)
	}
	session.send(`{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"bash","arguments":{}}}`)
	if refused := session.read(); refused["error"].(map[string]any)["code"] != float64(-32602) {
		t.Fatalf("unknown tool: %v", refused)
	}
	session.send(`{not json`)
	if refused := session.read(); refused["id"] != nil || refused["error"].(map[string]any)["code"] != float64(-32700) {
		t.Fatalf("parse error: %v", refused)
	}
	// Missing arguments are the tool's error, which the model sees.
	if result := session.call(5, "fetch", map[string]any{}); result["isError"] != true || resultText(t, result) != "Give the page's address as url." {
		t.Fatalf("fetch without url: %v", result)
	}
}

func TestChatToolsMemoryGoesThroughTheHost(t *testing.T) {
	f := newPlainChatFixture(t, HostOptions{})
	session := startChatTools(t, &chatToolServer{socket: memorySocketPath(f.store.Path), version: "test", fetcher: newWebFetcher("test")})
	saved := session.call(1, "memory_save", map[string]string{"text": "Prefers\nmetric units"})
	if saved["isError"] != nil || resultText(t, saved) != "Saved to memory." {
		t.Fatalf("save: %v", saved)
	}
	entries := f.host.plainChats.memory.list().Entries
	if len(entries) != 1 || entries[0].Text != "Prefers metric units" {
		t.Fatalf("the host keeps %+v", entries)
	}
	// The host reads the entry from OpenCode's part.
	tool := asOpenCodePart(t, "agentland_memory_save", saved)
	if tool.Memory == nil || *tool.Memory != (ChatToolMemory{ID: entries[0].ID, Text: "Prefers metric units"}) || tool.Title != "Prefers metric units" {
		t.Fatalf("part %+v", tool)
	}
	forgot := session.call(2, "memory_forget", map[string]string{"id": entries[0].ID})
	if forgot["isError"] != nil || resultText(t, forgot) != "Removed from memory." || len(f.host.plainChats.memory.list().Entries) != 0 {
		t.Fatalf("forget: %v", forgot)
	}
	// The forget part carries the entry it removed.
	if tool := asOpenCodePart(t, "agentland_memory_forget", forgot); tool.Memory == nil || *tool.Memory != (ChatToolMemory{ID: entries[0].ID, Text: "Prefers metric units"}) {
		t.Fatalf("a forget part carries %+v", tool.Memory)
	}
	if missing := session.call(3, "memory_forget", map[string]string{"id": "mem_missing"}); missing["isError"] != true || resultText(t, missing) != "No memory entry has that id." {
		t.Fatalf("forget of a missing entry: %v", missing)
	}
	// Refusals are the tool's errors, in words; while memory is off the model
	// neither saves nor forgets.
	kept, err := f.host.plainChats.memory.save("Lives in Lisbon")
	if err != nil {
		t.Fatal(err)
	}
	f.host.plainChats.memory.setEnabled(false)
	for index, check := range []struct {
		tool, key, value, words string
	}{
		{"memory_save", "text", "x", "Memory is off."},
		{"memory_forget", "id", kept.ID, "Memory is off, so nothing was removed."},
		{"memory_save", "note", "x", "Give the fact to keep as text."},
	} {
		result := session.call(10+index, check.tool, map[string]string{check.key: check.value})
		if result["isError"] != true || !strings.Contains(resultText(t, result), check.words) {
			t.Fatalf("%v: %v", check, result)
		}
		if tool := asOpenCodePart(t, "agentland_"+check.tool, result); tool.Status != "error" || tool.Memory != nil {
			t.Fatalf("an error part %+v", tool)
		}
	}
	if entries := f.host.plainChats.memory.list().Entries; len(entries) != 1 || entries[0].ID != kept.ID {
		t.Fatalf("memory while off %+v", entries)
	}
	// Without the host there is no memory.
	lost := startChatTools(t, &chatToolServer{socket: filepath.Join(t.TempDir(), "missing.sock"), version: "test", fetcher: newWebFetcher("test")})
	if result := lost.call(1, "memory_save", map[string]string{"text": "x"}); result["isError"] != true || !strings.Contains(resultText(t, result), "cannot be reached") {
		t.Fatalf("save without the host: %v", result)
	}
}

func TestChatToolsFetchNamesItsSource(t *testing.T) {
	_, network := newFetchServer(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/robots.txt":
			http.NotFound(w, r)
		case "/old":
			http.Redirect(w, r, "/tides", http.StatusMovedPermanently)
		default:
			w.Header().Set("Content-Type", "text/html")
			fmt.Fprint(w, "<title>Lisbon tides</title><p>High tide at 06:12.</p>")
		}
	})
	session := startChatTools(t, &chatToolServer{version: "test", fetcher: network.fetcher(t)})
	result := session.call(1, "fetch", map[string]string{"url": "http://pages.example/old"})
	if result["isError"] != nil || resultText(t, result) != "Title: Lisbon tides\nURL: http://pages.example/tides\n\nHigh tide at 06:12." {
		t.Fatalf("fetch: %v", result)
	}
	tool := asOpenCodePart(t, "agentland_fetch", result)
	if !reflect.DeepEqual(tool.Sources, []ChatToolSource{{Title: "Lisbon tides", URL: "http://pages.example/tides"}}) || tool.Title != "Lisbon tides" {
		t.Fatalf("part %+v", tool)
	}
	refused := session.call(2, "fetch", map[string]string{"url": "http://127.0.0.1/admin"})
	if refused["isError"] != true || resultText(t, refused) != "The page could not be reached." || refused["metadata"] != nil {
		t.Fatalf("a private address: %v", refused)
	}
}

func TestChatToolsCancelledCallGetsNoAnswer(t *testing.T) {
	release := make(chan struct{})
	_, network := newFetchServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/robots.txt" {
			http.NotFound(w, r)
			return
		}
		select {
		case <-release:
		case <-r.Context().Done():
		}
	})
	defer close(release)
	session := startChatTools(t, &chatToolServer{version: "test", fetcher: network.fetcher(t)})
	session.send(`{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"fetch","arguments":{"url":"http://pages.example/slow"}}}`)
	waitFor(t, "the call to reach the page", func() bool {
		_, dialed := network.record()
		return len(dialed) == 2
	})
	session.send(`{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7,"reason":"stopped"}}`)
	session.send(`{"jsonrpc":"2.0","id":8,"method":"ping"}`)
	if pong := session.read(); pong["id"] != float64(8) {
		t.Fatalf("the next message after a cancel: %v", pong)
	}
	session.send(`{"jsonrpc":"2.0","id":9,"method":"ping"}`)
	if pong := session.read(); pong["id"] != float64(9) {
		t.Fatalf("a cancelled call answered: %v", pong)
	}
}

// A save OpenCode cancels after it reached the host is waited for and then
// forgotten again: no tool part would show it, so the user could not undo it.
func TestChatToolsForgetASaveTheirCallerCancelled(t *testing.T) {
	path := filepath.Join(plainStateFolder(t), "m.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	requests := make(chan memorySocketRequest, 4)
	answerSave := make(chan struct{})
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				line, _ := bufio.NewReader(conn).ReadBytes('\n')
				var request memorySocketRequest
				json.Unmarshal(line, &request)
				requests <- request
				if request.Op == "save" {
					<-answerSave
				}
				json.NewEncoder(conn).Encode(memorySocketAnswer{Entry: &ChatToolMemory{ID: "mem_saved", Text: "Prefers tea"}})
			}()
		}
	}()
	next := func() memorySocketRequest {
		t.Helper()
		select {
		case request := <-requests:
			return request
		case <-time.After(10 * time.Second):
			t.Fatal("the host got no request")
			return memorySocketRequest{}
		}
	}
	session := startChatTools(t, &chatToolServer{socket: path, version: "test"})
	session.send(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"memory_save","arguments":{"text":"Prefers tea"}}}`)
	if saved := next(); saved != (memorySocketRequest{Op: "save", Text: "Prefers tea"}) {
		t.Fatalf("request %+v", saved)
	}
	session.send(`{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1,"reason":"stopped"}}`)
	session.send(`{"jsonrpc":"2.0","id":2,"method":"ping"}`)
	if pong := session.read(); pong["id"] != float64(2) {
		t.Fatalf("after the cancel: %v", pong)
	}
	close(answerSave)
	if forgot := next(); forgot != (memorySocketRequest{Op: "forget", ID: "mem_saved"}) {
		t.Fatalf("after the saved answer: %+v", forgot)
	}
	// The cancelled call gets no answer.
	session.send(`{"jsonrpc":"2.0","id":3,"method":"ping"}`)
	if pong := session.read(); pong["id"] != float64(3) {
		t.Fatalf("a cancelled call answered: %v", pong)
	}
}

// At most chatToolsCalls calls run at once; the others wait for one to end.
func TestChatToolsRunFourCallsAtOnce(t *testing.T) {
	release := make(chan struct{})
	arrived := make(chan struct{}, 16)
	var mu sync.Mutex
	running, most := 0, 0
	_, network := newFetchServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/robots.txt" {
			http.NotFound(w, r)
			return
		}
		mu.Lock()
		running++
		most = max(most, running)
		mu.Unlock()
		arrived <- struct{}{}
		select {
		case <-release:
		case <-r.Context().Done():
		}
		mu.Lock()
		running--
		mu.Unlock()
		fmt.Fprint(w, "page")
	})
	var once sync.Once
	stop := func() { once.Do(func() { close(release) }) }
	t.Cleanup(stop)
	session := startChatTools(t, &chatToolServer{version: "test", fetcher: network.fetcher(t)})
	for id := 1; id <= chatToolsCalls+2; id++ {
		session.send(fmt.Sprintf(`{"jsonrpc":"2.0","id":%d,"method":"tools/call","params":{"name":"fetch","arguments":{"url":"http://pages.example/%d"}}}`, id, id))
	}
	for range chatToolsCalls {
		select {
		case <-arrived:
		case <-time.After(10 * time.Second):
			t.Fatal("the first calls did not run")
		}
	}
	select {
	case <-arrived:
		t.Fatal("a fifth call ran while four were running")
	case <-time.After(300 * time.Millisecond):
	}
	// Pings are answered while calls wait.
	session.send(`{"jsonrpc":"2.0","id":99,"method":"ping"}`)
	if pong := session.read(); pong["id"] != float64(99) {
		t.Fatalf("ping: %v", pong)
	}
	stop()
	answered := map[float64]bool{}
	for range chatToolsCalls + 2 {
		message := session.read()
		result, _ := message["result"].(map[string]any)
		if result == nil || result["isError"] != nil || !strings.HasSuffix(resultText(t, result), "\n\npage") {
			t.Fatalf("answer %v", message)
		}
		answered[message["id"].(float64)] = true
	}
	mu.Lock()
	defer mu.Unlock()
	if len(answered) != chatToolsCalls+2 || most != chatToolsCalls {
		t.Fatalf("answered %v, at most %d at once", answered, most)
	}
}

// A tool that panics answers as a failed call, and the server goes on.
func TestChatToolsSurviveAPanickingTool(t *testing.T) {
	session := startChatTools(t, &chatToolServer{version: "test"}) // no fetcher: fetch panics
	failed := session.call(1, "fetch", map[string]string{"url": "https://example.com/"})
	if failed["isError"] != true || resultText(t, failed) != "The tool failed; try again." {
		t.Fatalf("a panicking call: %v", failed)
	}
	session.send(`{"jsonrpc":"2.0","id":2,"method":"ping"}`)
	if pong := session.read(); pong["id"] != float64(2) {
		t.Fatalf("after a panic: %v", pong)
	}
}
