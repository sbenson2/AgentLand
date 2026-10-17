package host

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// Chat names (docs/HOST-API.md "Chat names"): free naming, POST
// /v1/chat/title, events, persistence and the archive.

func listedSession(t *testing.T, f *chatFixture, id string) Session {
	t.Helper()
	w := f.call(t, "GET", "/v1/sessions?projectId=p1", nil)
	if w.Code != 200 {
		t.Fatalf("sessions: %d %s", w.Code, w.Body)
	}
	var body struct{ Sessions []Session }
	json.Unmarshal(w.Body.Bytes(), &body)
	for _, session := range body.Sessions {
		if session.ID == id {
			return session
		}
	}
	t.Fatalf("session %s is not listed: %s", id, w.Body)
	return Session{}
}

func sameName(t *testing.T, what string, session Session, title, source, basis string) {
	t.Helper()
	if session.Title != title || session.TitleSource != source || session.TitleBasis != basis {
		t.Fatalf("%s: %q %q %q, want %q %q %q", what, session.Title, session.TitleSource, session.TitleBasis, title, source, basis)
	}
}

func sendText(t *testing.T, f *chatFixture, sessionID, text string) string {
	t.Helper()
	w := f.call(t, "POST", "/v1/messages", map[string]string{"projectId": "p1", "sessionId": sessionID, "text": text})
	if w.Code != 202 {
		t.Fatalf("send %q: %d %s", text, w.Code, w.Body)
	}
	var receipt sendReceipt
	json.Unmarshal(w.Body.Bytes(), &receipt)
	return receipt.MessageID
}

func nameChat(t *testing.T, f *chatFixture, sessionID, title, basedOn string) *httptest.ResponseRecorder {
	t.Helper()
	return f.call(t, "POST", "/v1/chat/title", map[string]string{"projectId": "p1", "sessionId": sessionID, "title": title, "basedOn": basedOn})
}

// titleEvents are the chat.updated lines of a chat's ring after seq.
func titleEvents(f *chatFixture, chat *hubChat, after uint64) []string {
	var events []string
	for _, line := range ringLines(f, chat, after) {
		if strings.Contains(line, `"type":"chat.updated"`) {
			_, body, _ := strings.Cut(line, `"type":"chat.updated"`)
			events = append(events, `{"type":"chat.updated"`+body)
		}
	}
	return events
}

func ringSeq(f *chatFixture, chat *hubChat) uint64 {
	f.host.chat.mu.Lock()
	defer f.host.chat.mu.Unlock()
	return chat.ring.last()
}

func sameEvents(t *testing.T, what string, got []string, want ...string) {
	t.Helper()
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("%s:\n%s\nwant:\n%s", what, strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

func runnerCalls(f *chatFixture) int {
	f.runner.mu.Lock()
	defer f.runner.mu.Unlock()
	return len(f.runner.calls)
}

// ocUserMessage is an OpenCode user message with the given ID, created at
// fixtureEpochMs + second*1000.
func ocUserMessage(id string, second int, text string) map[string]any {
	return map[string]any{"info": map[string]any{"id": id, "sessionID": "s1", "role": "user", "time": map[string]any{"created": fixtureEpochMs + second*1000}},
		"parts": []any{map[string]any{"id": id + "p", "sessionID": "s1", "messageID": id, "type": "text", "text": text}}}
}

func TestOpenCodeChatsGetAutoNamesUntilOpenCodeTitlesThem(t *testing.T) {
	f := newChatFixture(t)
	f.oc.set(func(o *fakeOpenCode) { o.titles["s1"] = "New chat" })
	sameName(t, "a placeholder", listedSession(t, f, "s1"), "New chat", "default", "")
	chat := hubChatFor(t, f, "s1")
	if chat.info.TitleSource != "default" {
		t.Fatalf("snapshot chat %+v", chat.info)
	}
	start := ringSeq(f, chat)

	first := sendText(t, f, "s1", "can you fix the login redirect on safari?")
	sameName(t, "after the first message", listedSession(t, f, "s1"), "Fix the login redirect on safari", "auto", first)
	sameEvents(t, "the auto name", titleEvents(f, chat, start), `{"type":"chat.updated","title":"Fix the login redirect on safari","titleSource":"auto","titleBasis":"`+first+`"}`)
	// A message that names nothing keeps the name and its basis.
	start = ringSeq(f, chat)
	sendText(t, f, "s1", "yes, keep going")
	sameName(t, "after a message without a name", listedSession(t, f, "s1"), "Fix the login redirect on safari", "auto", first)
	// The next that does names the chat after it.
	third := sendText(t, f, "s1", "ok now add a test for the redirect")
	sameName(t, "after the third message", listedSession(t, f, "s1"), "Add a test for the redirect", "auto", third)
	sameEvents(t, "the second auto name", titleEvents(f, chat, start), `{"type":"chat.updated","title":"Add a test for the redirect","titleSource":"auto","titleBasis":"`+third+`"}`)
	// OpenCode keeps its own title: auto names never reach it.
	f.oc.mu.Lock()
	renames := len(f.oc.renames)
	f.oc.mu.Unlock()
	if renames != 0 {
		t.Fatalf("an auto name was written to OpenCode %d times", renames)
	}
	// An OpenCode update that still carries a placeholder changes nothing.
	start = ringSeq(f, chat)
	feed(t, f, "session.updated", map[string]any{"sessionID": "s1", "info": map[string]any{"id": "s1", "title": "New chat", "directory": f.oc.directory}})
	feed(t, f, "session.updated", map[string]any{"sessionID": "s1", "info": map[string]any{"id": "s1", "title": "New session - 2026-09-26T10:00:00.000Z", "directory": f.oc.directory}})
	sameEvents(t, "placeholder updates", titleEvents(f, chat, start))
	// OpenCode's own title replaces the auto name.
	f.oc.set(func(o *fakeOpenCode) { o.titles["s1"] = "Safari login redirect loop" })
	feed(t, f, "session.updated", map[string]any{"sessionID": "s1", "info": map[string]any{"id": "s1", "title": "Safari login redirect loop", "directory": f.oc.directory}})
	sameEvents(t, "OpenCode's title", titleEvents(f, chat, start), `{"type":"chat.updated","title":"Safari login redirect loop","titleSource":"provider"}`)
	sameName(t, "OpenCode's title", listedSession(t, f, "s1"), "Safari login redirect loop", "provider", "")
	// Auto never replaces it.
	start = ringSeq(f, chat)
	sendText(t, f, "s1", "please also update the docs for the redirect")
	sameName(t, "after OpenCode named it", listedSession(t, f, "s1"), "Safari login redirect loop", "provider", "")
	sameEvents(t, "no auto name over OpenCode's", titleEvents(f, chat, start))
}

func TestAutoNamesRefreshDeviceTitlesAndKeepExplicitProviderTitles(t *testing.T) {
	f := newChatFixture(t)
	// OpenCode's fixture title is its own.
	sendText(t, f, "s1", "please rename the chat tabs after the work")
	sameName(t, "a provider title", listedSession(t, f, "s1"), "Fixture", "provider", "")
	// A device-generated name advances with the next substantial prompt.
	f.oc.addMessages("s1", ocUserFixture(1, "First"), ocAssistantFixture(2, 1, "One"))
	if w := nameChat(t, f, "s1", "Tab names", fixtureID("msg", 1)); w.Code != 200 {
		t.Fatalf("name: %d %s", w.Code, w.Body)
	}
	latest := sendText(t, f, "s1", "now make the terminal tabs follow the program title")
	sameName(t, "a refreshed device name", listedSession(t, f, "s1"), "Make the terminal tabs follow the program title", "auto", latest)
	sendText(t, f, "s1", "yes, keep going")
	sameName(t, "confirmation keeps the subject", listedSession(t, f, "s1"), "Make the terminal tabs follow the program title", "auto", latest)
	// A Claude Code or Codex chat created with a title of its own keeps it.
	named := f.cliSession(t, "codex")
	if w := f.call(t, "POST", "/v1/sessions", map[string]string{"projectId": "p1", "title": "Nightly dependency check", "provider": "codex"}); w.Code != 201 {
		t.Fatalf("create: %d %s", w.Code, w.Body)
	} else {
		var session Session
		json.Unmarshal(w.Body.Bytes(), &session)
		sameName(t, "a created title", session, "Nightly dependency check", "provider", "")
		sendText(t, f, session.ID, "check every module for updates and open a summary")
		waitFor(t, "the reply", func() bool { return runnerCalls(f) >= 1 })
		sameName(t, "a created title after a message", listedSession(t, f, session.ID), "Nightly dependency check", "provider", "")
	}
	// The placeholder chat is named.
	sameName(t, "a placeholder", listedSession(t, f, named), "codex", "default", "")
	id := sendText(t, f, named, "update the parser to handle titles")
	sameName(t, "a named CLI chat", listedSession(t, f, named), "Update the parser to handle titles", "auto", id)
}

// Chat calls its providers Claude Code and Codex (owner, 2026-10-12; Claude
// and ChatGPT earlier that day). The apps' default titles, old and new, the
// host's untitled one and the defaults saved chats already have ("Claude
// chat", "ChatGPT chat", the bare names) are all placeholders, so auto naming
// replaces each of them.
func TestAutoNamesOldAndNewProviderDefaultTitles(t *testing.T) {
	f := newChatFixture(t)
	for _, title := range []string{"", "Claude chat", "ChatGPT chat", "Claude Code chat", "Codex chat", "ChatGPT", "Codex", "Claude Code"} {
		w := f.call(t, "POST", "/v1/sessions", map[string]string{"projectId": "p1", "title": title, "provider": "codex"})
		if w.Code != 201 {
			t.Fatalf("create %q: %d %s", title, w.Code, w.Body)
		}
		var session Session
		json.Unmarshal(w.Body.Bytes(), &session)
		want := title
		if title == "" {
			want = "Codex"
		}
		sameName(t, "created as "+strconv.Quote(title), session, want, "default", "")
		calls := runnerCalls(f)
		id := sendText(t, f, session.ID, "update the parser to handle titles")
		sameName(t, "named from "+strconv.Quote(title), listedSession(t, f, session.ID), "Update the parser to handle titles", "auto", id)
		waitFor(t, "the reply", func() bool { return runnerCalls(f) > calls })
	}
}

func TestChatTitleRouteNamesOpenCodeChats(t *testing.T) {
	f := newChatFixture(t)
	f.oc.addMessages("s1", ocUserFixture(1, "First"), ocAssistantFixture(2, 1, "One"), ocUserFixture(3, "Second"), ocAssistantFixture(4, 3, "Two"))
	chat := hubChatFor(t, f, "s1")
	start := ringSeq(f, chat)

	// Refused by OpenCode: nothing changes.
	f.oc.set(func(o *fakeOpenCode) { o.renameErr = 500 })
	if w := nameChat(t, f, "s1", "Login work", fixtureID("msg", 3)); w.Code != 502 || errorCode(t, w) != "provider_unavailable" {
		t.Fatalf("refused: %d %s", w.Code, w.Body)
	}
	sameName(t, "after a refusal", listedSession(t, f, "s1"), "Fixture", "provider", "")
	sameEvents(t, "after a refusal", titleEvents(f, chat, start))
	f.oc.set(func(o *fakeOpenCode) { o.renameErr = 0 })

	// Named: OpenCode renamed, every stream told, the answer the new name.
	w := nameChat(t, f, "s1", "  “Fix the login redirect.”  ", fixtureID("msg", 3))
	if w.Code != 200 || strings.TrimSpace(w.Body.String()) != `{"title":"Fix the login redirect","titleSource":"device","titleBasis":"`+fixtureID("msg", 3)+`"}` {
		t.Fatalf("named: %d %s", w.Code, w.Body)
	}
	f.oc.mu.Lock()
	renames := strings.Join(f.oc.renames, "|")
	f.oc.mu.Unlock()
	if renames != "Fix the login redirect" {
		t.Fatalf("OpenCode renames %q", renames)
	}
	sameName(t, "named", listedSession(t, f, "s1"), "Fix the login redirect", "device", fixtureID("msg", 3))
	sameEvents(t, "named", titleEvents(f, chat, start), `{"type":"chat.updated","title":"Fix the login redirect","titleSource":"device","titleBasis":"`+fixtureID("msg", 3)+`"}`)
	// OpenCode's echo, and a late update with the title from before, keep it.
	start = ringSeq(f, chat)
	feed(t, f, "session.updated", map[string]any{"sessionID": "s1", "info": map[string]any{"id": "s1", "title": "Fix the login redirect", "directory": f.oc.directory}})
	feed(t, f, "session.updated", map[string]any{"sessionID": "s1", "info": map[string]any{"id": "s1", "title": "Fixture", "directory": f.oc.directory}})
	sameEvents(t, "the echo", titleEvents(f, chat, start))
	// The same name again changes nothing.
	if w := nameChat(t, f, "s1", "Fix the login redirect", fixtureID("msg", 3)); w.Code != 200 {
		t.Fatalf("again: %d %s", w.Code, w.Body)
	}
	sameEvents(t, "the same name again", titleEvents(f, chat, start))
	f.oc.mu.Lock()
	renames = strings.Join(f.oc.renames, "|")
	f.oc.mu.Unlock()
	if renames != "Fix the login redirect" {
		t.Fatalf("the same name was written again: %q", renames)
	}

	// Stale: a name from an older message than the current basis.
	w = nameChat(t, f, "s1", "First message", fixtureID("msg", 1))
	var stale struct {
		Error struct{ Code, Title, TitleSource, TitleBasis string }
	}
	json.Unmarshal(w.Body.Bytes(), &stale)
	if w.Code != 409 || stale.Error.Code != "title_stale" || stale.Error.Title != "Fix the login redirect" || stale.Error.TitleSource != "device" || stale.Error.TitleBasis != fixtureID("msg", 3) {
		t.Fatalf("stale: %d %s", w.Code, w.Body)
	}
	// A newer message, or the reply to it, is accepted.
	if w := nameChat(t, f, "s1", "Login redirect fixed", fixtureID("msg", 4)); w.Code != 200 {
		t.Fatalf("newer: %d %s", w.Code, w.Body)
	}
	sameName(t, "renamed", listedSession(t, f, "s1"), "Login redirect fixed", "device", fixtureID("msg", 4))

	// A rename in OpenCode's own apps afterwards is OpenCode's title.
	start = ringSeq(f, chat)
	f.oc.set(func(o *fakeOpenCode) { o.titles["s1"] = "Renamed in the TUI" })
	feed(t, f, "session.updated", map[string]any{"sessionID": "s1", "info": map[string]any{"id": "s1", "title": "Renamed in the TUI", "directory": f.oc.directory}})
	sameEvents(t, "a rename in OpenCode", titleEvents(f, chat, start), `{"type":"chat.updated","title":"Renamed in the TUI","titleSource":"provider"}`)
	sameName(t, "a rename in OpenCode", listedSession(t, f, "s1"), "Renamed in the TUI", "provider", "")
}

func TestChatTitleRouteRefusals(t *testing.T) {
	f := newChatFixture(t)
	f.oc.addMessages("s1", ocUserFixture(1, "First"), ocAssistantFixture(2, 1, "One"), ocUserFixture(3, "Second"))
	f.oc.set(func(o *fakeOpenCode) {
		o.reverts["s2"] = ""
		o.messages["s2"] = []any{ocUserFixture(9, "Elsewhere")}
	})
	valid := map[string]any{"projectId": "p1", "sessionId": "s1", "title": "Fix it", "basedOn": fixtureID("msg", 1)}
	if w := request(t, f.host.Handler(), "POST", "/v1/chat/title", "", valid); w.Code != 401 {
		t.Fatalf("without a token: %d", w.Code)
	}
	with := func(key string, value any) map[string]any {
		body := map[string]any{}
		for name, item := range valid {
			body[name] = item
		}
		if value == nil {
			delete(body, key)
		} else {
			body[key] = value
		}
		return body
	}
	for name, body := range map[string]map[string]any{
		"no title":           with("title", nil),
		"no basis":           with("basedOn", nil),
		"no chat":            with("sessionId", nil),
		"an unknown field":   with("device", "iPhone"),
		"an empty title":     with("title", ""),
		"only white space":   with("title", " \t\n "),
		"only quotes":        with("title", `""`),
		"61 characters":      with("title", strings.Repeat("a", 61)),
		"a basis over limit": with("basedOn", strings.Repeat("m", 257)),
		"an unknown message": with("basedOn", fixtureID("msg", 42)),
		"another chat's":     with("basedOn", fixtureID("msg", 9)),
		"not a string":       with("title", 42),
	} {
		if w := f.call(t, "POST", "/v1/chat/title", body); w.Code != 400 || errorCode(t, w) != "invalid_request" {
			t.Errorf("%s: %d %s", name, w.Code, w.Body)
		}
	}
	// 60 characters of any script are accepted.
	if w := f.call(t, "POST", "/v1/chat/title", with("title", strings.Repeat("é", 60))); w.Code != 200 {
		t.Fatalf("60 characters: %d %s", w.Code, w.Body)
	}
	for name, body := range map[string]map[string]any{
		"an unknown chat":    with("sessionId", "missing"),
		"an unknown project": with("projectId", "p9"),
	} {
		if w := f.call(t, "POST", "/v1/chat/title", body); w.Code != 404 || errorCode(t, w) != "not_found" {
			t.Errorf("%s: %d %s", name, w.Code, w.Body)
		}
	}
	// A message a rewind hides is not one the chat shows.
	f.oc.set(func(o *fakeOpenCode) { o.reverts["s1"] = fixtureID("msg", 3) })
	if w := f.call(t, "POST", "/v1/chat/title", with("basedOn", fixtureID("msg", 3))); w.Code != 400 {
		t.Fatalf("a rewound message: %d %s", w.Code, w.Body)
	}
	if w := f.call(t, "POST", "/v1/chat/title", with("basedOn", fixtureID("msg", 2))); w.Code != 200 {
		t.Fatalf("a message before the rewind: %d %s", w.Code, w.Body)
	}
}

// A basis the chat no longer shows never makes a name stale; the host's own
// auto name after a newer message does.
func TestChatTitleStalenessFollowsTheMessageOrder(t *testing.T) {
	f := newChatFixture(t)
	f.oc.set(func(o *fakeOpenCode) { o.titles["s1"] = "New chat" })
	f.oc.addMessages("s1", ocUserFixture(1, "First"), ocAssistantFixture(2, 1, "One"))
	sent := sendText(t, f, "s1", "rename the terminal tabs after the program")
	// OpenCode files the message under the host's ID, after the others.
	f.oc.addMessages("s1", ocUserMessage(sent, 60, "rename the terminal tabs after the program"))
	sameName(t, "auto", listedSession(t, f, "s1"), "Rename the terminal tabs after the program", "auto", sent)
	if w := nameChat(t, f, "s1", "Older", fixtureID("msg", 2)); w.Code != 409 || errorCode(t, w) != "title_stale" {
		t.Fatalf("older than the auto name's basis: %d %s", w.Code, w.Body)
	}
	if w := nameChat(t, f, "s1", "Terminal tab names", sent); w.Code != 200 {
		t.Fatalf("the auto name's own basis: %d %s", w.Code, w.Body)
	}
	// The basis rewound: any message the chat shows is accepted.
	f.oc.set(func(o *fakeOpenCode) { o.reverts["s1"] = sent })
	if w := nameChat(t, f, "s1", "From the first reply", fixtureID("msg", 2)); w.Code != 200 {
		t.Fatalf("with the basis rewound: %d %s", w.Code, w.Body)
	}
}

func TestChatTitleRouteNamesCLIChatsAndTheNamesSurviveARestart(t *testing.T) {
	f := newChatFixture(t)
	id := f.cliSession(t, "claude")
	stream := hubChatFor(t, f, id)
	start := ringSeq(f, stream)
	sent := sendText(t, f, id, "first lets check the terminal scrolling on the iPad")
	sameName(t, "auto", listedSession(t, f, id), "Check the terminal scrolling on the iPad", "auto", sent)
	var messages []ChatMessage
	waitFor(t, "the reply", func() bool {
		messages, _, _ = f.host.chatProviderFor(Session{ID: id}).page(mustProject(t, f.store), Session{ID: id}, "", 50)
		return len(messages) == 2
	})
	if messages[1].ID != sent {
		t.Fatalf("messages %+v", messages)
	}
	reply := messages[0].ID
	if w := nameChat(t, f, id, "iPad terminal scrolling", reply); w.Code != 200 {
		t.Fatalf("name: %d %s", w.Code, w.Body)
	}
	sameName(t, "device", listedSession(t, f, id), "iPad terminal scrolling", "device", reply)
	waitFor(t, "both names on the stream", func() bool { return len(titleEvents(f, stream, start)) == 2 })
	sameEvents(t, "names", titleEvents(f, stream, start),
		`{"type":"chat.updated","title":"Check the terminal scrolling on the iPad","titleSource":"auto","titleBasis":"`+sent+`"}`,
		`{"type":"chat.updated","title":"iPad terminal scrolling","titleSource":"device","titleBasis":"`+reply+`"}`)
	// An older message is stale.
	if w := nameChat(t, f, id, "Older", sent); w.Code != 409 {
		t.Fatalf("stale: %d %s", w.Code, w.Body)
	}
	// The registry keeps the name: a host started on the same state has it.
	chats, err := NewCLIChats(f.chatsPath, f.runner)
	if err != nil {
		t.Fatal(err)
	}
	restarted := newHost(f.store, NewOpenCodeAdapter(f.oc.server.URL, "opencode", "fixture", f.oc.server.Client()), HostOptions{CLIChats: chats})
	t.Cleanup(func() { restarted.Close() })
	session, err := restarted.session(mustProject(t, f.store), id)
	if err != nil {
		t.Fatal(err)
	}
	sameName(t, "after a restart", session, "iPad terminal scrolling", "device", reply)
}

func claudeListed(t *testing.T, f *claudeFixture, id string) Session {
	t.Helper()
	var body struct{ Sessions []Session }
	json.Unmarshal(f.call("GET", "/v1/sessions?projectId=p1", nil).Body.Bytes(), &body)
	for _, session := range body.Sessions {
		if session.ID == id {
			return session
		}
	}
	t.Fatalf("session %s is not listed", id)
	return Session{}
}

// Claude Code chats run through the stream-json engine: names come from the
// messages it delivers (regenerate too), stay in the registry, survive a
// settings push from the engine and go with a fork made without a title.
func TestClaudeChatNames(t *testing.T) {
	f := newClaudeFixture(t, nil)
	f.script(1, step(map[string]any{"do": "init"}), textTurn("msg_1", "one", "", 0.001), textTurn("msg_2", "two", "", 0.001))
	f.script(2, step(map[string]any{"do": "init"}), textTurn("msg_3", "two again", "", 0.001))
	id := f.newChat()
	stream := f.stream(id)
	snapshot := stream.until(t, "snapshot", 5*time.Second)
	if chat := snapshot[len(snapshot)-1].Chat; chat == nil || chat.Title != "Claude" || chat.TitleSource != "default" || chat.TitleBasis != "" {
		t.Fatalf("snapshot: %s", snapshot[len(snapshot)-1].raw)
	}
	first := f.mustSend(id, "can you make the tab names describe the work", nil)
	f.waitIdle(id)
	named := claudeListed(t, f, id)
	sameName(t, "the first message", named, "Make the tab names describe the work", "auto", first.MessageID)
	// The host names the chat once the send has returned, which a fast turn
	// may finish before, so the name can follow turn.finished: read until it
	// comes (until fails the test when nothing more arrives).
	deadline := time.Now().Add(10 * time.Second)
	for {
		events := stream.until(t, "chat.updated", time.Until(deadline))
		if strings.Contains(events[len(events)-1].raw, `"title":"Make the tab names describe the work","titleSource":"auto","titleBasis":"`+first.MessageID+`"`) {
			break
		}
	}
	second := f.mustSend(id, "now add tests for the terminal titles", nil)
	f.waitIdle(id)
	sameName(t, "the second message", claudeListed(t, f, id), "Add tests for the terminal titles", "auto", second.MessageID)
	// Regenerate sends the prompt again under a new ID, which names the chat.
	w := f.call("POST", "/v1/chat/regenerate", map[string]any{"projectId": "p1", "sessionId": id, "effort": "low"})
	var again sendReceipt
	json.Unmarshal(w.Body.Bytes(), &again)
	if w.Code != 202 || again.MessageID == second.MessageID {
		t.Fatalf("regenerate: %d %s", w.Code, w.Body)
	}
	f.waitIdle(id)
	sameName(t, "after regenerate", claudeListed(t, f, id), "Add tests for the terminal titles", "auto", again.MessageID)
	// A device's name on the reply.
	var page struct{ Messages []ChatMessage }
	json.Unmarshal(f.call("GET", "/v1/chat/messages?projectId=p1&sessionId="+id, nil).Body.Bytes(), &page)
	reply := page.Messages[0]
	if reply.Role != "assistant" {
		t.Fatalf("newest message %+v", reply)
	}
	if w := f.call("POST", "/v1/chat/title", map[string]string{"projectId": "p1", "sessionId": id, "title": "Terminal title tests", "basedOn": reply.ID}); w.Code != 200 {
		t.Fatalf("name: %d %s", w.Code, w.Body)
	}
	if stored, ok := f.chats.storedName(id); !ok || stored != (chatName{Title: "Terminal title tests", Source: "device", Basis: reply.ID}) {
		t.Fatalf("registry %+v", stored)
	}
	// The engine pushing its settings keeps the name.
	chat := f.chatState(id)
	chat.mu.Lock()
	chat.pushInfoLocked()
	chat.mu.Unlock()
	sameName(t, "after a settings push", claudeListed(t, f, id), "Terminal title tests", "device", reply.ID)
	f.host.chat.mu.Lock()
	hub := f.host.chat.chats[sessionKey{"p1", id}]
	info := hub.info
	f.host.chat.mu.Unlock()
	if info.Title != "Terminal title tests" || info.TitleSource != "device" || info.TitleBasis != reply.ID {
		t.Fatalf("hub %+v", info)
	}
	// A fork made without a title keeps the name and where it came from.
	w = f.call("POST", "/v1/chat/fork", map[string]string{"projectId": "p1", "sessionId": id})
	var forked Session
	json.Unmarshal(w.Body.Bytes(), &forked)
	if w.Code != 201 {
		t.Fatalf("fork: %d %s", w.Code, w.Body)
	}
	sameName(t, "the fork", forked, "Terminal title tests", "device", reply.ID)
	sameName(t, "the fork listed", claudeListed(t, f, forked.ID), "Terminal title tests", "device", reply.ID)
	// A fork given a title is its creator's.
	w = f.call("POST", "/v1/chat/fork", map[string]string{"projectId": "p1", "sessionId": id, "title": "Branch"})
	var titled Session
	json.Unmarshal(w.Body.Bytes(), &titled)
	sameName(t, "a titled fork", titled, "Branch", "provider", "")
}

func TestOpenCodeNamesSurviveARestart(t *testing.T) {
	f := newChatFixture(t)
	path := filepath.Join(filepath.Dir(f.store.Path), "host.json.titles.json")
	titles, err := NewChatTitleStore(path)
	if err != nil {
		t.Fatal(err)
	}
	f.host.titles = titles
	f.oc.set(func(o *fakeOpenCode) {
		o.titles["s1"] = "New chat"
		o.reverts["s2"] = ""
		o.titles["s2"] = "New session - 2026-09-26T10:00:00.000Z"
		o.messages["s2"] = []any{ocUserFixture(1, "First")}
	})
	sent := sendText(t, f, "s1", "make the chat tabs describe the work")
	if w := nameChat(t, f, "s2", "Chat tab names", fixtureID("msg", 1)); w.Code != 200 {
		t.Fatalf("name: %d %s", w.Code, w.Body)
	}
	if info, err := os.Stat(path); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("titles file: %v %v", info, err)
	}
	reopened, err := NewChatTitleStore(path)
	if err != nil {
		t.Fatal(err)
	}
	restarted := newHost(f.store, NewOpenCodeAdapter(f.oc.server.URL, "opencode", "fixture", f.oc.server.Client()), HostOptions{ChatTitles: reopened})
	t.Cleanup(func() { restarted.Close() })
	p := mustProject(t, f.store)
	if session, err := restarted.session(p, "s1"); err != nil {
		t.Fatal(err)
	} else {
		sameName(t, "an auto name after a restart", session, "Make the chat tabs describe the work", "auto", sent)
	}
	if session, err := restarted.session(p, "s2"); err != nil {
		t.Fatal(err)
	} else {
		sameName(t, "a device name after a restart", session, "Chat tab names", "device", fixtureID("msg", 1))
	}
}

func TestChatNamesReachTheArchive(t *testing.T) {
	f, archive, _ := newArchiveChatFixture(t, ArchiveOptions{}, nil)
	f.oc.set(func(o *fakeOpenCode) { o.titles["s1"] = "New chat" })
	f.oc.addMessages("s1", ocUserFixture(1, "First"))
	sent := sendText(t, f, "s1", "make the chat tabs describe the work")
	autoName := func(page ArchiveChatPage) bool {
		return page.Chat.Title == "Make the chat tabs describe the work" && page.Chat.TitleSource == "auto" && page.Chat.TitleBasis == sent
	}
	waitArchived(t, archive, "s1", "the auto name", autoName)
	// A backfill of the session keeps the host's name, not OpenCode's
	// placeholder.
	if err := f.host.backfill.run(t.Context()); err != nil {
		t.Fatal(err)
	}
	flushArchive(t, archive)
	if page := archivedPage(t, archive, "s1"); !autoName(page) {
		t.Fatalf("after a backfill: %+v", page.Chat)
	}
	if w := nameChat(t, f, "s1", "Chat tab names", fixtureID("msg", 1)); w.Code != 200 {
		t.Fatalf("name: %d %s", w.Code, w.Body)
	}
	waitArchived(t, archive, "s1", "the device name", func(page ArchiveChatPage) bool {
		return page.Chat.Title == "Chat tab names" && page.Chat.TitleSource == "device" && page.Chat.TitleBasis == fixtureID("msg", 1)
	})
	// The change feed carries both fields.
	changes, err := archive.Changes(t.Context(), "", 200, []string{"p1"})
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, change := range changes.Changes {
		if change.Entity == "chat" && strings.Contains(string(change.Payload), `"title":"Chat tab names","titleSource":"device","titleBasis":"`+fixtureID("msg", 1)+`"`) {
			found = true
		}
	}
	if !found {
		t.Fatalf("change feed: %+v", changes.Changes)
	}
}
