package host

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"path"
	"sync"
	"syscall"
	"time"
)

// OpenCode 1.18.31 sends every instance's bus events on GET /global/event as
// server-sent events whose data is {"directory", "payload": {"type",
// "properties"}}. The first event is server.connected and a server.heartbeat
// follows every 10 s. Nothing is replayed after a reconnect.
const (
	openCodeEventSilence    = 25 * time.Second
	openCodeEventBackoff    = 500 * time.Millisecond
	openCodeEventMaxBackoff = 10 * time.Second
	// openCodeEventLimit bounds one event's data. OpenCode puts attachments
	// inline as data URLs, so a larger event is skipped and its chat read
	// again over REST.
	openCodeEventLimit  = 1 << 20
	openCodeEventPrefix = 64 << 10
)

var errNotLoopback = errors.New("the OpenCode event stream must use a loopback address")

// chatEventSource is an agent whose changes stream to the host.
type chatEventSource interface {
	eventPump(handler openCodeEventHandler, silence, backoff, maxBackoff time.Duration) *openCodeEventPump
}

type openCodeEventHandler interface {
	openCodeEvent(*openCodeEventPump, openCodeEvent)
	openCodeConnected(pump *openCodeEventPump, up bool, version string)
	openCodeOversized(pump *openCodeEventPump, directory, sessionID string)
}

// openCodeEventPump holds the host's one connection to OpenCode's event
// stream. Its goroutine runs from start until stop.
type openCodeEventPump struct {
	adapter    *OpenCodeAdapter
	client     *http.Client
	handler    openCodeEventHandler
	silence    time.Duration
	backoff    time.Duration
	maxBackoff time.Duration
	limit      int
	stopOnce   sync.Once
	quit       chan struct{}
	done       chan struct{}
}

func (a *OpenCodeAdapter) eventPump(handler openCodeEventHandler, silence, backoff, maxBackoff time.Duration) *openCodeEventPump {
	return &openCodeEventPump{adapter: a, client: loopbackStreamClient(), handler: handler, silence: silence, backoff: backoff, maxBackoff: maxBackoff, limit: openCodeEventLimit, quit: make(chan struct{}), done: make(chan struct{})}
}

// loopbackStreamClient has no overall timeout (the stream is long-lived),
// dials only loopback addresses and never follows redirects.
func loopbackStreamClient() *http.Client {
	dialer := &net.Dialer{Timeout: 5 * time.Second, Control: func(_, address string, _ syscall.RawConn) error {
		host, _, err := net.SplitHostPort(address)
		if err != nil {
			return err
		}
		if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {
			return errNotLoopback
		}
		return nil
	}}
	transport := &http.Transport{DialContext: dialer.DialContext, ResponseHeaderTimeout: 10 * time.Second, MaxIdleConns: 2, IdleConnTimeout: 30 * time.Second, DisableCompression: true}
	return &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
}

func (p *openCodeEventPump) start() { go p.run() }

// stop ends the stream and waits for its goroutine.
func (p *openCodeEventPump) stop() {
	p.stopOnce.Do(func() { close(p.quit) })
	<-p.done
}

func (p *openCodeEventPump) run() {
	defer close(p.done)
	defer p.client.CloseIdleConnections()
	wait := p.backoff
	for {
		began := time.Now()
		connected := p.session()
		select {
		case <-p.quit:
			return
		default:
		}
		if connected && time.Since(began) > p.maxBackoff {
			wait = p.backoff
		}
		timer := time.NewTimer(wait)
		select {
		case <-p.quit:
			timer.Stop()
			return
		case <-timer.C:
		}
		wait = min(wait*2, p.maxBackoff)
	}
}

func (p *openCodeEventPump) request(ctx context.Context, route string) (*http.Request, error) {
	u := *p.adapter.base
	u.Path = path.Join(p.adapter.base.Path, route)
	request, err := http.NewRequestWithContext(ctx, "GET", u.String(), nil)
	if err != nil {
		return nil, err
	}
	request.SetBasicAuth(p.adapter.username, p.adapter.password)
	return request, nil
}

// session reads one connection until it fails, goes silent or the pump
// stops. It reports whether OpenCode confirmed the connection.
func (p *openCodeEventPump) session() (connected bool) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ended := make(chan struct{})
	defer close(ended)
	go func() {
		select {
		case <-p.quit:
			cancel()
		case <-ended:
		}
	}()
	request, err := p.request(ctx, "/global/event")
	if err != nil {
		return false
	}
	request.Header.Set("Accept", "text/event-stream")
	response, err := p.client.Do(request)
	if err != nil {
		return false
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		io.Copy(io.Discard, io.LimitReader(response.Body, 64<<10))
		return false
	}
	// OpenCode sends a heartbeat every 10 s; silence past the watchdog means
	// the connection is gone even if the socket is still open.
	watchdog := time.AfterFunc(p.silence, cancel)
	defer watchdog.Stop()
	defer func() {
		if connected {
			p.handler.openCodeConnected(p, false, "")
		}
	}()
	reader := bufio.NewReaderSize(response.Body, 32<<10)
	var data bytes.Buffer
	var prefix []byte
	oversized := false
	for {
		line, long, err := readEventLine(reader, p.limit+16)
		if err != nil {
			return connected
		}
		watchdog.Reset(p.silence)
		if len(line) == 0 && !long {
			switch {
			case oversized:
				p.handler.openCodeOversized(p, sniffJSONString(prefix, "directory"), sniffJSONString(prefix, "sessionID"))
			case data.Len() > 0:
				if p.dispatch(ctx, data.Bytes()) {
					connected = true
				}
			}
			data.Reset()
			prefix, oversized = nil, false
			continue
		}
		field, value, _ := bytes.Cut(line, []byte{':'})
		if len(field) == 0 || string(field) != "data" || oversized {
			continue
		}
		value = bytes.TrimPrefix(value, []byte{' '})
		if long || data.Len()+len(value)+1 > p.limit {
			oversized = true
			prefix = append(append([]byte(nil), data.Bytes()...), value...)
			prefix = prefix[:min(len(prefix), openCodeEventPrefix)]
			data.Reset()
			continue
		}
		if data.Len() > 0 {
			data.WriteByte('\n')
		}
		data.Write(value)
	}
}

// dispatch delivers one event and reports whether it confirmed the connection.
func (p *openCodeEventPump) dispatch(ctx context.Context, raw []byte) bool {
	var envelope struct {
		Directory string `json:"directory"`
		Payload   struct {
			Type       string          `json:"type"`
			Properties json.RawMessage `json:"properties"`
		} `json:"payload"`
	}
	if json.Unmarshal(raw, &envelope) != nil {
		return false
	}
	switch envelope.Payload.Type {
	case "server.connected":
		p.handler.openCodeConnected(p, true, p.version(ctx))
		return true
	case "", "server.heartbeat", "sync":
		return false
	}
	var session struct {
		SessionID string `json:"sessionID"`
	}
	_ = json.Unmarshal(envelope.Payload.Properties, &session)
	p.handler.openCodeEvent(p, openCodeEvent{directory: envelope.Directory, kind: envelope.Payload.Type, sessionID: session.SessionID, properties: envelope.Payload.Properties})
	return false
}

// version reads OpenCode's version for capabilities; failures leave it empty.
func (p *openCodeEventPump) version(parent context.Context) string {
	ctx, cancel := context.WithTimeout(parent, 3*time.Second)
	defer cancel()
	request, err := p.request(ctx, "/global/health")
	if err != nil {
		return ""
	}
	request.Header.Set("Accept", "application/json")
	response, err := p.client.Do(request)
	if err != nil {
		return ""
	}
	defer response.Body.Close()
	var health struct {
		Version string `json:"version"`
	}
	if response.StatusCode != http.StatusOK || json.NewDecoder(io.LimitReader(response.Body, 64<<10)).Decode(&health) != nil || len(health.Version) > 64 {
		return ""
	}
	return health.Version
}

// readEventLine reads one line without its line ending, keeping at most limit
// bytes; long reports that the line was longer and the rest was discarded.
func readEventLine(reader *bufio.Reader, limit int) ([]byte, bool, error) {
	var line []byte
	long := false
	for {
		chunk, err := reader.ReadSlice('\n')
		if !long {
			if room := limit - len(line); len(chunk) > room {
				line = append(line, chunk[:max(room, 0)]...)
				long = true
			} else {
				line = append(line, chunk...)
			}
		}
		if err == nil {
			break
		}
		if !errors.Is(err, bufio.ErrBufferFull) {
			return nil, false, err
		}
	}
	line = bytes.TrimSuffix(line, []byte{'\n'})
	line = bytes.TrimSuffix(line, []byte{'\r'})
	return line, long, nil
}

// sniffJSONString finds a short string value by key in the start of an event
// that was too large to decode.
func sniffJSONString(data []byte, key string) string {
	marker := []byte(`"` + key + `":"`)
	index := bytes.Index(data, marker)
	if index < 0 {
		return ""
	}
	rest := data[index+len(marker):]
	end := bytes.IndexByte(rest, '"')
	if end < 0 || end > 1024 {
		return ""
	}
	return string(rest[:end])
}
