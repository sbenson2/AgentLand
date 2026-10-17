package host

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// Plain chats (docs/HOST-API.md "Plain chats"): the shared types encode as the
// document's examples, byte for byte once compacted, and the examples decode
// back to the same values with no member the types lack. The examples are
// copied from the document as it prints them, and each is checked to still be
// there, so the types and the document cannot drift apart.

// plainChatToolPart is a tool part as HOST-API prints it: ChatTool with the
// members plain chats add.
type plainChatToolPart struct {
	ChatTool
	ChatToolResults
}

// plainChatExample checks that example appears word for word in
// docs/HOST-API.md.
func plainChatExample(t *testing.T, example string) {
	t.Helper()
	doc, err := os.ReadFile(filepath.Join("..", "docs", "HOST-API.md"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(doc), example) {
		t.Fatalf("docs/HOST-API.md no longer prints this example:\n%s", example)
	}
}

// plainChatRoundTrip checks that value encodes as want exactly (compacted)
// and that want decodes back to value, refusing members the type lacks.
func plainChatRoundTrip[T any](t *testing.T, value T, want string) {
	t.Helper()
	var compact bytes.Buffer
	if err := json.Compact(&compact, []byte(want)); err != nil {
		t.Fatalf("not JSON: %v\n%s", err, want)
	}
	got, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != compact.String() {
		t.Fatalf("encoded\n%s\nwant\n%s", got, compact.String())
	}
	var back T
	decoder := json.NewDecoder(strings.NewReader(want))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&back); err != nil {
		t.Fatalf("decoding the example: %v", err)
	}
	if !reflect.DeepEqual(back, value) {
		t.Fatalf("decoded %+v\nwant %+v", back, value)
	}
}

func TestPlainChatCapabilityMatchesHostAPI(t *testing.T) {
	const example = `{"projectId": "chats", "tools": ["websearch", "fetch", "memory"],
               "searchProvider": "exa", "instructionFiles": ["~/AGENTS.md"]}`
	plainChatExample(t, example)
	plainChatRoundTrip(t, plainChatsCapability{
		ProjectID:        plainChatsProjectID,
		Tools:            []string{plainChatToolWebsearch, plainChatToolFetch, plainChatToolMemory},
		SearchProvider:   plainChatSearchExa,
		InstructionFiles: []string{"~/AGENTS.md"},
	}, example)

	// No tools working and no instruction files: tools stays a list, and
	// searchProvider and instructionFiles are left out.
	plainChatRoundTrip(t, plainChatsCapability{ProjectID: plainChatsProjectID, Tools: []string{}},
		`{"projectId":"chats","tools":[]}`)
}

func TestPlainChatToolPartsMatchHostAPI(t *testing.T) {
	const search = `{"name": "websearch", "callId": "call_7", "status": "completed", "title": "tide times lisbon",
 "input": "{\"query\":\"tide times lisbon\"}", "truncated": false,
 "sources": [{"title": "Lisbon tide table", "url": "https://tides.example.com/lisbon"},
             {"title": "example.org", "url": "https://example.org/tides"}]}`
	plainChatExample(t, search)
	plainChatRoundTrip(t, plainChatToolPart{
		ChatTool: ChatTool{Name: chatToolWebsearch, CallID: "call_7", Status: "completed", Title: "tide times lisbon",
			Input: `{"query":"tide times lisbon"}`},
		ChatToolResults: ChatToolResults{Sources: []ChatToolSource{
			{Title: "Lisbon tide table", URL: "https://tides.example.com/lisbon"},
			{Title: "example.org", URL: "https://example.org/tides"},
		}},
	}, search)

	const save = `{"name": "agentland_memory_save", "callId": "call_9", "status": "completed",
 "title": "Prefers metric units", "input": "{\"text\":\"Prefers metric units\"}",
 "output": "Saved to memory.", "truncated": false,
 "memory": {"id": "mem_4f2a9c1e", "text": "Prefers metric units"}}`
	plainChatExample(t, save)
	plainChatRoundTrip(t, plainChatToolPart{
		ChatTool: ChatTool{Name: chatToolMemorySave, CallID: "call_9", Status: "completed", Title: "Prefers metric units",
			Input: `{"text":"Prefers metric units"}`, Output: "Saved to memory."},
		ChatToolResults: ChatToolResults{Memory: &ChatToolMemory{ID: "mem_4f2a9c1e", Text: "Prefers metric units"}},
	}, save)

	// A tool part without sources or memory encodes exactly as before.
	plain := ChatTool{Name: "bash", CallID: "call_1", Status: "running", Input: `{"command":"ls"}`}
	before, err := json.Marshal(plain)
	if err != nil {
		t.Fatal(err)
	}
	plainChatRoundTrip(t, plainChatToolPart{ChatTool: plain}, string(before))
}

func TestPlainChatMemoryRoutesMatchHostAPI(t *testing.T) {
	entry := memoryEntry{ID: "mem_4f2a9c1e", Text: "Prefers metric units",
		CreatedAt: "2026-09-27T18:04:11.000Z", UpdatedAt: "2026-09-27T18:04:11.000Z"}
	limits := memoryLimits{MaxEntries: memoryMaxEntries, MaxTotalChars: memoryMaxTotalChars}

	// GET /v1/memory.
	const list = `{"enabled": true,
 "entries": [{"id": "mem_4f2a9c1e", "text": "Prefers metric units",
              "createdAt": "2026-09-27T18:04:11.000Z", "updatedAt": "2026-09-27T18:04:11.000Z"}],
 "limits": {"maxEntries": 50, "maxTotalChars": 2000}}`
	plainChatExample(t, list)
	plainChatRoundTrip(t, memoryList{Enabled: true, Entries: []memoryEntry{entry}, Limits: limits}, list)
	plainChatRoundTrip(t, memoryList{Entries: []memoryEntry{}, Limits: limits},
		`{"enabled":false,"entries":[],"limits":{"maxEntries":50,"maxTotalChars":2000}}`)

	// PATCH /v1/memory: {id, text} → the entry.
	id, text := "mem_4f2a9c1e", "Prefers metric units, except for cooking"
	plainChatRoundTrip(t, memoryUpdateInput{ID: &id, Text: &text},
		`{"id":"mem_4f2a9c1e","text":"Prefers metric units, except for cooking"}`)
	plainChatRoundTrip(t, entry,
		`{"id":"mem_4f2a9c1e","text":"Prefers metric units","createdAt":"2026-09-27T18:04:11.000Z","updatedAt":"2026-09-27T18:04:11.000Z"}`)

	// DELETE /v1/memory?id= → {removed: true}.
	plainChatRoundTrip(t, memoryRemoved{Removed: true}, `{"removed":true}`)

	// POST /v1/memory/settings: {enabled} → {enabled}.
	off := false
	plainChatRoundTrip(t, memorySettingsInput{Enabled: &off}, `{"enabled":false}`)
	plainChatRoundTrip(t, memorySettings{Enabled: false}, `{"enabled":false}`)

	// A missing member stays nil, so the route can answer 400 invalid_request.
	var update memoryUpdateInput
	var settings memorySettingsInput
	if err := json.Unmarshal([]byte(`{}`), &update); err != nil || update.ID != nil || update.Text != nil {
		t.Fatalf("an empty PATCH body reads %+v (%v)", update, err)
	}
	if err := json.Unmarshal([]byte(`{}`), &settings); err != nil || settings.Enabled != nil {
		t.Fatalf("an empty settings body reads %+v (%v)", settings, err)
	}
}
