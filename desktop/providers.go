package host

import (
	"net/http"
	"sort"
	"strings"
	"time"
)

// OpenCode's providers (docs/HOST-API.md "Providers"): every provider the
// running OpenCode speaks, whether it is connected, how many models it has
// and the environment variables that give it a key. Never a key, never a
// provider's options.

type providerJSON struct {
	ID        string   `json:"id"`
	Name      string   `json:"name"`
	Connected bool     `json:"connected"`
	Models    int      `json:"models"`
	Env       []string `json:"env"`
}

// openCodeProviders is the part of OpenCode 1.18.31's GET /provider the
// host reads: {all: [{id, name, env, models: {id: model}}], connected}.
// Everything else (options among it) is never decoded.
type openCodeProviders struct {
	All []struct {
		ID     string              `json:"id"`
		Name   string              `json:"name"`
		Env    []string            `json:"env"`
		Models map[string]struct{} `json:"models"`
	} `json:"all"`
	Connected []string `json:"connected"`
}

const (
	providerCatalogLimit = 32 << 20
	providerCatalogWait  = 15 * time.Second
)

func (h *Host) listProviders(w http.ResponseWriter, r *http.Request) {
	if !h.agentsAvailable(w) {
		return
	}
	adapter, ok := h.agent.(*OpenCodeAdapter)
	if !ok {
		writeError(w, 503, "provider_catalog_unavailable", "OpenCode is not answering")
		return
	}
	project := Project{}
	if state, err := h.store.Read(); err == nil && len(state.Config.Projects) > 0 {
		project = state.Config.Projects[0]
	}
	type answer struct {
		body openCodeProviders
		err  error
	}
	done := make(chan answer, 1)
	go func() {
		var body openCodeProviders
		err := adapter.doLimited("GET", "/provider", project, nil, &body, providerCatalogLimit)
		done <- answer{body, err}
	}()
	timer := time.NewTimer(providerCatalogWait)
	defer timer.Stop()
	var got answer
	select {
	case got = <-done:
	case <-timer.C:
		writeError(w, 503, "provider_catalog_unavailable", "OpenCode is not answering")
		return
	case <-r.Context().Done():
		return
	}
	if got.err != nil || got.body.All == nil {
		writeError(w, 503, "provider_catalog_unavailable", "OpenCode is not answering")
		return
	}
	writeJSON(w, 200, map[string]any{"providers": providerList(got.body)})
}

// providerList maps OpenCode's providers, sorted by name ignoring case.
func providerList(body openCodeProviders) []providerJSON {
	connected := map[string]bool{}
	for _, id := range body.Connected {
		connected[id] = true
	}
	providers := make([]providerJSON, 0, len(body.All))
	for _, provider := range body.All {
		id, _ := clipText(strings.TrimSpace(provider.ID), 128)
		if id == "" {
			continue
		}
		name, _ := clipText(strings.TrimSpace(provider.Name), 200)
		if name == "" {
			name = id
		}
		env := []string{}
		for _, variable := range provider.Env {
			if agentEnvName.MatchString(variable) && len(env) < 16 {
				env = append(env, variable)
			}
		}
		providers = append(providers, providerJSON{ID: id, Name: name, Connected: connected[provider.ID], Models: len(provider.Models), Env: env})
	}
	sort.SliceStable(providers, func(i, j int) bool {
		left, right := strings.ToLower(providers[i].Name), strings.ToLower(providers[j].Name)
		if left != right {
			return left < right
		}
		return providers[i].ID < providers[j].ID
	})
	return providers
}
