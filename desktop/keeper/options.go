package keeper

import "time"

// ServeOptions configures Serve.
type ServeOptions struct {
	// StatePath is the host's state file. The socket and lock sit beside it.
	StatePath string
	// LogPath is the lifecycle log. Empty discards it.
	LogPath string
	// Version is this build's version, told to clients in the hello reply.
	Version string
	// IdleAfter is how long the keeper waits with no terminals and no
	// connections before it exits. Zero means 10 minutes.
	IdleAfter time.Duration
	// MaxTerminals is the most terminals the keeper holds, running or
	// finished. Zero means 64.
	MaxTerminals int
	// Now tells the time for start times, exits and the log. Nil means time.Now.
	Now func() time.Time
}

const (
	defaultIdleAfter    = 10 * time.Minute
	defaultMaxTerminals = 64
)

func (o ServeOptions) withDefaults() ServeOptions {
	if o.IdleAfter <= 0 {
		o.IdleAfter = defaultIdleAfter
	}
	if o.MaxTerminals <= 0 {
		o.MaxTerminals = defaultMaxTerminals
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	return o
}
