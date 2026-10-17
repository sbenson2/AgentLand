package main

import (
	host "agentland/host"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func configuredProjects(raw []string) ([]host.Project, error) {
	projects := make([]host.Project, 0, len(raw))
	for _, value := range raw {
		fields := strings.SplitN(value, "=", 3)
		if len(fields) != 3 {
			return nil, fmt.Errorf("invalid project %q", value)
		}
		directory, err := filepath.Abs(fields[2])
		if err != nil {
			return nil, err
		}
		projects = append(projects, host.Project{ID: fields[0], Name: fields[1], Directory: directory})
	}
	if len(projects) == 0 {
		return nil, errors.New("at least one --project is required")
	}
	return projects, nil
}
func configCommand(args []string) error {
	if len(args) == 0 {
		return errors.New("usage: agentland-host config <show|set> [options]")
	}
	fs := flag.NewFlagSet("config "+args[0], flag.ContinueOnError)
	state := stateFlag(fs)
	switch args[0] {
	case "show":
		if err := fs.Parse(args[1:]); err != nil {
			return err
		}
		stored, err := host.NewStore(*state).Read()
		if err != nil {
			return err
		}
		return json.NewEncoder(os.Stdout).Encode(stored.Config)
	case "set":
		endpoint := fs.String("opencode-url", "http://127.0.0.1:4197", "loopback OpenCode URL")
		passwordEnv := fs.String("password-env", "AGENTLAND_OPENCODE_PASSWORD", "name of password environment variable")
		var projects projectsFlag
		fs.Var(&projects, "project", "project as id=name=/absolute/directory (repeatable)")
		if err := fs.Parse(args[1:]); err != nil {
			return err
		}
		values, err := configuredProjects(projects)
		if err != nil {
			return err
		}
		return host.NewStore(*state).UpdateConfig(host.Config{OpenCodeURL: *endpoint, PasswordEnv: *passwordEnv, Projects: values})
	default:
		return errors.New("unknown configuration command")
	}
}
