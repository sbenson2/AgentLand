package host

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http/httptest"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// TestCodexFakeProcess is not a test of its own. The Codex tests run the
// test binary as a fake codex (AGENTLAND_CODEX_FAKE=1): "app-server" speaks
// the app-server's JSON-RPC and "exec" prints codex exec events, following
// scripts keyed on words in the prompt. It appends everything it receives to
// AGENTLAND_CODEX_FAKE_STATE/log.jsonl for the tests to check.
func TestCodexFakeProcess(t *testing.T) {
	if os.Getenv("AGENTLAND_CODEX_FAKE") != "1" {
		return
	}
	args := flag.Args()
	state := os.Getenv("AGENTLAND_CODEX_FAKE_STATE")
	code := 2
	switch {
	case len(args) > 0 && args[0] == "app-server":
		code = fakeAppServer(state)
	case len(args) > 0 && args[0] == "exec":
		code = fakeExec(state, args)
	}
	os.Exit(code)
}

// fakeLog appends one JSON line to the fake's log.
func fakeLog(state string, entry any) {
	file, err := os.OpenFile(filepath.Join(state, "log.jsonl"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	defer file.Close()
	data, _ := json.Marshal(entry)
	file.Write(append(data, '\n'))
}

// fakeCounter returns the next value of a counter kept in the state
// directory, so IDs stay unique across restarts.
func fakeCounter(state, name string) int {
	path := filepath.Join(state, "counter-"+name)
	data, _ := os.ReadFile(path)
	value, _ := strconv.Atoi(strings.TrimSpace(string(data)))
	value++
	os.WriteFile(path, []byte(strconv.Itoa(value)), 0o600)
	return value
}

type fakeServer struct {
	state   string
	writeMu sync.Mutex
	mu      sync.Mutex
	loaded  map[string]bool
	waiting map[string]chan json.RawMessage // server request ID → reply
	stop    map[string]chan struct{}        // turn ID → interrupt
	nextReq int
}

func (s *fakeServer) send(message any) {
	data, _ := json.Marshal(message)
	s.writeMu.Lock()
	os.Stdout.Write(append(data, '\n'))
	s.writeMu.Unlock()
}

func (s *fakeServer) notify(method string, params any) {
	s.send(map[string]any{"method": method, "params": params, "emittedAtMs": time.Now().UnixMilli()})
}

// ask sends a request to the host and waits for its answer. The first
// request of a process has ID 0, as in Codex.
func (s *fakeServer) ask(method string, params any, stop chan struct{}) (json.RawMessage, bool) {
	s.mu.Lock()
	id := s.nextReq
	s.nextReq++
	reply := make(chan json.RawMessage, 1)
	s.waiting[strconv.Itoa(id)] = reply
	s.mu.Unlock()
	s.send(map[string]any{"id": id, "method": method, "params": params})
	select {
	case answer := <-reply:
		if thread, ok := params.(map[string]any)["threadId"]; ok {
			s.notify("serverRequest/resolved", map[string]any{"threadId": thread, "requestId": id})
		}
		return answer, true
	case <-stop:
		return nil, false
	case <-time.After(20 * time.Second):
		return nil, false
	}
}

func knownThreads(state string) map[string]bool {
	data, _ := os.ReadFile(filepath.Join(state, "threads.json"))
	threads := map[string]bool{}
	json.Unmarshal(data, &threads)
	return threads
}

func rememberThread(state, id string) {
	threads := knownThreads(state)
	threads[id] = true
	data, _ := json.Marshal(threads)
	os.WriteFile(filepath.Join(state, "threads.json"), data, 0o600)
}

func fakeAppServer(state string) int {
	fakeLog(state, map[string]any{"start": os.Getpid(), "at": time.Now().UnixMilli(), "args": flag.Args(), "cwd": fakeCwd()})
	// A stubborn app-server outlives its input's end and ignores SIGTERM.
	stubborn := os.Getenv("AGENTLAND_CODEX_FAKE_STUBBORN") == "1"
	if stubborn {
		signal.Ignore(syscall.SIGTERM)
	}
	if os.Getenv("AGENTLAND_CODEX_FAKE_FAIL_HANDSHAKE") == "1" {
		os.Stderr.WriteString("fake codex: app-server is not available\n")
		return 2
	}
	if os.Getenv("AGENTLAND_CODEX_FAKE_STDERR") == "1" {
		// More than the host keeps: it holds the last 64 KiB.
		os.Stderr.WriteString(strings.Repeat("noise\n", 40000))
	}
	version := os.Getenv("AGENTLAND_CODEX_FAKE_VERSION")
	if version == "" {
		version = "0.156.1"
	}
	missing := map[string]bool{}
	for _, method := range strings.Split(os.Getenv("AGENTLAND_CODEX_FAKE_MISSING"), ",") {
		missing[method] = method != ""
	}
	server := &fakeServer{state: state, loaded: map[string]bool{}, waiting: map[string]chan json.RawMessage{}, stop: map[string]chan struct{}{}}
	reader := bufio.NewReaderSize(os.Stdin, 1<<20)
	for {
		line, err := reader.ReadBytes('\n')
		if len(strings.TrimSpace(string(line))) > 0 {
			var message struct {
				ID     json.RawMessage `json:"id"`
				Method string          `json:"method"`
				Params json.RawMessage `json:"params"`
				Result json.RawMessage `json:"result"`
				Error  json.RawMessage `json:"error"`
			}
			if json.Unmarshal(line, &message) == nil {
				fakeLog(state, json.RawMessage(strings.TrimSpace(string(line))))
				switch {
				case message.Method != "" && len(message.ID) > 0:
					if missing[message.Method] {
						server.send(map[string]any{"id": message.ID, "error": map[string]any{"code": -32600, "message": "Invalid request: unknown variant `" + message.Method + "`, expected one of `initialize`"}})
					} else {
						server.handle(message.ID, message.Method, message.Params, version)
					}
				case message.Method == "" && len(message.ID) > 0:
					server.mu.Lock()
					reply := server.waiting[string(message.ID)]
					delete(server.waiting, string(message.ID))
					server.mu.Unlock()
					if reply != nil {
						answer := message.Result
						if len(message.Error) > 0 {
							answer = json.RawMessage(`{"error":` + string(message.Error) + `}`)
						}
						reply <- answer
					}
				}
			}
		}
		if err != nil {
			if stubborn {
				// Sleeps, where select {} would end the process: Go takes a
				// process with every goroutine blocked for a deadlock.
				for {
					time.Sleep(time.Hour)
				}
			}
			return 0
		}
	}
}

func fakeCwd() string {
	cwd, _ := os.Getwd()
	return cwd
}

func fakeThread(id string) map[string]any {
	return map[string]any{"id": id, "turns": []any{}, "status": map[string]any{"type": "idle"}, "historyMode": "paginated", "cliVersion": "0.156.1", "createdAt": 1, "updatedAt": 1, "cwd": "/", "ephemeral": false, "modelProvider": "fake", "preview": "", "projectId": nil, "sessionId": id, "source": "vscode"}
}

func (s *fakeServer) handle(id json.RawMessage, method string, params json.RawMessage, version string) {
	var p struct {
		ThreadID string `json:"threadId"`
		TurnID   string `json:"turnId"`
		Input    []struct {
			Type string `json:"type"`
			Text string `json:"text"`
			Path string `json:"path"`
		} `json:"input"`
		ClientUserMessageID string `json:"clientUserMessageId"`
		LastTurnID          string `json:"lastTurnId"`
	}
	json.Unmarshal(params, &p)
	respond := func(result any) { s.send(map[string]any{"id": id, "result": result}) }
	fail := func(message string) {
		s.send(map[string]any{"id": id, "error": map[string]any{"code": -32600, "message": message}})
	}
	switch method {
	case "initialize":
		respond(map[string]any{"userAgent": "agentland_host/" + version + " (Fake OS; arm64) test (agentland_host; 0.1.0)", "codexHome": "/fake", "platformFamily": "unix", "platformOs": "macos"})
	case "thread/start":
		thread := fmt.Sprintf("thread-%d", fakeCounter(s.state, "thread"))
		rememberThread(s.state, thread)
		s.mu.Lock()
		s.loaded[thread] = true
		s.mu.Unlock()
		respond(map[string]any{"thread": fakeThread(thread), "model": "fake", "modelProvider": "fake", "cwd": "/", "approvalPolicy": "on-request", "approvalsReviewer": "user", "sandbox": map[string]any{"type": "workspaceWrite"}})
	case "thread/resume":
		if !knownThreads(s.state)[p.ThreadID] {
			fail("no rollout found for thread id " + p.ThreadID)
			return
		}
		s.mu.Lock()
		s.loaded[p.ThreadID] = true
		s.mu.Unlock()
		respond(map[string]any{"thread": fakeThread(p.ThreadID), "model": "fake", "modelProvider": "fake", "cwd": "/", "approvalPolicy": "on-request", "approvalsReviewer": "user", "sandbox": map[string]any{"type": "workspaceWrite"}})
	case "thread/fork":
		thread := fmt.Sprintf("thread-%d", fakeCounter(s.state, "thread"))
		rememberThread(s.state, thread)
		s.mu.Lock()
		s.loaded[thread] = true
		s.mu.Unlock()
		forked := fakeThread(thread)
		forked["forkedFromId"] = p.ThreadID
		respond(map[string]any{"thread": forked, "model": "fake", "modelProvider": "fake", "cwd": "/", "approvalPolicy": "on-request", "approvalsReviewer": "user", "sandbox": map[string]any{"type": "workspaceWrite"}})
	case "thread/revert":
		respond(map[string]any{"thread": fakeThread(p.ThreadID)})
	case "thread/unsubscribe":
		s.mu.Lock()
		delete(s.loaded, p.ThreadID)
		s.mu.Unlock()
		respond(map[string]any{"status": "unsubscribed"})
	case "config/read":
		// General chats read the effective config before their profile.
		respond(map[string]any{"config": map[string]any{}})
	case "model/list":
		efforts := []any{map[string]any{"reasoningEffort": "low", "description": "Fast"}, map[string]any{"reasoningEffort": "medium", "description": "Balanced"}, map[string]any{"reasoningEffort": "high", "description": "Deep"}}
		respond(map[string]any{"data": []any{
			map[string]any{"id": "fake-large", "model": "fake-large", "displayName": "Fake Large", "description": "", "hidden": false, "isDefault": true, "defaultReasoningEffort": "medium", "supportedReasoningEfforts": efforts},
			map[string]any{"id": "fake-hidden", "model": "fake-hidden", "displayName": "Hidden", "description": "", "hidden": true, "isDefault": false, "defaultReasoningEffort": "low", "supportedReasoningEfforts": efforts},
		}, "nextCursor": nil})
	case "turn/start":
		s.mu.Lock()
		loaded := s.loaded[p.ThreadID]
		s.mu.Unlock()
		if !loaded {
			fail("thread not found: " + p.ThreadID)
			return
		}
		text := ""
		for _, input := range p.Input {
			if input.Type == "text" {
				text = input.Text
			}
		}
		if strings.Contains(text, "CRASHSTART") {
			os.Exit(3)
		}
		turn := fmt.Sprintf("turn-%d", fakeCounter(s.state, "turn"))
		stop := make(chan struct{})
		s.mu.Lock()
		s.stop[turn] = stop
		s.mu.Unlock()
		respond(map[string]any{"turn": map[string]any{"id": turn, "items": []any{}, "itemsView": "notLoaded", "status": "inProgress"}})
		go s.runTurn(p.ThreadID, turn, text, p.ClientUserMessageID, stop)
	case "turn/interrupt":
		s.mu.Lock()
		stop := s.stop[p.TurnID]
		delete(s.stop, p.TurnID)
		s.mu.Unlock()
		if stop == nil {
			fail("no active turn to interrupt")
			return
		}
		close(stop)
		respond(map[string]any{})
	default:
		s.send(map[string]any{"id": id, "error": map[string]any{"code": -32600, "message": "Invalid request: unknown variant `" + method + "`, expected one of `initialize`"}})
	}
}

// runTurn plays the script chosen by the prompt's words.
func (s *fakeServer) runTurn(thread, turn, text, clientID string, stop chan struct{}) {
	base := func() map[string]any { return map[string]any{"threadId": thread, "turnId": turn} }
	with := func(values map[string]any) map[string]any {
		params := base()
		for key, value := range values {
			params[key] = value
		}
		return params
	}
	now := time.Now().UnixMilli()
	item := func(kind string, item map[string]any) {
		s.notify("item/"+kind, with(map[string]any{"item": item, "startedAtMs": now, "completedAtMs": now}))
	}
	message := func(id, text string, deltas ...string) {
		item("started", map[string]any{"type": "agentMessage", "id": id, "text": ""})
		for _, delta := range deltas {
			s.notify("item/agentMessage/delta", with(map[string]any{"itemId": id, "delta": delta}))
		}
		item("completed", map[string]any{"type": "agentMessage", "id": id, "text": text})
	}
	finish := func(status string, failure any) {
		s.mu.Lock()
		delete(s.stop, turn)
		s.mu.Unlock()
		s.notify("thread/status/changed", map[string]any{"threadId": thread, "status": map[string]any{"type": "idle"}})
		s.notify("turn/completed", map[string]any{"threadId": thread, "turn": map[string]any{"id": turn, "items": []any{}, "itemsView": "summary", "status": status, "error": failure}})
	}
	s.notify("thread/status/changed", map[string]any{"threadId": thread, "status": map[string]any{"type": "active", "activeFlags": []any{}}})
	s.notify("turn/started", map[string]any{"threadId": thread, "turn": map[string]any{"id": turn, "items": []any{}, "status": "inProgress"}})
	user := map[string]any{"type": "userMessage", "id": "user-" + turn, "clientId": clientID, "content": []any{map[string]any{"type": "text", "text": text}}}
	item("started", user)
	item("completed", user)
	usage := func(total int) {
		breakdown := func(n int) map[string]any {
			return map[string]any{"totalTokens": n * 150, "inputTokens": n * 120, "cachedInputTokens": n * 20, "cacheWriteInputTokens": 0, "outputTokens": n * 30, "reasoningOutputTokens": n * 5}
		}
		s.notify("thread/tokenUsage/updated", with(map[string]any{"tokenUsage": map[string]any{"total": breakdown(total), "last": breakdown(1)}}))
	}
	switch {
	case strings.Contains(text, "BIG"):
		// One line longer than the host reads, then an ordinary reply.
		s.writeMu.Lock()
		os.Stdout.Write([]byte(`{"method":"item/agentMessage/delta","params":{"threadId":"` + thread + `","turnId":"` + turn + `","itemId":"nowhere","delta":"` + strings.Repeat("x", 9<<20) + "\"}}\n"))
		s.writeMu.Unlock()
		message("msg-"+turn, "After the big line.", "After ", "the big line.")
		finish("completed", nil)
	case strings.Contains(text, "APPROVE"):
		command := map[string]any{"type": "commandExecution", "id": "cmd-" + turn, "command": "/bin/zsh -lc 'touch x'", "cwd": "/", "status": "inProgress", "commandActions": []any{map[string]any{"type": "unknown", "command": "touch x"}}, "aggregatedOutput": nil}
		item("started", command)
		decisions := json.RawMessage(os.Getenv("AGENTLAND_CODEX_FAKE_DECISIONS"))
		if len(decisions) == 0 {
			decisions = json.RawMessage(`["accept","acceptForSession",{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["touch","x"]}},"decline","cancel"]`)
		}
		answer, ok := s.ask("item/commandExecution/requestApproval", with(map[string]any{"itemId": "cmd-" + turn, "startedAtMs": now, "reason": "Needs to write", "command": "/bin/zsh -lc 'touch x'", "cwd": "/", "commandActions": []any{map[string]any{"type": "unknown", "command": "touch x"}}, "availableDecisions": decisions}), stop)
		if !ok {
			finish("interrupted", nil)
			return
		}
		fakeLog(s.state, map[string]any{"decision": answer})
		var reply struct {
			Decision json.RawMessage `json:"decision"`
		}
		json.Unmarshal(answer, &reply)
		if strings.Contains(string(reply.Decision), "accept") {
			s.notify("item/commandExecution/outputDelta", with(map[string]any{"itemId": "cmd-" + turn, "delta": "done\n"}))
			command["status"], command["aggregatedOutput"], command["exitCode"] = "completed", "done\n", 0
		} else {
			command["status"] = "declined"
		}
		item("completed", command)
		message("msg-"+turn, "Finished.", "Finished.")
		usage(1)
		finish("completed", nil)
	case strings.Contains(text, "FILES"):
		change := map[string]any{"type": "fileChange", "id": "patch-" + turn, "status": "inProgress", "changes": []any{map[string]any{"path": "notes/a.txt", "kind": map[string]any{"type": "add"}, "diff": "+hello\n"}}}
		item("started", change)
		answer, ok := s.ask("item/fileChange/requestApproval", with(map[string]any{"itemId": "patch-" + turn, "startedAtMs": now, "reason": "Write notes"}), stop)
		if !ok {
			finish("interrupted", nil)
			return
		}
		fakeLog(s.state, map[string]any{"decision": answer})
		s.notify("item/fileChange/patchUpdated", with(map[string]any{"itemId": "patch-" + turn, "changes": []any{map[string]any{"path": "notes/a.txt", "kind": map[string]any{"type": "add"}, "diff": "+hello\n+world\n"}}}))
		change["status"] = "completed"
		change["changes"] = []any{map[string]any{"path": "notes/a.txt", "kind": map[string]any{"type": "add"}, "diff": "+hello\n+world\n"}}
		item("completed", change)
		finish("completed", nil)
	case strings.Contains(text, "PERMS"):
		answer, ok := s.ask("item/permissions/requestApproval", with(map[string]any{"itemId": "perm-" + turn, "startedAtMs": now, "cwd": "/", "reason": "Needs the network", "permissions": map[string]any{"network": map[string]any{"enabled": true}}}), stop)
		if !ok {
			finish("interrupted", nil)
			return
		}
		fakeLog(s.state, map[string]any{"permissions": answer})
		finish("completed", nil)
	case strings.Contains(text, "ASK"):
		questions := []any{
			map[string]any{"id": "token", "header": "Token", "question": "Paste the token", "isSecret": true, "isOther": true, "options": nil},
			map[string]any{"id": "color", "header": "Color", "question": "Pick one", "isOther": true, "options": []any{map[string]any{"label": "Red", "description": "Warm"}, map[string]any{"label": "Blue", "description": "Cool"}}},
		}
		answer, ok := s.ask("item/tool/requestUserInput", with(map[string]any{"itemId": "ask-" + turn, "isBlocking": true, "questions": questions}), stop)
		if !ok {
			finish("interrupted", nil)
			return
		}
		fakeLog(s.state, map[string]any{"answers": answer})
		message("msg-"+turn, "Thanks.", "Thanks.")
		finish("completed", nil)
	case strings.Contains(text, "ELICIT"):
		answer, _ := s.ask("mcpServer/elicitation/request", with(map[string]any{"serverName": "docs", "message": "Sign in"}), stop)
		fakeLog(s.state, map[string]any{"elicitation": answer})
		answer, _ = s.ask("agentland/unknownRequest", with(nil), stop)
		fakeLog(s.state, map[string]any{"unknown": answer})
		message("msg-"+turn, "Carried on.", "Carried on.")
		finish("completed", nil)
	case strings.Contains(text, "STALL"):
		item("started", map[string]any{"type": "agentMessage", "id": "msg-" + turn, "text": ""})
		s.notify("item/agentMessage/delta", with(map[string]any{"itemId": "msg-" + turn, "delta": "Working"}))
		select {
		case <-stop:
			finish("interrupted", nil)
		case <-time.After(20 * time.Second):
			finish("completed", nil)
		}
	case strings.Contains(text, "FAIL"):
		s.notify("error", with(map[string]any{"error": map[string]any{"message": "Reconnecting 1/3"}, "willRetry": true}))
		s.notify("error", with(map[string]any{"error": map[string]any{"message": "fake provider refused", "codexErrorInfo": "unauthorized"}, "willRetry": false}))
		finish("failed", map[string]any{"message": "fake provider refused", "codexErrorInfo": "unauthorized"})
	case strings.Contains(text, "CRASH"):
		item("started", map[string]any{"type": "agentMessage", "id": "msg-" + turn, "text": ""})
		s.notify("item/agentMessage/delta", with(map[string]any{"itemId": "msg-" + turn, "delta": "Partial"}))
		time.Sleep(50 * time.Millisecond)
		os.Exit(3)
	case strings.Contains(text, "MANY"):
		for n := 0; n < 300; n++ {
			command := map[string]any{"type": "commandExecution", "id": fmt.Sprintf("cmd-%s-%d", turn, n), "command": "true", "cwd": "/", "status": "completed", "commandActions": []any{}, "aggregatedOutput": "", "exitCode": 0}
			item("completed", command)
		}
		message("msg-"+turn, "Many done.", "Many done.")
		finish("completed", nil)
	case strings.Contains(text, "TOOLS"):
		item("started", map[string]any{"type": "mcpToolCall", "id": "mcp-" + turn, "server": "docs", "tool": "search", "arguments": map[string]any{"q": "go"}, "status": "inProgress"})
		item("completed", map[string]any{"type": "mcpToolCall", "id": "mcp-" + turn, "server": "docs", "tool": "search", "arguments": map[string]any{"q": "go"}, "status": "completed", "result": map[string]any{"content": []any{map[string]any{"type": "text", "text": "found it"}}}})
		item("started", map[string]any{"type": "webSearch", "id": "web-" + turn, "query": "agentland"})
		item("completed", map[string]any{"type": "webSearch", "id": "web-" + turn, "query": "agentland", "action": map[string]any{"type": "search", "query": "agentland"}})
		s.notify("turn/plan/updated", with(map[string]any{"explanation": "Steps", "plan": []any{map[string]any{"step": "Read", "status": "completed"}, map[string]any{"step": "Write", "status": "inProgress"}}}))
		item("completed", map[string]any{"type": "contextCompaction", "id": "compact-" + turn})
		s.notify("warning", map[string]any{"threadId": thread, "message": "Model metadata not found"})
		s.notify("item/autoApprovalReview/completed", with(map[string]any{"review": map[string]any{"status": "denied", "rationale": "Too risky"}, "action": map[string]any{"type": "command", "command": "rm -rf /tmp/x"}}))
		s.notify("some/newNotification", with(nil))
		item("completed", map[string]any{"type": "someNewItem", "id": "new-" + turn})
		message("msg-"+turn, "Tools done.", "Tools done.")
		finish("completed", nil)
	case strings.Contains(text, "OUT"):
		command := map[string]any{"type": "commandExecution", "id": "cmd-" + turn, "command": "yes", "cwd": "/", "status": "inProgress", "commandActions": []any{}, "aggregatedOutput": nil}
		item("started", command)
		chunk := strings.Repeat("y\n", 16<<10)
		for n := 0; n < 3; n++ {
			s.notify("item/commandExecution/outputDelta", with(map[string]any{"itemId": "cmd-" + turn, "delta": chunk}))
		}
		command["status"], command["exitCode"] = "failed", 1
		item("completed", command)
		finish("completed", nil)
	default:
		reasoning := map[string]any{"type": "reasoning", "id": "rs-" + turn, "summary": []any{}, "content": []any{}}
		item("started", reasoning)
		s.notify("item/reasoning/summaryPartAdded", with(map[string]any{"itemId": "rs-" + turn, "summaryIndex": 0}))
		s.notify("item/reasoning/summaryTextDelta", with(map[string]any{"itemId": "rs-" + turn, "summaryIndex": 0, "delta": "Thinking "}))
		s.notify("item/reasoning/summaryTextDelta", with(map[string]any{"itemId": "rs-" + turn, "summaryIndex": 0, "delta": "it over."}))
		reasoning["summary"] = []any{"Thinking it over."}
		item("completed", reasoning)
		message("msg-"+turn, "Hello from the fake Codex.", "Hello ", "from the ", "fake Codex.")
		usage(1)
		finish("completed", nil)
	}
}

// fakeExec plays codex exec: it records its arguments, directory and stdin
// and prints JSONL events.
func fakeExec(state string, args []string) int {
	input, _ := io.ReadAll(os.Stdin)
	fakeLog(state, map[string]any{"exec": args, "cwd": fakeCwd(), "stdin": string(input)})
	thread := "exec-thread-1"
	for index, arg := range args {
		if arg == "resume" && index+2 < len(args) {
			thread = args[len(args)-2]
		}
	}
	out := bufio.NewWriter(os.Stdout)
	emit := func(event any) {
		data, _ := json.Marshal(event)
		out.Write(append(data, '\n'))
		out.Flush()
	}
	prompt := string(input)
	emit(map[string]any{"type": "thread.started", "thread_id": thread})
	emit(map[string]any{"type": "turn.started"})
	emit(map[string]any{"type": "item.completed", "item": map[string]any{"id": "item_0", "type": "error", "message": "Model metadata for `fake` not found."}})
	emit(map[string]any{"type": "item.completed", "item": map[string]any{"id": "item_1", "type": "reasoning", "text": "Thinking."}})
	if strings.Contains(prompt, "EXECSTALL") {
		time.Sleep(20 * time.Second)
	}
	if strings.Contains(prompt, "EXECSTUBBORN") {
		// A run that records SIGTERM and keeps going, with a tool in its
		// process group that ignores SIGTERM and holds its output: only
		// SIGKILL to the group ends them.
		terms := make(chan os.Signal, 4)
		signal.Notify(terms, syscall.SIGTERM)
		go func() {
			for range terms {
				fakeLog(state, map[string]any{"term": os.Getpid()})
			}
		}()
		self, _ := os.Executable()
		tool := exec.Command(self)
		tool.Env = append(os.Environ(), "AGENTLAND_FAKE_AGENT=acp-child", "AGENTLAND_FAKE_CHILD_PID="+filepath.Join(state, "exec-tool.pid"))
		tool.Stdout = os.Stdout
		if tool.Start() != nil {
			return 7
		}
		fakeLog(state, map[string]any{"execPid": os.Getpid()})
		for {
			time.Sleep(time.Hour)
		}
	}
	if strings.Contains(prompt, "EXECFAIL") {
		emit(map[string]any{"type": "error", "message": "fake provider refused"})
		emit(map[string]any{"type": "turn.failed", "error": map[string]any{"message": "fake provider refused"}})
		return 1
	}
	emit(map[string]any{"type": "item.started", "item": map[string]any{"id": "item_2", "type": "command_execution", "command": "/bin/zsh -lc 'echo hi'", "aggregated_output": "", "exit_code": nil, "status": "in_progress"}})
	emit(map[string]any{"type": "item.completed", "item": map[string]any{"id": "item_2", "type": "command_execution", "command": "/bin/zsh -lc 'echo hi'", "aggregated_output": "hi\n", "exit_code": 0, "status": "completed"}})
	emit(map[string]any{"type": "item.completed", "item": map[string]any{"id": "item_3", "type": "file_change", "changes": []any{map[string]any{"path": "b.txt", "kind": "update"}}, "status": "completed"}})
	if strings.Contains(prompt, "HUGE") {
		// A 5 MiB line (over the old 4 MiB cap) and one past the line limit.
		emit(map[string]any{"type": "item.completed", "item": map[string]any{"id": "item_4", "type": "agent_message", "text": strings.Repeat("z", 5<<20)}})
		out.Write([]byte(`{"type":"item.completed","item":{"id":"item_5","type":"agent_message","text":"` + strings.Repeat("q", 9<<20) + "\"}}\n"))
		out.Flush()
	}
	emit(map[string]any{"type": "item.completed", "item": map[string]any{"id": "item_6", "type": "agent_message", "text": "Exec reply: " + strings.TrimSpace(prompt)}})
	emit(map[string]any{"type": "turn.completed", "usage": map[string]any{"input_tokens": 300, "cached_input_tokens": 100, "cache_write_input_tokens": 0, "output_tokens": 50, "reasoning_output_tokens": 10}})
	return 0
}

// codexFake points an engine at the fake codex.
type codexFake struct {
	t     *testing.T
	state string
	env   []string

	mu   sync.Mutex
	logs []string // the engine's diagnostics
}

func (f *codexFake) diagnostics() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.logs...)
}

func newCodexFake(t *testing.T, env ...string) *codexFake {
	t.Helper()
	return &codexFake{t: t, state: t.TempDir(), env: env}
}

func (f *codexFake) config() codexEngineConfig {
	self, err := os.Executable()
	if err != nil {
		f.t.Fatal(err)
	}
	env := append([]string{"AGENTLAND_CODEX_FAKE=1", "AGENTLAND_CODEX_FAKE_STATE=" + f.state}, f.env...)
	return codexEngineConfig{
		executable:  func() (string, bool) { return self, true },
		prefixArgs:  []string{"-test.run=^TestCodexFakeProcess$", "--"},
		env:         env,
		dir:         f.state,
		backoff:     []time.Duration{50 * time.Millisecond, 100 * time.Millisecond, 200 * time.Millisecond},
		idleCheck:   20 * time.Millisecond,
		callTimeout: 10 * time.Second,
		fallbackFor: time.Hour,
		log: func(message string) {
			f.mu.Lock()
			f.logs = append(f.logs, message)
			f.mu.Unlock()
		},
	}
}

// fakeEntry is one line of the fake's log.
type fakeEntry struct {
	raw         string
	ID          json.RawMessage `json:"id"`
	Method      string          `json:"method"`
	Params      json.RawMessage `json:"params"`
	Result      json.RawMessage `json:"result"`
	Error       json.RawMessage `json:"error"`
	Start       int             `json:"start"`
	At          int64           `json:"at"`
	Decision    json.RawMessage `json:"decision"`
	Permissions json.RawMessage `json:"permissions"`
	Answers     json.RawMessage `json:"answers"`
	Elicitation json.RawMessage `json:"elicitation"`
	Unknown     json.RawMessage `json:"unknown"`
	Exec        []string        `json:"exec"`
	Cwd         string          `json:"cwd"`
	Stdin       string          `json:"stdin"`
	// A stubborn exec run's pid, and each SIGTERM it got (its pid).
	ExecPid int `json:"execPid"`
	Term    int `json:"term"`
}

func (f *codexFake) log() []fakeEntry {
	data, err := os.ReadFile(filepath.Join(f.state, "log.jsonl"))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		f.t.Fatal(err)
	}
	entries := []fakeEntry{}
	for _, line := range strings.Split(string(data), "\n") {
		if line == "" {
			continue
		}
		var entry fakeEntry
		if json.Unmarshal([]byte(line), &entry) == nil {
			entry.raw = line
			entries = append(entries, entry)
		}
	}
	return entries
}

// requests returns the host's requests with the given method, in order.
func (f *codexFake) requests(method string) []fakeEntry {
	result := []fakeEntry{}
	for _, entry := range f.log() {
		if entry.Method == method && len(entry.ID) > 0 {
			result = append(result, entry)
		}
	}
	return result
}

func (f *codexFake) starts() int {
	count := 0
	for _, entry := range f.log() {
		if entry.Start != 0 {
			count++
		}
	}
	return count
}

// codexTestRunner runs Codex chats through the engine with a test config.
type codexTestRunner struct{ config codexEngineConfig }

func (r codexTestRunner) Available() []string { return []string{"claude", "codex"} }
func (r codexTestRunner) Run(context.Context, string, string, string, string, []ChatAttachment) (CLIChatResult, error) {
	return CLIChatResult{}, errors.New("codex chats run through the engine")
}
func (r codexTestRunner) codexEngineConfig() codexEngineConfig { return r.config }

// codexFixture is a host whose Codex chats run against a fake codex.
type codexFixture struct {
	t       *testing.T
	fake    *codexFake
	host    *Host
	store   *Store
	chats   *CLIChats
	token   string
	server  *httptest.Server
	project Project
}

func newCodexFixture(t *testing.T, fake *codexFake) *codexFixture {
	return newCodexFixtureWith(t, fake, fake.config())
}

func newCodexFixtureWith(t *testing.T, fake *codexFake, config codexEngineConfig) *codexFixture {
	t.Helper()
	directory := t.TempDir()
	oc := newFakeOpenCode(t, directory)
	store := NewStore(filepath.Join(t.TempDir(), "private-state", "host.json"))
	if err := store.Initialize(Config{OpenCodeURL: oc.server.URL, PasswordEnv: "FIXTURE_PASSWORD", Projects: []Project{{ID: "p1", Name: "Codex", Directory: directory}}}); err != nil {
		t.Fatal(err)
	}
	chats, err := NewCLIChats(store.Path+".chats.json", codexTestRunner{config: config})
	if err != nil {
		t.Fatal(err)
	}
	host := newHost(store, NewOpenCodeAdapter(oc.server.URL, "opencode", "fixture", oc.server.Client()), HostOptions{CLIChats: chats})
	host.chatPace = time.Millisecond
	host.chatBeatEvery = time.Hour
	host.chatAuthEvery = time.Hour
	server := httptest.NewServer(host.Handler())
	f := &codexFixture{t: t, fake: fake, host: host, store: store, chats: chats, server: server, project: mustProject(t, store)}
	t.Cleanup(func() {
		server.Close()
		host.Close()
	})
	f.token = paired(t, host, store)
	return f
}

func (f *codexFixture) call(method, path string, body any) *httptest.ResponseRecorder {
	f.t.Helper()
	return request(f.t, f.host.Handler(), method, path, f.token, body)
}

func (f *codexFixture) newChat() string {
	f.t.Helper()
	w := f.call("POST", "/v1/sessions", map[string]string{"projectId": "p1", "title": "Codex", "provider": "codex"})
	if w.Code != 201 {
		f.t.Fatalf("create: %d %s", w.Code, w.Body)
	}
	var session Session
	json.Unmarshal(w.Body.Bytes(), &session)
	return session.ID
}

func (f *codexFixture) send(id, text string, extra map[string]any) sendReceipt {
	f.t.Helper()
	body := map[string]any{"projectId": "p1", "sessionId": id, "text": text}
	for key, value := range extra {
		body[key] = value
	}
	w := f.call("POST", "/v1/messages", body)
	if w.Code != 202 {
		f.t.Fatalf("send %q: %d %s", text, w.Code, w.Body)
	}
	var receipt sendReceipt
	json.Unmarshal(w.Body.Bytes(), &receipt)
	return receipt
}

// idle waits until the chat has no running turn.
func (f *codexFixture) idle(id string) {
	f.t.Helper()
	waitFor(f.t, "the Codex turn to end", func() bool {
		status, err := f.chats.Status(f.project, id)
		return err == nil && status.State == "idle"
	})
}

func (f *codexFixture) messages(id string) []Message {
	f.t.Helper()
	w := f.call("GET", "/v1/messages?projectId=p1&sessionId="+id, nil)
	if w.Code != 200 {
		f.t.Fatalf("messages: %d %s", w.Code, w.Body)
	}
	var body struct {
		Messages []Message `json:"messages"`
	}
	json.Unmarshal(w.Body.Bytes(), &body)
	return body.Messages
}

func (f *codexFixture) stream(id string) *streamReader {
	f.t.Helper()
	reader, code, body := openStream(f.t, f.server, f.token, "projectId=p1&sessionId="+id)
	if code != 200 {
		f.t.Fatalf("stream: %d %s", code, body)
	}
	return reader
}
