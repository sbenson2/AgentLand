package host

import (
	"encoding/json"
	"errors"
	"net/url"
	"path"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"
)

// The ACP registry (docs/HOST-API.md "Agents", "The registry"): its entries
// as the host checks them, and the distribution this Mac uses for each.
// Every entry is checked on its own; one that fails is left out and the rest
// are kept.

const (
	agentRegistryURL   = "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json"
	agentRegistryLimit = 4 << 20
	// agentRegistryEntryLimit bounds the entries kept (41 on 2026-09-26):
	// the first valid ones in the document's order.
	agentRegistryEntryLimit = 2000
)

var errRegistryFormat = errors.New("the registry is not in a format this host reads")

// agentIDPattern is the rule every agent id follows: 1–64 lowercase letters,
// digits, ".", "_" and "-", starting with a letter or digit, and never a name
// the agents folder keeps beside the agents' own folders. No id ends in
// ".json" (registry.json), and none starts with "." (.icons, temporary
// files).
var agentIDPattern agentIDRule

type agentIDRule struct{}

func (agentIDRule) MatchString(id string) bool {
	return agentIDSyntax.MatchString(id) && !strings.HasSuffix(id, ".json")
}

var (
	agentIDSyntax       = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,63}$`)
	agentVersionPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$`)
	// An exact uv package version: a digit first, never a tag. PEP 440's ==
	// is exact, and a wildcard (1.*) is refused by the characters.
	uvExactVersion = regexp.MustCompile(`^[0-9][0-9A-Za-z.+!-]{0,63}$`)
	// A full npm version: three numbers and optional pre-release or build
	// parts. npm reads 1, 1.2 and 1.x as ranges, never as one version.
	npmExactVersion   = regexp.MustCompile(`^\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)*$`)
	npmNamePattern    = regexp.MustCompile(`^(@[a-z0-9][a-z0-9._~-]*/)?[a-z0-9][a-z0-9._~-]*$`)
	pythonNamePattern = regexp.MustCompile(`^[A-Za-z0-9]([A-Za-z0-9._-]{0,126}[A-Za-z0-9])?$`)
	agentEnvName      = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]{0,127}$`)
	agentPlatformKey  = regexp.MustCompile(`^(darwin|linux|windows)-(aarch64|x86_64)$`)
)

// registryAgent is one checked registry entry.
type registryAgent struct {
	ID, Name, Version string
	Description       string
	Website           string // the entry's website, else its repository
	License           string
	Icon              string
	NPX, UVX          *registryPackage
	Binary            map[string]registryBinary
}

type registryPackage struct {
	// Package is pinned: name@version for npm, name==version for uv.
	Package string
	Name    string // without the version
	Args    []string
	Env     map[string]string
}

type registryBinary struct {
	Archive string
	Format  string // zip, tar.gz or tar.bz2
	Cmd     string // cleaned, slash-separated, relative
	Args    []string
	SHA256  string // lowercase hex, "" when the registry gives none
	Env     map[string]string
}

// parseRegistry reads a registry document. A document that is not a JSON
// object with an agents array, or of another major version, is refused; each
// entry that fails its checks is left out, as is a repeated id, and entries
// past the first agentRegistryEntryLimit kept are not read.
func parseRegistry(data []byte) ([]registryAgent, error) {
	var document struct {
		Version json.RawMessage   `json:"version"`
		Agents  []json.RawMessage `json:"agents"`
	}
	if err := json.Unmarshal(data, &document); err != nil || document.Agents == nil {
		return nil, errRegistryFormat
	}
	if len(document.Version) > 0 && string(document.Version) != "null" {
		var version string
		if json.Unmarshal(document.Version, &version) != nil || (version != "1" && !strings.HasPrefix(version, "1.")) {
			return nil, errRegistryFormat
		}
	}
	seen := map[string]bool{}
	agents := []registryAgent{}
	for _, raw := range document.Agents {
		if len(agents) == agentRegistryEntryLimit {
			break
		}
		agent, ok := parseRegistryAgent(raw)
		if !ok || seen[agent.ID] {
			continue
		}
		seen[agent.ID] = true
		agents = append(agents, agent)
	}
	sort.Slice(agents, func(i, j int) bool { return agents[i].ID < agents[j].ID })
	return agents, nil
}

// registryString decodes an optional string member; anything else is "".
func registryString(raw json.RawMessage) string {
	var value string
	if len(raw) == 0 || json.Unmarshal(raw, &value) != nil {
		return ""
	}
	return value
}

func parseRegistryAgent(raw json.RawMessage) (registryAgent, bool) {
	var entry map[string]json.RawMessage
	if json.Unmarshal(raw, &entry) != nil || entry == nil {
		return registryAgent{}, false
	}
	agent := registryAgent{ID: registryString(entry["id"]), Name: registryString(entry["name"]), Version: registryString(entry["version"])}
	if !agentIDPattern.MatchString(agent.ID) || !validAgentVersion(agent.Version) || !plainAgentText(agent.Name, 100) || strings.TrimSpace(agent.Name) == "" {
		return registryAgent{}, false
	}
	agent.Name = strings.TrimSpace(agent.Name)
	agent.Description = agentDescription(registryString(entry["description"]))
	agent.Website = agentHTTPSURL(registryString(entry["website"]), 512)
	if agent.Website == "" {
		agent.Website = agentHTTPSURL(registryString(entry["repository"]), 512)
	}
	if license := strings.TrimSpace(registryString(entry["license"])); plainAgentText(license, 100) {
		agent.License = license
	}
	agent.Icon = agentHTTPSURL(registryString(entry["icon"]), 512)
	var distribution map[string]json.RawMessage
	if json.Unmarshal(entry["distribution"], &distribution) != nil {
		return registryAgent{}, false
	}
	if npx, ok := parseRegistryPackage(distribution["npx"], agent.Version, false); ok {
		agent.NPX = &npx
	}
	if uvx, ok := parseRegistryPackage(distribution["uvx"], agent.Version, true); ok {
		agent.UVX = &uvx
	}
	var binaries map[string]json.RawMessage
	if json.Unmarshal(distribution["binary"], &binaries) == nil {
		for platform, raw := range binaries {
			if !agentPlatformKey.MatchString(platform) {
				continue
			}
			if binary, ok := parseRegistryBinary(raw); ok {
				if agent.Binary == nil {
					agent.Binary = map[string]registryBinary{}
				}
				agent.Binary[platform] = binary
			}
		}
	}
	if agent.NPX == nil && agent.UVX == nil && len(agent.Binary) == 0 {
		return registryAgent{}, false
	}
	return agent, true
}

// validAgentVersion is a version that can name its install's folder: never
// one of the files kept beside the versions (macOS compares names without
// case).
func validAgentVersion(version string) bool {
	return agentVersionPattern.MatchString(version) && !strings.HasSuffix(strings.ToLower(version), ".json")
}

// plainAgentText is text of at most limit characters without control
// characters.
func plainAgentText(value string, limit int) bool {
	if !utf8.ValidString(value) || utf8.RuneCountInString(value) > limit {
		return false
	}
	for _, r := range value {
		if unicode.IsControl(r) {
			return false
		}
	}
	return true
}

// agentDescription drops control characters and cuts to 1000 characters.
func agentDescription(value string) string {
	if !utf8.ValidString(value) {
		return ""
	}
	value = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, value)
	value = strings.Join(strings.Fields(value), " ")
	if utf8.RuneCountInString(value) > 1000 {
		runes := []rune(value)
		value = strings.TrimSpace(string(runes[:999])) + "…"
	}
	return value
}

// agentHTTPSURL returns value when it is an https URL with a host and no user
// information, at most limit bytes; otherwise "".
func agentHTTPSURL(value string, limit int) string {
	if value == "" || len(value) > limit || !utf8.ValidString(value) || strings.ContainsAny(value, " \t\r\n\x00") {
		return ""
	}
	parsed, err := url.Parse(value)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil || parsed.Opaque != "" {
		return ""
	}
	return value
}

func parseRegistryArgs(raw json.RawMessage) ([]string, bool) {
	if len(raw) == 0 || string(raw) == "null" {
		return []string{}, true
	}
	var args []string
	if json.Unmarshal(raw, &args) != nil || len(args) > 32 {
		return nil, false
	}
	for _, arg := range args {
		if arg == "" || len(arg) > 1024 || !utf8.ValidString(arg) || strings.ContainsRune(arg, 0) {
			return nil, false
		}
	}
	if args == nil {
		args = []string{}
	}
	return args, true
}

func parseRegistryEnv(raw json.RawMessage) (map[string]string, bool) {
	if len(raw) == 0 || string(raw) == "null" {
		return nil, true
	}
	var env map[string]string
	if json.Unmarshal(raw, &env) != nil || len(env) > 32 {
		return nil, false
	}
	for name, value := range env {
		if !agentEnvName.MatchString(name) || len(value) > 4096 || !utf8.ValidString(value) || strings.ContainsRune(value, 0) {
			return nil, false
		}
	}
	if len(env) == 0 {
		return nil, true
	}
	return env, true
}

// parseRegistryPackage checks an npx or uvx distribution and pins its package
// to an exact version (the entry's when it names none): for npm a full
// version, since anything shorter is a range there.
func parseRegistryPackage(raw json.RawMessage, version string, python bool) (registryPackage, bool) {
	var fields map[string]json.RawMessage
	if len(raw) == 0 || json.Unmarshal(raw, &fields) != nil || fields == nil {
		return registryPackage{}, false
	}
	spec := strings.TrimSpace(registryString(fields["package"]))
	args, ok := parseRegistryArgs(fields["args"])
	if !ok {
		return registryPackage{}, false
	}
	env, ok := parseRegistryEnv(fields["env"])
	if !ok {
		return registryPackage{}, false
	}
	name, pinned := "", ""
	if python {
		name, pinned = spec, ""
		if before, after, found := strings.Cut(spec, "=="); found {
			name, pinned = before, after
		} else if before, after, found := strings.Cut(spec, "@"); found {
			name, pinned = before, after
		}
		if pinned == "" {
			pinned = version
		}
		if !pythonNamePattern.MatchString(name) || !uvExactVersion.MatchString(pinned) {
			return registryPackage{}, false
		}
		return registryPackage{Package: name + "==" + pinned, Name: name, Args: args, Env: env}, true
	}
	name = spec
	if at := strings.LastIndex(spec, "@"); at > 0 {
		name, pinned = spec[:at], spec[at+1:]
	}
	if pinned == "" {
		pinned = version
	}
	if len(name) > 214 || !npmNamePattern.MatchString(name) || len(pinned) > 64 || !npmExactVersion.MatchString(pinned) {
		return registryPackage{}, false
	}
	return registryPackage{Package: name + "@" + pinned, Name: name, Args: args, Env: env}, true
}

func parseRegistryBinary(raw json.RawMessage) (registryBinary, bool) {
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil || fields == nil {
		return registryBinary{}, false
	}
	binary := registryBinary{Archive: agentHTTPSURL(registryString(fields["archive"]), 2048)}
	if binary.Archive == "" {
		return registryBinary{}, false
	}
	parsed, _ := url.Parse(binary.Archive)
	lower := strings.ToLower(parsed.Path)
	switch {
	case strings.HasSuffix(lower, ".zip"):
		binary.Format = "zip"
	case strings.HasSuffix(lower, ".tar.gz"), strings.HasSuffix(lower, ".tgz"):
		binary.Format = "tar.gz"
	case strings.HasSuffix(lower, ".tar.bz2"), strings.HasSuffix(lower, ".tbz2"):
		binary.Format = "tar.bz2"
	default:
		return registryBinary{}, false
	}
	cmd, ok := cleanAgentCmd(registryString(fields["cmd"]))
	if !ok {
		return registryBinary{}, false
	}
	binary.Cmd = cmd
	if binary.Args, ok = parseRegistryArgs(fields["args"]); !ok {
		return registryBinary{}, false
	}
	if binary.Env, ok = parseRegistryEnv(fields["env"]); !ok {
		return registryBinary{}, false
	}
	if sum := registryString(fields["sha256"]); sum != "" {
		sum = strings.ToLower(sum)
		if !validSHA256(sum) {
			return registryBinary{}, false
		}
		binary.SHA256 = sum
	} else if len(fields["sha256"]) > 0 && string(fields["sha256"]) != "null" && string(fields["sha256"]) != `""` {
		return registryBinary{}, false
	}
	return binary, true
}

func validSHA256(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, c := range value {
		if !(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// cleanAgentCmd accepts a relative, slash-separated path without "..".
func cleanAgentCmd(value string) (string, bool) {
	if value == "" || len(value) > 512 || !utf8.ValidString(value) || strings.ContainsAny(value, "\\\x00") || strings.HasPrefix(value, "/") {
		return "", false
	}
	for _, component := range strings.Split(value, "/") {
		if component == ".." {
			return "", false
		}
	}
	cleaned := path.Clean(value)
	if cleaned == "." || cleaned == ".." || strings.HasPrefix(cleaned, "../") || strings.HasPrefix(cleaned, "/") {
		return "", false
	}
	return cleaned, true
}

// agentPlatform names this build's platform the registry's way.
func agentPlatform() string {
	return agentPlatformFor(runtime.GOOS, runtime.GOARCH)
}

func agentPlatformFor(goos, goarch string) string {
	arch := map[string]string{"arm64": "aarch64", "amd64": "x86_64"}[goarch]
	if arch == "" {
		return ""
	}
	switch goos {
	case "darwin", "linux", "windows":
		return goos + "-" + arch
	}
	return ""
}

// agentDistribution is the way this Mac installs an agent.
type agentDistribution struct {
	Kind     string // binary, npx or uvx
	Binary   registryBinary
	Package  registryPackage
	Verified bool
}

// args are the distribution's (ACP) arguments; env its own environment.
func (d agentDistribution) args() []string {
	if d.Kind == "binary" {
		return d.Binary.Args
	}
	return d.Package.Args
}

func (d agentDistribution) env() map[string]string {
	if d.Kind == "binary" {
		return d.Binary.Env
	}
	return d.Package.Env
}

// choose picks, in order: this platform's binary with sha256, npx, uvx, this
// platform's binary without sha256 (not verified).
func (a registryAgent) choose(platform string) (agentDistribution, bool) {
	binary, hasBinary := a.Binary[platform]
	switch {
	case hasBinary && binary.SHA256 != "":
		return agentDistribution{Kind: "binary", Binary: binary, Verified: true}, true
	case a.NPX != nil:
		return agentDistribution{Kind: "npx", Package: *a.NPX, Verified: true}, true
	case a.UVX != nil:
		return agentDistribution{Kind: "uvx", Package: *a.UVX, Verified: true}, true
	case hasBinary:
		return agentDistribution{Kind: "binary", Binary: binary}, true
	}
	return agentDistribution{}, false
}

// nativeAgentID maps the registry's ids for the agents AgentLand runs with
// its own adapters onto their ids; others are used as they are.
func nativeAgentID(registryID string) string {
	switch registryID {
	case "claude-acp", "claude":
		return "claude"
	case "codex-acp", "codex":
		return "codex"
	}
	return registryID
}

// nativeAgent reports the agents AgentLand runs with its own adapters.
func nativeAgent(id string) bool { return id == "claude" || id == "codex" || id == "opencode" }
