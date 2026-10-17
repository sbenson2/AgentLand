package host

import (
	"context"
	"net"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestLocalWebBrowserSmoke is opt-in because it needs installed Playwright
// browsers. It serves the production bundle through the real local gateway.
func TestLocalWebBrowserSmoke(t *testing.T) {
	if os.Getenv("AGENTLAND_WEB_BROWSER_TEST") != "1" {
		t.Skip("set AGENTLAND_WEB_BROWSER_TEST=1")
	}
	if _, err := os.Stat(filepath.Join("..", "web", "dist", "index.html")); err != nil {
		t.Skip("build web assets first")
	}
	w, _, _ := localWebFixture(t)
	w.assets, _ = filepath.Abs(filepath.Join("..", "web", "dist"))
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewUnstartedServer(w.handler())
	server.Listener = listener
	w.SetAddress(listener.Addr().String())
	server.Start()
	defer server.Close()
	for _, browser := range []string{"chromium", "webkit"} {
		t.Run(browser, func(t *testing.T) {
			grant := localWebGrant(t, w)
			url := "http://" + listener.Addr().String() + "/#launch=" + grant
			ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, "node", filepath.Join("web", "e2e", "live-gateway.mjs"), browser)
			cmd.Dir, cmd.Stdin, cmd.Stdout, cmd.Stderr = filepath.Join(".."), strings.NewReader(url+"\n"), os.Stdout, os.Stderr
			if err := cmd.Run(); err != nil {
				if ctx.Err() != nil {
					t.Fatalf("browser smoke timed out: %v", ctx.Err())
				}
				t.Fatal(err)
			}
		})
	}
}
