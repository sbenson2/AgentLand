package host

// Codex engine updates to the chat hub (codex_engine.go). The engine changes
// a chat's record first and then mirrors the change here, while it holds the
// CLI chats' lock. A chat nobody streams costs nothing; a chat that is still
// loading reads the change from the record, and the hub reads it once more
// afterwards in case the load began before the change.

func (h *chatHub) codexApply(key sessionKey, apply func(c *hubChat, touched uint64)) {
	if h == nil {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	c := h.chats[key]
	if c == nil || c.removed || h.closed {
		return
	}
	if c.loading {
		c.again = true
		return
	}
	h.counter++
	apply(c, h.counter)
}

// codexMessage adds a message or updates its header and parts. The caller
// passes a copy the hub may keep.
func (h *chatHub) codexMessage(key sessionKey, message ChatMessage) {
	h.codexApply(key, func(c *hubChat, touched uint64) {
		entry, _ := c.find(message.ID)
		if entry == nil {
			c.insertMessage(message, true, touched)
			c.trim()
			return
		}
		c.updateHeader(entry, message, touched)
		for _, part := range message.Parts {
			c.upsertPart(message.ID, part, true, touched)
		}
	})
}

// codexHeader updates a message's status, times, usage and error only.
func (h *chatHub) codexHeader(key sessionKey, message ChatMessage) {
	h.codexApply(key, func(c *hubChat, touched uint64) {
		if entry, _ := c.find(message.ID); entry != nil {
			c.updateHeader(entry, message, touched)
		}
	})
}

func (h *chatHub) codexPart(key sessionKey, messageID string, part ChatPart) {
	h.codexApply(key, func(c *hubChat, touched uint64) {
		c.upsertPart(messageID, part, true, touched)
	})
}

// codexDelta appends text to a part's text or tool output. offset is the
// field's length before the delta: text the hub already has (read with the
// record) is skipped, and a gap makes the hub read the chat again.
func (h *chatHub) codexDelta(key sessionKey, messageID, partID, field string, offset int, text string) {
	h.codexApply(key, func(c *hubChat, touched uint64) {
		entry, _ := c.find(messageID)
		if entry == nil {
			return
		}
		part, _ := entry.part(partID)
		if part == nil {
			return
		}
		value := &part.part.Text
		if field == "output" {
			if part.part.Tool == nil {
				return
			}
			value = &part.part.Tool.Output
		}
		current := len(*value)
		switch {
		case offset > current:
			h.requestReconcileLocked(c)
			return
		case offset+len(text) <= current:
			return
		case offset < current:
			text = text[current-offset:]
		}
		*value += text
		part.touched = max(part.touched, touched)
		entry.touched = max(entry.touched, touched)
		c.emitDelta(messageID, partID, field, current, text)
	})
}

// codexState sets the provider activity: busy, retry or idle.
func (h *chatHub) codexState(key sessionKey, state string, retry *ChatRetry) {
	h.codexApply(key, func(c *hubChat, touched uint64) {
		c.state, c.retry = state, retry
		c.statusTouched = touched
		c.recomputeStatus()
	})
}

func (h *chatHub) codexInteraction(key sessionKey, interaction ChatInteraction) {
	h.codexApply(key, func(c *hubChat, touched uint64) {
		c.upsertInteraction(interaction, touched)
	})
}

func (h *chatHub) codexResolved(key sessionKey, id, outcome string) {
	h.codexApply(key, func(c *hubChat, touched uint64) {
		c.resolveInteraction(id, outcome, touched)
	})
}

// codexInfo announces a changed model, mode or effort.
func (h *chatHub) codexInfo(key sessionKey, model, mode, effort string) {
	h.codexApply(key, func(c *hubChat, _ uint64) {
		c.applySettings(model, mode, effort)
	})
}

// codexRebuild reads the chat again and starts a new ring epoch, so every
// subscriber gets a fresh snapshot (after a rewind, restore or a send that
// dropped rewound messages).
func (h *chatHub) codexRebuild(key sessionKey) {
	if h == nil {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	c := h.chats[key]
	if c == nil || c.removed || h.closed {
		return
	}
	c.rebuild = true
	h.requestReconcileLocked(c)
}
