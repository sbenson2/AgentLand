package host

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var updateVaultGolden = flag.Bool("update-vault-golden", false, "rewrite testdata/vault from the renderer")

// The vault tests show times in a fixed zone, UTC-7, whatever the machine's.
var (
	vaultTestZone    = time.FixedZone("PDT", -7*60*60)
	vaultTestStarted = time.Date(2026, 10, 12, 21, 32, 5, 0, time.UTC) // 14:32:05 in vaultTestZone
)

func vaultAt(offset time.Duration) string {
	return archiveTimeText(vaultTestStarted.Add(offset).UnixMilli())
}

func vaultTestNames() vaultChatNames {
	return vaultChatNames{
		Base:            "Chats/AgentLand/2026-10-12 Plan the vault writer (k3f9a2)",
		FirstTitle:      "Plan the vault writer",
		ProviderName:    "Claude Code",
		WorkspaceName:   "AgentLand",
		WorkspaceFolder: "AgentLand",
		Location:        vaultTestZone,
	}
}

func vaultTestChat(title string) archiveChatJSON {
	return archiveChatJSON{ID: "ses_8f2k3f9a2c", ProjectID: "agentland-3f2a", Provider: "claude", Title: title, TitleSource: "provider",
		Model: "claude-opus-5-5", CreatedAt: vaultAt(0), UpdatedAt: vaultAt(38*time.Minute + 39*time.Second)}
}

func vaultTextMessage(id, role string, ord int64, at time.Duration, text string) archiveMessageJSON {
	return archiveMessageJSON{ID: id, ChatID: "ses_8f2k3f9a2c", Role: role, Status: "complete", Ord: ord, CreatedAt: vaultAt(at),
		Parts: []archivePartJSON{{ID: id + "-text", Kind: "text", Text: text}}}
}

// vaultFrontmatter returns a note's frontmatter lines as key and raw value.
func vaultFrontmatter(t *testing.T, text string) map[string]string {
	t.Helper()
	rest, ok := strings.CutPrefix(text, "---\n")
	block, _, closed := strings.Cut(rest, "\n---\n")
	if !ok || !closed {
		t.Fatalf("no frontmatter:\n%s", text)
	}
	fields := map[string]string{}
	for _, line := range strings.Split(block, "\n") {
		key, value, found := strings.Cut(line, ": ")
		if !found {
			t.Fatalf("frontmatter line %q", line)
		}
		fields[key] = value
	}
	return fields
}

func TestVaultChatNoteGolden(t *testing.T) {
	chat := vaultTestChat("Wire the vault status into Settings")
	chat.ParentID, chat.Relation = "ses_a9d3e1", "continue"
	image := "3fa9c1e2b7d4" + strings.Repeat("0", 52)
	messages := []archiveMessageJSON{
		{ID: "m1", ChatID: chat.ID, Role: "user", Status: "complete", Ord: 0, CreatedAt: vaultAt(0), Parts: []archivePartJSON{
			{Kind: "context", Text: "From “Fix the archive”:\n\nthe export works."},
			{Kind: "text", Text: "Show the vault's status in Settings.\n\nSay when it last wrote.\n"},
			{Kind: "attachment", Attachment: &archiveAttachmentJSON{Name: "screenshot.png", MIME: "image/png", Size: 2048, SHA256: image}},
			{Kind: "attachment", Attachment: &archiveAttachmentJSON{Name: "spec.pdf", MIME: "application/pdf", Size: 10240, SHA256: strings.Repeat("ab", 32)}},
		}},
		{ID: "m2", ChatID: chat.ID, Role: "assistant", Status: "complete", Model: "claude-opus-5-5", Ord: 1, CreatedAt: vaultAt(5 * time.Second), CompletedAt: vaultAt(40 * time.Second), Parts: []archivePartJSON{
			{Kind: "reasoning", Text: "The pane needs a status row.\n\nRun the tests first."},
			{Kind: "tool", Tool: &archiveToolJSON{Name: "Bash", Status: "completed", Title: "Run the tests", Input: "go test ./...",
				Output: "ok  \tagentland/host\t14.5s\nGITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789\n```\nnested fence\n```"}},
			{Kind: "tool", Tool: &archiveToolJSON{Name: "web_fetch", Status: "completed", Title: "Read the docs",
				ChatToolResults: ChatToolResults{Sources: []ChatToolSource{{Title: "Callouts [Obsidian]", URL: "https://help.obsidian.md/callouts"}}}}},
			{Kind: "tool", Tool: &archiveToolJSON{Name: "agentland_memory_save", Status: "completed",
				ChatToolResults: ChatToolResults{Memory: &ChatToolMemory{ID: "mem_1", Text: "Prefers Go."}}}},
			{Kind: "text", Text: "The tests pass at 364daa28c0ffee1234567890abcdef0123456789."},
			{Kind: "patch", Text: "--- a/x.go\n+++ b/x.go"},
			{Kind: "notice", Text: "Files were restored."},
		}},
		{ID: "m3", ChatID: chat.ID, Role: "user", Status: "complete", Ord: 2, CreatedAt: vaultAt(time.Minute), Hidden: true,
			Parts: []archivePartJSON{{Kind: "text", Text: "rewound question"}}},
		// The next morning.
		vaultTextMessage("m4", "user", 3, 19*time.Hour+33*time.Minute, "And on the iPhone?"),
		{ID: "m5", ChatID: chat.ID, Role: "assistant", Status: "aborted", Model: "claude-opus-5-5", Ord: 4, CreatedAt: vaultAt(19*time.Hour + 33*time.Minute + 3*time.Second),
			Error: &archiveErrorJSON{Code: "provider_error", Message: "The model is unavailable"},
			Parts: []archivePartJSON{{Kind: "text", Text: "Starting on the iPhone", Truncated: true}}},
		{ID: "m6", ChatID: chat.ID, Role: "assistant", Status: "streaming", Ord: 5, CreatedAt: vaultAt(19*time.Hour + 34*time.Minute),
			Parts: []archivePartJSON{{Kind: "text", Text: "Trying again"}}},
	}
	interactions := []archiveInteractionJSON{
		{ID: "per_1", ChatID: chat.ID, Kind: "permission", Outcome: "once", Summary: "Bash: go test ./...", CreatedAt: vaultAt(10 * time.Second)},
		{ID: "que_1", ChatID: chat.ID, Kind: "question", Summary: "Which pane?", CreatedAt: vaultAt(19*time.Hour + 35*time.Minute)},
	}
	names := vaultTestNames()
	names.ContinuedFrom = vaultLink{Path: "Chats/AgentLand/2026-10-11 Fix the archive (a9d3e1)", Title: "Fix the archive"}

	parts := renderChat(chat, messages, interactions, names)
	if len(parts) != 1 || parts[0].Part != 1 || parts[0].Path != names.Base+".md" {
		t.Fatalf("parts %+v", parts)
	}
	wantAttachments := []vaultAttachment{{SHA256: image, Size: 2048, Path: "Attachments/2026-10/3fa9c1e2b7d4-screenshot.png"}}
	if fmt.Sprint(parts[0].Attachments) != fmt.Sprint(wantAttachments) {
		t.Fatalf("attachments %+v", parts[0].Attachments)
	}
	golden := filepath.Join("testdata", "vault", "chat.md")
	if *updateVaultGolden {
		if err := os.MkdirAll(filepath.Dir(golden), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(golden, []byte(parts[0].Text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(golden)
	if err != nil {
		t.Fatal(err)
	}
	if parts[0].Text != string(want) {
		t.Fatalf("chat note:\n%s\n--- want (%s) ---\n%s", parts[0].Text, golden, want)
	}
}

func TestVaultChatSplitsAtOneMiB(t *testing.T) {
	chat, names := vaultTestChat("A long chat"), vaultTestNames()
	small := renderChat(chat, []archiveMessageJSON{vaultTextMessage("m1", "user", 0, 0, "Hello")}, nil, names)
	if len(small) != 1 || strings.Contains(small[0].Text, "\npart: ") || strings.Contains(small[0].Text, "Continued") {
		t.Fatalf("a short chat:\n%s", small[0].Text)
	}

	// About 100 KiB each: two full parts of 11 messages and a third of one.
	paragraph := strings.Repeat("All work and no play makes a dull note. ", 2600)
	var messages []archiveMessageJSON
	for index := range 23 {
		role := []string{"user", "assistant"}[index%2]
		messages = append(messages, vaultTextMessage(fmt.Sprintf("m%02d", index), role, int64(index), time.Duration(index)*time.Minute,
			fmt.Sprintf("Message %02d. %s", index, paragraph)))
	}
	parts := renderChat(chat, messages, nil, names)
	if len(parts) != 3 {
		t.Fatalf("%d parts", len(parts))
	}
	next := 0
	for index, part := range parts {
		number := index + 1
		if part.Part != number || part.Path != vaultPartBase(names.Base, number)+".md" {
			t.Fatalf("part %d is %d at %q", number, part.Part, part.Path)
		}
		fields := vaultFrontmatter(t, part.Text)
		if fields["part"] != fmt.Sprint(number) || fields["parts"] != "3" {
			t.Fatalf("part %d frontmatter %v", number, fields)
		}
		if number > 1 && !strings.Contains(part.Text, "\n# A long chat (part "+fmt.Sprint(number)+")\n") {
			t.Fatalf("part %d heading", number)
		}
		previous := "Continued from [[" + vaultPartBase(names.Base, number-1) + "|part " + fmt.Sprint(number-1) + "]]"
		if strings.Contains(part.Text, previous) != (number > 1) {
			t.Fatalf("part %d link back", number)
		}
		following := "Continued in [[" + vaultPartBase(names.Base, number+1) + "|part " + fmt.Sprint(number+1) + "]]"
		if strings.Contains(part.Text, following) != (number < 3) {
			t.Fatalf("part %d link on", number)
		}
		// A part ends at the first message boundary past 1 MiB.
		if number < 3 && (len(part.Text) < vaultPartLimit || len(part.Text) > vaultPartLimit+len(paragraph)+4096) {
			t.Fatalf("part %d is %d bytes", number, len(part.Text))
		}
		// Every message is whole, once, in order.
		for next < len(messages) && strings.Contains(part.Text, fmt.Sprintf("Message %02d. ", next)) {
			if strings.Count(part.Text, fmt.Sprintf("Message %02d. %s", next, paragraph)) != 1 {
				t.Fatalf("message %d is not whole in part %d", next, number)
			}
			next++
		}
	}
	if next != len(messages) {
		t.Fatalf("parts hold %d of %d messages in order", next, len(messages))
	}
}

func TestVaultFrontmatterQuotesTitles(t *testing.T) {
	for _, title := range []string{`He said "hi": #1 [[x]] | y`, "- leading dash", "'single'", `back\slash`, "yes", "123", "null", "🎪 circus", ""} {
		names := vaultTestNames()
		names.WorkspaceName = "Team | Q4 [plans]"
		names.FirstTitle = "First: one"
		parts := renderChat(vaultTestChat(title), []archiveMessageJSON{vaultTextMessage("m1", "user", 0, 0, "Hello")}, nil, names)
		fields := vaultFrontmatter(t, parts[0].Text)
		for key, value := range fields {
			if !json.Valid([]byte(value)) {
				t.Fatalf("%s: %s is not quoted: %s", title, key, value)
			}
		}
		want := title
		if want == "" {
			want = "Untitled chat"
		}
		var got string
		var aliases []string
		json.Unmarshal([]byte(fields["title"]), &got)
		json.Unmarshal([]byte(fields["aliases"]), &aliases)
		if got != want || fmt.Sprint(aliases) != fmt.Sprint([]string{"First: one", want}) {
			t.Fatalf("title %q aliases %q, want %q", got, aliases, want)
		}
		if !strings.Contains(parts[0].Text, "\n---\n# "+want+"\n") {
			t.Fatalf("heading for %q:\n%s", title, parts[0].Text)
		}
		var workspace string
		json.Unmarshal([]byte(fields["workspace"]), &workspace)
		if workspace != "[[Workspaces/AgentLand|Team Q4 plans]]" {
			t.Fatalf("workspace link %q", workspace)
		}
	}
	// One alias when the title never changed.
	parts := renderChat(vaultTestChat("Plan the vault writer"), nil, nil, vaultTestNames())
	if fields := vaultFrontmatter(t, parts[0].Text); fields["aliases"] != `["Plan the vault writer"]` {
		t.Fatalf("aliases %s", fields["aliases"])
	}
}

func TestVaultToolTextIsCappedAndMasked(t *testing.T) {
	message := archiveMessageJSON{ID: "m1", ChatID: "ses_8f2k3f9a2c", Role: "assistant", Status: "complete", Ord: 0, CreatedAt: vaultAt(0),
		Parts: []archivePartJSON{
			{Kind: "reasoning", Text: "The password: hunter2 is in the log."},
			{Kind: "tool", Tool: &archiveToolJSON{Name: "Bash", Status: "completed", Title: "Use token ghp_abcdefghijklmnopqrstuvwxyz0123456789",
				Input:  strings.Repeat("x", 40<<10),
				Output: "password: hunter2\ncommit 364daa28c0ffee1234567890abcdef0123456789\n",
				Error:  "key sk-proj-abcdefghijklmnopqrstuvwx", Truncated: true}},
			{Kind: "text", Text: "Your key is sk-proj-abcdefghijklmnopqrstuvwx."},
		}}
	text := renderChat(vaultTestChat("Masking"), []archiveMessageJSON{message}, nil, vaultTestNames())[0].Text
	for _, secret := range []string{"hunter2", "sk-proj", "ghp_"} {
		if strings.Contains(text, secret) {
			t.Fatalf("%s in the note:\n%s", secret, text)
		}
	}
	if !strings.Contains(text, "364daa28c0ffee1234567890abcdef0123456789") {
		t.Fatal("the commit was masked")
	}
	if count := strings.Count(text, "x"); count > vaultToolFieldLimit+200 || count < vaultToolFieldLimit-200 {
		t.Fatalf("%d bytes of a 40 KiB input", count)
	}
	for _, notice := range []string{vaultToolCapped, archiveToolShortened} {
		if !strings.Contains(text, notice) {
			t.Fatalf("no %q:\n%s", notice, text[len(text)-2000:])
		}
	}
	if !strings.Contains(text, "\n> [!tool]- Bash · completed — Use token …\n") {
		t.Fatalf("tool callout:\n%s", text[:2000])
	}
}

func TestVaultAttachmentEmbeds(t *testing.T) {
	shot, big, pdf, gif := strings.Repeat("a1", 32), strings.Repeat("b2", 32), strings.Repeat("c3", 32), strings.Repeat("d4", 32)
	// 22:00 on October 31 in vaultTestZone, already November in UTC.
	at := time.Date(2026, 11, 1, 5, 0, 0, 0, time.UTC).Sub(vaultTestStarted)
	attachment := func(name, mime string, size int64, sum string) archivePartJSON {
		return archivePartJSON{Kind: "attachment", Attachment: &archiveAttachmentJSON{Name: name, MIME: mime, Size: size, SHA256: sum}}
	}
	messages := []archiveMessageJSON{
		{ID: "m1", ChatID: "ses_8f2k3f9a2c", Role: "user", Status: "complete", Ord: 0, CreatedAt: vaultAt(at), Parts: []archivePartJSON{
			attachment("my [shot]|1.png", "image/png", 2048, shot),
			attachment("big.jpg", "image/jpeg", 20<<20, big),
			attachment("unstored.png", "image/png", 10, ""),
			attachment("spec.pdf", "application/pdf", 4096, pdf),
			attachment("", "image/gif; x=y", 64, gif),
			attachment("photo.heic", "image/heic", 64, strings.Repeat("e5", 32)),
		}},
		{ID: "m2", ChatID: "ses_8f2k3f9a2c", Role: "user", Status: "complete", Ord: 1, CreatedAt: vaultAt(at + time.Minute), Parts: []archivePartJSON{
			attachment("my [shot]|1.png", "image/png", 2048, shot),
		}},
	}
	part := renderChat(vaultTestChat("Pictures"), messages, nil, vaultTestNames())[0]
	shotPath := "Attachments/2026-10/" + shot[:12] + "-my shot 1.png"
	gifPath := "Attachments/2026-10/" + gif[:12] + "-image.gif"
	if strings.Count(part.Text, "\n![["+shotPath+"]]\n") != 2 || !strings.Contains(part.Text, "\n![["+gifPath+"]]\n") {
		t.Fatalf("embeds:\n%s", part.Text)
	}
	for _, listed := range []string{"**Attachment:** big.jpg (image/jpeg, 20971520 bytes)", "**Attachment:** unstored.png (image/png, 10 bytes)",
		"**Attachment:** spec.pdf (application/pdf, 4096 bytes)", "**Attachment:** photo.heic (image/heic, 64 bytes)"} {
		if !strings.Contains(part.Text, "\n"+listed+"\n") {
			t.Fatalf("%q not listed:\n%s", listed, part.Text)
		}
	}
	want := []vaultAttachment{{SHA256: shot, Size: 2048, Path: shotPath}, {SHA256: gif, Size: 64, Path: gifPath}}
	if fmt.Sprint(part.Attachments) != fmt.Sprint(want) {
		t.Fatalf("copies %+v", part.Attachments)
	}
}
