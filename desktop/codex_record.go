package host

import (
	"strings"
	"time"
)

// codexChatRecord is the Codex part of a CLI chat record (chats.json): the
// chat's Codex settings, the unified form of streamed messages and the
// rewind state. Records written before streaming have none.
type codexChatRecord struct {
	// Model is the Codex model slug; empty uses Codex's configured default.
	Model  string `json:"model,omitempty"`
	Mode   string `json:"mode,omitempty"`
	Effort string `json:"effort,omitempty"`
	// Unified holds each streamed message's parts, by message ID. Messages
	// without an entry (user messages, replies of the one-shot runs) are
	// derived from their legacy fields.
	Unified map[string]*ChatMessage `json:"unified,omitempty"`
	// Turns maps a user message ID to the Codex turn it started. Only turns
	// run through the app-server have one; only those can be rewound.
	Turns map[string]string `json:"turns,omitempty"`
	// Rewind is the user message the chat is rewound to: it and every later
	// message are hidden until a restore, or dropped by the next send.
	Rewind string `json:"rewind,omitempty"`
	// PendingRevert is a Codex turn the next send removes from Codex's
	// history (thread/revert) before it starts a turn.
	PendingRevert string `json:"pendingRevert,omitempty"`
	// Parent is the chat this one was forked from.
	Parent string `json:"parent,omitempty"`
	// TokenTotal is the thread's latest token total, so a codex exec run,
	// which reports the thread total, can be turned into this turn's usage.
	TokenTotal *codexTokens `json:"tokenTotal,omitempty"`
}

func (record *cliChatRecord) codex() *codexChatRecord {
	if record.Codex == nil {
		record.Codex = &codexChatRecord{}
	}
	return record.Codex
}

func (record *cliChatRecord) codexRewind() string {
	if record.Codex == nil {
		return ""
	}
	return record.Codex.Rewind
}

// visibleMessages returns the legacy transcript up to a Codex rewind point,
// with each streamed message's unified form attached.
func (record *cliChatRecord) visibleMessages() []Message {
	result := make([]Message, 0, len(record.Messages))
	for _, message := range record.Messages {
		if record.Codex != nil {
			if record.Codex.Rewind != "" && message.ID == record.Codex.Rewind {
				break
			}
			if unified := record.Codex.Unified[message.ID]; unified != nil {
				copied := cloneChatMessage(*unified)
				copied.Ord = int64(len(result) + 1)
				message.Unified = &copied
			}
		}
		result = append(result, message)
	}
	return result
}

// codexUnifiedLocked returns the chat's visible messages in the unified
// model, oldest first. Ords are transcript positions, as for one-shot chats.
func (record *cliChatRecord) codexUnified() []ChatMessage {
	visible := record.visibleMessages()
	messages := unifiedMessages(visible, "codex", record.Session.ID, func(_ int, message Message) time.Time {
		if created, ok := record.Created[message.ID]; ok {
			return created
		}
		return record.UpdatedAt
	})
	for index := range messages {
		message := &messages[index]
		message.ChatID, message.Provider, message.Ord = record.Session.ID, "codex", int64(index+1)
		if message.Role == "assistant" && message.Model == "" {
			message.Model = "codex/default"
		}
		if created, ok := record.Created[message.ID]; ok {
			message.createdMs = created.UnixMilli()
		}
	}
	return messages
}

func cloneChatMessage(message ChatMessage) ChatMessage {
	if message.Usage != nil {
		usage := *message.Usage
		if usage.CostMicros != nil {
			cost := *usage.CostMicros
			usage.CostMicros = &cost
		}
		message.Usage = &usage
	}
	if message.Error != nil {
		failure := *message.Error
		message.Error = &failure
	}
	parts := make([]ChatPart, len(message.Parts))
	for index, part := range message.Parts {
		parts[index] = clonePart(part)
	}
	message.Parts = parts
	return message
}

func clonePart(part ChatPart) ChatPart {
	if part.Tool != nil {
		tool := *part.Tool
		part.Tool = &tool
	}
	if part.Attachment != nil {
		attachment := *part.Attachment
		part.Attachment = &attachment
	}
	return part
}

// codexLegacy derives the legacy GET /v1/messages fields of a streamed
// message: text parts joined, reasoning, tools and the error.
func codexLegacy(message *ChatMessage) Message {
	result := Message{ID: message.ID, Role: message.Role}
	texts := []string{}
	for _, part := range message.Parts {
		switch part.Kind {
		case "text":
			if part.Text != "" {
				texts = append(texts, part.Text)
			}
		case "reasoning":
			reasoning := ReasoningPart{Text: part.Text}
			if start, end := parseChatTime(part.Start), parseChatTime(part.End); !start.IsZero() && end.After(start) {
				reasoning.DurationMs = end.Sub(start).Milliseconds()
			}
			result.Reasoning = append(result.Reasoning, reasoning)
		case "tool":
			if tool := part.Tool; tool != nil {
				result.Tools = append(result.Tools, ToolCall{ID: part.ID, CallID: tool.CallID, Name: tool.Name, Status: tool.Status, Title: tool.Title, Input: tool.Input, Output: tool.Output, Error: tool.Error, Truncated: tool.Truncated})
			}
		case "attachment":
			if part.Attachment != nil {
				result.Attachments = append(result.Attachments, *part.Attachment)
			}
		}
	}
	result.Text, _ = clipText(strings.Join(texts, "\n\n"), chatTextLimit)
	if message.Error != nil {
		result.Error = message.Error.Message
	}
	return result
}

func parseChatTime(value string) time.Time {
	if value == "" {
		return time.Time{}
	}
	parsed, err := time.Parse("2006-01-02T15:04:05.000Z", value)
	if err != nil {
		return time.Time{}
	}
	return parsed
}
