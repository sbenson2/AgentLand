package host

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"
)

// causeRunner runs one-shot prompts until their context ends, and says why
// it ended.
type causeRunner struct{ causes chan error }

func (causeRunner) Available() []string { return []string{"claude", "codex"} }
func (r causeRunner) Run(ctx context.Context, _, _, _, _ string, _ []ChatAttachment) (CLIChatResult, error) {
	<-ctx.Done()
	r.causes <- context.Cause(ctx)
	return CLIChatResult{}, ctx.Err()
}

// A one-shot run's context says why it ended, which sets its grace: Stop
// (no cause) gives it oneShotStopGrace, the host's shutdown agentShutdownKill,
// from BeginShutdown on (stopAgents), after which no run starts.
func TestOneShotRunsEndWithTheirCause(t *testing.T) {
	runner := causeRunner{causes: make(chan error, 1)}
	chats, err := NewCLIChats(filepath.Join(t.TempDir(), "chats.json"), runner)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(chats.Close)
	project := Project{ID: "p1", Directory: t.TempDir()}
	session, err := chats.CreateSession(project, "One shot", "claude")
	if err != nil {
		t.Fatal(err)
	}
	cause := func(stop func()) error {
		t.Helper()
		ended := make(chan struct{})
		if err := chats.Prompt(project, session.ID, "hello", PromptOptions{}, nil, func() { close(ended) }); err != nil {
			t.Fatal(err)
		}
		waitFor(t, "the run to start", func() bool {
			chats.mu.Lock()
			defer chats.mu.Unlock()
			return chats.jobs[session.ID] != nil
		})
		stop()
		select {
		case got := <-runner.causes:
			<-ended
			return got
		case <-time.After(5 * time.Second):
			t.Fatal("the run did not end")
			return nil
		}
	}
	got := cause(func() { chats.Abort(project, session.ID) })
	if !errors.Is(got, context.Canceled) || errors.Is(got, errHostShutdown) {
		t.Fatalf("Stop's cause %v", got)
	}
	ctx, stop := context.WithCancelCause(context.Background())
	stop(nil)
	if grace := oneShotGraceFor(ctx); grace != oneShotStopGrace {
		t.Fatalf("Stop's grace %v", grace)
	}
	got = cause(chats.stopAgents)
	if !errors.Is(got, errHostShutdown) {
		t.Fatalf("the shutdown's cause %v", got)
	}
	ctx, stop = context.WithCancelCause(context.Background())
	stop(errHostShutdown)
	if grace := oneShotGraceFor(ctx); grace != agentShutdownKill {
		t.Fatalf("the shutdown's grace %v", grace)
	}
	if err := chats.Prompt(project, session.ID, "later", PromptOptions{}, nil, nil); !errors.Is(err, ErrCLIChatUnavailable) {
		t.Fatalf("a run after the shutdown began: %v", err)
	}
}
