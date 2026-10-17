package host

import (
	"encoding/json"
	"os/exec"
	"strings"
	"time"
)

// The codex exec fallback runs one prompt per process and streams its JSONL
// events line by line: no output cap fails a run and no approvals are asked
// (Codex 0.156.1 rejects `--sandbox` together with `--approve-for-me`, so a
// new run takes `--approve-for-me` alone).

// codexExecArgs builds the codex exec arguments. A new chat runs
//
//	exec [-i IMAGE]… --json --skip-git-repo-check --approve-for-me -C DIR [-m MODEL] [-c model_reasoning_effort="E"] -
//
// and a resumed one, which accepts no --approve-for-me or -C and runs with
// its working directory set to DIR,
//
//	exec resume [-i IMAGE]… --json --skip-git-repo-check -c sandbox_mode="workspace-write" -c approval_policy="on-request" -c approvals_reviewer="auto_review" [-m MODEL] [-c model_reasoning_effort="E"] THREAD -
//
// Other modes pass their sandbox and approval policy as -c values in both
// forms. Image paths with commas (which -i splits on) and other attachments
// are returned to be named in the prompt. The ChatGPT sign-in
// (codexChatLoginArgs) and configArgs follow the chat's settings.
func codexExecArgs(directory, threadID string, attachments []ChatAttachment, settings codexSettings, configArgs []string) ([]string, []ChatAttachment) {
	args := []string{"exec"}
	if threadID != "" {
		args = append(args, "resume")
	}
	listed := []ChatAttachment{}
	for _, attachment := range attachments {
		if strings.HasPrefix(attachment.MIME, "image/") && !strings.Contains(attachment.Path, ",") {
			args = append(args, "-i", attachment.Path)
		} else {
			listed = append(listed, attachment)
		}
	}
	args = append(args, "--json", "--skip-git-repo-check")
	mode := settings.modeSpec()
	if threadID == "" && (mode.id == "auto-review" || mode.id == "ask") {
		args = append(args, "--approve-for-me")
	} else {
		for _, value := range mode.execConfig {
			args = append(args, "-c", value)
		}
	}
	if threadID == "" {
		args = append(args, "-C", directory)
	}
	if settings.model != "" {
		args = append(args, "-m", settings.model)
	}
	if settings.effort != "" {
		args = append(args, "-c", `model_reasoning_effort="`+settings.effort+`"`)
	}
	args = append(append(args, codexChatLoginArgs...), configArgs...)
	if threadID != "" {
		args = append(args, threadID)
	}
	return append(args, "-"), listed
}

// codexExecEvent is one line of codex exec --json.
type codexExecEvent struct {
	Type     string           `json:"type"`
	ThreadID string           `json:"thread_id"`
	Item     json.RawMessage  `json:"item"`
	Usage    *codexExecTokens `json:"usage"`
	Error    *struct {
		Message string `json:"message"`
	} `json:"error"`
	Message string `json:"message"`
}

// runExec runs the turn through codex exec. Starting the process delivers
// the prompt; if the process cannot start, nothing was sent.
func (e *codexEngine) runExec(turn *codexTurn, send codexSend) {
	c := e.chats
	c.mu.Lock()
	record := c.records[turn.sessionID]
	if record == nil || turn.done {
		c.mu.Unlock()
		return
	}
	if record.codex().PendingRevert != "" {
		c.mu.Unlock()
		e.endTurn(turn, "rejected", &ChatError{Code: "agent_error", Message: "Codex must run as an app-server to send an edited message. Try again when it does, or restore the chat."})
		return
	}
	threadID := record.NativeID
	turn.transport = "exec"
	c.mu.Unlock()

	executable, ok := e.config.resolve()
	if !ok {
		e.endTurn(turn, "rejected", codexFailure(errCodexNotSent, nil))
		return
	}
	args, listed := codexExecArgs(send.directory, threadID, send.attachments, turn.settings, e.config.configArgs)
	images := false
	for _, attachment := range send.attachments {
		if strings.HasPrefix(attachment.MIME, "image/") {
			images = true
		}
	}
	command := exec.Command(executable, append(append([]string{}, e.config.prefixArgs...), args...)...)
	command.Dir = send.directory
	command.Env = codexEnvironment(e.config.env)
	command.Stdin = strings.NewReader(codexPromptText(send.text, listed, images))
	stderr := newCodexRing(codexStderrRing)
	command.Stderr = stderr
	command.WaitDelay = 2 * time.Second
	codexProcessGroup(command)
	stdout, err := command.StdoutPipe()
	if err == nil {
		err = command.Start()
	}
	if err != nil {
		e.endTurn(turn, "rejected", codexFailure(errCodexNotSent, nil))
		return
	}
	// Recorded for the next host until it is reaped (acp_leftovers.go).
	c.processes.add(command, executableRecord(command.Process, command.Path))
	// A stop ends the run's process group (oneshot.go): SIGTERM at once,
	// SIGKILL after agentShutdownKill once the engine is closing (the host's
	// shutdown), else after oneShotStopGrace.
	group := newOneShotGroup(command.Process)
	stop := func() {
		grace := oneShotStopGrace
		select {
		case <-e.closing:
			grace = agentShutdownKill
		default:
		}
		group.stop(grace)
	}
	limit := time.AfterFunc(e.config.duration(e.config.execLimit, time.Hour), func() {
		c.mu.Lock()
		turn.lastError = "Codex ran for over an hour and was stopped."
		c.mu.Unlock()
		stop()
	})
	defer limit.Stop()
	c.mu.Lock()
	turn.delivered = true
	turn.cancel = stop
	interrupted := turn.interrupt
	c.mu.Unlock()
	if interrupted {
		stop()
	}

	reader := newCodexLineReader(stdout, e.config.lineLimitOrDefault())
	for {
		line, oversized, err := reader.next()
		if oversized > 0 {
			c.mu.Lock()
			turn.lossy = true
			c.mu.Unlock()
			continue
		}
		if err != nil {
			break
		}
		var event codexExecEvent
		if len(line) == 0 || json.Unmarshal(line, &event) != nil {
			continue
		}
		e.execEvent(turn, event)
	}
	_ = command.Wait()
	group.ended()
	c.processes.remove(command)
	c.mu.Lock()
	var finished func()
	if !turn.done {
		outcome, failure := "lost", (*ChatError)(nil)
		switch {
		case turn.interrupt:
			outcome = "interrupted"
		case turn.lastError != "":
			failure = &ChatError{Code: "agent_error", Message: turn.lastError}
		default:
			if tail := strings.TrimSpace(stderr.tail()); tail != "" {
				stderrLine := lastLines(tail, 1<<10)
				failure = &ChatError{Code: "agent_error", Message: "Codex stopped before this reply completed: " + stderrLine}
			}
		}
		finished = e.finishLocked(c.records[turn.sessionID], turn, outcome, failure)
	}
	c.mu.Unlock()
	if finished != nil {
		finished()
	}
}

// execEvent applies one codex exec event to the running turn.
func (e *codexEngine) execEvent(turn *codexTurn, event codexExecEvent) {
	c := e.chats
	c.mu.Lock()
	record := c.records[turn.sessionID]
	if record == nil || turn.done {
		c.mu.Unlock()
		return
	}
	var finished func()
	now := time.Now()
	switch event.Type {
	case "thread.started":
		if event.ThreadID != "" {
			if record.NativeID == "" {
				record.NativeID = event.ThreadID
				_ = c.saveLocked()
			}
			turn.threadID = record.NativeID
			e.threads[record.NativeID] = turn.key
		}
	case "item.started", "item.updated", "item.completed":
		var item codexItem
		if json.Unmarshal(event.Item, &item) == nil {
			e.itemLocked(record, turn, item, now, event.Type == "item.completed")
		}
	case "turn.completed":
		if event.Usage != nil {
			total := event.Usage.tokens()
			usage := total
			// codex exec reports the thread's total; this turn used the part
			// added since the last total the host saw.
			if previous := record.codex().TokenTotal; previous != nil && total.InputTokens >= previous.InputTokens && total.OutputTokens >= previous.OutputTokens {
				usage = total.minus(*previous)
			}
			turn.usage = usage.usage()
			record.codex().TokenTotal = &total
		}
		finished = e.finishLocked(record, turn, "completed", nil)
	case "turn.failed":
		message := "Codex could not complete this request."
		if event.Error != nil && strings.TrimSpace(event.Error.Message) != "" {
			message = strings.TrimSpace(event.Error.Message)
		}
		finished = e.finishLocked(record, turn, "failed", &ChatError{Code: "agent_error", Message: message})
	case "error":
		if message := strings.TrimSpace(event.Message); message != "" {
			turn.lastError, _ = clipText(message, chatShortLimit)
		}
	}
	c.mu.Unlock()
	if finished != nil {
		finished()
	}
}
