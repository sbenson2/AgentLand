package host

import (
	"fmt"
	"io"
	"net/http"
	"time"
)

// A pulse is one small streaming response per connected app. It carries no
// workspace data: a line every pulseInterval lets a paired client notice a host
// that went silent (sleep, lost Wi-Fi) within a few seconds, and "stopping"
// tells it immediately when this host is shutting down. Each stream ends well
// before the server's write timeout; clients simply open the next one.
const pulseInterval = 1500 * time.Millisecond
const pulseLifetime = 24 * time.Second

// BeginShutdown releases pulses and terminal long-polls so HTTP shutdown does
// not wait for them and connected apps learn the host is stopping. It also
// starts ending the agents' processes (CLIChats.stopAgents), which must be
// gone before the Mac app's kill 2 s after it asked the host to stop; the
// terminals and other chat work end in Close. It is safe to call more than
// once.
func (h *Host) BeginShutdown() {
	h.stoppingOnce.Do(func() {
		close(h.stopping)
		if h.cliChats != nil {
			go h.cliChats.stopAgents()
		}
	})
}

func (h *Host) pulse(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		internal(w)
		return
	}
	w.Header().Set("Content-Type", "application/x-ndjson")
	w.WriteHeader(200)
	send := func(line string) bool {
		if _, err := io.WriteString(w, line+"\n"); err != nil {
			return false
		}
		flusher.Flush()
		return true
	}
	select {
	case <-h.stopping:
		send(`{"type":"stopping"}`)
		return
	default:
	}
	if !send(fmt.Sprintf(`{"type":"ready","intervalMs":%d}`, h.pulseEvery.Milliseconds())) {
		return
	}
	// Remote access: the revision of capabilities.remoteAccess now and
	// whenever it changes, so a connected device reads capabilities again.
	var remoteChanged <-chan struct{}
	lastRevision := ""
	if h.remote != nil {
		revision, changed := h.remote.reportState()
		if !send(remoteAccessPulse(revision)) {
			return
		}
		lastRevision, remoteChanged = revision, changed
	}
	// Plain chats: the revision of capabilities.plainChats now and whenever
	// it changes (it appears, goes, or lists other tools, search provider or
	// instruction files).
	var plainChanged <-chan struct{}
	lastPlain := ""
	if h.plainChats != nil {
		revision, changed := h.plainChats.capabilityState()
		if !send(plainChatsPulse(revision)) {
			return
		}
		lastPlain, plainChanged = revision, changed
	}
	beat := time.NewTicker(h.pulseEvery)
	defer beat.Stop()
	end := time.NewTimer(h.pulseFor)
	defer end.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-h.stopping:
			send(`{"type":"stopping"}`)
			return
		case <-end.C:
			send(`{"type":"end"}`)
			return
		case <-beat.C:
			if !send(`{"type":"beat"}`) {
				return
			}
		case <-remoteChanged:
			revision, changed := h.remote.reportState()
			remoteChanged = changed
			if revision != lastRevision {
				if !send(remoteAccessPulse(revision)) {
					return
				}
				lastRevision = revision
			}
		case <-plainChanged:
			revision, changed := h.plainChats.capabilityState()
			plainChanged = changed
			if revision != lastPlain {
				if !send(plainChatsPulse(revision)) {
					return
				}
				lastPlain = revision
			}
		}
	}
}

func remoteAccessPulse(revision string) string {
	return `{"type":"remoteAccess","revision":"` + revision + `"}`
}

func plainChatsPulse(revision string) string {
	return `{"type":"plainChats","revision":"` + revision + `"}`
}
