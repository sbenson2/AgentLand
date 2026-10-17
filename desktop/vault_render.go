package host

import (
	"fmt"
	"path"
	"strings"
	"time"
	"unicode"
)

// Chat notes. A chat becomes one Markdown note, in parts of about 1 MiB:
// frontmatter (every value JSON-quoted, which is valid YAML), the title, then
// each visible message under a "## You · 14:32" or "## Claude Code · model ·
// 14:32" heading, with tools in collapsed [!tool]- callouts, reasoning in
// [!thinking]- callouts, images embedded and other attachments listed. Times
// are shown in the names' zone. Text is masked (maskVaultSecrets) and each
// tool field is cut to 16 KiB. A part ends at the first message boundary past
// 1 MiB; parts link to each other. The writer adds the marker and the user's
// text (writeNote) and copies the embedded images.

const (
	vaultPartLimit      = 1 << 20
	vaultToolFieldLimit = 16 << 10
	// vaultImageLimit is the largest image a note embeds (and the vault
	// copies); a larger one is listed.
	vaultImageLimit = 16 << 20
	vaultToolCapped = "_Shortened to 16 KiB in the vault._"
)

// vaultImageTypes gives the extension of each image format Obsidian shows
// embedded; vaultImageExtensions are those extensions.
var (
	vaultImageTypes      = map[string]string{"image/png": ".png", "image/jpeg": ".jpg", "image/gif": ".gif", "image/webp": ".webp", "image/svg+xml": ".svg", "image/avif": ".avif", "image/bmp": ".bmp"}
	vaultImageExtensions = map[string]bool{".png": true, ".jpg": true, ".jpeg": true, ".gif": true, ".webp": true, ".svg": true, ".avif": true, ".bmp": true}
)

// notePart is one part of a note, from 1: its path relative to the vault's
// root (with ".md"), the generated text that goes above its marker and the
// images it embeds, which the writer copies to their paths.
type notePart struct {
	Part        int
	Path        string
	Text        string
	Attachments []vaultAttachment
}

// vaultAttachment is an archived blob the vault keeps a copy of.
type vaultAttachment struct {
	SHA256 string
	Size   int64
	Path   string // relative to the vault's root
}

// vaultLink names another note: its path without ".md", and its title.
type vaultLink struct {
	Path  string
	Title string
}

// vaultChatNames is what a chat's note shows that the archive does not hold.
type vaultChatNames struct {
	// Base is the note's path without ".md", fixed when it was first
	// written; FirstTitle is the title it had then.
	Base       string
	FirstTitle string
	// ProviderName is the provider's display name, such as Claude Code.
	ProviderName string
	// WorkspaceName is the workspace's current name; WorkspaceFolder its
	// folder under Chats/ and the name of its hub, fixed when first seen.
	WorkspaceName   string
	WorkspaceFolder string
	// ContinuedFrom is the note of the chat this one continues, if any.
	ContinuedFrom vaultLink
	// Location is the zone times are shown in (time.Local when nil).
	Location *time.Location
}

// renderChat renders a chat's note. Messages are in order; hidden (rewound)
// ones are left out. Interactions, oldest first, appear after the messages
// that came before them.
func renderChat(chat archiveChatJSON, messages []archiveMessageJSON, interactions []archiveInteractionJSON, names vaultChatNames) []notePart {
	r := newVaultChatRenderer(chat, names)
	notes := make([]vaultMessageNote, 0, len(messages))
	for _, message := range messages {
		if !message.Hidden {
			notes = append(notes, r.message(message))
		}
	}
	return r.parts(chat, notes, interactions)
}

// vaultMessageNote is a visible message rendered for its chat's note: the
// time it was created, its text and the images it embeds. A message renders
// the same until it changes, so the writer keeps these rather than masking a
// long chat again whenever it grows.
type vaultMessageNote struct {
	CreatedAt   string
	Text        string
	Attachments []vaultAttachment
}

func newVaultChatRenderer(chat archiveChatJSON, names vaultChatNames) *vaultChatRenderer {
	r := &vaultChatRenderer{names: names, location: names.Location}
	if r.location == nil {
		r.location = time.Local
	}
	r.started = r.localTime(chat.CreatedAt)
	r.provider = names.ProviderName
	if r.provider == "" {
		r.provider = chat.Provider
	}
	return r
}

// context is what a rendered message depends on besides the message: the
// provider's name, the chat's first day and the zone.
func (r *vaultChatRenderer) context() string {
	return r.provider + "\x00" + r.started.Format(time.RFC3339) + "\x00" + r.location.String()
}

// message renders one visible message.
func (r *vaultChatRenderer) message(message archiveMessageJSON) vaultMessageNote {
	body := &vaultBody{}
	r.writeMessage(body, message)
	return vaultMessageNote{CreatedAt: message.CreatedAt, Text: body.text.String(), Attachments: body.attachments}
}

// parts puts rendered messages and interactions into the note's parts.
func (r *vaultChatRenderer) parts(chat archiveChatJSON, notes []vaultMessageNote, interactions []archiveInteractionJSON) []notePart {
	names := r.names
	bodies := []*vaultBody{{}}
	body := bodies[0]
	for _, note := range notes {
		// Archive times share one layout, so they order as text.
		for len(interactions) > 0 && interactions[0].CreatedAt < note.CreatedAt {
			r.writeInteraction(body, interactions[0])
			interactions = interactions[1:]
		}
		if body.text.Len() >= vaultPartLimit {
			body = &vaultBody{}
			bodies = append(bodies, body)
		}
		body.text.WriteString(note.Text)
		for _, attachment := range note.Attachments {
			body.attach(attachment)
		}
	}
	for _, interaction := range interactions {
		r.writeInteraction(body, interaction)
	}

	title := vaultChatTitle(chat)
	parts := make([]notePart, len(bodies))
	for index, body := range bodies {
		number := index + 1
		var out strings.Builder
		r.writeFrontmatter(&out, chat, title, number, len(bodies))
		if number == 1 {
			fmt.Fprintf(&out, "# %s\n", title)
		} else {
			fmt.Fprintf(&out, "# %s (part %d)\n\nContinued from [[%s|part %d]]\n", title, number, vaultPartBase(names.Base, number-1), number-1)
		}
		out.WriteString(body.text.String())
		if number < len(bodies) {
			fmt.Fprintf(&out, "\nContinued in [[%s|part %d]]\n", vaultPartBase(names.Base, number+1), number+1)
		}
		parts[index] = notePart{Part: number, Path: vaultPartBase(names.Base, number) + ".md", Text: out.String(), Attachments: body.attachments}
	}
	return parts
}

// vaultChatTitle is a chat note's title: the chat's, masked, or "Untitled
// chat".
func vaultChatTitle(chat archiveChatJSON) string {
	if title := vaultLine(maskVaultSecrets(chat.Title)); title != "" {
		return title
	}
	return "Untitled chat"
}

type vaultChatRenderer struct {
	names    vaultChatNames
	location *time.Location
	started  time.Time
	provider string
}

// vaultBody is one part's messages and the images they embed.
type vaultBody struct {
	text        strings.Builder
	attachments []vaultAttachment
}

// attach adds an image the body embeds, once.
func (body *vaultBody) attach(attachment vaultAttachment) {
	for _, existing := range body.attachments {
		if existing.Path == attachment.Path {
			return
		}
	}
	body.attachments = append(body.attachments, attachment)
}

func (r *vaultChatRenderer) localTime(text string) time.Time {
	t, err := time.Parse(archiveTimeLayout, text)
	if err != nil {
		return time.Time{}
	}
	return t.In(r.location)
}

// when shows a time as 14:32, with its date when it is not the chat's first
// day.
func (r *vaultChatRenderer) when(text string) string {
	t := r.localTime(text)
	if t.Format(time.DateOnly) == r.started.Format(time.DateOnly) {
		return t.Format("15:04")
	}
	return t.Format("2006-01-02 15:04")
}

func (r *vaultChatRenderer) writeFrontmatter(out *strings.Builder, chat archiveChatJSON, title string, part, parts int) {
	aliases := []string{title}
	if first := vaultLine(maskVaultSecrets(r.names.FirstTitle)); first != "" && first != title {
		aliases = []string{first, title}
	}
	workspace := vaultLinkText(r.names.WorkspaceName)
	if workspace == "" {
		workspace = r.names.WorkspaceFolder
	}
	tags := []string{"agentland/chat"}
	for _, tag := range []struct{ prefix, name string }{{"agentland/provider/", chat.Provider}, {"agentland/workspace/", r.names.WorkspaceFolder}} {
		if name := vaultTag(tag.name); name != "" {
			tags = append(tags, tag.prefix+name)
		}
	}
	fields := []vaultField{
		{"agentland-id", "chat/" + chat.ID},
		{"type", "chat"},
		{"title", title},
		{"aliases", aliases},
		{"provider", chat.Provider},
		{"provider-name", r.provider},
	}
	if r.names.WorkspaceFolder != "" {
		fields = append(fields, vaultField{"workspace", "[[Workspaces/" + r.names.WorkspaceFolder + "|" + workspace + "]]"})
	}
	fields = append(fields, vaultField{"workspace-id", chat.ProjectID})
	if chat.Model != "" {
		fields = append(fields, vaultField{"model", chat.Model})
	}
	fields = append(fields, vaultField{"started", r.started.Format(time.RFC3339)}, vaultField{"updated", r.localTime(chat.UpdatedAt).Format(time.RFC3339)})
	if link := r.names.ContinuedFrom; link.Path != "" {
		fields = append(fields, vaultField{"continued-from", "[[" + link.Path + "|" + vaultLinkText(maskVaultSecrets(link.Title)) + "]]"})
	}
	if parts > 1 {
		fields = append(fields, vaultField{"part", part}, vaultField{"parts", parts})
	}
	fields = append(fields, vaultField{"tags", tags})
	writeVaultFrontmatter(out, fields)
}

// vaultField is one frontmatter property.
type vaultField struct {
	key   string
	value any
}

// writeVaultFrontmatter writes properties as JSON values, which YAML reads as
// they are: quoted strings, lists and numbers.
func writeVaultFrontmatter(out *strings.Builder, fields []vaultField) {
	out.WriteString("---\n")
	for _, field := range fields {
		encoded, _ := archiveJSON(field.value) // strings, string lists and numbers always encode
		fmt.Fprintf(out, "%s: %s\n", field.key, encoded)
	}
	out.WriteString("---\n")
}

func (r *vaultChatRenderer) writeMessage(body *vaultBody, message archiveMessageJSON) {
	out := &body.text
	who := "You"
	if message.Role == "assistant" {
		who = vaultLine(r.provider)
		if message.Model != "" {
			who += " · " + vaultLine(message.Model)
		}
	}
	fmt.Fprintf(out, "\n## %s · %s\n", who, r.when(message.CreatedAt))
	if notice := messageStatusNotice(message.Status); notice != "" {
		fmt.Fprintf(out, "\n%s\n", notice)
	}
	for _, part := range message.Parts {
		switch part.Kind {
		case "text":
			if part.Text != "" {
				fmt.Fprintf(out, "\n%s\n", strings.TrimRight(maskVaultSecrets(part.Text), "\n"))
			}
		case "reasoning":
			if part.Text != "" {
				fmt.Fprintf(out, "\n> [!thinking]- Thinking\n%s", markdownQuote(maskVaultSecrets(part.Text)))
			}
		case "context":
			fmt.Fprintf(out, "\n> [!quote]- Context from another chat\n%s", markdownQuote(maskVaultSecrets(part.Text)))
		case "notice":
			fmt.Fprintf(out, "\n%s\n", noticeMarkdown(maskVaultSecrets(part.Text)))
		case "patch":
			fmt.Fprintf(out, "\n%s", patchMarkdown(maskVaultSecrets(part.Text)))
		case "tool":
			writeVaultTool(out, part.Tool)
		case "attachment":
			if part.Attachment != nil {
				r.writeAttachment(body, *part.Attachment, message.CreatedAt)
			}
		}
		if part.Truncated {
			fmt.Fprintf(out, "\n%s\n", archivePartShortened)
		}
	}
	if message.Error != nil {
		failure := archiveErrorJSON{Code: message.Error.Code, Message: maskVaultSecrets(message.Error.Message)}
		fmt.Fprintf(out, "\n%s\n", errorMarkdown(failure))
	}
}

// writeVaultTool writes a tool as a collapsed callout: its name, status and
// title, then each field fenced and cut to 16 KiB after masking.
func writeVaultTool(out *strings.Builder, tool *archiveToolJSON) {
	if tool == nil {
		return
	}
	label := tool.Name + " · " + tool.Status
	if tool.Title != "" {
		label += " — " + tool.Title
	}
	var inner strings.Builder
	for _, field := range []struct{ label, text string }{{"Input", tool.Input}, {"Output", tool.Output}, {"Error", tool.Error}} {
		if field.text == "" {
			continue
		}
		text, capped := archiveClip(maskVaultSecrets(field.text), vaultToolFieldLimit)
		fmt.Fprintf(&inner, "%s:\n%s", field.label, markdownFence(text))
		if capped {
			fmt.Fprintf(&inner, "%s\n", vaultToolCapped)
		}
	}
	if len(tool.Sources) > 0 {
		inner.WriteString("Sources:\n")
		for _, source := range tool.Sources {
			title := strings.NewReplacer("[", `\[`, "]", `\]`).Replace(vaultLine(source.Title))
			address := strings.Map(func(r rune) rune {
				if r == '<' || r == '>' || unicode.IsSpace(r) || unicode.IsControl(r) {
					return -1
				}
				return r
			}, source.URL)
			fmt.Fprintf(&inner, "- [%s](<%s>)\n", maskVaultSecrets(title), maskVaultSecrets(address))
		}
	}
	if tool.Memory != nil {
		fmt.Fprintf(&inner, "Saved to memory: %s\n", vaultLine(maskVaultSecrets(tool.Memory.Text)))
	}
	if tool.Truncated {
		fmt.Fprintf(&inner, "%s\n", archiveToolShortened)
	}
	fmt.Fprintf(out, "\n> [!tool]- %s\n", vaultLine(maskVaultSecrets(label)))
	if inner.Len() > 0 {
		out.WriteString(markdownQuote(inner.String()))
	}
}

// writeAttachment embeds an image of a format Obsidian shows, stored in the
// archive and at most 16 MiB, from its copy in Attachments/<month>/; any
// other attachment is listed.
func (r *vaultChatRenderer) writeAttachment(body *vaultBody, attachment archiveAttachmentJSON, created string) {
	out := &body.text
	name := vaultSafeName(attachment.Name)
	extension := strings.ToLower(path.Ext(name))
	if !vaultImageExtensions[extension] {
		mediaType, _, _ := strings.Cut(attachment.MIME, ";")
		extension = vaultImageTypes[strings.ToLower(strings.TrimSpace(mediaType))]
		if name == "" {
			name = "image"
		}
		name += extension
	}
	if extension == "" || !archiveValidSHA(attachment.SHA256) || attachment.Size <= 0 || attachment.Size > vaultImageLimit {
		listed := attachment
		listed.Name = vaultLine(maskVaultSecrets(attachment.Name))
		fmt.Fprintf(out, "\n%s\n", attachmentMarkdown(listed))
		return
	}
	copied := "Attachments/" + r.localTime(created).Format("2006-01") + "/" + attachment.SHA256[:12] + "-" + name
	fmt.Fprintf(out, "\n![[%s]]\n", copied)
	body.attach(vaultAttachment{SHA256: attachment.SHA256, Size: attachment.Size, Path: copied})
}

// vaultInteractionOutcomes says how a permission or question ended.
var vaultInteractionOutcomes = map[string]string{"once": "allowed once", "always": "always allowed", "reject": "rejected",
	"answered": "answered", "rejected": "rejected", "expired": "expired", "": "no answer"}

func (r *vaultChatRenderer) writeInteraction(body *vaultBody, interaction archiveInteractionJSON) {
	kind := "Permission"
	if interaction.Kind == "question" {
		kind = "Question"
	}
	outcome := vaultInteractionOutcomes[interaction.Outcome]
	if outcome == "" {
		outcome = vaultLine(interaction.Outcome)
	}
	line := kind + " · " + outcome
	if summary := vaultLine(maskVaultSecrets(interaction.Summary)); summary != "" {
		line += " — " + summary
	}
	fmt.Fprintf(&body.text, "\n> [!info] %s\n", line)
}

// vaultLine puts text on one line, with single spaces.
func vaultLine(text string) string {
	return strings.Join(strings.Fields(text), " ")
}

// vaultLinkText is text shown inside a [[link|text]]: one line, without the
// brackets and bar that would end the link.
func vaultLinkText(text string) string {
	return vaultLine(strings.Map(func(r rune) rune {
		if r == '[' || r == ']' || r == '|' {
			return ' '
		}
		return r
	}, text))
}

// vaultTag makes a name an Obsidian tag segment: lower case letters, digits,
// "_" and "-", other characters as "-".
func vaultTag(name string) string {
	var tag strings.Builder
	dash := false
	for _, r := range strings.ToLower(name) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_' {
			tag.WriteRune(r)
			dash = false
		} else if !dash && tag.Len() > 0 {
			tag.WriteByte('-')
			dash = true
		}
	}
	return strings.TrimRight(tag.String(), "-")
}
