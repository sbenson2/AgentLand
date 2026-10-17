package host

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"maps"
	"path"
	"slices"
	"strings"
	"time"
)

// Hubs, Daily notes and the README, which the writer brings up to date after
// each pass's notes (writeLists). They list what the vault holds, from its
// records (vault_files' listings), so a note stays listed after its chat or
// terminal is deleted in AgentLand:
//
//   - Workspaces/<folder>.md: a workspace's chats grouped by provider, then
//     its terminals, newest first. Its name is fixed when the vault first
//     sees the workspace (it is the workspace's folder under Chats/); a
//     rename changes its title and aliases.
//   - Providers/<name>.md: a provider's chats grouped by workspace.
//   - Daily/YYYY-MM-DD.md: the chats and terminals started that day, and
//     those last active that day that started on an earlier one.
//   - README.md: what the folder is, written once.
//
// They are rendered again when a note's listing or a workspace's name
// changed, at most every 30 s, and written only when their text changed.

const vaultReadmePath = "README.md"

// vaultListed is a note as the hubs list it.
type vaultListed struct {
	entity string // chat or terminalLog
	base   string // its path without ".md"
	vaultListing
}

// writeLists writes the hubs, the Daily notes and the README when what they
// list may have changed and they are due. It returns when they are due again
// with something to write.
func (w *vaultWriter) writeLists(ctx context.Context, now time.Time, batch *vaultBatch) (time.Time, error) {
	names := w.workspaceNames(batch)
	if batch.listed || !maps.Equal(names, w.listNames) {
		w.listsDirty = true
	}
	if !w.listsDirty {
		return time.Time{}, nil
	}
	if w.listsAt.After(now) {
		return w.listsAt, nil
	}
	if w.busy() {
		// Like the backfill, they wait while a chat runs a turn.
		return now.Add(w.pausePoll), nil
	}
	w.listsAt = now.Add(w.hubEvery)
	again, err := w.renderLists(ctx, now, names, batch)
	if err != nil || again {
		return w.listsAt, err
	}
	batch.lists = true
	return time.Time{}, nil
}

// renderLists renders every hub and Daily note, and the README if the vault
// never wrote it, from the vault's records and this pass's, and writes those
// whose text changed. It reports whether one has to be written again later.
func (w *vaultWriter) renderLists(ctx context.Context, now time.Time, names map[string]string, batch *vaultBatch) (bool, error) {
	recorded, err := w.archive.vaultFiles(ctx, w.vaultID, "chat", "terminalLog", "workspace", "provider", "daily", "readme")
	if err != nil {
		return false, err
	}
	latest := map[vaultFileKey]vaultFileRecord{}
	for _, file := range recorded {
		latest[file.vaultFileKey] = file
	}
	for _, file := range batch.files {
		if file.Part == 1 && file.Entity != "attachment" {
			latest[file.vaultFileKey] = file
		}
	}
	location := w.location
	if location == nil {
		location = time.Local
	}

	listed := []vaultListed{}
	spaces := map[string]vaultWorkspace{}
	providers := map[string]string{} // hub paths by provider
	days := map[string]bool{}
	for key, file := range latest {
		switch key.Entity {
		case "chat", "terminalLog":
			if file.Listing.Started != "" {
				listed = append(listed, vaultListed{entity: key.Entity, base: strings.TrimSuffix(file.Path, ".md"), vaultListing: file.Listing})
				if key.Entity == "chat" && file.Listing.Provider != "" {
					providers[file.Listing.Provider] = ""
				}
			}
		case "workspace":
			folder := strings.TrimSuffix(path.Base(file.Path), ".md")
			name := names[key.EntityID]
			if space := vaultSpaceName(key.EntityID); space != "" {
				name = space
			}
			for _, fallback := range []string{file.FirstTitle, folder} {
				if vaultLine(name) == "" {
					name = fallback
				}
			}
			spaces[key.EntityID] = vaultWorkspace{name: vaultLine(name), folder: folder}
		case "provider":
			providers[key.EntityID] = ""
		case "daily":
			days[key.EntityID] = true
		}
	}
	// Newest first; the Daily notes list them oldest first.
	slices.SortFunc(listed, func(a, b vaultListed) int {
		return cmp.Or(cmp.Compare(b.Started, a.Started), cmp.Compare(a.base, b.base))
	})

	// Each provider's hub path, recorded or new.
	for _, provider := range slices.Sorted(maps.Keys(providers)) {
		key := vaultFileKey{Entity: "provider", EntityID: provider, Part: 1}
		if file, found := latest[key]; found {
			providers[provider] = file.Path
			continue
		}
		name := vaultSafeName(vaultProviderName(provider))
		if name == "" {
			name = "Provider"
		}
		for _, hub := range []string{"Providers/" + name + ".md", "Providers/" + name + " (" + vaultShortID(provider, vaultShortIDLength) + ").md"} {
			taken, err := w.pathTaken(ctx, hub, key, batch)
			if err != nil {
				return false, err
			}
			if !taken {
				providers[provider] = hub
				batch.paths[hub] = key
				break
			}
		}
	}

	again := false
	write := func(key vaultFileKey, hub, noteID, text, firstTitle string) error {
		record, found := latest[key]
		retry, err := w.writeHub(key, hub, noteID, text, firstTitle, record, found, now, batch)
		again = again || retry
		return err
	}
	for _, projectID := range slices.Sorted(maps.Keys(spaces)) {
		chats, terminals := []vaultListed{}, []vaultListed{}
		for _, note := range listed {
			switch {
			case note.ProjectID != projectID:
			case note.entity == "chat":
				chats = append(chats, note)
			default:
				terminals = append(terminals, note)
			}
		}
		key := vaultFileKey{Entity: "workspace", EntityID: projectID, Part: 1}
		first := latest[key].FirstTitle
		text := renderVaultWorkspaceHub(projectID, spaces[projectID], first, chats, terminals, providers, location)
		if err := write(key, "Workspaces/"+spaces[projectID].folder+".md", "workspace/"+projectID, text, first); err != nil {
			return again, err
		}
	}
	for _, provider := range slices.Sorted(maps.Keys(providers)) {
		if providers[provider] == "" {
			continue // every name it could have is taken
		}
		chats := []vaultListed{}
		for _, note := range listed {
			if note.entity == "chat" && note.Provider == provider {
				chats = append(chats, note)
			}
		}
		text := renderVaultProviderHub(provider, chats, spaces, location)
		if err := write(vaultFileKey{Entity: "provider", EntityID: provider, Part: 1}, providers[provider], "provider/"+provider, text, ""); err != nil {
			return again, err
		}
	}

	started, active := map[string][]vaultListed{}, map[string][]vaultListed{}
	for _, note := range slices.Backward(listed) {
		day := vaultLocalTime(note.Started, location).Format(time.DateOnly)
		started[day] = append(started[day], note)
		days[day] = true
		if note.Active == "" {
			continue
		}
		if last := vaultLocalTime(note.Active, location).Format(time.DateOnly); last > day {
			active[last] = append(active[last], note)
			days[last] = true
		}
	}
	for _, day := range slices.Sorted(maps.Keys(days)) {
		text := renderVaultDaily(day, started[day], active[day], spaces, location)
		if err := write(vaultFileKey{Entity: "daily", EntityID: day, Part: 1}, "Daily/"+day+".md", "daily/"+day, text, ""); err != nil {
			return again, err
		}
	}

	readme := vaultFileKey{Entity: "readme", EntityID: "readme", Part: 1}
	if _, found := latest[readme]; !found {
		if err := write(readme, vaultReadmePath, "readme", vaultReadme, ""); err != nil {
			return again, err
		}
	}
	return again, nil
}

// writeHub writes a hub, a Daily note or the README unless its text is the
// one last written. It reports whether it has to try again later (the note
// changed while it was written, or iCloud keeps its data elsewhere).
func (w *vaultWriter) writeHub(key vaultFileKey, hub, noteID, text, firstTitle string, record vaultFileRecord, recorded bool, now time.Time, batch *vaultBatch) (bool, error) {
	file := vaultFileRecord{vaultFileKey: key, Path: hub, Digest: vaultDigest(vaultNoteHead(text)), FirstTitle: firstTitle}
	if recorded && record.Path == hub && record.Digest == file.Digest {
		return false, nil
	}
	// A workspace's hub is recorded when its folder is named, without a
	// digest, before it is written: until then a file at its path is the
	// vault's only if it carries the hub's agentland-id.
	known := recorded && record.Path == hub && record.Digest != ""
	outcome, digest, err := writeNote(w.root, vaultNote{Path: hub, ID: noteID, Generated: text, Recorded: known, Digest: record.Digest})
	switch {
	case errors.Is(err, errVaultNotOurs):
		w.leftAlone[hub] = true
		return false, nil
	case errors.Is(err, errVaultChanged):
		return true, nil
	case err != nil:
		return false, err
	}
	switch outcome {
	case vaultUserEdited:
		w.leftAlone[hub] = true
		return false, nil
	case vaultEvicted:
		return true, nil
	case vaultWritten:
		w.wrote(hub, now)
	}
	delete(w.leftAlone, hub)
	file.Digest = digest
	w.record(batch, file)
	return false, nil
}

// vaultListLink links a listed note, shown by its title.
func vaultListLink(note vaultListed) string {
	title := vaultLinkText(note.Title)
	if title == "" {
		title = "Untitled"
	}
	return "[[" + note.base + "|" + title + "]]"
}

// vaultHubLink links a hub, shown by its name.
func vaultHubLink(hub, name string) string {
	if text := vaultLinkText(name); text != "" {
		return "[[" + strings.TrimSuffix(hub, ".md") + "|" + text + "]]"
	}
	return "[[" + strings.TrimSuffix(hub, ".md") + "]]"
}

func renderVaultWorkspaceHub(projectID string, space vaultWorkspace, firstName string, chats, terminals []vaultListed, providers map[string]string, location *time.Location) string {
	var out strings.Builder
	aliases := []string{space.name}
	if first := vaultLine(firstName); first != "" && first != space.name {
		aliases = []string{first, space.name}
	}
	writeVaultFrontmatter(&out, []vaultField{{"agentland-id", "workspace/" + projectID}, {"type", "workspace"}, {"title", space.name},
		{"aliases", aliases}, {"workspace-id", projectID}, {"tags", []string{"agentland/hub"}}})
	fmt.Fprintf(&out, "# %s\n", space.name)
	if len(chats) > 0 {
		out.WriteString("\n## Chats\n")
		groups := map[string][]vaultListed{}
		for _, chat := range chats {
			groups[chat.Provider] = append(groups[chat.Provider], chat)
		}
		order := slices.SortedFunc(maps.Keys(groups), func(a, b string) int {
			return cmp.Or(cmp.Compare(strings.ToLower(vaultProviderName(a)), strings.ToLower(vaultProviderName(b))), cmp.Compare(a, b))
		})
		for _, provider := range order {
			heading := vaultLine(vaultProviderName(provider))
			if hub := providers[provider]; hub != "" {
				heading = vaultHubLink(hub, heading)
			}
			fmt.Fprintf(&out, "\n### %s\n\n", heading)
			for _, chat := range groups[provider] {
				fmt.Fprintf(&out, "- %s · %s\n", vaultListLink(chat), vaultLocalTime(chat.Started, location).Format(time.DateOnly))
			}
		}
	}
	if len(terminals) > 0 {
		out.WriteString("\n## Terminals\n\n")
		for _, terminal := range terminals {
			fmt.Fprintf(&out, "- %s · %s\n", vaultListLink(terminal), vaultLocalTime(terminal.Started, location).Format("2006-01-02 15:04"))
		}
	}
	if len(chats) == 0 && len(terminals) == 0 {
		out.WriteString("\n_No notes yet._\n")
	}
	return out.String()
}

func renderVaultProviderHub(provider string, chats []vaultListed, spaces map[string]vaultWorkspace, location *time.Location) string {
	var out strings.Builder
	name := vaultLine(vaultProviderName(provider))
	writeVaultFrontmatter(&out, []vaultField{{"agentland-id", "provider/" + provider}, {"type", "provider"}, {"title", name},
		{"provider", provider}, {"tags", []string{"agentland/hub"}}})
	fmt.Fprintf(&out, "# %s\n", name)
	groups := map[string][]vaultListed{}
	for _, chat := range chats {
		groups[chat.ProjectID] = append(groups[chat.ProjectID], chat)
	}
	order := slices.SortedFunc(maps.Keys(groups), func(a, b string) int {
		return cmp.Or(cmp.Compare(strings.ToLower(spaces[a].name), strings.ToLower(spaces[b].name)), cmp.Compare(a, b))
	})
	for _, projectID := range order {
		heading := projectID
		if space, found := spaces[projectID]; found {
			heading = vaultHubLink("Workspaces/"+space.folder, space.name)
		}
		fmt.Fprintf(&out, "\n## %s\n\n", heading)
		for _, chat := range groups[projectID] {
			fmt.Fprintf(&out, "- %s · %s\n", vaultListLink(chat), vaultLocalTime(chat.Started, location).Format(time.DateOnly))
		}
	}
	if len(chats) == 0 {
		out.WriteString("\n_No notes yet._\n")
	}
	return out.String()
}

func renderVaultDaily(day string, started, active []vaultListed, spaces map[string]vaultWorkspace, location *time.Location) string {
	var out strings.Builder
	writeVaultFrontmatter(&out, []vaultField{{"agentland-id", "daily/" + day}, {"type", "daily"}, {"date", day}, {"tags", []string{"agentland/daily"}}})
	fmt.Fprintf(&out, "# %s\n", day)
	describe := func(note vaultListed) string {
		kind := "Terminal"
		if note.entity == "chat" {
			kind = vaultLine(vaultProviderName(note.Provider))
		}
		if space := spaces[note.ProjectID].name; space != "" {
			kind += " · " + space
		}
		return kind
	}
	if len(started) > 0 {
		out.WriteString("\n## Started\n\n")
		for _, note := range started {
			fmt.Fprintf(&out, "- %s %s · %s\n", vaultLocalTime(note.Started, location).Format("15:04"), vaultListLink(note), describe(note))
		}
	}
	if len(active) > 0 {
		out.WriteString("\n## Last active\n\n")
		for _, note := range active {
			fmt.Fprintf(&out, "- %s · %s · started %s\n", vaultListLink(note), describe(note), vaultLocalTime(note.Started, location).Format(time.DateOnly))
		}
	}
	if len(started) == 0 && len(active) == 0 {
		out.WriteString("\n_Nothing listed._\n")
	}
	return out.String()
}

// vaultReadme is the README's text.
const vaultReadme = `---
agentland-id: "readme"
type: "readme"
---
# AgentLand Vault

AgentLand keeps this folder in step with the chats and terminal sessions it archives on this Mac, as Markdown notes.

- **Chats/**: a folder for each workspace, with a note for each chat. General holds the chats that belong to no workspace.
- **Terminals/**: a note for each terminal session, by workspace.
- **Workspaces/** and **Providers/**: notes that list the chats by workspace and by provider.
- **Daily/**: what started and what was last active each day.
- **Attachments/**: the images chats show.
- **Notes/**: yours. AgentLand never writes there.

AgentLand rewrites what is above the ` + "`%% agentland:end %%`" + ` line of its notes; what you write below that line stays. A note keeps the name it was first given, and later titles become aliases. Deleting a chat or terminal in AgentLand keeps its note here.

AgentLand masks API keys, tokens and passwords it recognises, but it can miss some: this folder is not a safe place for secrets.
`
