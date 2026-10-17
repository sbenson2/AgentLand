package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	host "agentland/host"
	"agentland/host/internal/localterm"
	"agentland/host/keeper"
)

type projectsFlag []string

var version = "0.1.0-dev"

func (p *projectsFlag) String() string     { return strings.Join(*p, ",") }
func (p *projectsFlag) Set(v string) error { *p = append(*p, v); return nil }

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}
func run(args []string) error {
	if len(args) == 0 {
		return usage()
	}
	switch args[0] {
	case "version":
		fmt.Println("AgentLand host", version)
		return nil
	case "tls":
		return tlsCommand(args[1:])
	case "config":
		return configCommand(args[1:])
	case "init":
		return initCommand(args[1:])
	case "serve":
		return serveCommand(args[1:])
	case "pair":
		return pairCommand(args[1:])
	case "devices":
		return devicesCommand(args[1:])
	case "revoke":
		return revokeCommand(args[1:])
	case "install-opencode":
		return installOpenCodeCommand(args[1:])
	case "chat-tools":
		return chatToolsCommand(args[1:])
	case "terminals":
		return terminalsCommand(args[1:])
	default:
		return usage()
	}
}
func usage() error {
	return errors.New("usage: agentland-host <init|config|tls|serve|install-opencode|chat-tools|terminals serve|terminals stop|terminals run|terminals attach|terminals hook|pair|devices|revoke|version> [options]")
}

// chatToolsCommand is `chat-tools --state <host.json>`: the plain chats' tool
// server, an MCP server on stdin and stdout that OpenCode starts from the
// Chats space's opencode.json (docs/HOST-API.md "The chat agent"). It keeps
// no state; its memory tools reach the host that runs on the same state.
func chatToolsCommand(args []string) error {
	fs := flag.NewFlagSet("chat-tools", flag.ContinueOnError)
	state := stateFlag(fs)
	if err := fs.Parse(args); errors.Is(err, flag.ErrHelp) {
		return nil
	} else if err != nil {
		return err
	}
	if fs.NArg() > 0 {
		return errors.New("chat-tools takes only --state")
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	return host.RunChatTools(ctx, host.ChatToolsOptions{StatePath: *state, Version: version, Input: os.Stdin, Output: os.Stdout})
}

// installOpenCodeCommand is `install-opencode --state <host.json>`: it makes
// sure the managed OpenCode is installed and valid (docs/HOST-API.md
// "install-opencode"), writing one JSON event per line on stdout. The Mac app
// runs it before it starts OpenCode, never while its host runs.
func installOpenCodeCommand(args []string) error {
	fs := flag.NewFlagSet("install-opencode", flag.ContinueOnError)
	state := stateFlag(fs)
	if err := fs.Parse(args); errors.Is(err, flag.ErrHelp) {
		return nil
	} else if err != nil {
		return host.InstallOpenCodeRefused(os.Stdout, "invalid_arguments", err.Error())
	}
	if fs.NArg() > 0 {
		return host.InstallOpenCodeRefused(os.Stdout, "invalid_arguments", "install-opencode takes no arguments besides --state.")
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	return host.InstallOpenCode(ctx, host.InstallOpenCodeOptions{StatePath: *state, Version: version, Output: os.Stdout})
}
func stateFlag(fs *flag.FlagSet) *string {
	return fs.String("state", host.DefaultStatePath(), "path to protected host state")
}

// keeperLogPath is the log of a keeper this host starts: the user's
// terminals log for the default state, and <state>.terminals.log beside any
// other state (tests, the harness), so those never write into the user's log.
func keeperLogPath(state string) string {
	if sameStatePath(state, host.DefaultStatePath()) {
		return keeper.DefaultLogPath()
	}
	return state + ".terminals.log"
}

func sameStatePath(a, b string) bool {
	absA, errA := filepath.Abs(a)
	absB, errB := filepath.Abs(b)
	return errA == nil && errB == nil && absA == absB
}
func initCommand(args []string) error {
	fs := flag.NewFlagSet("init", flag.ContinueOnError)
	state := stateFlag(fs)
	oc := fs.String("opencode-url", "http://127.0.0.1:4197", "loopback OpenCode server URL")
	env := fs.String("password-env", "AGENTLAND_OPENCODE_PASSWORD", "environment variable containing the separate AgentLand OpenCode password")
	var raw projectsFlag
	fs.Var(&raw, "project", "project as id=name=/absolute/directory (repeatable)")
	if err := fs.Parse(args); errors.Is(err, flag.ErrHelp) {
		return nil
	} else if err != nil {
		return err
	}
	projects, err := configuredProjects(raw)
	if err != nil {
		return err
	}
	if err := host.NewStore(*state).Initialize(host.Config{OpenCodeURL: *oc, PasswordEnv: *env, Projects: projects}); err != nil {
		return err
	}
	fmt.Println("initialized", *state)
	return nil
}
func serveCommand(args []string) error {
	surviveClosedOutput()
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	statePath := stateFlag(fs)
	listen := fs.String("listen", "127.0.0.1:9841", "listener address")
	cert := fs.String("cert", "", "TLS certificate file")
	key := fs.String("key", "", "TLS private key file")
	dev := fs.Bool("dev-http", false, "explicit loopback-only HTTP listener")
	terminal := fs.Bool("enable-terminal", false, "allow paired devices to create shells as this computer user")
	localSessionEnv := fs.String("local-session-env", "", "environment variable with this process's loopback-only desktop session token")
	noArchive := fs.Bool("no-archive", false, "do not keep the local archive of chats and terminal output (<state>.archive)")
	// Web previews (preview.go): an opt-in second HTTPS listener through
	// which paired devices open web servers on this computer's loopback ports.
	enablePreview := fs.Bool("enable-preview", false, "let paired devices open web servers on this computer's loopback ports through a second HTTPS listener")
	previewListen := fs.String("preview-listen", "", fmt.Sprintf("preview listener address, host:port or :port (default: the --listen host with port %d)", host.DefaultPreviewPort))
	var previewAllow portsFlag
	fs.Var(&previewAllow, "preview-allow-port", "let previews use this normally hidden SSH, printing, Docker or database port (repeatable)")
	// Workspaces (workspaces.go): the folder whose sub-folders paired devices
	// browse and add as workspaces; tests name a temporary one.
	workspaceHome := fs.String("workspace-home", "", "folder whose sub-folders paired devices may browse and add as workspaces (default: this user's home folder)")
	openCodeHome := fs.String("opencode-home", "", "the managed OpenCode's root folder, shared with the OpenCode terminals (set by the Mac app when it runs that OpenCode)")
	// Routes (network_routes.go): the name devices on the local network
	// reach this host by; with it the host lists its routes, Tailscale's too
	// while Tailscale runs (read with `tailscale status --json` only).
	advertisedHost := fs.String("advertised-host", "", "name devices on the local network reach this host by; lists it and, while Tailscale runs, this computer's Tailscale name as routes in capabilities")
	tailscaleCLI := fs.String("tailscale-cli", "", "Tailscale command line to read the status from (default: the standard install locations); needs --advertised-host")
	// Remote access (tunnel.go): the Unix socket the Mac app bridges paired
	// devices' iroh streams to; requests through it are never this Mac's own.
	tunnelSocket := fs.String("tunnel-socket", "", "Unix socket in the state file's folder that serves the API to paired devices bridged through the Mac app's remote access; needs --local-session-env and HTTPS")
	// Agents (agents_catalog.go): the ACP registry's agents, installed and
	// updated in <state>.agents, and ACP chats.
	noAgents := fs.Bool("no-agents", false, "do not keep the agent catalog: no registry reads, installs, automatic updates or ACP chats (<state>.agents)")
	// Plain chats (plain_chats.go): the service OpenCode's web search sends
	// queries to, which the Mac app sets for its managed OpenCode.
	webSearchProvider := fs.String("websearch-provider", "", "the service this Mac's OpenCode sends web searches to (exa), as its runner set it; capabilities name it to devices")
	// Chat runs on the Claude and ChatGPT subscriptions (chat_subscription.go);
	// OpenCode, on the AI Providers' API keys, only when asked for.
	openCodeChat := fs.Bool("opencode-chat", false, "let OpenCode run general Chat too, on the API keys of the Mac's AI Providers (off: Chat uses the Claude and ChatGPT subscriptions only)")
	webAssets := fs.String("web-assets", "", "absolute directory containing the local web bundle")
	if err := fs.Parse(args); errors.Is(err, flag.ErrHelp) {
		return nil
	} else if err != nil {
		return err
	}
	if *terminal {
		if err := keeper.SupportError(runtime.GOOS); err != nil {
			return err
		}
	}
	if err := tunnelSettings(*statePath, *tunnelSocket, *localSessionEnv, *dev); err != nil {
		return err
	}
	home, err := workspaceHomeSetting(*workspaceHome)
	if err != nil {
		return err
	}
	routes, err := routeSettings(*listen, *advertisedHost, *tailscaleCLI, *dev)
	if err != nil {
		return err
	}
	if !validSearchProvider(*webSearchProvider) {
		return errors.New("--websearch-provider takes a service name of lowercase letters, digits and hyphens, at most 32 bytes")
	}
	// Web previews: settle the preview listener before anything opens.
	var preview *host.PreviewListen
	var previewOptions *host.PreviewOptions
	if *enablePreview {
		var err error
		if preview, previewOptions, err = previewSettings(*listen, *previewListen, previewAllow); err != nil {
			return err
		}
		if err := host.ValidateListen(host.ListenOptions{Address: *listen, CertificateFile: *cert, KeyFile: *key, DevelopmentHTTP: *dev, Preview: preview}); err != nil {
			return err
		}
	} else if *previewListen != "" || len(previewAllow) > 0 {
		return errors.New("--preview-listen and --preview-allow-port need --enable-preview")
	}
	store := host.NewStore(*statePath)
	state, err := store.Read()
	if err != nil {
		return err
	}
	// One process at a time runs on the state: serve holds its lock while it
	// runs, install-opencode while it installs.
	release, err := host.LockState(*statePath)
	if errors.Is(err, host.ErrStateBusy) {
		return fmt.Errorf("%w (%s); quit it first", err, *statePath)
	}
	if err != nil {
		return err
	}
	defer release()
	password, err := state.Config.Password()
	if err != nil {
		return err
	}
	client := &http.Client{Timeout: 30 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	agent := host.NewOpenCodeAdapter(state.Config.OpenCodeURL, "opencode", password, client)
	cliChats, err := host.NewCLIChats(*statePath+".chats.json", host.HostCLIChatRunner{})
	if err != nil {
		return err
	}
	attachments, err := host.NewAttachmentStore(*statePath + ".attachments")
	if err != nil {
		return err
	}
	queue, err := host.NewPromptQueue(*statePath + ".queue.json")
	if err != nil {
		return err
	}
	// Chat names (chat_title_store.go): the names the host gave OpenCode chats.
	titles, err := host.NewChatTitleStore(*statePath + ".titles.json")
	if err != nil {
		return err
	}
	localSessionToken := ""
	if *localSessionEnv != "" {
		localSessionToken = os.Getenv(*localSessionEnv)
		if localSessionToken == "" {
			return errors.New("local session token environment variable is empty")
		}
	}
	// Archive (M1 chunk B1): on by default; app.Close closes it.
	var archive *host.Archive
	// Vault (vault_routes.go): offered with the archive, off until this Mac's
	// app turns it on, in ~/AgentLand Vault unless it chooses a folder.
	var vault *host.VaultOptions
	if !*noArchive {
		if archive, err = host.OpenArchive(*statePath+".archive", host.ArchiveOptions{}); err != nil {
			return fmt.Errorf("open archive: %w", err)
		}
		if userHome, err := os.UserHomeDir(); err == nil && filepath.IsAbs(userHome) {
			vault = &host.VaultOptions{DefaultFolder: filepath.Join(userHome, "AgentLand Vault")}
		}
	}
	var agents *host.AgentOptions
	if !*noAgents {
		agents = &host.AgentOptions{Version: version}
	}
	// Plain chats (plain_chats.go): OpenCode starts this program as their tool
	// server (chat-tools).
	executable, err := os.Executable()
	if err != nil {
		return fmt.Errorf("find this program for the plain chats' tool server: %w", err)
	}
	// Terminals never see the local session token (terminal_launch.go).
	var terminalHiddenEnv []string
	if *localSessionEnv != "" {
		terminalHiddenEnv = append(terminalHiddenEnv, *localSessionEnv)
	}
	// Terminals (terminal_keeper.go): with terminal access off the backend
	// only ends what a keeper still runs for this state; it starts none.
	var terminals host.TerminalBackend
	if *terminal || keeper.SupportError(runtime.GOOS) == nil {
		terminals = host.NewKeeperBackend(host.KeeperBackendOptions{StatePath: *statePath, LogPath: keeperLogPath(*statePath), Executable: executable, Version: version})
	}
	app := host.NewWithOptions(store, agent, host.HostOptions{TerminalEnabled: *terminal, Terminals: terminals, TerminalHiddenEnv: terminalHiddenEnv, Version: version, LocalSessionToken: localSessionToken, CLIChats: cliChats, Attachments: attachments, Queue: queue, Archive: archive, Preview: previewOptions, WorkspaceHome: home, Routes: routes, RemoteAccess: *tunnelSocket != "", ChatTitles: titles, Agents: agents, Vault: vault, OpenCodeHome: *openCodeHome,
		PlainChats: &host.PlainChatOptions{Executable: executable, SearchProvider: *webSearchProvider, OpenCode: *openCodeChat}})
	// Terminals from Terminal.app (terminal_local.go): `terminals run`
	// registers coding agents typed there on a private socket beside the
	// keeper's. Without it they run as they would with AgentLand off.
	var localTerminals io.Closer
	if runtime.GOOS == "darwin" {
		if localTerminals, err = app.ListenLocalTerminals(localterm.SocketPath(*statePath)); err != nil {
			fmt.Fprintln(os.Stderr, "coding agents typed in Terminal.app stay out of AgentLand:", err)
			localTerminals = nil
		}
	}
	var localWeb *host.WebListen
	if *webAssets != "" {
		assets, err := filepath.Abs(*webAssets)
		if err != nil || !filepath.IsAbs(*webAssets) {
			return errors.New("--web-assets must be an absolute directory")
		}
		if localSessionToken == "" {
			return errors.New("--web-assets needs --local-session-env")
		}
		localWebHandler, err := host.NewLocalWebHandler(assets, *statePath, app, localSessionToken)
		if err != nil {
			return err
		}
		localWeb = &host.WebListen{Assets: assets, StatePath: *statePath, LocalToken: localSessionToken, Host: app, Handler: localWebHandler.Handler(), SetAddress: localWebHandler.SetAddress}
		app.SetLocalWeb(localWebHandler)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	fmt.Println("listening on", *listen)
	listenOptions := host.ListenOptions{Address: *listen, CertificateFile: *cert, KeyFile: *key, DevelopmentHTTP: *dev, OnShutdown: app.BeginShutdown}
	if localWeb != nil {
		listenOptions.Web = localWeb
	}
	// Web previews.
	if preview != nil {
		preview.Handler, preview.OnShutdown = app.PreviewHandler(), app.StopPreviews
		listenOptions.Preview = preview
		fmt.Println("web previews on", preview.Address)
	}
	// Remote access.
	if *tunnelSocket != "" {
		listenOptions.Tunnel = app.TunnelListen(*tunnelSocket)
		fmt.Println("remote access tunnel on", *tunnelSocket)
	}
	err = host.ServeContext(ctx, app.Handler(), listenOptions)
	if errors.Is(err, http.ErrServerClosed) {
		err = nil
	}
	// No registration lands while the host closes; one the keeper adopted
	// meanwhile stays there for the next host.
	if localTerminals != nil {
		localTerminals.Close()
	}
	return errors.Join(err, app.Close())
}

// workspaceHomeSetting checks --workspace-home: empty keeps this user's home
// folder; otherwise it must name an existing folder, made absolute.
func workspaceHomeSetting(value string) (string, error) {
	if value == "" {
		return "", nil
	}
	home, err := filepath.Abs(value)
	if err != nil {
		return "", err
	}
	if info, err := os.Stat(home); err != nil || !info.IsDir() {
		return "", fmt.Errorf("--workspace-home %q is not an existing folder", value)
	}
	return home, nil
}

// tunnelSettings checks --tunnel-socket: it needs the Mac's local session,
// which reports the endpoint and follows the peer list, and the HTTPS
// listener, whose TLS the tunnel carries; the path lies in the state folder.
func tunnelSettings(statePath, socket, localSessionEnv string, developmentHTTP bool) error {
	if socket == "" {
		return nil
	}
	if localSessionEnv == "" {
		return errors.New("--tunnel-socket needs --local-session-env")
	}
	if developmentHTTP {
		return errors.New("--tunnel-socket needs the HTTPS listener, not --dev-http")
	}
	return host.ValidateTunnelSocket(statePath, socket)
}

// validSearchProvider checks --websearch-provider: empty (not known), or a
// service name such as exa.
func validSearchProvider(name string) bool {
	if len(name) > 32 {
		return false
	}
	for _, c := range name {
		if (c < 'a' || c > 'z') && (c < '0' || c > '9') && c != '-' {
			return false
		}
	}
	return true
}

// routeSettings reads --advertised-host and --tailscale-cli: no routes without
// an advertised host, and none over development HTTP, which devices never use.
func routeSettings(listen, advertisedHost, tailscaleCLI string, developmentHTTP bool) (*host.RouteOptions, error) {
	if advertisedHost == "" {
		if tailscaleCLI != "" {
			return nil, errors.New("--tailscale-cli needs --advertised-host")
		}
		return nil, nil
	}
	if developmentHTTP {
		return nil, errors.New("--advertised-host needs the HTTPS listener, not --dev-http")
	}
	listenHost, portText, err := net.SplitHostPort(listen)
	if err != nil {
		return nil, errors.New("listen address must be host:port")
	}
	port, err := strconv.Atoi(portText)
	if err != nil {
		return nil, errors.New("listen address needs a numeric port")
	}
	options := host.RouteOptions{AdvertisedHost: advertisedHost, Port: port, ListenHost: listenHost, TailscaleCLI: tailscaleCLI}
	if err := host.ValidateRouteOptions(options); err != nil {
		return nil, err
	}
	return &options, nil
}

// Web previews.

// portsFlag collects repeated port numbers.
type portsFlag []int

func (p *portsFlag) String() string { return fmt.Sprint([]int(*p)) }
func (p *portsFlag) Set(value string) error {
	port, err := strconv.Atoi(value)
	if err != nil || port < 1 || port > 65535 {
		return errors.New("port must be between 1 and 65535")
	}
	*p = append(*p, port)
	return nil
}

// previewSettings resolves the preview listener: the --listen host, unless
// --preview-listen names one, with --preview-listen's port or the default.
func previewSettings(listen, previewListen string, allow []int) (*host.PreviewListen, *host.PreviewOptions, error) {
	apiHost, apiPortText, err := net.SplitHostPort(listen)
	if err != nil {
		return nil, nil, errors.New("listen address must be host:port")
	}
	previewHost, portText := apiHost, strconv.Itoa(host.DefaultPreviewPort)
	if previewListen != "" {
		if previewHost, portText, err = net.SplitHostPort(previewListen); err != nil {
			return nil, nil, errors.New("--preview-listen must be host:port or :port")
		}
		if previewHost == "" {
			previewHost = apiHost
		}
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port < 1 || port > 65535 {
		return nil, nil, errors.New("--preview-listen needs a port between 1 and 65535")
	}
	apiPort, _ := strconv.Atoi(apiPortText)
	return &host.PreviewListen{Address: net.JoinHostPort(previewHost, portText)}, &host.PreviewOptions{Port: port, APIPort: apiPort, AllowPorts: allow}, nil
}

func pairCommand(args []string) error {
	fs := flag.NewFlagSet("pair", flag.ContinueOnError)
	state := stateFlag(fs)
	expires := fs.Duration("expires", 10*time.Minute, "pairing code lifetime")
	numericPIN := fs.Bool("pin", false, "create a ten-digit single-use PIN (maximum lifetime ten minutes)")
	if err := fs.Parse(args); errors.Is(err, flag.ErrHelp) {
		return nil
	} else if err != nil {
		return err
	}
	if *expires <= 0 || *expires > time.Hour {
		return errors.New("expires must be between 1ns and 1h")
	}
	store := host.NewStore(*state)
	var code string
	var err error
	if *numericPIN {
		code, err = store.CreatePairingPIN(*expires)
	} else {
		code, err = store.CreatePairingCode(*expires)
	}
	if err != nil {
		return err
	}
	fmt.Println(code)
	return nil
}
func devicesCommand(args []string) error {
	fs := flag.NewFlagSet("devices", flag.ContinueOnError)
	state := stateFlag(fs)
	if err := fs.Parse(args); errors.Is(err, flag.ErrHelp) {
		return nil
	} else if err != nil {
		return err
	}
	devices, err := host.NewStore(*state).ListDevices()
	if err != nil {
		return err
	}
	for _, d := range devices {
		status := "active"
		if d.RevokedAt != nil {
			status = "revoked"
		}
		presence := "offline"
		if d.IsPresent(time.Now()) {
			presence = "online"
		}
		// The last pairing: a device that paired again over its record shows
		// when, so the Mac's pairing window sees it pair.
		paired := d.CreatedAt
		if d.PairedAt != nil {
			paired = *d.PairedAt
		}
		fmt.Printf("%s\t%s\t%s\t%s\t%s\n", d.ID, status, paired.Format(time.RFC3339), d.Name, presence)
	}
	return nil
}
func revokeCommand(args []string) error {
	fs := flag.NewFlagSet("revoke", flag.ContinueOnError)
	state := stateFlag(fs)
	id := fs.String("device", "", "device ID")
	if err := fs.Parse(args); errors.Is(err, flag.ErrHelp) {
		return nil
	} else if err != nil {
		return err
	}
	if *id == "" {
		return errors.New("--device is required")
	}
	if err := host.NewStore(*state).RevokeDevice(*id); err != nil {
		return err
	}
	fmt.Println("revoked", *id)
	return nil
}

// surviveClosedOutput keeps the host running when its output pipe closes.
// The Mac app reads the host's stdout and stderr through a pipe into
// host.log; if the app dies, Go's default for a write to a broken pipe on
// fd 1 or 2 is to exit by SIGPIPE, which would take the host and every
// terminal and chat with it at its next log line. Asking for SIGPIPE makes
// such a write fail with EPIPE instead (the line is lost, nothing else).
// Notify rather than Ignore: an ignored signal stays ignored in every
// program the host starts (agents, git), a handled one is reset for them.
func surviveClosedOutput() {
	signal.Notify(make(chan os.Signal, 1), syscall.SIGPIPE)
}
