package host

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"testing"
	"time"
)

// fixtureID makes an OpenCode-format ID whose 48-bit value orders by n.
func fixtureID(prefix string, n int) string {
	return fmt.Sprintf("%s_%012x%s", prefix, 0x0001a2b3c000+n, "Fixture0000000")
}

const fixtureEpochMs = 1790000000000

func ocUserFixture(n int, text string) map[string]any {
	id := fixtureID("msg", n)
	return map[string]any{"info": map[string]any{"id": id, "sessionID": "s1", "role": "user", "time": map[string]any{"created": fixtureEpochMs + n*1000}, "agent": "build", "model": map[string]any{"providerID": "anthropic", "modelID": "claude"}},
		"parts": []any{map[string]any{"id": fixtureID("prt", n*100), "sessionID": "s1", "messageID": id, "type": "text", "text": text}}}
}

func ocAssistantInfo(n, parent int, completed bool) map[string]any {
	info := map[string]any{"id": fixtureID("msg", n), "sessionID": "s1", "role": "assistant", "parentID": fixtureID("msg", parent), "time": map[string]any{"created": fixtureEpochMs + n*1000}, "modelID": "claude", "providerID": "anthropic", "mode": "build", "agent": "build", "path": map[string]any{"cwd": "/", "root": "/"}, "cost": 0, "tokens": map[string]any{"input": 0, "output": 0, "reasoning": 0, "cache": map[string]any{"read": 0, "write": 0}}}
	if completed {
		info["time"] = map[string]any{"created": fixtureEpochMs + n*1000, "completed": fixtureEpochMs + n*1000 + 500}
		info["cost"] = 0.002
		info["tokens"] = map[string]any{"input": 100, "output": 20, "reasoning": 5, "cache": map[string]any{"read": 50, "write": 0}}
	}
	return info
}

func ocAssistantFixture(n, parent int, text string) map[string]any {
	id := fixtureID("msg", n)
	return map[string]any{"info": ocAssistantInfo(n, parent, true), "parts": []any{map[string]any{"id": fixtureID("prt", n*100), "sessionID": "s1", "messageID": id, "type": "text", "text": text, "time": map[string]any{"start": fixtureEpochMs + n*1000 + 10, "end": fixtureEpochMs + n*1000 + 400}}}}
}

func ocTextPartFixture(message, n int, text string, ended bool) map[string]any {
	times := map[string]any{"start": fixtureEpochMs + message*1000 + n}
	if ended {
		times["end"] = fixtureEpochMs + message*1000 + n + 100
	}
	return map[string]any{"id": fixtureID("prt", message*100+n), "sessionID": "s1", "messageID": fixtureID("msg", message), "type": "text", "text": text, "time": times}
}

// streamEvent is one decoded NDJSON line of GET /v1/chat/events.
type streamEvent struct {
	raw          string
	Seq          uint64            `json:"seq"`
	Type         string            `json:"type"`
	Cursor       string            `json:"cursor"`
	Resumed      *bool             `json:"resumed"`
	Chat         *ChatInfo         `json:"chat"`
	Messages     []ChatMessage     `json:"messages"`
	HasMore      bool              `json:"hasMore"`
	Interactions []ChatInteraction `json:"interactions"`
	Queue        []QueueItem       `json:"queue"`
	Rewind       *rewindRef        `json:"rewind"`
	Message      *ChatMessage      `json:"message"`
	MessageID    string            `json:"messageId"`
	PartID       string            `json:"partId"`
	Part         *ChatPart         `json:"part"`
	Field        string            `json:"field"`
	Offset       int               `json:"offset"`
	Delta        string            `json:"delta"`
	Status       json.RawMessage   `json:"status"`
	State        string            `json:"state"`
	CompletedAt  string            `json:"completedAt"`
	Usage        *ChatUsage        `json:"usage"`
	Error        *ChatError        `json:"error"`
	Interaction  *ChatInteraction  `json:"interaction"`
	ID           string            `json:"id"`
	Outcome      string            `json:"outcome"`
	Items        []QueueItem       `json:"items"`
	TurnID       string            `json:"turnId"`
	Title        string            `json:"title"`
}

type streamReader struct {
	lines chan string
	quit  chan struct{}
	body  io.ReadCloser
}

// openStream opens GET /v1/chat/events; a non-200 answer returns its status
// and body instead of a reader.
func openStream(t *testing.T, server *httptest.Server, token, query string) (*streamReader, int, string) {
	t.Helper()
	request, _ := http.NewRequest("GET", server.URL+"/v1/chat/events?"+query, nil)
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	response, err := server.Client().Do(request)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != 200 {
		body, _ := io.ReadAll(io.LimitReader(response.Body, 64<<10))
		response.Body.Close()
		return nil, response.StatusCode, string(body)
	}
	if got := response.Header.Get("Content-Type"); got != "application/x-ndjson" {
		t.Fatalf("content type %q", got)
	}
	reader := &streamReader{lines: make(chan string, 1<<16), quit: make(chan struct{}), body: response.Body}
	go func() {
		defer close(reader.lines)
		scanner := bufio.NewScanner(response.Body)
		scanner.Buffer(make([]byte, 64<<10), 1<<20)
		for scanner.Scan() {
			line := scanner.Text()
			if len(line) > 256<<10 {
				line = fmt.Sprintf("OVERSIZED %d", len(line))
			}
			select {
			case reader.lines <- line:
			case <-reader.quit:
				return
			}
		}
	}()
	t.Cleanup(reader.close)
	return reader, 200, ""
}

func (s *streamReader) close() {
	select {
	case <-s.quit:
	default:
		close(s.quit)
		s.body.Close()
	}
}

func (s *streamReader) next(t *testing.T, within time.Duration) streamEvent {
	t.Helper()
	select {
	case line, open := <-s.lines:
		if !open {
			t.Fatal("stream closed")
		}
		if strings.HasPrefix(line, "OVERSIZED") {
			t.Fatalf("a stream line exceeded 256 KiB: %s", line)
		}
		var event streamEvent
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			t.Fatalf("stream line %q: %v", line, err)
		}
		event.raw = line
		return event
	case <-time.After(within):
		t.Fatalf("no stream line within %v", within)
		return streamEvent{}
	}
}

// until reads lines until one has the given type and returns all of them.
func (s *streamReader) until(t *testing.T, kind string, within time.Duration) []streamEvent {
	t.Helper()
	deadline := time.Now().Add(within)
	var events []streamEvent
	for {
		event := s.next(t, time.Until(deadline))
		events = append(events, event)
		if event.Type == kind {
			return events
		}
	}
}

// ended reports whether the server closed the stream within the wait.
func (s *streamReader) ended(within time.Duration) bool {
	timer := time.NewTimer(within)
	defer timer.Stop()
	for {
		select {
		case _, open := <-s.lines:
			if !open {
				return true
			}
		case <-timer.C:
			return false
		}
	}
}

// clientChat applies stream events the way a client does, checking that every
// delta continues exactly where its field ends.
type clientChat struct {
	t            *testing.T
	messages     map[string]*ChatMessage
	status       string
	interactions map[string]ChatInteraction
	queue        []QueueItem
	rewind       string
	seq          uint64
	turns        []string
}

func newClientChat(t *testing.T) *clientChat {
	return &clientChat{t: t, messages: map[string]*ChatMessage{}, interactions: map[string]ChatInteraction{}}
}

func (c *clientChat) apply(event streamEvent) {
	c.t.Helper()
	if event.Seq < c.seq && event.Type != "snapshot" && event.Type != "ready" {
		c.t.Fatalf("seq went back from %d to %d: %s", c.seq, event.Seq, event.raw)
	}
	c.seq = event.Seq
	switch event.Type {
	case "snapshot":
		c.messages = map[string]*ChatMessage{}
		for index := range event.Messages {
			message := event.Messages[index]
			c.messages[message.ID] = &message
		}
		var status ChatStatusInfo
		json.Unmarshal(event.Status, &status)
		c.status = status.State
		c.interactions = map[string]ChatInteraction{}
		for _, interaction := range event.Interactions {
			c.interactions[interaction.ID] = interaction
		}
		c.queue = event.Queue
		c.rewind = ""
		if event.Rewind != nil {
			c.rewind = event.Rewind.MessageID
		}
	case "message.created":
		message := *event.Message
		c.messages[message.ID] = &message
	case "message.updated":
		message := c.messages[event.MessageID]
		if message == nil {
			c.t.Fatalf("update for unknown message: %s", event.raw)
		}
		var status string
		json.Unmarshal(event.Status, &status)
		if status != "" {
			message.Status = status
		}
		if event.CompletedAt != "" {
			message.CompletedAt = event.CompletedAt
		}
		if event.Usage != nil {
			message.Usage = event.Usage
		}
		if event.Error != nil {
			message.Error = event.Error
		}
	case "message.removed":
		delete(c.messages, event.MessageID)
	case "part.created", "part.updated":
		message := c.messages[event.MessageID]
		if message == nil {
			c.t.Fatalf("part for unknown message: %s", event.raw)
		}
		for index := range message.Parts {
			if message.Parts[index].ID == event.Part.ID {
				message.Parts[index] = *event.Part
				return
			}
		}
		message.Parts = append(message.Parts, *event.Part)
		sort.SliceStable(message.Parts, func(i, j int) bool { return message.Parts[i].Ord < message.Parts[j].Ord })
	case "part.delta":
		message := c.messages[event.MessageID]
		if message == nil {
			c.t.Fatalf("delta for unknown message: %s", event.raw)
		}
		for index := range message.Parts {
			part := &message.Parts[index]
			if part.ID != event.PartID {
				continue
			}
			field := &part.Text
			if event.Field == "output" {
				field = &part.Tool.Output
			}
			if event.Offset != len(*field) {
				c.t.Fatalf("delta offset %d but the field has %d bytes: %s", event.Offset, len(*field), event.raw[:min(len(event.raw), 200)])
			}
			*field += event.Delta
			return
		}
		c.t.Fatalf("delta for unknown part: %s", event.raw)
	case "part.removed":
		message := c.messages[event.MessageID]
		if message == nil {
			return
		}
		for index := range message.Parts {
			if message.Parts[index].ID == event.PartID {
				message.Parts = append(message.Parts[:index], message.Parts[index+1:]...)
				return
			}
		}
	case "status":
		c.status = event.State
	case "interaction.requested":
		c.interactions[event.Interaction.ID] = *event.Interaction
	case "interaction.resolved":
		delete(c.interactions, event.ID)
	case "queue.updated":
		c.queue = event.Items
	case "turn.started":
		c.turns = append(c.turns, "started:"+event.TurnID)
	case "turn.finished":
		c.turns = append(c.turns, "finished:"+event.TurnID+":"+event.Outcome)
	}
}

// ordered returns the client's messages in ord order.
func (c *clientChat) ordered() []ChatMessage {
	result := make([]ChatMessage, 0, len(c.messages))
	for _, message := range c.messages {
		result = append(result, *message)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Ord < result[j].Ord })
	return result
}

// hubMessages returns the hub's messages for a chat in ord order.
func hubMessages(h *Host, key sessionKey) []ChatMessage {
	h.chat.mu.Lock()
	defer h.chat.mu.Unlock()
	c := h.chat.chats[key]
	if c == nil {
		return nil
	}
	result := make([]ChatMessage, 0, len(c.messages))
	for _, message := range c.messages {
		result = append(result, message.full())
	}
	return result
}

func sameMessages(t *testing.T, got, want []ChatMessage) {
	t.Helper()
	gotJSON, wantJSON := string(marshalJSONLine(got)), string(marshalJSONLine(want))
	if gotJSON != wantJSON {
		t.Fatalf("messages differ:\n got: %s\nwant: %s", clipForLog(gotJSON), clipForLog(wantJSON))
	}
}

func clipForLog(value string) string {
	if len(value) > 3000 {
		return value[:1500] + " … " + value[len(value)-1500:]
	}
	return value
}

func eventTypes(events []streamEvent) string {
	types := make([]string, len(events))
	for index, event := range events {
		types[index] = event.Type
	}
	return strings.Join(types, ",")
}

// streamFixture serves the chat fixture's host over HTTP with fast streams.
func streamFixture(t *testing.T) (*chatFixture, *httptest.Server) {
	t.Helper()
	f := newChatFixture(t)
	f.host.chatPace = time.Millisecond
	f.host.chatBeatEvery = time.Hour
	f.host.chatAuthEvery = time.Hour
	server := httptest.NewServer(f.host.Handler())
	t.Cleanup(server.Close)
	return f, server
}
