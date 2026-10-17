package host

import (
	"bufio"
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"strings"
)

const archiveExportBatch = 100

var errArchiveExportFormat = errors.New("choose markdown, json or jsonl")

// Export streams one chat as markdown, json or jsonl. With an empty chatID
// and jsonl it streams the whole archive instead: every chat, including those
// of projects that are no longer configured, with messages and interactions,
// then every terminal log record (not the output itself). Markdown leaves out
// hidden (rewound) messages; JSON keeps them, marked hidden. The caller
// decides who may export what. An unknown chat returns sql.ErrNoRows before
// anything is written.
func (a *Archive) Export(ctx context.Context, w io.Writer, chatID, format string) error {
	if format != "markdown" && format != "json" && format != "jsonl" {
		return errArchiveExportFormat
	}
	if chatID == "" && format != "jsonl" {
		return errArchiveExportFormat
	}
	tx, err := a.readDB.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return err
	}
	defer tx.Rollback()
	out := bufio.NewWriterSize(w, 64<<10)
	exportedAt := archiveTimeText(a.now().UnixMilli())
	if chatID == "" {
		err = a.exportAll(ctx, tx, out, exportedAt)
	} else {
		var chat archiveChatJSON
		if chat, err = archiveLoadChat(ctx, tx, chatID); err != nil {
			return err
		}
		switch format {
		case "markdown":
			err = exportChatMarkdown(ctx, tx, out, chat, exportedAt)
		case "json":
			err = exportChatJSON(ctx, tx, out, chat, exportedAt)
		default:
			err = exportChatLines(ctx, tx, out, chat)
		}
	}
	if err != nil {
		return err
	}
	return out.Flush()
}

// archiveJSON encodes without HTML escaping, which keeps exported text readable.
func archiveJSON(value any) ([]byte, error) {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buffer.Bytes(), []byte("\n")), nil
}

func writeArchiveJSON(out *bufio.Writer, value any) error {
	encoded, err := archiveJSON(value)
	if err != nil {
		return err
	}
	_, err = out.Write(encoded)
	return err
}

func writeArchiveLine(out *bufio.Writer, value any) error {
	if err := writeArchiveJSON(out, value); err != nil {
		return err
	}
	return out.WriteByte('\n')
}

// archiveEachMessage visits a chat's messages in order, a batch at a time.
func archiveEachMessage(ctx context.Context, q archiveQuerier, chatID string, visit func(archiveMessageJSON) error) error {
	ord, pk := int64(math.MinInt64), int64(math.MinInt64)
	for {
		messages, err := archiveLoadMessages(ctx, q, `WHERE m.chat_id = ? AND (m.ord, m.pk) > (?, ?) ORDER BY m.ord, m.pk LIMIT ?`, chatID, ord, pk, archiveExportBatch)
		if err != nil {
			return err
		}
		for _, message := range messages {
			if err := visit(message); err != nil {
				return err
			}
		}
		if len(messages) < archiveExportBatch {
			return nil
		}
		last := messages[len(messages)-1]
		ord, pk = last.Ord, last.pk
	}
}

func archiveLoadInteractions(ctx context.Context, q archiveQuerier, chatID string) ([]archiveInteractionJSON, error) {
	rows, err := q.QueryContext(ctx, `SELECT id, chat_id, kind, outcome, summary, created_at, resolved_at FROM interactions WHERE chat_id = ? ORDER BY created_at, id`, chatID)
	if err != nil {
		return nil, err
	}
	interactions := []archiveInteractionJSON{}
	for rows.Next() {
		var interaction archiveInteractionJSON
		var created int64
		var resolved sql.NullInt64
		if err := rows.Scan(&interaction.ID, &interaction.ChatID, &interaction.Kind, &interaction.Outcome, &interaction.Summary, &created, &resolved); err != nil {
			rows.Close()
			return nil, err
		}
		interaction.CreatedAt, interaction.ResolvedAt = archiveTimeText(created), archiveNullTime(resolved)
		interactions = append(interactions, interaction)
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	return interactions, rows.Err()
}

func exportChatJSON(ctx context.Context, q archiveQuerier, out *bufio.Writer, chat archiveChatJSON, exportedAt string) error {
	out.WriteString(`{"format":"agentland.chat","version":1,"exportedAt":`)
	if err := writeArchiveJSON(out, exportedAt); err != nil {
		return err
	}
	out.WriteString(`,"chat":`)
	if err := writeArchiveJSON(out, chat); err != nil {
		return err
	}
	out.WriteString(`,"messages":[`)
	first := true
	err := archiveEachMessage(ctx, q, chat.ID, func(message archiveMessageJSON) error {
		if !first {
			out.WriteByte(',')
		}
		first = false
		return writeArchiveJSON(out, message)
	})
	if err != nil {
		return err
	}
	interactions, err := archiveLoadInteractions(ctx, q, chat.ID)
	if err != nil {
		return err
	}
	out.WriteString(`],"interactions":`)
	if err := writeArchiveJSON(out, interactions); err != nil {
		return err
	}
	_, err = out.WriteString("}\n")
	return err
}

type archiveChatLine struct {
	Type string          `json:"type"`
	Chat archiveChatJSON `json:"chat"`
}

type archiveMessageLine struct {
	Type    string             `json:"type"`
	Message archiveMessageJSON `json:"message"`
}

type archiveInteractionLine struct {
	Type        string                 `json:"type"`
	Interaction archiveInteractionJSON `json:"interaction"`
}

// exportChatLines writes a chat line, then one line per message and
// interaction.
func exportChatLines(ctx context.Context, q archiveQuerier, out *bufio.Writer, chat archiveChatJSON) error {
	_, err := exportChatLinesCounted(ctx, q, out, chat)
	return err
}

// exportChatLinesCounted is exportChatLines that also returns the number of
// messages written.
func exportChatLinesCounted(ctx context.Context, q archiveQuerier, out *bufio.Writer, chat archiveChatJSON) (int, error) {
	if err := writeArchiveLine(out, archiveChatLine{Type: "chat", Chat: chat}); err != nil {
		return 0, err
	}
	count := 0
	err := archiveEachMessage(ctx, q, chat.ID, func(message archiveMessageJSON) error {
		count++
		return writeArchiveLine(out, archiveMessageLine{Type: "message", Message: message})
	})
	if err != nil {
		return count, err
	}
	interactions, err := archiveLoadInteractions(ctx, q, chat.ID)
	if err != nil {
		return count, err
	}
	for _, interaction := range interactions {
		if err := writeArchiveLine(out, archiveInteractionLine{Type: "interaction", Interaction: interaction}); err != nil {
			return count, err
		}
	}
	return count, nil
}

// exportAll streams the whole archive as JSON Lines. The last line, "end",
// carries the totals, so a reader can tell a complete export from a cut one.
func (a *Archive) exportAll(ctx context.Context, q archiveQuerier, out *bufio.Writer, exportedAt string) error {
	header := struct {
		Type       string `json:"type"`
		Format     string `json:"format"`
		Version    int    `json:"version"`
		Epoch      string `json:"epoch"`
		ExportedAt string `json:"exportedAt"`
	}{"archive", "agentland.archive", 1, a.epoch, exportedAt}
	if err := writeArchiveLine(out, header); err != nil {
		return err
	}
	rows, err := q.QueryContext(ctx, `SELECT id FROM chats ORDER BY created_at, id`)
	if err != nil {
		return err
	}
	var chats []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return err
		}
		chats = append(chats, id)
	}
	if err := rows.Close(); err != nil {
		return err
	}
	totals := struct {
		Type         string `json:"type"`
		Chats        int    `json:"chats"`
		Messages     int    `json:"messages"`
		TerminalLogs int    `json:"terminalLogs"`
	}{Type: "end"}
	for _, id := range chats {
		chat, err := archiveLoadChat(ctx, q, id)
		if err != nil {
			return err
		}
		count, err := exportChatLinesCounted(ctx, q, out, chat)
		if err != nil {
			return err
		}
		totals.Chats++
		totals.Messages += count
	}
	type terminalLogLine struct {
		Type        string                 `json:"type"`
		TerminalLog archiveTerminalLogJSON `json:"terminalLog"`
		File        string                 `json:"file"`
	}
	started, id := int64(math.MinInt64), ""
	for {
		logs, err := archiveScanTerminalLogs(q.QueryContext(ctx, `SELECT `+archiveTerminalLogColumns+`
			FROM terminal_logs WHERE (started_at, id) > (?, ?) ORDER BY started_at, id LIMIT ?`, started, id, archiveExportBatch))
		if err != nil {
			return err
		}
		for _, log := range logs {
			if err := writeArchiveLine(out, terminalLogLine{Type: "terminalLog", TerminalLog: log, File: log.file}); err != nil {
				return err
			}
			totals.TerminalLogs++
		}
		if len(logs) < archiveExportBatch {
			return writeArchiveLine(out, totals)
		}
		last := logs[len(logs)-1]
		started, id = last.started, last.ID
	}
}

// Markdown.

func exportChatMarkdown(ctx context.Context, q archiveQuerier, out *bufio.Writer, chat archiveChatJSON, exportedAt string) error {
	title := chat.Title
	if title == "" {
		title = "Untitled chat"
	}
	fmt.Fprintf(out, "# %s\n\n", title)
	fmt.Fprintf(out, "- Chat: %s\n- Project: %s\n- Provider: %s\n", chat.ID, chat.ProjectID, chat.Provider)
	if chat.Model != "" {
		fmt.Fprintf(out, "- Model: %s\n", chat.Model)
	}
	fmt.Fprintf(out, "- Created: %s\n- Exported: %s\n", chat.CreatedAt, exportedAt)
	return archiveEachMessage(ctx, q, chat.ID, func(message archiveMessageJSON) error {
		if !message.Hidden {
			writeMessageMarkdown(out, message)
		}
		return nil
	})
}

func writeMessageMarkdown(out *bufio.Writer, message archiveMessageJSON) {
	heading := "User"
	if message.Role == "assistant" {
		heading = "Assistant"
		if message.Model != "" {
			heading += " · " + message.Model
		}
	}
	fmt.Fprintf(out, "\n## %s · %s\n", heading, message.CreatedAt)
	if notice := messageStatusNotice(message.Status); notice != "" {
		fmt.Fprintf(out, "\n%s\n", notice)
	}
	for _, part := range message.Parts {
		switch part.Kind {
		case "text":
			if part.Text != "" {
				fmt.Fprintf(out, "\n%s\n", strings.TrimRight(part.Text, "\n"))
			}
		case "reasoning":
			if part.Text != "" {
				fmt.Fprintf(out, "\n> **Reasoning**\n>\n%s", markdownQuote(part.Text))
			}
		case "context":
			fmt.Fprintf(out, "\n> **Context from another chat**\n>\n%s", markdownQuote(part.Text))
		case "notice":
			fmt.Fprintf(out, "\n%s\n", noticeMarkdown(part.Text))
		case "patch":
			fmt.Fprintf(out, "\n%s", patchMarkdown(part.Text))
		case "tool":
			writeToolMarkdown(out, part.Tool)
		case "attachment":
			if attachment := part.Attachment; attachment != nil {
				fmt.Fprintf(out, "\n%s\n", attachmentMarkdown(*attachment))
			}
		}
		if part.Truncated {
			fmt.Fprintf(out, "\n%s\n", archivePartShortened)
		}
	}
	if message.Error != nil {
		fmt.Fprintf(out, "\n%s\n", errorMarkdown(*message.Error))
	}
}

// The lines a chat's Markdown (the export and the vault's notes) gives what
// is not plain text.
const (
	archivePartShortened = "_This part was shortened in the archive._"
	archiveToolShortened = "_Tool text was shortened._"
)

// messageStatusNotice is the line a reply that did not finish carries, or "".
func messageStatusNotice(status string) string {
	switch status {
	case "streaming":
		return "_This reply was still being written when it was saved._"
	case "aborted":
		return "_This reply was stopped before it finished._"
	}
	return ""
}

func noticeMarkdown(text string) string {
	return "> Note: " + strings.ReplaceAll(strings.TrimSpace(text), "\n", " ")
}

func patchMarkdown(text string) string {
	return "**Patch**\n\n" + markdownFence(text)
}

func attachmentMarkdown(attachment archiveAttachmentJSON) string {
	return fmt.Sprintf("**Attachment:** %s (%s, %d bytes)", attachment.Name, attachment.MIME, attachment.Size)
}

func errorMarkdown(failure archiveErrorJSON) string {
	if failure.Code == "" {
		return "**Error:** " + failure.Message
	}
	return fmt.Sprintf("**Error:** %s (%s)", failure.Message, failure.Code)
}

func writeToolMarkdown(out *bufio.Writer, tool *archiveToolJSON) {
	if tool == nil {
		return
	}
	fmt.Fprintf(out, "\n**Tool:** %s (%s)", tool.Name, tool.Status)
	if tool.Title != "" {
		fmt.Fprintf(out, " — %s", tool.Title)
	}
	out.WriteString("\n")
	for _, field := range []struct{ label, text string }{{"Input", tool.Input}, {"Output", tool.Output}, {"Error", tool.Error}} {
		if field.text != "" {
			fmt.Fprintf(out, "\n%s:\n\n%s", field.label, markdownFence(field.text))
		}
	}
	if tool.Truncated {
		fmt.Fprintf(out, "\n%s\n", archiveToolShortened)
	}
}

// markdownFence wraps text in a code fence longer than any backtick run in it.
func markdownFence(text string) string {
	longest, run := 0, 0
	for _, r := range text {
		if r == '`' {
			run++
			longest = max(longest, run)
		} else {
			run = 0
		}
	}
	fence := strings.Repeat("`", max(3, longest+1))
	return fence + "\n" + strings.TrimRight(text, "\n") + "\n" + fence + "\n"
}

func markdownQuote(text string) string {
	var quoted strings.Builder
	for _, line := range strings.Split(strings.TrimRight(text, "\n"), "\n") {
		if line == "" {
			quoted.WriteString(">\n")
		} else {
			quoted.WriteString("> " + line + "\n")
		}
	}
	return quoted.String()
}
