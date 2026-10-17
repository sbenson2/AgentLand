package host

import "errors"

// Live providers keep a chat's state in this process and push every change
// to the hub as it happens (Claude Code over stream-json, claude_*.go). The
// hub never reads them in the background: a first read and the switch to
// live changes happen under the provider's own lock, so nothing is missed or
// applied twice.

type liveChatProvider interface {
	chatProvider
	// snapshot reads the chat's newest limit visible messages and the rest of
	// its state and runs apply with them while no change can be pushed.
	snapshot(p Project, sessionID string, limit int, apply func(chatLoad)) error
}

// liveUpdate applies one change to a chat the hub tracks. The provider calls
// it while holding its own lock, so changes arrive in order. Chats that are
// not tracked, or are still loading, ignore it: their first read has it.
func (h *chatHub) liveUpdate(key sessionKey, apply func(c *hubChat, touched uint64)) {
	if h == nil {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	c := h.chats[key]
	if h.closed || c == nil || c.loading || c.removed {
		return
	}
	h.counter++
	apply(c, h.counter)
}

// liveReplace replaces a tracked chat's state and starts a new ring epoch,
// so every subscriber receives a snapshot (after a rewind, a restore or a
// truncating resume).
func (h *chatHub) liveReplace(key sessionKey, load chatLoad) {
	if h == nil {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	c := h.chats[key]
	if h.closed || c == nil || c.loading || c.removed {
		return
	}
	h.applyLiveLocked(c, load)
}

// applyLiveLocked is applyInitialLocked for a live chat: its parts accept the
// deltas that follow.
func (h *chatHub) applyLiveLocked(c *hubChat, load chatLoad) {
	h.applyInitialLocked(c, load)
	for _, message := range c.messages {
		for _, part := range message.parts {
			part.live = true
		}
	}
}

// subscribeLive completes subscribe for a live provider's chat.
func (h *chatHub) subscribeLive(c *hubChat, live liveChatProvider, p Project, sessionID string) (*hubChat, error) {
	var err error
	select {
	case h.slots <- struct{}{}:
		err = live.snapshot(p, sessionID, chatSnapshotMessages, func(load chatLoad) {
			h.mu.Lock()
			defer h.mu.Unlock()
			if c.removed || h.closed {
				return
			}
			h.applyLiveLocked(c, load)
			c.loading = false
			close(c.loaded)
		})
		<-h.slots
	case <-h.done:
		err = errChatHubClosed
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if err == nil && (c.loading || c.removed || h.closed) {
		err = errChatHubClosed
	}
	if err != nil {
		c.loadErr = err
		if c.loading {
			c.loading = false
			close(c.loaded)
		}
		h.removeChatLocked(c)
		return nil, err
	}
	c.again = false
	return c, nil
}

// reconcileLive reads a live chat again when something asked for it.
func (h *chatHub) reconcileLive(c *hubChat, live liveChatProvider) {
	for {
		h.mu.Lock()
		c.rebuild, c.again = false, false
		h.mu.Unlock()
		err := live.snapshot(c.project, c.key.sessionID, chatSnapshotMessages, func(load chatLoad) {
			h.mu.Lock()
			defer h.mu.Unlock()
			if !c.removed && !h.closed {
				h.applyLiveLocked(c, load)
			}
		})
		h.mu.Lock()
		if errors.Is(err, ErrNotFound) && !c.removed && !h.closed {
			h.removeChatLocked(c)
		}
		if !c.again || c.removed || h.closed {
			c.reconciling = false
			h.mu.Unlock()
			return
		}
		h.mu.Unlock()
	}
}
