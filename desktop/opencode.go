package host

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// OpenCode stores each attachment as a data URL inside the transcript, so a
// chat with files can be far larger than an ordinary response.
const openCodeTranscriptLimit = 256 << 20

type OpenCodeAdapter struct {
	base               *url.URL
	username, password string
	client             *http.Client
}

func NewOpenCodeAdapter(raw, username, password string, client *http.Client) *OpenCodeAdapter {
	u, _ := url.Parse(raw)
	if username == "" {
		username = "opencode"
	}
	if client == nil {
		client = &http.Client{Timeout: 30 * time.Second}
	}
	copyClient := *client
	copyClient.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	if copyClient.Timeout == 0 {
		copyClient.Timeout = 30 * time.Second
	}
	return &OpenCodeAdapter{base: u, username: username, password: password, client: &copyClient}
}

// attachTarget is what `opencode attach` needs to reach this server: its URL
// and basic-auth credentials (terminal_launch.go passes the credentials in
// the environment, never in arguments).
func (a *OpenCodeAdapter) attachTarget() (url, user, password string) {
	return a.base.String(), a.username, a.password
}

// openCodeStatusError is a response OpenCode sent; the request was received
// and rejected rather than lost in transport.
type openCodeStatusError struct{ status int }

func (e openCodeStatusError) Error() string {
	return fmt.Sprintf("OpenCode returned HTTP %d", e.status)
}

type ocSession struct {
	ID        string `json:"id"`
	Title     string `json:"title"`
	ProjectID string `json:"projectID"`
	Directory string `json:"directory"`
	Revert    *struct {
		MessageID string `json:"messageID"`
	} `json:"revert"`
	// Archive (M1 chunk B2): the backfill orders sessions by update time and
	// keeps their creation time.
	Time struct {
		Created float64 `json:"created"`
		Updated float64 `json:"updated"`
	} `json:"time"`
}

func sessionFromOC(s ocSession) Session {
	session := Session{ID: s.ID, Title: s.Title, ProjectID: s.ProjectID, Directory: s.Directory}
	if s.Revert != nil {
		session.RewindMessageID = s.Revert.MessageID
	}
	return session
}
func (a *OpenCodeAdapter) ListSessions(p Project) ([]Session, error) {
	var in []ocSession
	if err := a.do("GET", "/session", p, nil, &in); err != nil {
		return nil, err
	}
	out := make([]Session, 0, len(in))
	for _, s := range in {
		out = append(out, sessionFromOC(s))
	}
	return out, nil
}
func (a *OpenCodeAdapter) CreateSession(p Project, title string) (Session, error) {
	var in ocSession
	err := a.do("POST", "/session", p, map[string]string{"title": title}, &in)
	return sessionFromOC(in), err
}
func (a *OpenCodeAdapter) GetSession(p Project, id string) (Session, error) {
	var in ocSession
	err := a.do("GET", "/session/"+url.PathEscape(id), p, nil, &in)
	return sessionFromOC(in), err
}

// sessionRenamer renames a chat in its provider (chat names, chat_title.go).
type sessionRenamer interface {
	RenameSession(p Project, id, title string) (Session, error)
}

// RenameSession sets a session's title with OpenCode 1.18.31's
// session.update (PATCH /session/{id} {"title"}), which answers the updated
// session and tells its event stream (session.updated).
func (a *OpenCodeAdapter) RenameSession(p Project, id, title string) (Session, error) {
	var in ocSession
	if err := a.do("PATCH", "/session/"+url.PathEscape(id), p, map[string]string{"title": title}, &in); err != nil {
		return Session{}, err
	}
	if in.ID != id {
		return Session{}, errors.New("OpenCode renamed another session")
	}
	return sessionFromOC(in), nil
}

// ocPart holds the fields of every OpenCode 1.18.31 part type the host maps.
// Numbers are float64 and the retry error stays raw, so an unexpected value
// in one part type cannot fail a whole transcript.
type ocPart struct {
	ID, Type, Text, Tool, CallID string
	SessionID, MessageID         string
	Synthetic                    bool
	Mime, Filename               string
	Time                         struct{ Start, End, Created float64 }
	State                        struct {
		Status, Title, Output, Error string
		Input                        json.RawMessage
		// Metadata keeps only its agentland member, the tool server's result
		// that plain chats read (plain_chat_results.go).
		Metadata ocToolMetadata
		Time     struct{ Start, End float64 }
	}
	// patch, step-finish, retry, agent and subtask parts.
	Files                    []string
	Reason                   string
	Attempt                  float64
	Name, Agent, Description string
	RetryError               json.RawMessage `json:"error"`
}

type ocTokens struct {
	Input, Output, Reasoning float64
	Cache                    struct{ Read, Write float64 }
}

// ocInfo is an OpenCode user or assistant message without its parts.
type ocInfo struct {
	ID         string  `json:"id"`
	SessionID  string  `json:"sessionID"`
	Role       string  `json:"role"`
	ParentID   string  `json:"parentID"`
	ModelID    string  `json:"modelID"`
	ProviderID string  `json:"providerID"`
	Agent      string  `json:"agent"`
	Variant    string  `json:"variant"`
	Cost       float64 `json:"cost"`
	Tokens     ocTokens
	Time       struct{ Created, Completed float64 }
	// A user message names the model and variant it was sent with.
	Model struct {
		ProviderID string `json:"providerID"`
		ModelID    string `json:"modelID"`
		Variant    string `json:"variant"`
	} `json:"model"`
	Error *struct {
		Name string
		Data struct{ Message string }
	}
}

type ocMessage struct {
	Info  ocInfo
	Parts []ocPart
}

func (a *OpenCodeAdapter) Messages(p Project, id string) ([]Message, error) {
	in, _, err := a.messagePage(p, id, 0, "")
	if err != nil {
		return nil, err
	}
	out := make([]Message, 0, len(in))
	for _, m := range in {
		if m.Info.Role == "user" || m.Info.Role == "assistant" {
			out = append(out, messageFromOC(m, p.Directory))
		}
	}
	return out, nil
}

// messagePage reads a chat's messages oldest first. With limit 0 it reads the
// whole transcript; otherwise the newest limit messages older than the page
// cursor, and more reports that older messages exist.
func (a *OpenCodeAdapter) messagePage(p Project, id string, limit int, cursor string) ([]ocMessage, bool, error) {
	route := "/session/" + url.PathEscape(id) + "/message"
	if limit > 0 {
		query := url.Values{"limit": {strconv.Itoa(limit)}}
		if cursor != "" {
			query.Set("before", cursor)
		}
		route += "?" + query.Encode()
	}
	response, err := a.send("GET", route, p, nil)
	if err != nil {
		return nil, false, err
	}
	defer response.Body.Close()
	in, err := decodeOCMessages(io.LimitReader(response.Body, openCodeTranscriptLimit))
	if err != nil {
		return nil, false, err
	}
	io.Copy(io.Discard, io.LimitReader(response.Body, 64<<10))
	return in, limit > 0 && response.Header.Get("X-Next-Cursor") != "", nil
}

// message reads one message's info; its parts are skipped one at a time.
func (a *OpenCodeAdapter) message(p Project, sessionID, messageID string) (ocInfo, error) {
	response, err := a.send("GET", "/session/"+url.PathEscape(sessionID)+"/message/"+url.PathEscape(messageID), p, nil)
	if err != nil {
		return ocInfo{}, err
	}
	defer response.Body.Close()
	decoder := json.NewDecoder(io.LimitReader(response.Body, openCodeTranscriptLimit))
	var info ocInfo
	if token, err := decoder.Token(); err != nil || token != json.Delim('{') {
		return ocInfo{}, errors.Join(err, errUnexpectedTranscript)
	}
	for decoder.More() {
		key, err := decoder.Token()
		if err != nil {
			return ocInfo{}, err
		}
		if key == "info" {
			err = decoder.Decode(&info)
		} else {
			err = skipJSONValue(decoder)
		}
		if err != nil {
			return ocInfo{}, err
		}
	}
	if info.ID != messageID {
		return ocInfo{}, ErrNotFound
	}
	return info, nil
}

// skipJSONValue skips one value, holding at most one array element at a time.
func skipJSONValue(decoder *json.Decoder) error {
	var ignored json.RawMessage
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	switch token {
	case json.Delim('['):
		for decoder.More() {
			if err := decoder.Decode(&ignored); err != nil {
				return err
			}
		}
		_, err = decoder.Token()
	case json.Delim('{'):
		for decoder.More() {
			if _, err := decoder.Token(); err != nil {
				return err
			}
			if err := decoder.Decode(&ignored); err != nil {
				return err
			}
		}
		_, err = decoder.Token()
	}
	return err
}

// decodeOCMessages holds at most one part at a time, so a large data URL is
// never buffered together with the rest of the transcript. Like a plain
// decode, it treats a null transcript, message or part list as empty.
func decodeOCMessages(r io.Reader) ([]ocMessage, error) {
	decoder := json.NewDecoder(r)
	var result []ocMessage
	err := decodeJSONArray(decoder, func() error {
		var message ocMessage
		token, err := decoder.Token()
		if err != nil || token == nil {
			return err
		}
		if token != json.Delim('{') {
			return errUnexpectedTranscript
		}
		for decoder.More() {
			key, err := decoder.Token()
			if err != nil {
				return err
			}
			switch key {
			case "info":
				err = decoder.Decode(&message.Info)
			case "parts":
				err = decodeJSONArray(decoder, func() error {
					var part ocPart
					err := decoder.Decode(&part)
					message.Parts = append(message.Parts, part)
					return err
				})
			default:
				var ignored json.RawMessage
				err = decoder.Decode(&ignored)
			}
			if err != nil {
				return err
			}
		}
		if token, err = decoder.Token(); err != nil || token != json.Delim('}') {
			return errors.Join(err, errUnexpectedTranscript)
		}
		result = append(result, message)
		return nil
	})
	return result, err
}

var errUnexpectedTranscript = errors.New("unexpected OpenCode message format")

// decodeJSONArray calls element for each value of an array or accepts null.
func decodeJSONArray(decoder *json.Decoder, element func() error) error {
	token, err := decoder.Token()
	if err != nil || token == nil {
		return err
	}
	if token != json.Delim('[') {
		return errUnexpectedTranscript
	}
	for decoder.More() {
		if err := element(); err != nil {
			return err
		}
	}
	if token, err = decoder.Token(); err != nil || token != json.Delim(']') {
		return errors.Join(err, errUnexpectedTranscript)
	}
	return nil
}

// messageFromOC fills the legacy fields exactly as before the unified model
// existed and attaches the unified form: ordered parts with timestamps, the
// model and usage. root makes patch paths relative to the project.
func messageFromOC(m ocMessage, root string) Message {
	message := Message{ID: m.Info.ID, Role: m.Info.Role}
	unified := chatHeaderFromOC(m.Info)
	for index, part := range m.Parts {
		if len(unified.Parts) == chatPartsPerMessage {
			break
		}
		if mapped, ok := chatPartFromOC(part, index, root); ok {
			unified.Parts = append(unified.Parts, mapped)
		}
	}
	message.Unified = &unified
	var text []string
	for _, part := range m.Parts {
		switch part.Type {
		case "text":
			// OpenCode adds attached file contents to the prompt as synthetic text.
			if !part.Synthetic {
				text = append(text, part.Text)
			}
		case "reasoning":
			if strings.TrimSpace(part.Text) == "" {
				continue
			}
			value, _ := boundedToolText(part.Text)
			reasoning := ReasoningPart{Text: value}
			if part.Time.End > part.Time.Start {
				reasoning.DurationMs = int64(part.Time.End - part.Time.Start)
			}
			message.Reasoning = append(message.Reasoning, reasoning)
		case "file":
			name := part.Filename
			if name == "" {
				name = "attachment"
			}
			message.Attachments = append(message.Attachments, AttachmentInfo{Name: name, MIME: part.Mime})
		case "tool":
			input, inputCut := boundedToolText(string(part.State.Input))
			output, outputCut := boundedToolText(part.State.Output)
			failure, errorCut := boundedToolText(part.State.Error)
			message.Tools = append(message.Tools, ToolCall{ID: part.ID, CallID: part.CallID, Name: part.Tool, Status: part.State.Status, Title: part.State.Title, Input: input, Output: output, Error: failure, Truncated: inputCut || outputCut || errorCut})
		}
	}
	message.Text = strings.Join(text, "\n")
	if m.Info.Error != nil {
		message.Error, _ = boundedToolText(m.Info.Error.Data.Message)
		if strings.TrimSpace(message.Error) == "" {
			message.Error = "The agent could not complete this request. Check its provider settings on the host."
		}
	}
	return message
}

// Bound rendered tool fields independently; the client visibly marks a clipped
// result. Never apply this to permission patterns or question choices.
func boundedToolText(value string) (string, bool) {
	const limit = 64 << 10
	if len(value) <= limit {
		return value, false
	}
	end := limit
	for end > 0 && !utf8.RuneStart(value[end]) {
		end--
	}
	return value[:end], true
}
func (a *OpenCodeAdapter) Prompt(p Project, id, text string) error {
	return a.do("POST", "/session/"+url.PathEscape(id)+"/prompt_async", p, map[string]any{"parts": []any{map[string]string{"type": "text", "text": text}}}, nil)
}

// PromptAttachments sends each claimed file inline as a data URL. OpenCode
// 1.18.31 turns only text/plain data into readable prompt text and forwards
// other types to the model provider, so every accepted text type uses it.
func (a *OpenCodeAdapter) PromptAttachments(p Project, id, text string, options PromptOptions, files []ChatAttachment) error {
	if !validSendOptions(options) {
		return fmt.Errorf("invalid prompt options: %w", errPromptNotSent)
	}
	payload, err := openCodePromptBody(text, options, files)
	if err != nil {
		return err
	}
	return a.doPayload("POST", "/session/"+url.PathEscape(id)+"/prompt_async", p, payload, nil, 2<<20)
}

func openCodePromptBody(text string, options PromptOptions, files []ChatAttachment) ([]byte, error) {
	var body bytes.Buffer
	estimate := len(text) + 1024
	for _, file := range files {
		estimate += int(file.Size+2)/3*4 + 512
	}
	body.Grow(estimate)
	body.WriteString(`{"parts":[`)
	if text != "" {
		encoded, _ := json.Marshal(map[string]string{"type": "text", "text": text})
		body.Write(encoded)
	}
	for index, file := range files {
		if index > 0 || text != "" {
			body.WriteByte(',')
		}
		mimeType := file.MIME
		if strings.HasPrefix(mimeType, "text/") || mimeType == "application/json" {
			mimeType = "text/plain"
		}
		header, _ := json.Marshal(map[string]string{"type": "file", "mime": mimeType, "filename": file.Name})
		body.Write(header[:len(header)-1])
		body.WriteString(`,"url":"data:` + mimeType + `;base64,`)
		if err := appendBase64File(&body, file); err != nil {
			return nil, err
		}
		body.WriteString(`"}`)
	}
	body.WriteByte(']')
	if options.MessageID != "" {
		encoded, _ := json.Marshal(options.MessageID)
		body.WriteString(`,"messageID":`)
		body.Write(encoded)
	}
	if options.Model != "" {
		provider, model, _ := strings.Cut(options.Model, "/")
		encoded, _ := json.Marshal(map[string]string{"providerID": provider, "modelID": model})
		body.WriteString(`,"model":`)
		body.Write(encoded)
	}
	if options.Agent != "" {
		encoded, _ := json.Marshal(options.Agent)
		body.WriteString(`,"agent":`)
		body.Write(encoded)
	}
	// Plain chats: OpenCode 1.18.31's prompt system text.
	if options.System != "" {
		encoded, _ := json.Marshal(options.System)
		body.WriteString(`,"system":`)
		body.Write(encoded)
	}
	body.WriteByte('}')
	return body.Bytes(), nil
}

func appendBase64File(out *bytes.Buffer, file ChatAttachment) error {
	handle, err := os.Open(file.Path)
	if err != nil {
		return errAttachmentUnreadable
	}
	defer handle.Close()
	info, err := handle.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() != file.Size {
		return errAttachmentUnreadable
	}
	encoder := base64.NewEncoder(base64.StdEncoding, out)
	copied, err := io.Copy(encoder, io.LimitReader(handle, file.Size+1))
	if err != nil || copied != file.Size {
		return errAttachmentUnreadable
	}
	return encoder.Close()
}
func (a *OpenCodeAdapter) Abort(p Project, id string) error {
	var ok bool
	if err := a.do("POST", "/session/"+url.PathEscape(id)+"/abort", p, nil, &ok); err != nil {
		return err
	}
	if !ok {
		return errors.New("OpenCode did not abort session")
	}
	return nil
}

// Rewind uses OpenCode's revert, which also restores files changed after the
// message. Unrevert brings back both the messages and those file changes.
func (a *OpenCodeAdapter) Rewind(p Project, id, messageID string) error {
	return a.do("POST", "/session/"+url.PathEscape(id)+"/revert", p, map[string]string{"messageID": messageID}, nil)
}
func (a *OpenCodeAdapter) Restore(p Project, id string) error {
	return a.do("POST", "/session/"+url.PathEscape(id)+"/unrevert", p, nil, nil)
}
func (a *OpenCodeAdapter) do(method, pth string, project Project, body, out any) error {
	return a.doLimited(method, pth, project, body, out, 2<<20)
}
func (a *OpenCodeAdapter) doLimited(method, pth string, project Project, body, out any, limit int64) error {
	var payload []byte
	if body != nil {
		var err error
		if payload, err = json.Marshal(body); err != nil {
			return err
		}
	}
	return a.doPayload(method, pth, project, payload, out, limit)
}
func (a *OpenCodeAdapter) doPayload(method, pth string, project Project, payload []byte, out any, limit int64) error {
	resp, err := a.send(method, pth, project, payload)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	limited := io.LimitReader(resp.Body, limit)
	if out == nil {
		io.Copy(io.Discard, limited)
		return nil
	}
	return json.NewDecoder(limited).Decode(out)
}

// getContext sends one request within ctx and decodes at most limit bytes of
// its answer into out (nil discards it). Plain chats check the Chats space
// with it (plain_chats.go).
func (a *OpenCodeAdapter) getContext(ctx context.Context, method, pth string, project Project, out any, limit int64) error {
	resp, err := a.sendContext(ctx, method, pth, project, nil)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	limited := io.LimitReader(resp.Body, limit)
	if out == nil {
		io.Copy(io.Discard, limited)
		return nil
	}
	return json.NewDecoder(limited).Decode(out)
}

// legacyPTYWait bounds endLegacyPTY.
const legacyPTYWait = 3 * time.Second

// endLegacyPTY ends a terminal an older host ran as one of OpenCode's PTYs
// (an archive log whose terminal ID starts with "pty_"), within 3 s. The
// host's restore calls it once, best effort, for each such log still
// running (terminal_restore.go).
func (a *OpenCodeAdapter) endLegacyPTY(ctx context.Context, project Project, id string) error {
	ctx, cancel := context.WithTimeout(ctx, legacyPTYWait)
	defer cancel()
	return a.getContext(ctx, "DELETE", "/pty/"+url.PathEscape(id), project, nil, 1<<10)
}

// createSessionWithRules creates a session with OpenCode 1.18.31's session
// permission rule list (POST /session {title, permission}): plain chats
// deny every tool but the chat agent's.
func (a *OpenCodeAdapter) createSessionWithRules(p Project, title string, rules []ocPermissionRule) (Session, error) {
	var in ocSession
	err := a.do("POST", "/session", p, map[string]any{"title": title, "permission": rules}, &in)
	return sessionFromOC(in), err
}

// send returns only successful responses; the caller closes the body.
func (a *OpenCodeAdapter) send(method, pth string, project Project, payload []byte) (*http.Response, error) {
	return a.sendContext(context.Background(), method, pth, project, payload)
}

func (a *OpenCodeAdapter) sendContext(ctx context.Context, method, pth string, project Project, payload []byte) (*http.Response, error) {
	u := *a.base
	route, query, _ := strings.Cut(pth, "?")
	u.Path = path.Join(a.base.Path, route)
	u.RawQuery = query
	var reader io.Reader
	if payload != nil {
		reader = bytes.NewReader(payload)
	}
	req, err := http.NewRequestWithContext(ctx, method, u.String(), reader)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("X-OpenCode-Directory", project.Directory)
	req.SetBasicAuth(a.username, a.password)
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := a.client.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return resp, nil
	}
	io.Copy(io.Discard, io.LimitReader(resp.Body, 2<<20))
	resp.Body.Close()
	if resp.StatusCode == 404 {
		return nil, ErrNotFound
	}
	return nil, openCodeStatusError{resp.StatusCode}
}
