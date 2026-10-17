package host

import (
	"context"
	"crypto/tls"
	"errors"
	"net"
	"net/http"
	"slices"
	"strconv"
	"sync"
	"time"
)

type ListenOptions struct {
	Address         string
	CertificateFile string
	KeyFile         string
	DevelopmentHTTP bool
	// OnShutdown runs as soon as graceful shutdown starts, before in-flight
	// requests drain, so long-lived responses can end and tell clients why.
	OnShutdown func()

	// Web previews (preview.go): a second HTTPS listener with the same
	// certificate, started and shut down with this one. Nil serves none.
	Preview *PreviewListen

	// Remote access (tunnel.go): the API with the same certificate on the
	// tunnel socket, started and shut down with the TCP listener; from
	// Host.TunnelListen. Nil serves none.
	Tunnel *TunnelListen
	Web    *WebListen
}

// PreviewListen is the preview listener of serve --enable-preview.
type PreviewListen struct {
	Address string
	Handler http.Handler
	// OnShutdown runs when graceful shutdown starts. It must end preview
	// streams and close upgraded (WebSocket) connections, which
	// http.Server.Shutdown neither closes nor waits for (Host.StopPreviews).
	OnShutdown func()
}

func ValidateListen(o ListenOptions) error {
	host, _, err := net.SplitHostPort(o.Address)
	if err != nil {
		return errors.New("listen address must be host:port")
	}
	if o.DevelopmentHTTP {
		ip := net.ParseIP(host)
		if host != "localhost" && (ip == nil || !ip.IsLoopback()) {
			return errors.New("development HTTP listener must use a loopback address")
		}
		if o.CertificateFile != "" || o.KeyFile != "" {
			return errors.New("development HTTP does not accept TLS certificate options")
		}
	} else if o.CertificateFile == "" || o.KeyFile == "" {
		return errors.New("TLS certificate and key are required")
	}
	// Remote access: the tunnel carries the phone's TLS to this certificate.
	if o.Tunnel != nil {
		if o.DevelopmentHTTP {
			return errors.New("the tunnel socket needs HTTPS and cannot be combined with development HTTP")
		}
		if o.Tunnel.host == nil || o.Tunnel.host.remote == nil {
			return errors.New("the tunnel socket needs a host with remote access and the local session")
		}
	}
	// Web previews.
	if o.Web != nil && o.Web.Handler == nil {
		return errors.New("the local web listener needs a handler")
	}
	if o.Preview != nil {
		return validatePreviewListen(o)
	}
	return nil
}

// validatePreviewListen: the session cookie is Secure, so previews need
// HTTPS, and the preview listener needs a port of its own.
func validatePreviewListen(o ListenOptions) error {
	if o.DevelopmentHTTP {
		return errors.New("web previews need HTTPS and cannot be combined with development HTTP")
	}
	_, port, err := net.SplitHostPort(o.Preview.Address)
	if err != nil {
		return errors.New("preview listen address must be host:port")
	}
	if number, err := strconv.Atoi(port); err != nil || number < 1 || number > 65535 {
		return errors.New("preview listen address needs a port between 1 and 65535")
	}
	if _, apiPort, _ := net.SplitHostPort(o.Address); apiPort == port {
		return errors.New("the preview listener needs a port other than the API listener's")
	}
	return nil
}

// serverTimeouts are the listener's HTTP timeouts. Long-lived responses (the
// pulse, chat event streams) extend their own connection deadlines.
type serverTimeouts struct{ readHeader, read, write, idle time.Duration }

var listenerTimeouts = serverTimeouts{readHeader: 5 * time.Second, read: 20 * time.Second, write: 35 * time.Second, idle: 60 * time.Second}

func NewHTTPServer(handler http.Handler, address string) *http.Server {
	return newHTTPServer(handler, address, listenerTimeouts)
}

func newHTTPServer(handler http.Handler, address string, timeouts serverTimeouts) *http.Server {
	return &http.Server{Addr: address, Handler: handler, ReadHeaderTimeout: timeouts.readHeader, ReadTimeout: timeouts.read, WriteTimeout: timeouts.write, IdleTimeout: timeouts.idle, MaxHeaderBytes: 16 << 10}
}

// newPreviewHTTPServer serves the preview proxy. Proxied responses may stream
// and WebSockets stay open, so there is no whole-request read or write
// timeout; the proxy bounds each response write and each request body itself
// (preview_proxy.go).
func newPreviewHTTPServer(handler http.Handler, address string) *http.Server {
	return &http.Server{Addr: address, Handler: handler, ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 64 << 10}
}

func Serve(handler http.Handler, o ListenOptions) error {
	return ServeContext(context.Background(), handler, o)
}

// ServeContext serves the API, the preview listener when o.Preview is set and
// the tunnel socket when o.Tunnel is set, until ctx ends or one of them fails;
// then all shut down gracefully. Every listener is bound before any serves, so
// a taken preview port or tunnel socket fails the start. After a graceful
// shutdown it returns http.ErrServerClosed.
func ServeContext(ctx context.Context, handler http.Handler, o ListenOptions) error {
	if err := ValidateListen(o); err != nil {
		return err
	}
	servers := []*http.Server{NewHTTPServer(handler, o.Address)}
	if o.OnShutdown != nil {
		servers[0].RegisterOnShutdown(o.OnShutdown)
	}
	// Web previews.
	if o.Preview != nil {
		if o.Preview.Handler == nil {
			return errors.New("the preview listener needs a handler")
		}
		preview := newPreviewHTTPServer(o.Preview.Handler, o.Preview.Address)
		if o.Preview.OnShutdown != nil {
			preview.RegisterOnShutdown(o.Preview.OnShutdown)
		}
		servers = append(servers, preview)
	}
	var web *http.Server
	if o.Web != nil {
		web = NewHTTPServer(o.Web.Handler, "127.0.0.1:0")
		servers = append(servers, web)
	}
	// Remote access: the API's server settings, every request with its tunnel
	// peer, and nothing without one.
	var tunnelServer *http.Server
	if o.Tunnel != nil {
		tunnelServer = newHTTPServer(requireTunnelPeer(handler), "", listenerTimeouts)
		tunnelServer.ConnContext = tunnelConnContext
		if o.OnShutdown != nil {
			tunnelServer.RegisterOnShutdown(o.OnShutdown)
		}
	}
	if !o.DevelopmentHTTP {
		certificate, err := tls.LoadX509KeyPair(o.CertificateFile, o.KeyFile)
		if err != nil {
			return err
		}
		for _, s := range append(slices.Clone(servers), tunnelServer) {
			if s == web {
				continue
			}
			if s != nil {
				// One configuration each: ServeTLS adds HTTP/2 to the one it gets.
				s.TLSConfig = &tls.Config{Certificates: []tls.Certificate{certificate}}
			}
		}
	}
	listeners := make([]net.Listener, 0, len(servers)+1)
	closeListeners := func() {
		for _, open := range listeners {
			open.Close()
		}
	}
	for _, s := range servers {
		listener, err := net.Listen("tcp", s.Addr)
		if err != nil {
			closeListeners()
			return err
		}
		listeners = append(listeners, listener)
		if s == web && o.Web.SetAddress != nil {
			o.Web.SetAddress(listener.Addr().String())
		}
	}
	if tunnelServer != nil {
		socket, err := listenTunnelSocket(o.Tunnel.Path)
		if err != nil {
			closeListeners()
			return err
		}
		servers = append(servers, tunnelServer)
		listeners = append(listeners, newTunnelListener(socket, o.Tunnel.host))
	}
	served := make(chan error, len(servers))
	for i, s := range servers {
		go func() {
			if o.DevelopmentHTTP || s == web {
				served <- s.Serve(listeners[i])
			} else {
				served <- s.ServeTLS(listeners[i], "", "")
			}
		}()
	}
	var results []error
	select {
	case <-ctx.Done():
	case err := <-served:
		results = append(results, err)
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var group sync.WaitGroup
	for _, s := range servers {
		group.Add(1)
		go func() {
			defer group.Done()
			if s.Shutdown(shutdown) != nil {
				_ = s.Close()
			}
		}()
	}
	group.Wait()
	for len(results) < len(servers) {
		results = append(results, <-served)
	}
	var failures []error
	for _, err := range results {
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			failures = append(failures, err)
		}
	}
	if len(failures) > 0 {
		return errors.Join(failures...)
	}
	return http.ErrServerClosed
}
