//go:build darwin

package keeper

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// fakeKeeper listens on a socket and answers every hello with answer. A nil
// answer never replies.
func fakeKeeper(t *testing.T, answer *helloReply) string {
	t.Helper()
	path := filepath.Join(shortTempDir(t), "terminals.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	var conns []net.Conn
	var mu sync.Mutex
	t.Cleanup(func() {
		listener.Close()
		mu.Lock()
		for _, conn := range conns {
			conn.Close()
		}
		mu.Unlock()
		wg.Wait()
	})
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			mu.Lock()
			conns = append(conns, conn)
			mu.Unlock()
			if _, _, err := readFrame(conn); err != nil || answer == nil {
				continue
			}
			payload, _ := json.Marshal(answer)
			_ = writeFrame(conn, kindReply, payload)
		}
	}()
	return path
}

func TestDialReportsNoCommonProtocol(t *testing.T) {
	for _, answer := range []helloReply{
		{Version: "future", Error: "no common protocol"},
		{Protocol: ProtocolMax + 1, Version: "future"},
	} {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		c, err := Dial(ctx, fakeKeeper(t, &answer), testVersion)
		cancel()
		if !errors.Is(err, ErrNoCommonProtocol) {
			if c != nil {
				c.Close()
			}
			t.Fatalf("answer %+v: Dial = %v", answer, err)
		}
	}
}

func TestDialGivesUpOnAKeeperThatNeverAnswers(t *testing.T) {
	path := fakeKeeper(t, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	began := time.Now()
	c, err := Dial(ctx, path, testVersion)
	if err == nil {
		c.Close()
		t.Fatal("Dial succeeded without a hello reply")
	}
	if errors.Is(err, ErrNoCommonProtocol) {
		t.Fatalf("a silent keeper is not a protocol mismatch: %v", err)
	}
	if took := time.Since(began); took > 2*time.Second {
		t.Fatalf("gave up after %v", took)
	}
}

func TestRemoteErrorsCrossTheWire(t *testing.T) {
	k := serveForTest(t, ServeOptions{})
	c := dialForTest(t, k)
	ctx := testContext(t)

	if err := c.Input(ctx, "nope", []byte("x")); !IsNotFound(err) {
		t.Fatalf("Input to a missing terminal = %v", err)
	}
	if _, err := c.Attach(ctx, "nope", 0); !IsNotFound(err) {
		t.Fatalf("Attach to a missing terminal = %v", err)
	}
	if _, err := c.End(ctx, "nope"); !IsNotFound(err) {
		t.Fatalf("End of a missing terminal = %v", err)
	}
	spawnForTest(t, c, shellRequest(t, "t1", "true"))
	waitUntilFinished(t, c, "t1")
	if err := c.Input(ctx, "t1", []byte("x")); remoteCode(err) != CodeNotRunning || IsNotFound(err) {
		t.Fatalf("Input to a finished terminal = %v", err)
	}
	if IsNotFound(errors.New("not_found")) || IsInputStalled(nil) {
		t.Fatal("a plain error counted as a remote one")
	}
	if !IsNotFound(fmt.Errorf("wrapped: %w", &RemoteError{Code: CodeNotFound})) {
		t.Fatal("a wrapped remote error was missed")
	}
}

func TestStalledInputIsReportedAsInputStalled(t *testing.T) {
	saved := inputWait
	inputWait = 300 * time.Millisecond
	t.Cleanup(func() { inputWait = saved })
	k := serveForTest(t, ServeOptions{})
	c := dialForTest(t, k)
	ctx := testContext(t)
	spawnForTest(t, c, shellRequest(t, "t1", "sleep 30"))

	// Whole lines: canonical mode holds complete lines until the program reads.
	chunk := bytes.Repeat([]byte("0123456789abcde\n"), 2048)
	stalled := false
	for i := 0; i < 64 && !stalled; i++ {
		err := c.Input(ctx, "t1", chunk)
		switch {
		case IsInputStalled(err):
			stalled = true
		case err != nil:
			t.Fatalf("input %d: %v", i, err)
		}
	}
	if !stalled {
		t.Fatal("input was never refused")
	}
	list, err := c.List(ctx)
	if err != nil || len(list) != 1 || !list[0].Running {
		t.Fatalf("List = %+v, %v", list, err)
	}
}

func TestConcurrentCallsGetTheirOwnReplies(t *testing.T) {
	k := serveForTest(t, ServeOptions{})
	c := dialForTest(t, k)
	ctx := testContext(t)
	var wg sync.WaitGroup
	errs := make(chan error, 8)
	for i := range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			id := fmt.Sprintf("t%d", i)
			info, err := c.Spawn(ctx, shellRequest(t, id, "sleep 30"))
			if err == nil && info.ID != id {
				err = fmt.Errorf("spawn %s answered for %s", id, info.ID)
			}
			if err == nil {
				_, err = c.List(ctx)
			}
			errs <- err
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	if list, err := c.List(ctx); err != nil || len(list) != 8 {
		t.Fatalf("List = %d, %v", len(list), err)
	}
}

func TestCallsFailOnceTheKeeperIsGone(t *testing.T) {
	k := serveForTest(t, ServeOptions{})
	c := dialForTest(t, k)
	k.cancel()
	select {
	case <-c.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("Done never closed")
	}
	if _, err := c.List(testContext(t)); err == nil {
		t.Fatal("List succeeded after the keeper left")
	}
}

func TestACallWithAnEndedContextLeavesTheConnection(t *testing.T) {
	k := serveForTest(t, ServeOptions{})
	c := dialForTest(t, k)
	ended, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := c.List(ended); !errors.Is(err, context.Canceled) {
		t.Fatalf("List with an ended context = %v", err)
	}
	if _, err := c.List(testContext(t)); err != nil {
		t.Fatalf("the connection broke: %v", err)
	}
}

func TestCloseEndsTheClient(t *testing.T) {
	k := serveForTest(t, ServeOptions{})
	c := dialForTest(t, k)
	if err := c.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-c.Done():
	case <-time.After(time.Second):
		t.Fatal("Done stayed open after Close")
	}
	if _, err := c.List(testContext(t)); err == nil {
		t.Fatal("List succeeded after Close")
	}
}
