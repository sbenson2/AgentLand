package host

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

func attachmentFiles(t *testing.T, f *chatFixture) []string {
	t.Helper()
	entries, err := os.ReadDir(f.attachments.directory)
	if err != nil {
		t.Fatal(err)
	}
	names := []string{}
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	return names
}

func TestAttachmentNamesAreDisplayOnly(t *testing.T) {
	for raw, want := range map[string]string{
		"../../etc/passwd":             "passwd",
		`C:\Users\me\photo.png`:        "photo.png",
		"  report final.pdf  ":         "report final.pdf",
		"bad\nna\x00me\t.png":          "badname.png",
		"a\xffb.txt":                   "ab.txt",
		"":                             "attachment",
		"..":                           "attachment",
		"folder/":                      "attachment",
		"\x01\x02":                     "attachment",
		strings.Repeat("é", 100):       strings.Repeat("é", 60),
		strings.Repeat("a", 119) + "é": strings.Repeat("a", 119),
	} {
		got := attachmentName(raw)
		if got != want || len(got) > 120 || !utf8.ValidString(got) {
			t.Errorf("attachmentName(%q) = %q, want %q", raw, got, want)
		}
	}
}

func TestAttachmentUploadValidatesTypeSizeAndStoresPrivately(t *testing.T) {
	f := newChatFixture(t)
	for _, contentType := range []string{"image/svg+xml", "application/octet-stream", "text/html", "", "not a type"} {
		if w := f.upload(t, f.token, "s1", "file", contentType, []byte("data")); w.Code != 415 || errorCode(t, w) != "unsupported_attachment" {
			t.Fatalf("%q: %d %s", contentType, w.Code, w.Body.String())
		}
	}
	w := f.upload(t, f.token, "s1", "../notes\n.txt", "Text/Plain; charset=utf-8", []byte("hello"))
	if w.Code != 201 {
		t.Fatalf("text upload: %d %s", w.Code, w.Body.String())
	}
	var stored map[string]any
	json.Unmarshal(w.Body.Bytes(), &stored)
	if len(stored) != 4 || !strings.HasPrefix(stored["id"].(string), "att_") || stored["name"] != "notes.txt" || stored["mime"] != "text/plain" || stored["size"] != float64(5) {
		t.Fatalf("upload response: %s", w.Body.String())
	}
	if w := f.upload(t, f.token, "s1", "empty.txt", "text/plain", nil); w.Code != 400 {
		t.Fatalf("empty upload: %d", w.Code)
	}
	for _, test := range []struct {
		contentType string
		size        int
	}{{"image/png", 10<<20 + 1}, {"application/pdf", 10<<20 + 1}, {"text/markdown", 2<<20 + 1}, {"application/json", 2<<20 + 1}} {
		if w := f.upload(t, f.token, "s1", "big", test.contentType, make([]byte, test.size)); w.Code != 413 || errorCode(t, w) != "attachment_too_large" {
			t.Fatalf("%s of %d bytes: %d %s", test.contentType, test.size, w.Code, w.Body.String())
		}
	}
	// Without a declared length the body limit still applies while reading.
	r := httptest.NewRequest("POST", "/v1/attachments?projectId=p1&sessionId=s1&name=stream.csv", bytes.NewReader(make([]byte, 2<<20+1)))
	r.ContentLength = -1
	r.Header.Set("Content-Type", "text/csv")
	r.Header.Set("Authorization", "Bearer "+f.token)
	streamed := httptest.NewRecorder()
	f.host.Handler().ServeHTTP(streamed, r)
	if streamed.Code != 413 {
		t.Fatalf("streamed oversized upload: %d", streamed.Code)
	}
	if w := f.upload(t, f.token, "s1", "exact.png", "image/png", make([]byte, 10<<20)); w.Code != 201 {
		t.Fatalf("maximum image: %d %s", w.Code, w.Body.String())
	}
	if w := f.upload(t, f.token, "missing", "x.txt", "text/plain", []byte("x")); w.Code != 404 {
		t.Fatalf("unknown chat: %d", w.Code)
	}
	if w := f.upload(t, "", "s1", "x.txt", "text/plain", []byte("x")); w.Code != 401 {
		t.Fatalf("unauthenticated upload: %d", w.Code)
	}
	names := attachmentFiles(t, f)
	if len(names) != 2 {
		t.Fatalf("stored files: %v", names)
	}
	for _, name := range names {
		if !strings.HasPrefix(name, "att_") || strings.Contains(name, "notes") || (!strings.HasSuffix(name, ".txt") && !strings.HasSuffix(name, ".png")) {
			t.Fatalf("client-controlled or unexpected file name: %s", name)
		}
		info, err := os.Stat(filepath.Join(f.attachments.directory, name))
		if err != nil {
			t.Fatal(err)
		}
		if runtime.GOOS != "windows" && info.Mode().Perm() != 0600 {
			t.Fatalf("file mode %o", info.Mode().Perm())
		}
	}
	if info, err := os.Stat(f.attachments.directory); err != nil || (runtime.GOOS != "windows" && info.Mode().Perm() != 0700) {
		t.Fatalf("directory: %v %v", info, err)
	}
}

func TestAttachmentLimitsArePerDeviceAndUnsentFilesExpire(t *testing.T) {
	f := newChatFixture(t)
	other := paired(t, f.host, f.store)
	for index := 0; index < 32; index++ {
		f.uploadID(t, f.token, "s1", "note.txt", "text/plain", []byte("x"))
	}
	if w := f.upload(t, f.token, "s1", "extra.txt", "text/plain", []byte("x")); w.Code != 429 || errorCode(t, w) != "attachment_limit" {
		t.Fatalf("33rd upload: %d %s", w.Code, w.Body.String())
	}
	f.uploadID(t, other, "s1", "other.txt", "text/plain", []byte("x"))
	f.clock.Advance(24*time.Hour - time.Second)
	f.attachments.sweep()
	if len(attachmentFiles(t, f)) != 33 {
		t.Fatal("attachments expired early")
	}
	f.clock.Advance(time.Second)
	f.attachments.sweep()
	if names := attachmentFiles(t, f); len(names) != 0 {
		t.Fatalf("expired files remain: %v", names)
	}
	// Expiry released the count; the byte limit is 64 MiB of unsent files.
	for index := 0; index < 6; index++ {
		f.uploadID(t, f.token, "s1", "photo.png", "image/png", make([]byte, 10<<20))
	}
	if w := f.upload(t, f.token, "s1", "more.png", "image/png", make([]byte, 5<<20)); w.Code != 429 {
		t.Fatalf("upload beyond 64 MiB: %d", w.Code)
	}
	f.uploadID(t, f.token, "s1", "last.png", "image/png", make([]byte, 4<<20))
}

func TestAttachmentStoreRemovesStaleFilesOnStartup(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "state", "host.json.attachments")
	if err := os.MkdirAll(directory, 0755); err != nil {
		t.Fatal(err)
	}
	stale, fresh, folder := filepath.Join(directory, "att_old.png"), filepath.Join(directory, "att_new.png"), filepath.Join(directory, "folder")
	for _, path := range []string{stale, fresh} {
		if err := os.WriteFile(path, []byte("x"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Mkdir(folder, 0700); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-25 * time.Hour)
	for _, path := range []string{stale, folder} {
		if err := os.Chtimes(path, old, old); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := NewAttachmentStore(directory); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Fatal("stale attachment survived startup")
	}
	for _, path := range []string{fresh, folder} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("%s removed: %v", path, err)
		}
	}
	if info, _ := os.Stat(directory); runtime.GOOS != "windows" && info.Mode().Perm() != 0700 {
		t.Fatalf("directory mode %o", info.Mode().Perm())
	}
}

func TestAttachmentsOnlySendFromTheUploadingDeviceAndChat(t *testing.T) {
	f := newChatFixture(t)
	f.oc.set(func(oc *fakeOpenCode) { oc.reverts["s2"] = "" })
	other := paired(t, f.host, f.store)
	id := f.uploadID(t, f.token, "s1", "photo.png", "image/png", []byte("png"))
	send := func(token, session string, body map[string]any) int {
		body["projectId"], body["sessionId"] = "p1", session
		return request(t, f.host.Handler(), "POST", "/v1/messages", token, body).Code
	}
	for name, status := range map[string]int{
		"other device":   send(other, "s1", map[string]any{"text": "x", "attachments": []string{id}}),
		"other chat":     send(f.token, "s2", map[string]any{"text": "x", "attachments": []string{id}}),
		"unknown":        send(f.token, "s1", map[string]any{"text": "x", "attachments": []string{"att_missing"}}),
		"duplicate":      send(f.token, "s1", map[string]any{"text": "x", "attachments": []string{id, id}}),
		"more than five": send(f.token, "s1", map[string]any{"text": "x", "attachments": []string{id, "a", "b", "c", "d", "e"}}),
	} {
		if status != 400 {
			t.Errorf("%s: %d", name, status)
		}
	}
	if status := send(f.token, "s1", map[string]any{"text": ""}); status != 400 {
		t.Fatalf("empty message: %d", status)
	}
	if bodies := f.oc.promptBodies(); len(bodies) != 0 {
		t.Fatalf("rejected sends reached OpenCode: %d", len(bodies))
	}
	if status := send(f.token, "s1", map[string]any{"text": "", "attachments": []string{id}}); status != 202 {
		t.Fatalf("owner send after rejected attempts: %d", status)
	}
}

func TestOpenCodeAttachmentsAreSentAsDataURLsAndRemovedOnceAccepted(t *testing.T) {
	f := newChatFixture(t)
	png, notes := []byte("\x89PNG\r\n\x1a\nfixture"), []byte("# Notes\nkeep this")
	pngID := f.uploadID(t, f.token, "s1", "photo.png", "image/png", png)
	notesID := f.uploadID(t, f.token, "s1", "notes.md", "text/markdown", notes)
	body := map[string]any{"projectId": "p1", "sessionId": "s1", "text": "Look", "attachments": []string{pngID, notesID}, "model": "deepseek/chat", "agent": "plan"}
	// OpenCode rejected the prompt, so the files stay available to resend.
	f.oc.set(func(oc *fakeOpenCode) { oc.promptCode = 500 })
	if w := f.call(t, "POST", "/v1/messages", body); w.Code != 502 {
		t.Fatalf("rejected prompt: %d", w.Code)
	}
	if len(attachmentFiles(t, f)) != 2 {
		t.Fatal("a definite failure discarded the attachments")
	}
	f.oc.set(func(oc *fakeOpenCode) { oc.promptCode = 204 })
	if w := f.call(t, "POST", "/v1/messages", body); w.Code != 202 {
		t.Fatalf("send: %d %s", w.Code, w.Body.String())
	}
	bodies := f.oc.promptBodies()
	var prompt struct {
		Parts []map[string]string
		Model map[string]string
		Agent string
	}
	if err := json.Unmarshal(bodies[len(bodies)-1], &prompt); err != nil {
		t.Fatal(err)
	}
	want := []map[string]string{
		{"type": "text", "text": "Look"},
		{"type": "file", "mime": "image/png", "filename": "photo.png", "url": "data:image/png;base64," + base64.StdEncoding.EncodeToString(png)},
		{"type": "file", "mime": "text/plain", "filename": "notes.md", "url": "data:text/plain;base64," + base64.StdEncoding.EncodeToString(notes)},
	}
	encodedParts, _ := json.Marshal(prompt.Parts)
	encodedWant, _ := json.Marshal(want)
	if string(encodedParts) != string(encodedWant) || prompt.Model["providerID"] != "deepseek" || prompt.Model["modelID"] != "chat" || prompt.Agent != "plan" {
		t.Fatalf("prompt body: %s", bodies[len(bodies)-1])
	}
	if names := attachmentFiles(t, f); len(names) != 0 {
		t.Fatalf("accepted attachments remain on disk: %v", names)
	}
	if w := f.call(t, "POST", "/v1/messages", body); w.Code != 400 || errorCode(t, w) != "invalid_attachment" {
		t.Fatalf("resending consumed attachments: %d", w.Code)
	}
	// An attachment-only message has no text part.
	onlyID := f.uploadID(t, f.token, "s1", "report.pdf", "application/pdf", []byte("%PDF-1.7"))
	if w := f.call(t, "POST", "/v1/messages", map[string]any{"projectId": "p1", "sessionId": "s1", "text": "", "attachments": []string{onlyID}}); w.Code != 202 {
		t.Fatalf("attachment-only send: %d %s", w.Code, w.Body.String())
	}
	bodies = f.oc.promptBodies()
	if !strings.HasPrefix(string(bodies[len(bodies)-1]), `{"parts":[{"filename":"report.pdf","mime":"application/pdf","type":"file","url":"data:application/pdf;base64,`) {
		t.Fatalf("attachment-only body: %.120s", bodies[len(bodies)-1])
	}
	// Losing the connection after sending is uncertain: the files are not kept for a resend.
	lostID := f.uploadID(t, f.token, "s1", "lost.png", "image/png", png)
	f.oc.set(func(oc *fakeOpenCode) { oc.dropPrompt = true })
	if w := f.call(t, "POST", "/v1/messages", map[string]any{"projectId": "p1", "sessionId": "s1", "text": "maybe", "attachments": []string{lostID}}); w.Code != 502 {
		t.Fatalf("uncertain delivery: %d", w.Code)
	}
	if names := attachmentFiles(t, f); len(names) != 0 {
		t.Fatalf("uncertain delivery kept attachments: %v", names)
	}
}

func TestCLIChatAttachmentsReachTheRunnerAndAreRemovedAfterTheRun(t *testing.T) {
	f := newChatFixture(t)
	f.runner.release = make(chan struct{})
	id := f.cliSession(t, "claude")
	pngID := f.uploadID(t, f.token, id, "photo.png", "image/png", []byte("png"))
	notesID := f.uploadID(t, f.token, id, "notes.txt", "text/plain", []byte("notes"))
	if w := f.call(t, "POST", "/v1/messages", map[string]any{"projectId": "p1", "sessionId": id, "text": "Check these", "attachments": []string{pngID, notesID}}); w.Code != 202 {
		t.Fatalf("send: %d %s", w.Code, w.Body.String())
	}
	waitFor(t, "the CLI run", func() bool { f.runner.mu.Lock(); defer f.runner.mu.Unlock(); return len(f.runner.calls) == 1 })
	f.runner.mu.Lock()
	call := f.runner.calls[0]
	f.runner.mu.Unlock()
	if call.Prompt != "Check these" || len(call.Attachments) != 2 || !call.Readable || call.Attachments[0].Name != "photo.png" || call.Attachments[1].MIME != "text/plain" || filepath.Dir(call.Attachments[0].Path) != f.attachments.directory {
		t.Fatalf("runner call: %+v", call)
	}
	// A definite failure (the chat is busy) returns the upload to its sender.
	laterID := f.uploadID(t, f.token, id, "later.txt", "text/plain", []byte("later"))
	if w := f.call(t, "POST", "/v1/messages", map[string]any{"projectId": "p1", "sessionId": id, "text": "next", "attachments": []string{laterID}}); w.Code != 409 {
		t.Fatalf("busy CLI chat: %d", w.Code)
	}
	if len(attachmentFiles(t, f)) != 3 {
		t.Fatal("files removed before the run ended")
	}
	close(f.runner.release)
	waitFor(t, "run cleanup", func() bool { return len(attachmentFiles(t, f)) == 1 })
	restored, err := NewCLIChats(f.chatsPath, f.runner)
	if err != nil {
		t.Fatal(err)
	}
	messages, err := restored.Messages(mustProject(t, f.store), id)
	if err != nil || len(messages) != 2 {
		t.Fatalf("stored transcript: %+v %v", messages, err)
	}
	user := messages[0]
	if user.Text != "Check these" || len(user.Attachments) != 2 || user.Attachments[0] != (AttachmentInfo{"photo.png", "image/png"}) || user.Attachments[1] != (AttachmentInfo{"notes.txt", "text/plain"}) {
		t.Fatalf("stored user message: %+v", user)
	}
	if w := f.call(t, "POST", "/v1/messages", map[string]any{"projectId": "p1", "sessionId": id, "text": "", "attachments": []string{laterID}}); w.Code != 202 {
		t.Fatalf("resend after the busy failure: %d %s", w.Code, w.Body.String())
	}
	waitFor(t, "second run cleanup", func() bool { return len(attachmentFiles(t, f)) == 0 })
}

func TestCLIChatInvocationPassesAttachmentsAsHostPaths(t *testing.T) {
	image := ChatAttachment{Path: "/state/host.json.attachments/att_1.png", Name: "photo.png", MIME: "image/png"}
	pdf := ChatAttachment{Path: "/state/host.json.attachments/att_2.pdf", Name: "report.pdf", MIME: "application/pdf"}
	comma := ChatAttachment{Path: "/odd,folder/att_3.png", Name: "c.png", MIME: "image/png"}
	listed := "Attached files (read them with your tools):\n- /state/host.json.attachments/att_2.pdf (report.pdf)\n- /odd,folder/att_3.png (c.png)"
	for _, test := range []struct {
		provider, nativeID, prompt string
		attachments                []ChatAttachment
		args, input                string
	}{
		// Codex 0.156.1 refuses --sandbox with --approve-for-me; a resumed run
		// keeps the same sandbox and approvals through -c.
		{"codex", "", "Review", []ChatAttachment{image, pdf, comma}, `exec -i /state/host.json.attachments/att_1.png --json --skip-git-repo-check --approve-for-me -C /repo -c forced_login_method="chatgpt" -`, "Review\n\n" + listed},
		{"codex", "thread-1", "", []ChatAttachment{image}, `exec resume -i /state/host.json.attachments/att_1.png --json --skip-git-repo-check -c sandbox_mode="workspace-write" -c approval_policy="on-request" -c approvals_reviewer="auto_review" -c forced_login_method="chatgpt" thread-1 -`, "See the attached images."},
		{"codex", "thread-1", "Plain", nil, `exec resume --json --skip-git-repo-check -c sandbox_mode="workspace-write" -c approval_policy="on-request" -c approvals_reviewer="auto_review" -c forced_login_method="chatgpt" thread-1 -`, "Plain"},
		{"claude", "native-1", "Review", []ChatAttachment{image, pdf}, "-p --add-dir /state/host.json.attachments --output-format json --permission-mode auto --resume native-1", "Review\n\nAttached files (read them with your tools):\n- /state/host.json.attachments/att_1.png (photo.png)\n- /state/host.json.attachments/att_2.pdf (report.pdf)"},
		{"claude", "native-1", "Plain", nil, "-p --output-format json --permission-mode auto --resume native-1", "Plain"},
	} {
		invocation, err := cliChatInvocation(test.provider, "/repo", test.nativeID, test.prompt, test.attachments)
		if err != nil || strings.Join(invocation.args, " ") != test.args || invocation.input != test.input || invocation.nativeID != test.nativeID {
			t.Errorf("%s %q:\n args %q\n want %q\n input %q\n want %q", test.provider, test.nativeID, strings.Join(invocation.args, " "), test.args, invocation.input, test.input)
		}
	}
	created, err := cliChatInvocation("claude", "/repo", "", "", []ChatAttachment{pdf})
	if err != nil || len(created.nativeID) != 36 || strings.Join(created.args[:3], " ") != "-p --add-dir /state/host.json.attachments" || created.args[len(created.args)-1] != created.nativeID {
		t.Fatalf("new Claude session: %+v %v", created, err)
	}
	if _, err := cliChatInvocation("other", "/repo", "", "x", nil); err == nil {
		t.Fatal("unknown provider accepted")
	}
}
