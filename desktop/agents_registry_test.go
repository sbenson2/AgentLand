package host

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

// registryFixture has entries shaped like the ACP registry's on 2026-09-26:
// a binary with checksums (goose), npm packages with and without ACP
// arguments (gemini, claude-acp), a binary without checksums (cursor), one
// platform only (kimi), uv (fast-agent) and binary with npm (kilo).
const registryFixture = `{"version":"1.0.0","agents":[
{"id":"goose","name":"goose","version":"1.52.0","description":"A local, extensible, open source AI agent","repository":"https://github.com/block/goose","website":"https://block.github.io/goose/","license":"Apache-2.0","icon":"https://cdn.agentclientprotocol.com/registry/v1/latest/goose.svg",
 "distribution":{"binary":{"darwin-aarch64":{"archive":"https://github.com/block/goose/releases/download/v1.52.0/goose-aarch64-apple-darwin.tar.bz2","cmd":"./goose","args":["acp"],"sha256":"10F7ACA02D26000000000000000000000000000000000000000000000000AAAA"},
                           "darwin-x86_64":{"archive":"https://github.com/block/goose/releases/download/v1.52.0/goose-x86_64-apple-darwin.tar.bz2","cmd":"./goose","args":["acp"],"sha256":"a71d9357b5600000000000000000000000000000000000000000000000000000"},
                           "freebsd-x86_64":{"archive":"https://example.com/goose.tar.gz","cmd":"./goose"}}}},
{"id":"gemini","name":"Gemini CLI","version":"0.61.0","description":"Google's official CLI for Gemini","repository":"https://github.com/google-gemini/gemini-cli","website":"https://geminicli.com","license":"Apache-2.0","distribution":{"npx":{"package":"@google/gemini-cli@0.61.0","args":["--acp"]}}},
{"id":"claude-acp","name":"Claude Agent","version":"0.81.2","license":"proprietary","icon":"https://cdn.agentclientprotocol.com/registry/v1/latest/claude-acp.svg","distribution":{"npx":{"package":"@agentclientprotocol/claude-agent-acp@0.81.2"}}},
{"id":"cursor","name":"Cursor","version":"2026.09.18","distribution":{"binary":{"darwin-aarch64":{"archive":"https://downloads.cursor.com/lab/2026.09.18-9a7762b/darwin/arm64/agent-cli-package.tar.gz","cmd":"./dist-package/cursor-agent","args":["acp"]},"darwin-x86_64":{"archive":"https://downloads.cursor.com/lab/2026.09.18-9a7762b/darwin/x64/agent-cli-package.tar.gz","cmd":"./dist-package/cursor-agent","args":["acp"]}}}},
{"id":"kimi","name":"Kimi CLI","version":"1.52.0","distribution":{"binary":{"darwin-aarch64":{"archive":"https://github.com/MoonshotAI/kimi-cli/releases/download/1.52.0/kimi-1.52.0-aarch64-apple-darwin.tar.gz","cmd":"./kimi","args":["acp"],"sha256":"43fe091f70bb0000000000000000000000000000000000000000000000000000"}}}},
{"id":"fast-agent","name":"fast-agent","version":"0.10.1","distribution":{"uvx":{"package":"fast-agent-acp==0.10.1","args":["-x"],"env":{"FAST_AGENT_MODEL":"codexplan"}}}},
{"id":"minion-code","name":"Minion Code","version":"0.1.44","distribution":{"uvx":{"package":"minion-code@0.1.44","args":["acp"]}}},
{"id":"kilo","name":"Kilo","version":"7.8.1","distribution":{"binary":{"darwin-aarch64":{"archive":"https://github.com/Kilo-Org/kilocode/releases/download/v7.8.1/kilo-darwin-arm64.zip","cmd":"./kilo","args":["acp"]}},"npx":{"package":"@kilocode/cli@7.8.1","args":["acp"]}}},
{"id":"agoragentic-acp","name":"Agoragentic","version":"1.3.0","distribution":{"npx":{"package":"agoragentic-mcp","args":["--acp"]}}}
],"extensions":[]}`

func mustRegistry(t *testing.T, document string) map[string]registryAgent {
	t.Helper()
	agents, err := parseRegistry([]byte(document))
	if err != nil {
		t.Fatal(err)
	}
	byID := map[string]registryAgent{}
	for _, agent := range agents {
		byID[agent.ID] = agent
	}
	return byID
}

func TestParseRegistryFixture(t *testing.T) {
	agents := mustRegistry(t, registryFixture)
	if len(agents) != 9 {
		t.Fatalf("agents %d", len(agents))
	}
	goose := agents["goose"]
	if goose.Name != "goose" || goose.Version != "1.52.0" || goose.Website != "https://block.github.io/goose/" || goose.License != "Apache-2.0" || goose.Icon == "" {
		t.Fatalf("goose %+v", goose)
	}
	if len(goose.Binary) != 2 {
		t.Fatalf("goose binaries %v (an unknown platform is left out)", goose.Binary)
	}
	binary := goose.Binary["darwin-aarch64"]
	if binary.Format != "tar.bz2" || binary.Cmd != "goose" || !reflect.DeepEqual(binary.Args, []string{"acp"}) || binary.SHA256 != strings.ToLower("10F7ACA02D26000000000000000000000000000000000000000000000000AAAA") {
		t.Fatalf("goose binary %+v (the checksum is kept in lower case)", binary)
	}
	if agents["gemini"].NPX == nil || agents["gemini"].NPX.Package != "@google/gemini-cli@0.61.0" || agents["gemini"].NPX.Name != "@google/gemini-cli" {
		t.Fatalf("gemini %+v", agents["gemini"].NPX)
	}
	// A package without a version is pinned to the entry's.
	if pkg := agents["agoragentic-acp"].NPX; pkg == nil || pkg.Package != "agoragentic-mcp@1.3.0" {
		t.Fatalf("agoragentic %+v", pkg)
	}
	// uv: == or @, kept as ==.
	if pkg := agents["fast-agent"].UVX; pkg == nil || pkg.Package != "fast-agent-acp==0.10.1" || pkg.Env["FAST_AGENT_MODEL"] != "codexplan" {
		t.Fatalf("fast-agent %+v", pkg)
	}
	if pkg := agents["minion-code"].UVX; pkg == nil || pkg.Package != "minion-code==0.1.44" {
		t.Fatalf("minion-code %+v", pkg)
	}
	// Without a website, the repository is shown.
	if agents["gemini"].Website != "https://geminicli.com" {
		t.Fatalf("gemini website %q", agents["gemini"].Website)
	}
}

func TestParseRegistryLeavesOutBadEntries(t *testing.T) {
	good := func(fields map[string]any) map[string]any {
		entry := map[string]any{"id": "ok", "name": "OK", "version": "1.0.0", "distribution": map[string]any{"npx": map[string]any{"package": "ok@1.0.0"}}}
		for key, value := range fields {
			if value == nil {
				delete(entry, key)
			} else {
				entry[key] = value
			}
		}
		return entry
	}
	binary := func(fields map[string]any) map[string]any {
		platform := map[string]any{"archive": "https://example.com/a.tar.gz", "cmd": "./a", "args": []string{"acp"}}
		for key, value := range fields {
			platform[key] = value
		}
		return map[string]any{"binary": map[string]any{"darwin-aarch64": platform}}
	}
	cases := []struct {
		name  string
		entry map[string]any
	}{
		{"upper-case id", good(map[string]any{"id": "Upper"})},
		{"id with a slash", good(map[string]any{"id": "a/b"})},
		{"id too long", good(map[string]any{"id": strings.Repeat("a", 65)})},
		{"id naming the registry's copy", good(map[string]any{"id": "registry.json"})},
		{"id naming a kept file", good(map[string]any{"id": "notes.json"})},
		{"id naming a hidden file", good(map[string]any{"id": ".icons"})},
		{"no name", good(map[string]any{"name": nil})},
		{"name with a control character", good(map[string]any{"name": "a\nb"})},
		{"version with a slash", good(map[string]any{"version": "1/2"})},
		{"version naming a kept file", good(map[string]any{"version": "Current.JSON"})},
		{"no distribution", good(map[string]any{"distribution": nil})},
		{"empty distribution", good(map[string]any{"distribution": map[string]any{}})},
		{"npm range", good(map[string]any{"distribution": map[string]any{"npx": map[string]any{"package": "ok@^1.0.0"}}})},
		{"npm tag", good(map[string]any{"distribution": map[string]any{"npx": map[string]any{"package": "ok@latest"}}})},
		{"npm major only (a range)", good(map[string]any{"distribution": map[string]any{"npx": map[string]any{"package": "ok@1"}}})},
		{"npm major and minor (a range)", good(map[string]any{"distribution": map[string]any{"npx": map[string]any{"package": "ok@1.2"}}})},
		{"npm x-range", good(map[string]any{"distribution": map[string]any{"npx": map[string]any{"package": "ok@1.x"}}})},
		{"npm patch x-range", good(map[string]any{"distribution": map[string]any{"npx": map[string]any{"package": "ok@1.2.x"}}})},
		{"npm four numbers", good(map[string]any{"distribution": map[string]any{"npx": map[string]any{"package": "ok@1.2.3.4"}}})},
		{"npm pinned to an entry version that is a range", good(map[string]any{"version": "2", "distribution": map[string]any{"npx": map[string]any{"package": "ok"}}})},
		{"npm upper-case name", good(map[string]any{"distribution": map[string]any{"npx": map[string]any{"package": "OK@1.0.0"}}})},
		{"empty argument", good(map[string]any{"distribution": map[string]any{"npx": map[string]any{"package": "ok@1.0.0", "args": []string{""}}}})},
		{"too many arguments", good(map[string]any{"distribution": map[string]any{"npx": map[string]any{"package": "ok@1.0.0", "args": strings.Split(strings.Repeat("a,", 33)[:65], ",")}}})},
		{"bad environment name", good(map[string]any{"distribution": map[string]any{"npx": map[string]any{"package": "ok@1.0.0", "env": map[string]string{"A-B": "x"}}}})},
		{"http archive", good(map[string]any{"distribution": binary(map[string]any{"archive": "http://example.com/a.tar.gz"})})},
		{"archive with user information", good(map[string]any{"distribution": binary(map[string]any{"archive": "https://user:pass@example.com/a.tar.gz"})})},
		{"unknown archive format", good(map[string]any{"distribution": binary(map[string]any{"archive": "https://example.com/a.dmg"})})},
		{"cmd leaving the folder", good(map[string]any{"distribution": binary(map[string]any{"cmd": "../a"})})},
		{"cmd with .. inside", good(map[string]any{"distribution": binary(map[string]any{"cmd": "./bin/../../a"})})},
		{"absolute cmd", good(map[string]any{"distribution": binary(map[string]any{"cmd": "/bin/sh"})})},
		{"short checksum", good(map[string]any{"distribution": binary(map[string]any{"sha256": "abc"})})},
		{"checksum of the wrong type", good(map[string]any{"distribution": binary(map[string]any{"sha256": 12})})},
	}
	for _, test := range cases {
		document, _ := json.Marshal(map[string]any{"version": "1.0.0", "agents": []any{test.entry}})
		agents, err := parseRegistry(document)
		if err != nil {
			t.Fatalf("%s: %v", test.name, err)
		}
		if len(agents) != 0 {
			t.Errorf("%s: kept %+v", test.name, agents)
		}
	}
	// A bad member that is only shown is dropped; the entry stays.
	document, _ := json.Marshal(map[string]any{"version": "1.0.0", "agents": []any{
		good(map[string]any{"website": "http://example.com", "license": strings.Repeat("x", 101), "icon": "javascript:alert(1)", "description": strings.Repeat("word ", 400)}),
		good(map[string]any{"name": "Second"}),
	}})
	agents, err := parseRegistry(document)
	if err != nil || len(agents) != 1 {
		t.Fatalf("a repeated id is left out: %v %+v", err, agents)
	}
	if agent := agents[0]; agent.Name != "OK" || agent.Website != "" || agent.License != "" || agent.Icon != "" || len([]rune(agent.Description)) != 1000 || !strings.HasSuffix(agent.Description, "…") {
		t.Fatalf("shown members %+v", agent)
	}
	// A full npm version keeps its pre-release and build parts; uv's == is
	// exact at any length.
	document, _ = json.Marshal(map[string]any{"version": "1.0.0", "agents": []any{
		good(map[string]any{"distribution": map[string]any{"npx": map[string]any{"package": "ok@1.2.3-beta.1+build.5"}}}),
		good(map[string]any{"id": "py", "version": "2", "distribution": map[string]any{"uvx": map[string]any{"package": "py-agent"}}}),
	}})
	agents, err = parseRegistry(document)
	if err != nil || len(agents) != 2 || agents[0].NPX == nil || agents[0].NPX.Package != "ok@1.2.3-beta.1+build.5" || agents[1].UVX == nil || agents[1].UVX.Package != "py-agent==2" {
		t.Fatalf("exact versions %v %+v", err, agents)
	}
}

func TestParseRegistryRefusesDocuments(t *testing.T) {
	for _, document := range []string{`[]`, `{}`, `{"agents":null}`, `{"version":"2.0.0","agents":[]}`, `{"version":3,"agents":[]}`, `not json`} {
		if _, err := parseRegistry([]byte(document)); err == nil {
			t.Errorf("%s was taken", document)
		}
	}
	if agents, err := parseRegistry([]byte(`{"agents":[]}`)); err != nil || len(agents) != 0 {
		t.Errorf("a document without version: %v", err)
	}
}

func TestDistributionChoice(t *testing.T) {
	agents := mustRegistry(t, registryFixture)
	cases := []struct {
		id, platform, kind string
		verified, ok       bool
	}{
		{"goose", "darwin-aarch64", "binary", true, true},
		{"goose", "darwin-x86_64", "binary", true, true},
		{"goose", "linux-x86_64", "", false, false},
		{"gemini", "darwin-aarch64", "npx", true, true},
		{"cursor", "darwin-aarch64", "binary", false, true},
		{"kimi", "darwin-aarch64", "binary", true, true},
		{"kimi", "darwin-x86_64", "", false, false},
		{"fast-agent", "darwin-x86_64", "uvx", true, true},
		// A binary without a checksum loses to a pinned package.
		{"kilo", "darwin-aarch64", "npx", true, true},
	}
	for _, test := range cases {
		dist, ok := agents[test.id].choose(test.platform)
		if ok != test.ok || dist.Kind != test.kind || dist.Verified != test.verified {
			t.Errorf("%s on %s: %+v %v, want %s verified=%v %v", test.id, test.platform, dist, ok, test.kind, test.verified, test.ok)
		}
	}
	if args := agents["gemini"].NPX.Args; !reflect.DeepEqual(args, []string{"--acp"}) {
		t.Errorf("gemini args %v", args)
	}
	for goos, want := range map[[2]string]string{{"darwin", "arm64"}: "darwin-aarch64", {"darwin", "amd64"}: "darwin-x86_64", {"linux", "amd64"}: "linux-x86_64", {"windows", "arm64"}: "windows-aarch64", {"darwin", "386"}: "", {"plan9", "amd64"}: ""} {
		if got := agentPlatformFor(goos[0], goos[1]); got != want {
			t.Errorf("%v: %q, want %q", goos, got, want)
		}
	}
	for id, want := range map[string]string{"claude-acp": "claude", "codex-acp": "codex", "opencode": "opencode", "gemini": "gemini", "claude": "claude"} {
		if got := nativeAgentID(id); got != want {
			t.Errorf("%s maps to %s, want %s", id, got, want)
		}
	}
}
