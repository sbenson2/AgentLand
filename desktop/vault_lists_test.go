package host

import (
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// settle runs passes a hub period apart until every note is written, the
// hubs list them and nothing waits.
func (f *vaultFixture) settle(w *vaultWriter) {
	f.t.Helper()
	for range 100 {
		f.advance(vaultHubEvery)
		if next := f.pass(w); next.IsZero() && w.status().State == "current" {
			return
		}
	}
	f.t.Fatalf("the vault did not settle: %+v", w.status())
}

// setClock moves the fixture's clock (and its archive's) to a time.
func (f *vaultFixture) setClock(at time.Time) {
	f.mu.Lock()
	f.clock = at
	f.mu.Unlock()
}

// vaultTestChatAt archives a chat with one message, started at a time.
func vaultTestChatAt(t *testing.T, archive *Archive, id, project, provider, title string, started time.Time) {
	t.Helper()
	if err := archive.UpsertChat(ArchiveChat{ID: id, ProjectID: project, Provider: provider, Title: title, CreatedAt: started}); err != nil {
		t.Fatal(err)
	}
	message := textMessage(id, id+"-m1", "user", 1, "hello")
	message.CreatedAt = started
	mustArchiveMessage(t, archive, message)
}

// vaultTestTerminal records a terminal's output; one with a status has ended.
func vaultTestTerminal(t *testing.T, archive *Archive, project, title, program string, started time.Time, output, status string) *TerminalLog {
	t.Helper()
	log, err := archive.OpenTerminalLog(TerminalLogInfo{ProjectID: project, Title: title, Program: program, StartedAt: started})
	if err != nil {
		t.Fatal(err)
	}
	log.Append([]byte(output))
	if status != "" {
		code := 0
		log.Close(status, &code)
	}
	return log
}

// vaultChatBase and vaultTerminalBase are where the vault names a chat's and
// a terminal's note, without ".md".
func vaultChatBase(folder, id, title string, started time.Time) string {
	return "Chats/" + folder + "/" + vaultNoteBase(started.In(vaultTestZone), title, id, vaultShortIDLength)
}

func vaultTerminalBase(folder, id, program string, started time.Time) string {
	local := started.In(vaultTestZone)
	return "Terminals/" + folder + "/" + vaultNoteBase(local, local.Format("1504")+" "+program, id, vaultShortIDLength)
}

// vaultHead is a note's text above its marker.
func vaultHead(t *testing.T, text string) string {
	t.Helper()
	head, _, found := strings.Cut(text, "\n"+vaultEndMarker+"\n")
	if !found {
		t.Fatalf("no marker:\n%s", text)
	}
	return head
}

// Terminals outside any workspace (routed agents typed in Terminal in a
// folder no workspace holds) go under a readable name, not their archive ID
// (Ruling 52): the hub Workspaces/Outside Workspaces.md and the folder
// Terminals/Outside Workspaces/.
func TestVaultNamesTerminalsOutsideWorkspaces(t *testing.T) {
	f := newVaultFixture(t)
	terminal := vaultTestTerminal(t, f.archive, terminalNoWorkspaceArchiveID, "Claude Code", "claude", archiveTestStart, "hi\r\n", "exited")
	w := f.writer()
	w.workspaces = func() map[string]string { return map[string]string{"p1": "AgentLand"} }
	f.settle(w)
	note := vaultTerminalBase("Outside Workspaces", terminal.ID(), "claude", archiveTestStart)
	if notes := f.notesIn("Terminals/"); !slices.Equal(notes, []string{note + ".md"}) {
		t.Fatalf("terminal notes %q, want %q", notes, note+".md")
	}
	hub := vaultHead(t, f.read("Workspaces/Outside Workspaces.md"))
	for _, part := range []string{`title: "Outside Workspaces"`, "# Outside Workspaces\n", "[[" + note + "|Claude Code]]"} {
		if !strings.Contains(hub, part) {
			t.Fatalf("the hub lacks %q:\n%s", part, hub)
		}
	}
	for _, path := range f.notes() {
		if strings.Contains(path, terminalNoWorkspaceArchiveID) {
			t.Fatalf("a note named by the archive ID: %s", path)
		}
	}
}

func TestVaultHubsGroupBothWays(t *testing.T) {
	f := newVaultFixture(t)
	at := func(hours int) time.Time { return archiveTestStart.Add(time.Duration(hours) * time.Hour) }
	vaultTestChatAt(t, f.archive, "c1", "p1", "opencode", "Fix the build", at(0))
	vaultTestChatAt(t, f.archive, "c2", "p1", "claude", "Plan the vault", at(1))
	vaultTestChatAt(t, f.archive, "c3", "p2", "claude", "Landing page", at(2))
	vaultTestChatAt(t, f.archive, "c4", plainChatsProjectID, "codex", "Weekend trip", at(3))
	vaultTestChatAt(t, f.archive, "c5", "p1", "claude", "Review the diff", at(4))
	terminal := vaultTestTerminal(t, f.archive, "p1", "Build", "shell", at(5), "make\r\n", "exited")
	names := map[string]string{"p1": "AgentLand", "p2": "Website"}
	w := f.writer()
	w.workspaces = func() map[string]string { return maps.Clone(names) }
	f.settle(w)

	c1, c2 := vaultChatBase("AgentLand", "c1", "Fix the build", at(0)), vaultChatBase("AgentLand", "c2", "Plan the vault", at(1))
	c3, c4 := vaultChatBase("Website", "c3", "Landing page", at(2)), vaultChatBase("General", "c4", "Weekend trip", at(3))
	c5, t1 := vaultChatBase("AgentLand", "c5", "Review the diff", at(4)), vaultTerminalBase("AgentLand", terminal.ID(), "shell", at(5))
	want := `---
agentland-id: "workspace/p1"
type: "workspace"
title: "AgentLand"
aliases: ["AgentLand"]
workspace-id: "p1"
tags: ["agentland/hub"]
---
# AgentLand

## Chats

### [[Providers/Claude Code|Claude Code]]

- [[` + c5 + `|Review the diff]] · 2026-09-23
- [[` + c2 + `|Plan the vault]] · 2026-09-23

### [[Providers/OpenCode|OpenCode]]

- [[` + c1 + `|Fix the build]] · 2026-09-23

## Terminals

- [[` + t1 + `|Build]] · 2026-09-23 10:00
`
	if head := vaultHead(t, f.read("Workspaces/AgentLand.md")); head != want {
		t.Fatalf("workspace hub\n%s\nwant\n%s", head, want)
	}
	claude := f.read("Providers/Claude Code.md")
	for _, part := range []string{
		"agentland-id: \"provider/claude\"\ntype: \"provider\"\ntitle: \"Claude Code\"\nprovider: \"claude\"\n",
		"# Claude Code\n\n## [[Workspaces/AgentLand|AgentLand]]\n\n- [[" + c5 + "|Review the diff]] · 2026-09-23\n- [[" + c2 + "|Plan the vault]] · 2026-09-23\n\n## [[Workspaces/Website|Website]]\n\n- [[" + c3 + "|Landing page]] · 2026-09-23\n",
	} {
		if !strings.Contains(claude, part) {
			t.Fatalf("Claude Code's hub lacks %q:\n%s", part, claude)
		}
	}
	if general := f.read("Workspaces/General.md"); !strings.Contains(general, "### [[Providers/Codex|Codex]]\n\n- [["+c4+"|Weekend trip]]") {
		t.Fatalf("General's hub\n%s", general)
	}
	if codex := f.read("Providers/Codex.md"); !strings.Contains(codex, "## [[Workspaces/General|General]]\n\n- [["+c4+"|Weekend trip]]") {
		t.Fatalf("Codex's hub\n%s", codex)
	}
	if opencode := f.read("Providers/OpenCode.md"); strings.Contains(opencode, "Build") {
		t.Fatalf("a terminal is listed under a provider\n%s", opencode)
	}

	// The workspace and a chat are renamed: the hub keeps its name, takes the
	// new title and keeps the first as an alias; the links show the new
	// titles.
	names["p1"] = "AgentLand App"
	if err := f.archive.UpsertChat(ArchiveChat{ID: "c2", ProjectID: "p1", Provider: "claude", Title: "Plan the vault writer"}); err != nil {
		t.Fatal(err)
	}
	f.settle(w)
	hub := f.read("Workspaces/AgentLand.md")
	fields := vaultFrontmatter(t, hub)
	if fields["title"] != `"AgentLand App"` || fields["aliases"] != `["AgentLand","AgentLand App"]` || !strings.Contains(hub, "\n# AgentLand App\n") ||
		!strings.Contains(hub, "- [["+c2+"|Plan the vault writer]]") {
		t.Fatalf("renamed hub\n%s", hub)
	}
	if claude := f.read("Providers/Claude Code.md"); !strings.Contains(claude, "## [[Workspaces/AgentLand|AgentLand App]]") {
		t.Fatalf("provider hub after the rename\n%s", claude)
	}
	if hubs := f.notesIn("Workspaces/"); len(hubs) != 3 {
		t.Fatalf("workspace hubs %v", hubs)
	}

	// A reply changes no hub, so none is written again.
	f.forget()
	mustArchiveMessage(t, f.archive, textMessage("c1", "c1-m2", "assistant", 2, "Fixed."))
	f.settle(w)
	if count := f.files(); count != 1 || f.writes[c1+".md"] != 1 {
		t.Fatalf("writes after a reply: %v", f.writes)
	}

	// A new title is listed at most 30 s after the hubs were last written.
	if err := f.archive.UpsertChat(ArchiveChat{ID: "c1", ProjectID: "p1", Provider: "opencode", Title: "Fix the release build"}); err != nil {
		t.Fatal(err)
	}
	f.advance(vaultChatEvery)
	next := f.pass(w)
	if f.writes[c1+".md"] != 2 || f.writes["Workspaces/AgentLand.md"] != 0 || !next.Equal(w.listsAt) {
		t.Fatalf("writes %v, next pass at %v (hubs at %v)", f.writes, next, w.listsAt)
	}
	f.advance(next.Sub(f.now()))
	f.pass(w)
	if hub := f.read("Workspaces/AgentLand.md"); f.writes["Workspaces/AgentLand.md"] != 1 || !strings.Contains(hub, "|Fix the release build]]") {
		t.Fatalf("hub after the new title (%d writes)\n%s", f.writes["Workspaces/AgentLand.md"], hub)
	}
}

func TestVaultDailyNote(t *testing.T) {
	f := newVaultFixture(t)
	utc := func(day, hour, minute int) time.Time { return time.Date(2026, 10, day, hour, minute, 0, 0, time.UTC) }
	// 09:00 to 10:30 on Oct 12, in UTC-7.
	f.setClock(utc(12, 17, 30))
	terminal := vaultTestTerminal(t, f.archive, "p1", "Build", "shell", utc(12, 16, 0), "make\r\n", "exited")
	vaultTestChatAt(t, f.archive, "today", "p1", "opencode", "Tide tables", utc(12, 17, 0))
	vaultTestChatAt(t, f.archive, "earlier", plainChatsProjectID, "claude", "Weekend trip", utc(11, 20, 0))
	if err := f.archive.UpsertChat(ArchiveChat{ID: "earlier", ProjectID: plainChatsProjectID, Provider: "claude", UpdatedAt: utc(12, 19, 0)}); err != nil {
		t.Fatal(err)
	}
	// 23:30 on Oct 10 there, though Oct 11 in UTC.
	vaultTestChatAt(t, f.archive, "late", "p1", "codex", "Late idea", utc(11, 6, 30))
	w := f.writer()
	f.settle(w)

	earlier := vaultChatBase("General", "earlier", "Weekend trip", utc(11, 20, 0))
	want := `---
agentland-id: "daily/2026-10-12"
type: "daily"
date: "2026-10-12"
tags: ["agentland/daily"]
---
# 2026-10-12

## Started

- 09:00 [[` + vaultTerminalBase("AgentLand", terminal.ID(), "shell", utc(12, 16, 0)) + `|Build]] · Terminal · AgentLand
- 10:00 [[` + vaultChatBase("AgentLand", "today", "Tide tables", utc(12, 17, 0)) + `|Tide tables]] · OpenCode · AgentLand

## Last active

- [[` + earlier + `|Weekend trip]] · Claude Code · General · started 2026-10-11
`
	if head := vaultHead(t, f.read("Daily/2026-10-12.md")); head != want {
		t.Fatalf("Daily note\n%s\nwant\n%s", head, want)
	}
	if day := f.read("Daily/2026-10-11.md"); !strings.Contains(day, "## Started\n\n- 13:00 [["+earlier+"|Weekend trip]]") || strings.Contains(day, "Last active") {
		t.Fatalf("Oct 11\n%s", day)
	}
	if day := f.read("Daily/2026-10-10.md"); !strings.Contains(day, "- 23:30 [["+vaultChatBase("AgentLand", "late", "Late idea", utc(11, 6, 30))+"|Late idea]] · Codex · AgentLand") {
		t.Fatalf("Oct 10\n%s", day)
	}
	if days := f.notesIn("Daily/"); len(days) != 3 {
		t.Fatalf("Daily notes %v", days)
	}

	// The chat is active again on Oct 13: it moves there.
	if err := f.archive.UpsertChat(ArchiveChat{ID: "earlier", ProjectID: plainChatsProjectID, Provider: "claude", UpdatedAt: utc(13, 16, 0)}); err != nil {
		t.Fatal(err)
	}
	f.settle(w)
	if day := f.read("Daily/2026-10-12.md"); strings.Contains(day, "Weekend trip") || !strings.Contains(day, "Tide tables") {
		t.Fatalf("Oct 12 after the chat moved on\n%s", day)
	}
	if day := f.read("Daily/2026-10-13.md"); !strings.Contains(day, "## Last active\n\n- [["+earlier+"|Weekend trip]] · Claude Code · General · started 2026-10-11\n") || strings.Contains(day, "## Started") {
		t.Fatalf("Oct 13\n%s", day)
	}
}

func TestVaultDeletedChatPolicy(t *testing.T) {
	f := newVaultFixture(t)
	vaultTestChatAt(t, f.archive, "c1", "p1", "opencode", "Keep me", archiveTestStart)
	terminal := vaultTestTerminal(t, f.archive, "p1", "Build", "shell", archiveTestStart, "make\r\n", "exited")
	w := f.writer()
	f.settle(w)
	chat, log := vaultChatBase("AgentLand", "c1", "Keep me", archiveTestStart)+".md", vaultTerminalBase("AgentLand", terminal.ID(), "shell", archiveTestStart)+".md"
	full := filepath.Join(f.folder, filepath.FromSlash(chat))
	if err := os.WriteFile(full, []byte(f.read(chat)+"My notes on it.\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	kept := map[string]string{chat: f.read(chat), log: f.read(log)}
	modified := map[string]time.Time{chat: f.modified(chat), log: f.modified(log)}

	// Both are deleted in AgentLand.
	if err := f.archive.DeleteChat("c1"); err != nil {
		t.Fatal(err)
	}
	if err := f.archive.DeleteTerminalLog(terminal.ID()); err != nil {
		t.Fatal(err)
	}
	f.forget()
	f.settle(w)
	f.settle(w)
	for path, text := range kept {
		if f.read(path) != text || !f.modified(path).Equal(modified[path]) || f.writes[path] != 0 {
			t.Fatalf("%s changed after its deletion:\n%s", path, f.read(path))
		}
	}
	// They stay listed, as the vault holds them.
	hub := f.read("Workspaces/AgentLand.md")
	day := f.read("Daily/2026-09-23.md")
	for _, base := range []string{strings.TrimSuffix(chat, ".md"), strings.TrimSuffix(log, ".md")} {
		if !strings.Contains(hub, "[["+base+"|") || !strings.Contains(day, "[["+base+"|") {
			t.Fatalf("%s is no longer listed:\n%s\n%s", base, hub, day)
		}
	}
	if count := f.files(); count != 0 {
		t.Fatalf("files written after the deletions: %v", f.writes)
	}
	for _, key := range []vaultFileKey{{Entity: "chat", EntityID: "c1", Part: 1}, {Entity: "terminalLog", EntityID: terminal.ID(), Part: 1}} {
		if _, err := f.archive.vaultFile(t.Context(), "v1", key); err != nil {
			t.Fatalf("record of %v: %v", key, err)
		}
	}
	if status := w.status(); status.Notes != 2 || status.State != "current" {
		t.Fatalf("status %+v", status)
	}
}
