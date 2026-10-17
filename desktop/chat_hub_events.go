package host

// Hub events (M5 notices). The chat hub tells the host about every turn that
// ends and every approval or question that appears, so it can issue notices.
// This happens under the hub's lock: the observer must not block or take the
// hub's lock again.

// hubEvent is one turn that ended (turn, outcome: completed, error or
// aborted) or one interaction that appeared.
type hubEvent struct {
	key         sessionKey
	title       string
	turn        string
	outcome     string
	interaction *ChatInteraction
}

// noteEndedTurn tells the observer about a turn that ended.
func (c *hubChat) noteEndedTurn(turn, outcome string) {
	if c.observe != nil {
		c.observe(hubEvent{key: c.key, title: c.info.Title, turn: turn, outcome: outcome})
	}
}

// noteNewInteraction tells the observer about an approval or question the
// hub had not held before.
func (c *hubChat) noteNewInteraction(interaction ChatInteraction) {
	if c.observe != nil {
		c.observe(hubEvent{key: c.key, title: c.info.Title, interaction: &interaction})
	}
}
