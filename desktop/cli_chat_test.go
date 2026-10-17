package host

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakeCLIChatCall struct {
	Provider, Directory, NativeID, Prompt string
	Attachments                           []ChatAttachment
	// Readable records whether every attachment file existed during the run.
	Readable bool
}

type fakeCLIChatRunner struct {
	mu    sync.Mutex
	calls []fakeCLIChatCall
	// release, when set, holds each run open until the test closes it.
	release chan struct{}
}

func (r *fakeCLIChatRunner) Available() []string { return []string{"claude", "codex"} }
func (r *fakeCLIChatRunner) Run(ctx context.Context, provider, directory, nativeID, prompt string, attachments []ChatAttachment) (CLIChatResult, error) {
	readable := true
	for _, attachment := range attachments {
		if _, err := os.Stat(attachment.Path); err != nil {
			readable = false
		}
	}
	r.mu.Lock()
	r.calls = append(r.calls, fakeCLIChatCall{provider, directory, nativeID, prompt, attachments, readable})
	release := r.release
	r.mu.Unlock()
	if release != nil {
		select {
		case <-release:
		case <-ctx.Done():
			return CLIChatResult{}, ctx.Err()
		}
	}
	if nativeID == "" {
		nativeID = "native-" + provider
	}
	return CLIChatResult{NativeID: nativeID, Text: "Reply to " + prompt}, nil
}

func TestCLIChatUsesHostSignInAndResumesSelectedProvider(t *testing.T) {
	_, store, opencode := testHost(t)
	runner := &fakeCLIChatRunner{}
	path := filepath.Join(t.TempDir(), "cli-chats.json")
	chats, err := NewCLIChats(path, runner)
	if err != nil {
		t.Fatal(err)
	}
	h := NewWithOptions(store, opencode, HostOptions{CLIChats: chats})
	token := paired(t, h, store)
	created := request(t, h.Handler(), "POST", "/v1/sessions", token, map[string]string{"projectId": "p1", "title": "Claude task", "provider": "claude"})
	if created.Code != 201 {
		t.Fatalf("create: %d %s", created.Code, created.Body)
	}
	var session Session
	if err := json.Unmarshal(created.Body.Bytes(), &session); err != nil {
		t.Fatal(err)
	}
	if session.Provider != "claude" || !strings.HasPrefix(session.ID, "claude:") {
		t.Fatal(created.Body.String())
	}
	options := request(t, h.Handler(), "GET", "/v1/chat/options?projectId=p1&sessionId="+session.ID, token, nil)
	if options.Code != 200 || !strings.Contains(options.Body.String(), `"provider":"Claude Code"`) {
		t.Fatalf("options: %d %s", options.Code, options.Body)
	}
	for _, prompt := range []string{"first", "second"} {
		sent := request(t, h.Handler(), "POST", "/v1/messages", token, map[string]string{"projectId": "p1", "sessionId": session.ID, "text": prompt})
		if sent.Code != 202 {
			t.Fatalf("send: %d %s", sent.Code, sent.Body)
		}
		deadline := time.Now().Add(2 * time.Second)
		for {
			messages := request(t, h.Handler(), "GET", "/v1/messages?projectId=p1&sessionId="+session.ID, token, nil)
			if strings.Contains(messages.Body.String(), "Reply to "+prompt) {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("CLI reply timed out: %s", messages.Body)
			}
			time.Sleep(10 * time.Millisecond)
		}
	}
	runner.mu.Lock()
	if len(runner.calls) != 2 || runner.calls[0].Provider != "claude" || runner.calls[1].NativeID != "native-claude" {
		t.Fatal(runner.calls)
	}
	runner.mu.Unlock()
	restored, err := NewCLIChats(path, runner)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := restored.GetSession(mustProject(t, store), session.ID); err != nil {
		t.Fatalf("session not restored: %v", err)
	}
	if messages, err := restored.Messages(mustProject(t, store), session.ID); err != nil || len(messages) != 4 {
		t.Fatalf("transcript not restored: %d %v", len(messages), err)
	}
	if got := request(t, h.Handler(), "POST", "/v1/sessions", token, map[string]string{"projectId": "p1", "title": "Bad", "provider": "unknown"}); got.Code == 201 {
		t.Fatal("unknown program accepted")
	}
	if got := request(t, h.Handler(), "GET", "/v1/messages?projectId=other&sessionId="+session.ID, token, nil); got.Code == 200 {
		t.Fatal("cross-project session accepted")
	}
}

func TestCLIChatInterruptedPromptIsRecoveredOnce(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cli-chats.json")
	project := Project{ID: "p1", Directory: t.TempDir()}
	id := "claude:interrupted"
	state := map[string]*cliChatRecord{id: {
		Session:   Session{ID: id, ProjectID: project.ID, Provider: "claude"},
		Directory: project.Directory,
		Messages:  []Message{{ID: "user-1", Role: "user", Text: "hello"}},
		Busy:      true,
	}}
	data, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	if err := writePrivateState(path, data); err != nil {
		t.Fatal(err)
	}
	recoveryID := ""
	for attempt := 0; attempt < 2; attempt++ {
		chats, err := NewCLIChats(path, &fakeCLIChatRunner{})
		if err != nil {
			t.Fatal(err)
		}
		messages, err := chats.Messages(project, id)
		if err != nil || len(messages) != 2 || messages[1].Error == "" {
			t.Fatalf("restart %d: %#v %v", attempt, messages, err)
		}
		if attempt == 0 {
			recoveryID = messages[1].ID
		} else if messages[1].ID != recoveryID {
			t.Fatal("the interrupted prompt was recovered again on the next restart")
		}
	}
}

func TestCLIChatParsesNativeCLIReplies(t *testing.T) {
	claude, err := parseCLIChatOutput("claude", "requested-id", []byte(`{"result":"Changed the file","session_id":"native-claude","is_error":false}`))
	if err != nil || claude.NativeID != "native-claude" || claude.Text != "Changed the file" {
		t.Fatalf("Claude JSON: %#v %v", claude, err)
	}
	codex, err := parseCLIChatOutput("codex", "", []byte("{\"type\":\"thread.started\",\"thread_id\":\"native-codex\"}\n{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Done\"}}\n"))
	if err != nil || codex.NativeID != "native-codex" || codex.Text != "Done" {
		t.Fatalf("Codex JSONL: %#v %v", codex, err)
	}
	if _, err := parseCLIChatOutput("claude", "", []byte(`{"result":"failed","is_error":true}`)); err == nil {
		t.Fatal("Claude error output accepted as a reply")
	}
	if _, err := parseCLIChatOutput("codex", "", []byte(`{"type":"thread.started","thread_id":"native"}`)); err == nil {
		t.Fatal("Codex output without a final reply accepted")
	}
}
