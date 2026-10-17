package keeper

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"io"
	"os"
	"testing"
	"time"
)

var update = flag.Bool("update", false, "rewrite the golden transcripts in testdata")

func TestFrameRoundTripAndLimits(t *testing.T) {
	for _, kind := range []byte{kindHello, kindRequest, kindReply, kindData, kindSkipped, kindExited} {
		var buf bytes.Buffer
		if err := writeFrame(&buf, kind, []byte("payload")); err != nil {
			t.Fatal(err)
		}
		k, p, err := readFrame(&buf)
		if err != nil || k != kind || string(p) != "payload" {
			t.Fatalf("kind %c: got %c %q %v", kind, k, p, err)
		}
	}
	for _, n := range []uint32{0, MaxFrame + 1} {
		var h [4]byte
		binary.BigEndian.PutUint32(h[:], n)
		if _, _, err := readFrame(bytes.NewReader(h[:])); !errors.Is(err, ErrFrameTooLarge) {
			t.Fatalf("length %d: err = %v", n, err)
		}
	}
	if err := writeFrame(io.Discard, kindData, make([]byte, MaxFrame)); !errors.Is(err, ErrFrameTooLarge) {
		t.Fatalf("oversized write: %v", err)
	}
	var buf bytes.Buffer
	_ = writeFrame(&buf, kindData, []byte("payload"))
	for _, cut := range []int{buf.Len() - 1, 5, 2} {
		_, _, err := readFrame(bytes.NewReader(buf.Bytes()[:cut]))
		if !errors.Is(err, io.ErrUnexpectedEOF) {
			t.Fatalf("cut at %d: %v", cut, err)
		}
	}
	if _, _, err := readFrame(bytes.NewReader(nil)); err != io.EOF {
		t.Fatalf("empty stream: %v", err)
	}
}

func TestDataPayload(t *testing.T) {
	off, p, err := decodeData(encodeData(42, []byte("xyz")))
	if err != nil || off != 42 || string(p) != "xyz" {
		t.Fatalf("got %d %q %v", off, p, err)
	}
	if _, _, err := decodeData([]byte{1, 2, 3}); err == nil {
		t.Fatal("short payload accepted")
	}
}

func TestChooseProtocol(t *testing.T) {
	cases := []struct {
		h  hello
		v  int
		ok bool
	}{
		{hello{Min: 1, Max: 1}, 1, true},
		{hello{Min: 1, Max: 2}, 1, true},
		{hello{Min: 2, Max: 2}, 0, false},
	}
	for _, c := range cases {
		v, ok := chooseProtocol(c.h, 1, 1)
		if v != c.v || ok != c.ok {
			t.Fatalf("%+v: got %d %v", c.h, v, ok)
		}
	}
}

func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// TestV1TranscriptIsStable pins every v1 byte a keeper and a host exchange:
// both hello roles and their replies (including a refusal), every request op
// and field, every reply shape and error code, and the stream frames with an
// exit the keeper caused. The host and keeper share this package, so only this
// golden catches a rename that would break a keeper still running from an
// older build. v1 only gains fields: regenerate with -update only for that.
func TestV1TranscriptIsStable(t *testing.T) {
	at := time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC)
	zero := 0
	var buf bytes.Buffer
	frames := 0
	put := func(kind byte, payload []byte) {
		if err := writeFrame(&buf, kind, payload); err != nil {
			t.Fatal(err)
		}
		frames++
	}
	meta := []byte(`{"owner":"d1"}`)

	// A control connection: hello, then requests and replies.
	put(kindHello, mustJSON(t, hello{Min: 1, Max: 1, Version: "test", Role: roleControl}))
	put(kindReply, mustJSON(t, helloReply{Protocol: 1, Version: "test", Features: []string{}}))
	put(kindRequest, mustJSON(t, request{Seq: 1, Op: opSpawn, Spawn: &SpawnRequest{
		ID: "t1", Dir: "/tmp", Path: "/bin/zsh", Args: []string{"-l"}, Env: []string{"TERM=xterm-256color"},
		Rows: 24, Cols: 80, Meta: meta}}))
	running := Info{ID: "t1", PID: 123, Started: at, Running: true, Start: 0, Cursor: 5, Meta: meta}
	put(kindReply, mustJSON(t, reply{Seq: 1, Info: &running}))
	put(kindRequest, mustJSON(t, request{Seq: 2, Op: opList}))
	finished := Info{ID: "t2", PID: 124, Started: at,
		Exit: &Exit{Signal: "SIGHUP", At: at, ByKeeper: true}, Start: 7, Cursor: 9}
	put(kindReply, mustJSON(t, reply{Seq: 2, List: []Info{running, finished}}))
	put(kindRequest, mustJSON(t, request{Seq: 3, Op: opInput, ID: "t1", Data: []byte("ls\r")}))
	put(kindRequest, mustJSON(t, request{Seq: 4, Op: opResize, ID: "t1", Rows: 40, Cols: 120}))
	put(kindRequest, mustJSON(t, request{Seq: 5, Op: opSetMeta, ID: "t1", Meta: meta}))
	put(kindRequest, mustJSON(t, request{Seq: 6, Op: opEnd, ID: "t1"}))
	put(kindRequest, mustJSON(t, request{Seq: 7, Op: opForget, ID: "t2"}))
	put(kindRequest, mustJSON(t, request{Seq: 8, Op: opStopAll}))
	put(kindReply, mustJSON(t, reply{Seq: 8}))
	for i, code := range []string{CodeNotFound, CodeExists, CodeLimit, CodeRunning, CodeNotRunning,
		CodeInputStalled, CodeStartFailed, CodeBadRequest, CodeStopping} {
		put(kindReply, mustJSON(t, reply{Seq: uint64(10 + i), Error: &Error{Code: code, Message: "m"}}))
	}

	// A refused hello.
	put(kindHello, mustJSON(t, hello{Min: 2, Max: 2, Version: "future", Role: roleControl}))
	put(kindReply, mustJSON(t, helloReply{Version: "test", Features: []string{}, Error: "no common protocol"}))

	// An attach connection: hello, one attach request, its reply, then the stream.
	put(kindHello, mustJSON(t, hello{Min: 1, Max: 1, Version: "test", Role: roleAttach}))
	put(kindReply, mustJSON(t, helloReply{Protocol: 1, Version: "test", Features: []string{}}))
	put(kindRequest, mustJSON(t, request{Seq: 1, Op: opAttach, ID: "t1", Cursor: 5}))
	put(kindReply, mustJSON(t, reply{Seq: 1, Info: &running}))
	put(kindData, encodeData(5, []byte("abc")))
	put(kindSkipped, encodeSkipped(2097152))
	put(kindExited, mustJSON(t, Exit{Code: &zero, At: at}))
	put(kindExited, mustJSON(t, Exit{Signal: "SIGHUP", At: at, ByKeeper: true}))

	const path = "testdata/v1-transcript.golden"
	if *update {
		if err := os.WriteFile(path, buf.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("%v (run with -update to create it)", err)
	}
	if !bytes.Equal(buf.Bytes(), want) {
		t.Fatalf("v1 transcript changed:\n got %q\nwant %q", buf.Bytes(), want)
	}
	// The pinned bytes must still decode.
	r := bytes.NewReader(want)
	n := 0
	for {
		_, _, err := readFrame(r)
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		n++
	}
	if n != frames {
		t.Fatalf("frames = %d, want %d", n, frames)
	}
	for _, key := range []string{`"byKeeper":true`, `"op":"attach"`, `"cursor":5`, `"role":"attach"`,
		`"data":`, `"rows":40`, `"cols":120`, `"list":[`, `"error":{"code":"not_found"`, `"error":"no common protocol"`} {
		if !bytes.Contains(want, []byte(key)) {
			t.Fatalf("golden lacks %s", key)
		}
	}
}

// TestV1AdoptTranscriptIsStable pins what adopting added to v1: the hello
// feature, the adopt, release and reportExit requests with their fields, the
// adopted terminal's info, the not_adopted code and a released exit.
// Regenerate with -run TestV1AdoptTranscriptIsStable -update, and only for
// added fields.
func TestV1AdoptTranscriptIsStable(t *testing.T) {
	at := time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)
	seven := 7
	var buf bytes.Buffer
	frames := 0
	put := func(kind byte, payload []byte) {
		if err := writeFrame(&buf, kind, payload); err != nil {
			t.Fatal(err)
		}
		frames++
	}
	meta := []byte(`{"owner":"local-mac"}`)

	put(kindHello, mustJSON(t, hello{Min: 1, Max: 1, Version: "test", Role: roleControl}))
	put(kindReply, mustJSON(t, helloReply{Protocol: 1, Version: "test", Features: []string{FeatureAdopt}}))
	put(kindRequest, mustJSON(t, request{Seq: 1, Op: opAdopt, Adopt: &AdoptRequest{
		ID: "term_1", PID: 42, Rows: 24, Cols: 80, Meta: meta}}))
	adopted := Info{ID: "term_1", PID: 42, Started: at, Running: true, Adopted: true,
		LastInput: at.Add(3 * time.Second), Start: 0, Cursor: 5, Meta: meta}
	put(kindReply, mustJSON(t, reply{Seq: 1, Info: &adopted}))
	put(kindRequest, mustJSON(t, request{Seq: 2, Op: opRelease, ID: "term_1"}))
	put(kindRequest, mustJSON(t, request{Seq: 3, Op: opReportExit, ID: "term_1", Exit: &Exit{Code: &seven, At: at}}))
	put(kindReply, mustJSON(t, reply{Seq: 4, Error: &Error{Code: CodeNotAdopted, Message: "m"}}))
	put(kindExited, mustJSON(t, Exit{At: at, Released: true}))

	const path = "testdata/v1-adopt.golden"
	if *update {
		if err := os.WriteFile(path, buf.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("%v (run with -update to create it)", err)
	}
	if !bytes.Equal(buf.Bytes(), want) {
		t.Fatalf("v1 adopt transcript changed:\n got %q\nwant %q", buf.Bytes(), want)
	}
	r := bytes.NewReader(want)
	n := 0
	for {
		_, _, err := readFrame(r)
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		n++
	}
	if n != frames {
		t.Fatalf("frames = %d, want %d", n, frames)
	}
	for _, key := range []string{`"features":["adopt"]`, `"op":"adopt"`, `"adopt":{"id":"term_1","pid":42,"rows":24,"cols":80,"meta":`,
		`"adopted":true`, `"lastInput":"2026-10-15T12:00:03Z"`, `"op":"release"`, `"op":"reportExit"`, `"exit":{"code":7,`,
		`"code":"not_adopted"`, `"released":true`} {
		if !bytes.Contains(want, []byte(key)) {
			t.Fatalf("golden lacks %s", key)
		}
	}
}

func TestDecodeRequestValidates(t *testing.T) {
	if _, err := decodeRequest([]byte(`{"seq":1,"op":"list"}`)); err != nil {
		t.Fatal(err)
	}
	tooLarge := string(bytes.Repeat([]byte("A"), 30000))
	for _, bad := range []string{`{`, `{"op":"nope"}`, `{"op":"setMeta","meta":"` + tooLarge + `"}`,
		`{"op":"adopt","adopt":{"id":"a","pid":1,"meta":"` + tooLarge + `"}}`} {
		if _, err := decodeRequest([]byte(bad)); err == nil {
			t.Fatalf("accepted %.40s", bad)
		}
	}
}
