package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"

	host "agentland/host"
	"agentland/host/internal/termrun"
)

// chatsUsage names the chats subcommands.
const chatsUsage = "usage: agentland-host chats <continue> …"

const chatsContinueUsage = "usage: agentland-host chats continue [--state <host.json>] -- <prompt>"

// chatsCommand is `chats continue`, which has the host continue the Claude
// Code chat whose tool runs it in a new chat (docs/HOST-API.md, "Continuing a
// chat in a new one").
func chatsCommand(args []string) error {
	if len(args) == 0 {
		return errors.New(chatsUsage)
	}
	switch args[0] {
	case "continue":
		os.Exit(chatsContinueCommand(args[1:], os.Stdout, os.Stderr))
	}
	return errors.New(chatsUsage)
}

// chatsContinueCommand is `chats continue [--state <host.json>] -- <prompt>`
// (termrun.ContinueChat), run by a Claude Code chat's tool: it answers its
// exit code, termrun.ContinueUsage when it is not used as
// chatsContinueUsage says. The state is $AGENTLAND_HOST_STATE, which the host
// sets in each chat's process, unless --state names another; the chat is
// $AGENTLAND_CHAT.
func chatsContinueCommand(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("chats continue", flag.ContinueOnError)
	fs.SetOutput(stderr)
	defaultState := os.Getenv("AGENTLAND_HOST_STATE")
	if defaultState == "" {
		defaultState = host.DefaultStatePath()
	}
	state := fs.String("state", defaultState, "path to protected host state")
	if err := fs.Parse(args); errors.Is(err, flag.ErrHelp) {
		return 0
	} else if err != nil {
		return termrun.ContinueUsage
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(stderr, chatsContinueUsage)
		return termrun.ContinueUsage
	}
	return termrun.ContinueChat(termrun.ContinueChatOptions{
		StatePath: *state, Version: version, Chat: os.Getenv("AGENTLAND_CHAT"), Prompt: fs.Arg(0),
		Stdout: stdout, Stderr: stderr,
	})
}
