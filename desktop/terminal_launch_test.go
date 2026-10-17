package host

import (
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
)

func envMap(environment []string) map[string]string {
	result := map[string]string{}
	for _, item := range environment {
		name, value, _ := strings.Cut(item, "=")
		result[name] = value
	}
	return result
}

func TestShellEnvironmentIsTheUsersOwn(t *testing.T) {
	home := "/Users/x"
	private := filepath.Join(home, "Library/Application Support/AgentLand")
	base := []string{
		"AGENTLAND_LOCAL_SESSION_TOKEN=a", "AGENTLAND_OPENCODE_PASSWORD=b", "OPENCODE_SERVER_PASSWORD=c", "OPENCODE_CONFIG=d",
		"CLAUDECODE=1", "ANTHROPIC_API_KEY=k", "OPENAI_API_KEY=k",
		"XDG_CONFIG_HOME=" + private + "/OpenCode/config", "XDG_DATA_HOME=/Users/x/.local/share",
		"TERM=dumb", "OPENCODE_TERMINAL=1", "HOME=" + home, "PATH=/usr/bin",
	}
	got := terminalEnvironment(base, []string{private}, nil)
	env := envMap(got)
	for _, name := range []string{"AGENTLAND_LOCAL_SESSION_TOKEN", "AGENTLAND_OPENCODE_PASSWORD", "OPENCODE_SERVER_PASSWORD", "OPENCODE_CONFIG",
		"CLAUDECODE", "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "XDG_CONFIG_HOME", "OPENCODE_TERMINAL"} {
		if _, found := env[name]; found {
			t.Errorf("%s was kept", name)
		}
	}
	if env["XDG_DATA_HOME"] != "/Users/x/.local/share" || env["HOME"] != home {
		t.Errorf("the user's own variables were lost: %v", env)
	}
	if env["TERM"] != "xterm-256color" {
		t.Errorf("TERM = %q", env["TERM"])
	}
	if want := "/usr/bin:/opt/homebrew/bin:/usr/local/bin:/bin:/usr/sbin:/sbin"; env["PATH"] != want {
		t.Errorf("PATH = %q, want %q", env["PATH"], want)
	}
	// The private-folder check is case-insensitive and cleans the value.
	odd := terminalEnvironment([]string{"XDG_STATE_HOME=" + strings.ToUpper(private) + "/x/../state"}, []string{private}, nil)
	if _, found := envMap(odd)["XDG_STATE_HOME"]; found {
		t.Error("a private XDG folder in other case was kept")
	}
	// Extra applies last, and an empty result is never nil.
	extra := terminalEnvironment([]string{"ANTHROPIC_API_KEY=k"}, nil, map[string]string{"TERM": "vt100", "A": "b"})
	if e := envMap(extra); e["TERM"] != "vt100" || e["A"] != "b" {
		t.Errorf("extra: %v", extra)
	}
	if empty := terminalEnvironment(nil, nil, nil); empty == nil {
		t.Error("the environment is nil: exec would inherit everything")
	}
}

func TestOpenCodeTerminalGetsOnlyWhatItNeeds(t *testing.T) {
	launcher := &terminalLauncher{
		resolve:        func(name string) (string, bool) { return "/bin/" + name, true },
		openCode:       func() (string, string, string) { return "http://127.0.0.1:4096", "opencode", "pw" },
		openCodeHome:   "/Users/x/Library/Application Support/AgentLand/OpenCode",
		privateFolders: []string{"/Users/x/Library/Application Support/AgentLand"},
		environ:        func() []string { return []string{"ANTHROPIC_API_KEY=k", "HOME=/Users/x", "PATH=/usr/bin"} },
	}
	project := Project{Directory: "/Users/x/work"}
	command, err := launcher.command(project, "opencode", nil)
	if err != nil {
		t.Fatal(err)
	}
	if command.Path != "/bin/opencode" || !reflect.DeepEqual(command.Args, []string{"attach", "http://127.0.0.1:4096", "--dir", "/Users/x/work"}) {
		t.Fatalf("command %+v", command)
	}
	env := envMap(command.Env)
	if _, found := env["ANTHROPIC_API_KEY"]; found {
		t.Error("an API key reached the OpenCode terminal")
	}
	home := launcher.openCodeHome
	want := map[string]string{
		"OPENCODE_SERVER_USERNAME": "opencode", "OPENCODE_SERVER_PASSWORD": "pw",
		"XDG_CONFIG_HOME": home + "/config", "XDG_DATA_HOME": home + "/data", "XDG_CACHE_HOME": home + "/cache", "XDG_STATE_HOME": home + "/state",
		"OPENCODE_CONFIG_DIR": home + "/config/opencode", "OPENCODE_CONFIG": home + "/config/opencode/opencode.json",
	}
	for name, value := range want {
		if env[name] != value {
			t.Errorf("%s = %q, want %q", name, env[name], value)
		}
	}
	bare := openCodeTUIEnvironment("u", "p", "")
	if !reflect.DeepEqual(bare, map[string]string{"OPENCODE_SERVER_USERNAME": "u", "OPENCODE_SERVER_PASSWORD": "p"}) {
		t.Errorf("without a home: %v", bare)
	}
}

func TestClaudeTerminalCarriesItsConversation(t *testing.T) {
	launcher := &terminalLauncher{resolve: func(name string) (string, bool) { return "/bin/" + name, true }, environ: func() []string { return nil }}
	id := "0a1b2c3d-0000-4000-8000-000000000000"
	for _, test := range []struct {
		conversation terminalConversation
		want         []string
	}{
		{terminalConversation{ID: id}, []string{"--session-id", id}},
		{terminalConversation{ID: id, Resume: true}, []string{"--resume", id}},
		{terminalConversation{Pick: true}, []string{"--resume"}},
	} {
		conversation := test.conversation
		command, err := launcher.command(Project{Directory: "/w"}, "claude", &conversation)
		if err != nil || command.Path != "/bin/claude" || !reflect.DeepEqual(command.Args, test.want) {
			t.Errorf("%+v: %+v %v", test.conversation, command, err)
		}
	}
	codex, err := launcher.command(Project{Directory: "/w"}, "codex", nil)
	if err != nil || codex.Path != "/bin/codex" || len(codex.Args) != 0 {
		t.Errorf("codex: %+v %v", codex, err)
	}
}

func TestCatalogAgentLaunchKeepsItsVersion(t *testing.T) {
	root := filepath.Join(t.TempDir(), "host.json.agents")
	store := agentStore{root: root}
	if err := store.ensureAgentDir("goose"); err != nil {
		t.Fatal(err)
	}
	folder := store.versionDir("goose", "1.2.3")
	if err := os.MkdirAll(folder, 0o700); err != nil {
		t.Fatal(err)
	}
	program := filepath.Join(folder, "goose")
	if err := os.WriteFile(program, []byte("#!/bin/sh\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := store.writeCurrent("goose", agentCurrent{Version: "1.2.3", Command: program, Args: []string{"acp"}, Kind: "binary",
		Env: map[string]string{"GOOSE_MODE": "x"}}); err != nil {
		t.Fatal(err)
	}
	launcher := &terminalLauncher{agents: &agentCatalog{store: store, lookup: func(string) (string, bool) { return "", false }}, environ: func() []string { return []string{"ANTHROPIC_API_KEY=k", "PATH=/usr/bin"} }}
	command, err := launcher.command(Project{Directory: "/w"}, "goose", nil)
	if err != nil {
		t.Fatal(err)
	}
	if command.Path != program || command.Version != "1.2.3" || len(command.Args) != 0 {
		t.Fatalf("command %+v", command)
	}
	env := envMap(command.Env)
	if env["GOOSE_MODE"] != "x" {
		t.Errorf("the agent's environment was lost: %v", env)
	}
	if _, found := env["ANTHROPIC_API_KEY"]; found {
		t.Error("an API key was kept")
	}
	if _, err := launcher.command(Project{Directory: "/w"}, "nobody", nil); err == nil {
		t.Error("an unknown program started")
	}
}

func TestLoginShellFallsBack(t *testing.T) {
	none := func(string) string { return "" }
	if got := loginShell([]string{"SHELL=/bin/bash"}, none); got != "/bin/bash" {
		t.Errorf("got %q", got)
	}
	var asked string
	lookup := func(user string) string { asked = user; return "/bin/sh" }
	for _, environ := range [][]string{{"SHELL=zsh", "USER=wes"}, {"USER=wes"}, {"SHELL=/no/such/shell", "USER=wes"}} {
		if got := loginShell(environ, lookup); got != "/bin/sh" || asked != "wes" {
			t.Errorf("%v: got %q asking %q", environ, got, asked)
		}
	}
	if got := loginShell([]string{"SHELL=zsh", "USER=wes"}, none); got != "/bin/zsh" {
		t.Errorf("last resort: %q", got)
	}
	if got := loginShell([]string{"SHELL=/bin/bash"}, lookup); got != "/bin/bash" {
		t.Errorf("got %q", got)
	}
}

func TestLauncherProgramsMatchTheCurrentList(t *testing.T) {
	launcher := &terminalLauncher{resolve: func(name string) (string, bool) { return "/bin/" + name, name != "codex" }}
	if got := launcher.programs(); !slices.Equal(got, []string{"shell", "opencode", "claude"}) {
		t.Errorf("programs %v", got)
	}
	shell, err := (&terminalLauncher{environ: func() []string { return []string{"SHELL=/bin/bash"} }}).command(Project{Directory: "/w"}, "shell", nil)
	if err != nil || shell.Path != "/bin/bash" || !reflect.DeepEqual(shell.Args, []string{"-l"}) {
		t.Errorf("shell %+v %v", shell, err)
	}
}

func TestNpxAgentKeepsTheDefaultPath(t *testing.T) {
	store := agentStore{root: filepath.Join(t.TempDir(), "host.json.agents")}
	if err := store.ensureAgentDir("gemini"); err != nil {
		t.Fatal(err)
	}
	folder := store.versionDir("gemini", "0.61.0")
	if err := os.MkdirAll(folder, 0o700); err != nil {
		t.Fatal(err)
	}
	program := filepath.Join(folder, "gemini")
	if err := os.WriteFile(program, []byte("#!/bin/sh\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := store.writeCurrent("gemini", agentCurrent{Version: "0.61.0", Command: program, Args: []string{"--acp"}, Kind: "npx"}); err != nil {
		t.Fatal(err)
	}
	catalog := &agentCatalog{store: store, lookup: func(string) (string, bool) { return "/nodes/bin/node", true }}
	launcher := &terminalLauncher{agents: catalog, environ: func() []string { return []string{"PATH=/usr/bin:/custom"} }}
	command, err := launcher.command(Project{Directory: "/w"}, "gemini", nil)
	if err != nil {
		t.Fatal(err)
	}
	if want := "/nodes/bin:/usr/bin:/custom:/opt/homebrew/bin:/usr/local/bin:/bin:/usr/sbin:/sbin"; envMap(command.Env)["PATH"] != want {
		t.Errorf("PATH = %q, want %q", envMap(command.Env)["PATH"], want)
	}
}

func TestLocalCatalogAgentVersionIsCached(t *testing.T) {
	program := filepath.Join(t.TempDir(), "gemini")
	if err := os.WriteFile(program, []byte("#!/bin/sh\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	catalog := &agentCatalog{store: agentStore{root: filepath.Join(t.TempDir(), "agents")}, versions: map[string]agentVersionEntry{},
		lookup: func(string) (string, bool) { return program, true }}
	runs := 0
	catalog.versionOf = func(string) string { runs++; return "3.4.5" }
	launcher := &terminalLauncher{agents: catalog, environ: func() []string { return nil }}
	for range 2 {
		command, err := launcher.command(Project{Directory: "/w"}, "gemini", nil)
		if err != nil || command.Version != "3.4.5" {
			t.Fatalf("%+v %v", command, err)
		}
	}
	if runs != 1 {
		t.Errorf("--version ran %d times", runs)
	}
}

func TestTerminalExecutableFilesRejectRelativeCandidates(t *testing.T) {
	fixture := filepath.Join(t.TempDir(), "codex")
	if err := os.WriteFile(fixture, []byte("fixture"), 0700); err != nil {
		t.Fatal(err)
	}
	if !executableFile(fixture) {
		t.Fatal("absolute executable fixture was rejected")
	}
	if executableFile("./codex") {
		t.Fatal("relative executable candidate was accepted")
	}
}

// The OpenCode password and the local session token may live in variables
// named anything; no terminal sees them, whatever the program.
func TestTerminalsNeverSeeTheHostsSecretVariables(t *testing.T) {
	store := NewStore(filepath.Join(t.TempDir(), "private", "state.json"))
	project := Project{ID: "p1", Name: "Project", Directory: t.TempDir()}
	if err := store.Initialize(Config{Projects: []Project{project}, OpenCodeURL: "http://127.0.0.1:4096", PasswordEnv: "MY_OPENCODE_PW"}); err != nil {
		t.Fatal(err)
	}
	launcher := newHostTerminalLauncher(store, &fakeAgent{}, HostOptions{TerminalHiddenEnv: []string{"MY_SESSION"}})
	environment := []string{"SHELL=/bin/sh", "MY_OPENCODE_PW=pw-secret", "MY_SESSION=session-secret", "KEEP=1"}
	launcher.environ = func() []string { return environment }
	launcher.resolve = func(name string) (string, bool) { return "/bin/" + name, true }
	launcher.openCode = func() (string, string, string) { return "http://127.0.0.1:4096", "opencode", "tui-secret" }
	for _, program := range []string{"shell", "claude", "codex", "opencode"} {
		command, err := launcher.command(project, program, nil)
		if err != nil {
			t.Fatal(err)
		}
		joined := strings.Join(command.Env, "\n")
		if strings.Contains(joined, "pw-secret") || strings.Contains(joined, "session-secret") || !slices.Contains(command.Env, "KEEP=1") {
			t.Fatalf("%s environment %v", program, command.Env)
		}
	}
	if environment[1] != "MY_OPENCODE_PW=pw-secret" {
		t.Fatal("the host's environment was changed")
	}
	state, _ := filepath.Abs(store.Path)
	if !slices.Contains(launcher.privateFolders, filepath.Dir(state)) {
		t.Fatalf("private folders %v", launcher.privateFolders)
	}
}
