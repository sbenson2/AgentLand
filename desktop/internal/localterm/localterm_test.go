package localterm

import (
	"bufio"
	"bytes"
	"errors"
	"io"
	"reflect"
	"strings"
	"testing"
)

func TestLineRoundTripAndLimit(t *testing.T) {
	var buffer bytes.Buffer
	sent := Request{Op: OpRegister, Command: "/opt/homebrew/bin/claude", Folder: "/Users/me/a b/ünï", Rows: 24, Cols: 80,
		ConversationID: "0f6f2a3c-1b2d-4e5f-8a9b-0c1d2e3f4a5b", Version: "1.2.3"}
	if err := WriteLine(&buffer, sent); err != nil {
		t.Fatal(err)
	}
	line := buffer.String()
	if strings.Count(line, "\n") != 1 || !strings.HasSuffix(line, "\n") || !strings.Contains(line, `"conversationId":"0f6f2a3c-`) {
		t.Fatalf("line %q", line)
	}
	var got Request
	if err := ReadLine(bufio.NewReaderSize(&buffer, 16), &got); err != nil || got != sent {
		t.Fatalf("read %+v, %v", got, err)
	}

	// Fields left out are left off the wire.
	buffer.Reset()
	if err := WriteLine(&buffer, Request{Op: OpCancel}); err != nil || buffer.String() != `{"op":"cancel"}`+"\n" {
		t.Fatalf("cancel %q, %v", buffer.String(), err)
	}
	buffer.Reset()
	reply := Reply{ID: "term_1", Meta: []byte(`{"v":2}`), Error: &Error{Code: CodeLimit, Message: "full"}}
	if err := WriteLine(&buffer, reply); err != nil {
		t.Fatal(err)
	}
	var back Reply
	if err := ReadLine(bufio.NewReader(&buffer), &back); err != nil || !reflect.DeepEqual(back, reply) {
		t.Fatalf("reply %+v, %v", back, err)
	}

	// A line of exactly MaxLine bytes is read; one byte more is refused, on
	// both sides.
	exact := `"` + strings.Repeat("x", MaxLine-2) + `"` + "\n"
	var text string
	if err := ReadLine(bufio.NewReader(strings.NewReader(exact)), &text); err != nil || len(text) != MaxLine-2 {
		t.Fatalf("exact line: %d, %v", len(text), err)
	}
	over := `"` + strings.Repeat("x", MaxLine-1) + `"` + "\n"
	if err := ReadLine(bufio.NewReader(strings.NewReader(over)), &text); !errors.Is(err, ErrLineTooLong) {
		t.Fatalf("over line: %v", err)
	}
	buffer.Reset()
	if err := WriteLine(&buffer, Request{Command: strings.Repeat("x", MaxLine)}); !errors.Is(err, ErrLineTooLong) || buffer.Len() != 0 {
		t.Fatalf("over write: %v, %d bytes", err, buffer.Len())
	}

	// Nothing at all is io.EOF; a line cut short is not.
	if err := ReadLine(bufio.NewReader(strings.NewReader("")), &got); err != io.EOF {
		t.Fatalf("empty: %v", err)
	}
	if err := ReadLine(bufio.NewReader(strings.NewReader(`{"op":"adop`)), &got); err == nil || err == io.EOF {
		t.Fatalf("cut short: %v", err)
	}
	if path := SocketPath("/Users/me/Library/Application Support/AgentLand/host.json"); path != "/Users/me/Library/Application Support/AgentLand/terminals-local.sock" {
		t.Fatalf("socket %s", path)
	}
}

func TestContinueRoundTrip(t *testing.T) {
	var buffer bytes.Buffer
	sent := Request{Op: OpContinue, From: "term_0123456789abcdef", Prompt: `Read HANDOFF.md — "go on"`, Rows: 40, Cols: 120, Version: "1.2.3"}
	if err := WriteLine(&buffer, sent); err != nil {
		t.Fatal(err)
	}
	line := buffer.String()
	if !strings.Contains(line, `"op":"continue"`) || !strings.Contains(line, `"from":"term_0123456789abcdef"`) || !strings.Contains(line, `"prompt":"Read HANDOFF.md`) {
		t.Fatalf("line %q", line)
	}
	var got Request
	if err := ReadLine(bufio.NewReader(&buffer), &got); err != nil || got != sent {
		t.Fatalf("read %+v, %v", got, err)
	}
	// A register leaves them off the wire.
	buffer.Reset()
	if err := WriteLine(&buffer, Request{Op: OpRegister}); err != nil || strings.Contains(buffer.String(), "from") || strings.Contains(buffer.String(), "prompt") {
		t.Fatalf("register %q, %v", buffer.String(), err)
	}
	buffer.Reset()
	reply := Reply{Error: &Error{Code: CodeNotContinuable, Message: "This terminal has ended."}}
	if err := WriteLine(&buffer, reply); err != nil || !strings.Contains(buffer.String(), `"code":"terminal_not_continuable"`) {
		t.Fatalf("refusal %q, %v", buffer.String(), err)
	}
}

func TestContinueChatRoundTrip(t *testing.T) {
	var buffer bytes.Buffer
	sent := Request{Op: OpContinueChat, Chat: "claude:0123456789abcdef", Prompt: `Read HANDOFF.md — "go on"`, Version: "1.2.3"}
	if err := WriteLine(&buffer, sent); err != nil {
		t.Fatal(err)
	}
	line := buffer.String()
	if !strings.Contains(line, `"op":"continueChat"`) || !strings.Contains(line, `"chat":"claude:0123456789abcdef"`) || strings.Contains(line, `"from"`) || strings.Contains(line, `"rows"`) {
		t.Fatalf("line %q", line)
	}
	var got Request
	if err := ReadLine(bufio.NewReader(&buffer), &got); err != nil || got != sent {
		t.Fatalf("read %+v, %v", got, err)
	}
	// A terminal's continue leaves the chat off the wire.
	buffer.Reset()
	if err := WriteLine(&buffer, Request{Op: OpContinue, From: "term_1"}); err != nil || strings.Contains(buffer.String(), "chat") {
		t.Fatalf("continue %q, %v", buffer.String(), err)
	}
	buffer.Reset()
	reply := Reply{Error: &Error{Code: CodeChatNotContinuable, Message: "Only a Claude Code chat can be continued."}}
	if err := WriteLine(&buffer, reply); err != nil || !strings.Contains(buffer.String(), `"code":"chat_not_continuable"`) {
		t.Fatalf("refusal %q, %v", buffer.String(), err)
	}
}
