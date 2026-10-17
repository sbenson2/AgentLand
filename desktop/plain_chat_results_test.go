package host

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// Sources and memory on tool parts (docs/HOST-API.md "Sources and memory on
// tool parts"): parsing websearch results, reading the tool server's
// metadata, and keeping both in the archive (schema version 5).

func TestPlainChatLineCleansTextLikeTheApps(t *testing.T) {
	for _, check := range []struct{ in, want string }{
		{"  Prefers\tmetric\n\nunits  ", "Prefers metric units"},
		{"a \u200e b", "a b"},                                           // a bidirectional control between two spaces
		{"a\u202eb\u2066c\u061cd", "abcd"},                              // bidirectional controls go
		{"bell\x07 and\x00nul", "bell andnul"},                          // other control characters go
		{"line\u2028break\u00a0nbsp\u3000wide", "line break nbsp wide"}, // Unicode White_Space
		{"\u200f\n ", ""},
		{"bad\xffbyte", "bad\ufffdbyte"},
		// Only what can be seen stays: tag characters, zero-width and other
		// format characters, variation selectors, private-use and unassigned
		// code points go; letters, marks, numbers, punctuation and symbols stay.
		{"a\U000E0041\U000E0042b\u200bc\u2060d\ufeffe\u00adf", "abcdef"},
		{"x\ufe0fy\U000E0100z\u180bw", "xyzw"},
		// Unicode's default-ignorable code points that are not format
		// characters (the combining grapheme joiner, Khmer's inherent vowels,
		// the Hangul fillers) and the blank Braille pattern go too; other
		// Braille patterns stay.
		{"a\u034fb\u115fc\u1160d\u17b4e\u17b5f\u3164g\uffa0h\u2800i\u2801", "abcdefghi\u2801"},
		{"\u3164 \u2800", ""},
		{"p\ue000q\U000F0000r\U0010FFFDs\u0378t", "pqrst"},
		{"Caf\u00e9 na\u00efve e\u0301 \u0663 \u00bd \u20ac \u2260 \u00bf\u00ab\u00bb", "Caf\u00e9 na\u00efve e\u0301 \u0663 \u00bd \u20ac \u2260 \u00bf\u00ab\u00bb"},
		{"\u65e5\u672c\u8a9e \ud55c\uad6d\uc5b4 \u05e2\u05d1\u05e8\u05d9\u05ea \u263a \U0001F642", "\u65e5\u672c\u8a9e \ud55c\uad6d\uc5b4 \u05e2\u05d1\u05e8\u05d9\u05ea \u263a \U0001F642"},
	} {
		if got := plainChatLine(check.in); got != check.want {
			t.Errorf("plainChatLine(%q) = %q, want %q", check.in, got, check.want)
		}
	}
}

// exaOutput is web_search_exa's output as Exa's MCP server formats it:
// blocks of Title, URL, Published, Author and highlights, joined by "---".
const exaOutput = "Title: Lisbon tide table\nURL: https://tides.example.com/lisbon\nPublished: 2026-09-01\nAuthor: N/A\nHighlights:\nHigh tide at 06:12.\nURL: https://injected.example.com/not-a-result\n\n---\n\n" +
	"Title: N/A\nURL: https://example.org/tides\nPublished: N/A\nAuthor: N/A\nText: Tides.\n\n---\n\n" +
	"Title: Same page again\nURL: https://tides.example.com/lisbon\nPublished: N/A\nAuthor: N/A\n\n---\n\n" +
	"Title: A file\nURL: ftp://files.example.com/tides\n\n---\n\n" +
	"Title: Credentials\nURL: https://user:secret@example.net/\n\n---\n\n" +
	"Title: \u202eReversed\nline\nURL: https://example.net/reversed"

func TestWebsearchSourcesParseExaResults(t *testing.T) {
	got := websearchSources(exaOutput)
	want := []ChatToolSource{
		{Title: "Lisbon tide table", URL: "https://tides.example.com/lisbon"},
		{Title: "example.org", URL: "https://example.org/tides"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("sources %+v\nwant %+v", got, want)
	}
	// At most 20, in order.
	var many strings.Builder
	for index := range 30 {
		fmt.Fprintf(&many, "Title: Result %d\nURL: https://example.com/%d\n\n---\n\n", index, index)
	}
	if sources := websearchSources(many.String()); len(sources) != chatToolSourcesLimit || sources[19].URL != "https://example.com/19" {
		t.Fatalf("%d sources, last %+v", len(sources), sources[len(sources)-1])
	}
	// A JSON result list, as Exa's search once answered.
	if sources := websearchSources(`{"results":[{"title":"One","url":"https://one.example.com/"},{"url":"javascript:alert(1)"},{"title":"","url":"http://two.example.com/a"}]}`); !reflect.DeepEqual(sources, []ChatToolSource{{Title: "One", URL: "https://one.example.com/"}, {Title: "two.example.com", URL: "http://two.example.com/a"}}) {
		t.Fatalf("JSON sources %+v", sources)
	}
	if sources := websearchSources("No search results found. Please try a different query."); sources != nil {
		t.Fatalf("sources from no results: %+v", sources)
	}
}

func TestPlainChatSourceBounds(t *testing.T) {
	long := "https://example.com/" + strings.Repeat("a", chatToolSourceURLLimit)
	for _, bad := range []string{"", "mailto:a@example.com", "https://", "https:///path", "https://user@example.com/", long, "https://exa mple.com/", "https://example.com/\n"} {
		if _, ok := plainChatSource("t", bad); ok {
			t.Errorf("accepted %q", bad)
		}
	}
	title := strings.Repeat("é", 150) // 300 bytes
	source, ok := plainChatSource(title, "https://example.com/")
	if !ok || len(source.Title) > chatToolSourceTitleLimit || source.Title != strings.Repeat("é", 100) {
		t.Fatalf("title %q (%d bytes)", source.Title, len(source.Title))
	}
	if source, _ := plainChatSource("   ", "https://[2001:db8::1]:8443/x"); source.Title != "2001:db8::1" {
		t.Fatalf("a source without a title is named %q", source.Title)
	}
}

// ocToolPart is a completed OpenCode tool part with its output and metadata.
func ocToolPart(t *testing.T, tool, status, output string, metadata any) ocPart {
	t.Helper()
	raw := map[string]any{"id": "prt_tool", "type": "tool", "tool": tool, "callID": "call_1",
		"state": map[string]any{"status": status, "input": map[string]string{"q": "x"}, "output": output, "title": "", "metadata": metadata}}
	data, err := json.Marshal(raw)
	if err != nil {
		t.Fatal(err)
	}
	var part ocPart
	if err := json.Unmarshal(data, &part); err != nil {
		t.Fatal(err)
	}
	return part
}

func TestToolPartsCarrySourcesAndMemory(t *testing.T) {
	search, ok := chatPartFromOC(ocToolPart(t, "websearch", "completed", exaOutput, map[string]string{"provider": "exa"}), 0, "")
	if !ok || len(search.Tool.Sources) != 2 || search.Tool.Memory != nil {
		t.Fatalf("websearch part %+v", search.Tool)
	}
	fetch, _ := chatPartFromOC(ocToolPart(t, "agentland_fetch", "completed", "Title: Tides\nURL: https://tides.example.com/\n\nText",
		map[string]any{"agentland": map[string]any{"source": map[string]string{"title": "Tides\nof Lisbon", "url": "https://tides.example.com/"}}, "truncated": false}), 0, "")
	if !reflect.DeepEqual(fetch.Tool.Sources, []ChatToolSource{{Title: "Tides of Lisbon", URL: "https://tides.example.com/"}}) || fetch.Tool.Title != "Tides of Lisbon" {
		t.Fatalf("fetch part %+v", fetch.Tool)
	}
	save, _ := chatPartFromOC(ocToolPart(t, "agentland_memory_save", "completed", "Saved to memory.",
		map[string]any{"agentland": map[string]any{"memory": map[string]string{"id": "mem_4f2a9c1e", "text": "Prefers metric units"}}}), 0, "")
	if save.Tool.Memory == nil || *save.Tool.Memory != (ChatToolMemory{ID: "mem_4f2a9c1e", Text: "Prefers metric units"}) || save.Tool.Sources != nil {
		t.Fatalf("memory save part %+v", save.Tool)
	}
	// The part reads as HOST-API's example does.
	encoded, _ := json.Marshal(save.Tool)
	if string(encoded) != `{"name":"agentland_memory_save","callId":"call_1","status":"completed","title":"Prefers metric units","input":"{\"q\":\"x\"}","output":"Saved to memory.","truncated":false,"memory":{"id":"mem_4f2a9c1e","text":"Prefers metric units"}}` {
		t.Fatalf("encoded %s", encoded)
	}
	// A completed forget carries the entry it removed.
	forget, _ := chatPartFromOC(ocToolPart(t, "agentland_memory_forget", "completed", "Removed from memory.",
		map[string]any{"agentland": map[string]any{"memory": map[string]string{"id": "mem_1", "text": "Likes\ntea"}}}), 0, "")
	if forget.Tool.Memory == nil || *forget.Tool.Memory != (ChatToolMemory{ID: "mem_1", Text: "Likes tea"}) || forget.Tool.Title != "Likes tea" {
		t.Fatalf("memory forget part %+v", forget.Tool)
	}
	// Nothing on a part that has not completed, on a refused save or forget,
	// on another tool, or from metadata another tool wrote.
	for _, part := range []ocPart{
		ocToolPart(t, "websearch", "running", exaOutput, nil),
		ocToolPart(t, "agentland_memory_save", "error", "", nil),
		ocToolPart(t, "agentland_memory_forget", "error", "", map[string]any{"agentland": map[string]any{"memory": map[string]string{"id": "mem_1", "text": "gone"}}}),
		ocToolPart(t, "bash", "completed", exaOutput, map[string]any{"agentland": map[string]any{"source": map[string]string{"title": "x", "url": "https://x.example.com/"}}}),
		ocToolPart(t, "agentland_fetch", "completed", "", map[string]any{"agentland": map[string]any{"source": map[string]string{"title": "x", "url": "file:///etc/passwd"}}}),
	} {
		mapped, _ := chatPartFromOC(part, 0, "")
		if mapped.Tool.Sources != nil || mapped.Tool.Memory != nil {
			t.Errorf("%s (%s) carries %+v", part.Tool, part.State.Status, mapped.Tool.ChatToolResults)
		}
	}
	// Only metadata's agentland member is read: metadata of another shape,
	// or a large one, never fails the part or the transcript.
	for _, metadata := range []string{`"text"`, `[1,2]`, `null`, `7`, `{"agentland":null}`, `{"agentland":"x"}`, `{"agentland":{"memory":5}}`,
		`{"output":"` + strings.Repeat("x", 1<<20) + `","agentland":{"memory":{"id":"mem_2","text":"Kept"}}}`} {
		var part ocPart
		raw := `{"id":"prt_1","type":"tool","tool":"agentland_memory_save","callID":"c","state":{"status":"completed","output":"Saved.","metadata":` + metadata + `}}`
		if err := json.Unmarshal([]byte(raw), &part); err != nil {
			t.Fatalf("metadata %.40s failed the part: %v", metadata, err)
		}
		mapped, _ := chatPartFromOC(part, 0, "")
		want := (*ChatToolMemory)(nil)
		if strings.Contains(metadata, "mem_2") {
			want = &ChatToolMemory{ID: "mem_2", Text: "Kept"}
		}
		if !reflect.DeepEqual(mapped.Tool.Memory, want) || len(part.State.Metadata.AgentLand) > 64 {
			t.Fatalf("metadata %.40s: %+v, kept %d bytes", metadata, mapped.Tool.Memory, len(part.State.Metadata.AgentLand))
		}
	}
	// The legacy tools[] of GET /v1/messages keeps its exact shape.
	message := messageFromOC(ocMessage{Info: ocInfo{ID: "msg_1", Role: "assistant"}, Parts: []ocPart{ocToolPart(t, "websearch", "completed", exaOutput, nil)}}, "")
	legacy, _ := json.Marshal(message)
	if bytes.Contains(legacy, []byte("sources")) || len(message.Unified.Parts[0].Tool.Sources) != 2 {
		t.Fatalf("legacy %s", legacy)
	}
}

// toolMessage is an assistant message with one tool part.
func toolMessage(chatID, id string, ord int64, tool ArchiveTool) ArchiveMessage {
	message := textMessage(chatID, id, "assistant", ord, "")
	message.Parts = []ArchivePart{{ID: id + "-tool", Kind: "tool", Tool: &tool}}
	return message
}

func archivedTool(t *testing.T, archive *Archive, chatID, messageID string) *archiveToolJSON {
	t.Helper()
	page, err := archive.ChatPage(t.Context(), chatID, "", 50)
	if err != nil {
		t.Fatal(err)
	}
	for _, message := range page.Messages {
		if message.ID == messageID {
			return message.Parts[0].Tool
		}
	}
	t.Fatalf("message %s is not archived", messageID)
	return nil
}

func TestArchiveKeepsSourcesAndMemory(t *testing.T) {
	archive := testArchive(t, ArchiveOptions{})
	mustArchiveChat(t, archive, "c1", "chats", "Tides")
	sources := []ChatToolSource{{Title: "Lisbon tide table", URL: "https://tides.example.com/lisbon"}, {Title: "bad", URL: "javascript:1"}}
	mustArchiveMessage(t, archive, toolMessage("c1", "m1", 1, ArchiveTool{Name: "websearch", CallID: "call_7", Status: "completed", ChatToolResults: ChatToolResults{Sources: sources}}))
	mustArchiveMessage(t, archive, toolMessage("c1", "m2", 2, ArchiveTool{Name: "agentland_memory_save", CallID: "call_9", Status: "completed", Output: "Saved to memory.",
		ChatToolResults: ChatToolResults{Memory: &ChatToolMemory{ID: "mem_4f2a9c1e", Text: "Prefers metric units"}}}))
	flushArchive(t, archive)
	if tool := archivedTool(t, archive, "c1", "m1"); !reflect.DeepEqual(tool.Sources, sources[:1]) || tool.Memory != nil {
		t.Fatalf("search part %+v", tool)
	}
	if tool := archivedTool(t, archive, "c1", "m2"); tool.Memory == nil || tool.Memory.ID != "mem_4f2a9c1e" || tool.Sources != nil {
		t.Fatalf("memory part %+v", tool)
	}
	var export bytes.Buffer
	if err := archive.Export(t.Context(), &export, "c1", "json"); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{`"sources":[{"title":"Lisbon tide table","url":"https://tides.example.com/lisbon"}]`, `"memory":{"id":"mem_4f2a9c1e","text":"Prefers metric units"}`} {
		if !strings.Contains(export.String(), want) {
			t.Fatalf("the JSON export lacks %s:\n%s", want, export.String())
		}
	}
}

func TestArchiveMigratesAVersionFourDatabaseWithToolParts(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "state.json.archive")
	archive := openTestArchive(t, directory, ArchiveOptions{})
	mustArchiveChat(t, archive, "c1", "p1", "Before")
	old := toolMessage("c1", "m1", 1, ArchiveTool{Name: "bash", CallID: "call_1", Status: "completed", Input: `{"command":"ls"}`, Output: "notes.txt"})
	mustArchiveMessage(t, archive, old)
	flushArchive(t, archive)
	var digest string
	if err := archive.readDB.QueryRow(`SELECT digest FROM messages WHERE id = 'm1'`).Scan(&digest); err != nil {
		t.Fatal(err)
	}
	// The digest a host before plain chats (main at a943d1a) gives this
	// message: a part without sources or memory digests as it did.
	const before = "856cdb8a73b57fa05efac7cf9db95f3b4a4f8f9e1e68fdfd9717696aa5a4e435"
	if digest != before {
		t.Fatalf("digest %s, a host before plain chats wrote %s", digest, before)
	}
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	// Turn it back into a version 4 database, as a host before plain chats
	// left it.
	db, err := sql.Open("sqlite", filepath.Join(directory, "archive.db"))
	if err != nil {
		t.Fatal(err)
	}
	for _, statement := range []string{
		`ALTER TABLE parts DROP COLUMN tool_sources`,
		`ALTER TABLE parts DROP COLUMN tool_memory_id`,
		`ALTER TABLE parts DROP COLUMN tool_memory_text`,
		// Version 6 (vault).
		`DROP TABLE vault_files`,
		`DROP TABLE vault_state`,
		// Version 7 (terminal ends).
		`DROP INDEX terminal_logs_by_terminal`,
		`ALTER TABLE terminal_logs DROP COLUMN end_reason`,
		`ALTER TABLE terminal_logs DROP COLUMN ended_by_device_id`,
		`ALTER TABLE terminal_logs DROP COLUMN conversation_id`,
		// Version 8 (terminals outside any workspace).
		`ALTER TABLE terminal_logs DROP COLUMN folder`,
		`UPDATE meta SET schema_version = 4`,
	} {
		if _, err := db.Exec(statement); err != nil {
			t.Fatal(err)
		}
	}
	db.Close()
	reopened := openTestArchive(t, directory, ArchiveOptions{})
	if version := archiveCount(t, reopened, `SELECT schema_version FROM meta`); version != int64(len(archiveMigrations)) {
		t.Fatalf("schema version %d", version)
	}
	if tool := archivedTool(t, reopened, "c1", "m1"); tool.Output != "notes.txt" || tool.Sources != nil || tool.Memory != nil {
		t.Fatalf("an old part after the migration %+v", tool)
	}
	// A tool without sources or memory digests as before, so writing the
	// same message again changes nothing.
	changes := archiveCount(t, reopened, `SELECT count(*) FROM changes`)
	mustArchiveMessage(t, reopened, old)
	flushArchive(t, reopened)
	var after string
	if err := reopened.readDB.QueryRow(`SELECT digest FROM messages WHERE id = 'm1'`).Scan(&after); err != nil || after != digest {
		t.Fatalf("digest %s, was %s (%v)", after, digest, err)
	}
	if now := archiveCount(t, reopened, `SELECT count(*) FROM changes`); now != changes {
		t.Fatalf("rewriting an old message made %d changes", now-changes)
	}
	// New parts keep what plain chats add.
	mustArchiveMessage(t, reopened, toolMessage("c1", "m2", 2, ArchiveTool{Name: "agentland_fetch", CallID: "call_2", Status: "completed",
		ChatToolResults: ChatToolResults{Sources: []ChatToolSource{{Title: "Tides", URL: "https://tides.example.com/"}}}}))
	flushArchive(t, reopened)
	if tool := archivedTool(t, reopened, "c1", "m2"); len(tool.Sources) != 1 || tool.Sources[0].Title != "Tides" {
		t.Fatalf("a new part after the migration %+v", tool)
	}
}
