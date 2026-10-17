package host

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
)

// robots.txt for agentland_fetch (RFC 9309): the groups for the product
// token "AgentLand" (case-insensitive), or else the "*" groups, apply; the
// longest matching Allow or Disallow rule wins, Allow on a tie; "*" matches
// any characters and a final "$" the end. A robots.txt that answers 4xx
// allows everything; one that answers 5xx, cannot be reached or does not
// arrive in full disallows everything. Each read of a page checks the
// robots.txt of every host it passes through (the tool server keeps nothing
// between reads).
//
// A hostile robots.txt cannot make the reader work harder than its size: the
// file is read once, line by line; a group's rules are kept once however many
// of its user-agent lines match; only the rules that apply are kept, split at
// "*" once; and a file with more than robotsRuleLimit rules (or
// robotsPartLimit pattern pieces) for the agent disallows everything, since it
// could not be honored in full.

const (
	robotsRuleLimit    = 2000
	robotsPartLimit    = 20000
	robotsPatternLimit = 2048
	// robotsCheckEvery is how many lines pass between checks of the read's
	// deadline.
	robotsCheckEvery = 1024
)

// robotsRule is one Allow or Disallow rule: its pattern split at "*" (empty
// pieces between stars dropped), whether it ends with "$", and its length for
// the longest match.
type robotsRule struct {
	allow    bool
	parts    []string
	anchored bool
	length   int
}

type robotsRules []robotsRule

var (
	robotsAllowAll = robotsRules{}
	robotsDenyAll  = robotsRules{{allow: false, parts: []string{"/"}, length: 1}}
)

// robotsSet collects the rules of the groups that apply, up to the limits.
type robotsSet struct {
	rules    robotsRules
	parts    int
	overflow bool
	seen     bool
}

// add keeps a rule; one that cannot be kept (a pattern over
// robotsPatternLimit, or past the limits) makes the set disallow everything.
func (s *robotsSet) add(rule robotsRule, ok bool) {
	if s.overflow {
		return
	}
	if !ok || len(s.rules) == robotsRuleLimit || s.parts+len(rule.parts) > robotsPartLimit {
		s.overflow, s.rules = true, nil
		return
	}
	s.rules = append(s.rules, rule)
	s.parts += len(rule.parts)
}

func (s *robotsSet) result() robotsRules {
	if s.overflow {
		return robotsDenyAll
	}
	return s.rules
}

func compileRobotsRule(allow bool, pattern string) (robotsRule, bool) {
	if len(pattern) > robotsPatternLimit {
		return robotsRule{}, false
	}
	rule := robotsRule{allow: allow, anchored: strings.HasSuffix(pattern, "$"), length: len(pattern)}
	pieces := strings.Split(strings.TrimSuffix(pattern, "$"), "*")
	rule.parts = make([]string, 0, len(pieces))
	for index, piece := range pieces {
		// Empty pieces between two stars match anything; the first and last
		// keep their place (the start and the end).
		if piece == "" && index != 0 && index != len(pieces)-1 {
			continue
		}
		rule.parts = append(rule.parts, piece)
	}
	return rule, true
}

// parseRobots returns the rules for agent (lower case) in a robots.txt, or
// ctx's error once it ends.
func parseRobots(ctx context.Context, data []byte, agent string) (robotsRules, error) {
	var named, fallback robotsSet
	groupNamed, groupStar, agentLines := false, false, false
	text := string(data)
	for lines := 0; len(text) > 0; lines++ {
		if lines%robotsCheckEvery == 0 {
			if err := ctx.Err(); err != nil {
				return nil, err
			}
		}
		line := text
		if end := strings.IndexByte(text, '\n'); end >= 0 {
			line, text = text[:end], text[end+1:]
		} else {
			text = ""
		}
		if comment := strings.IndexByte(line, '#'); comment >= 0 {
			line = line[:comment]
		}
		key, value, found := strings.Cut(line, ":")
		if !found {
			continue
		}
		key, value = strings.ToLower(strings.TrimSpace(key)), strings.TrimSpace(value)
		switch key {
		case "user-agent":
			if !agentLines {
				// A user-agent line after rules starts another group.
				groupNamed, groupStar = false, false
			}
			agentLines = true
			token := strings.ToLower(value)
			if end := strings.IndexAny(token, "/ "); end >= 0 {
				token = token[:end]
			}
			switch token {
			case agent:
				groupNamed, named.seen = true, true
			case "*":
				groupStar, fallback.seen = true, true
			}
		case "allow", "disallow":
			agentLines = false
			if value == "" || (!groupNamed && !groupStar) {
				continue // an empty disallow allows everything
			}
			rule, ok := compileRobotsRule(key == "allow", value)
			if groupNamed {
				named.add(rule, ok)
			}
			if groupStar {
				fallback.add(rule, ok)
			}
		}
	}
	if named.seen {
		return named.result(), nil
	}
	return fallback.result(), nil
}

// allowed reports whether the rules let the agent read path (the URL's
// escaped path and query), or ctx's error once it ends.
func (rules robotsRules) allowed(ctx context.Context, path string) (bool, error) {
	if path == "/robots.txt" {
		return true, nil
	}
	best, allow := -1, true
	for _, rule := range rules {
		// One rule's match can scan the whole path.
		if err := ctx.Err(); err != nil {
			return false, err
		}
		if (rule.length > best || (rule.length == best && rule.allow)) && robotsMatch(rule, path) {
			best, allow = rule.length, rule.allow
		}
	}
	return allow, nil
}

// robotsMatch matches a rule against the start of target.
func robotsMatch(rule robotsRule, target string) bool {
	if len(rule.parts) == 0 {
		return !rule.anchored || target == ""
	}
	if !strings.HasPrefix(target, rule.parts[0]) {
		return false
	}
	rest := target[len(rule.parts[0]):]
	if len(rule.parts) == 1 {
		return !rule.anchored || rest == ""
	}
	for _, part := range rule.parts[1 : len(rule.parts)-1] {
		index := strings.Index(rest, part)
		if index < 0 {
			return false
		}
		rest = rest[index+len(part):]
	}
	last := rule.parts[len(rule.parts)-1]
	if rule.anchored {
		return strings.HasSuffix(rest, last)
	}
	return strings.Contains(rest, last)
}

// robotsCache holds the rules of the hosts one read of a page passes.
type robotsCache struct {
	fetcher *webFetcher
	rules   map[string]robotsRules
}

// check refuses a URL the host's robots.txt does not let AgentLand read, and
// one whose host agentland_fetch never reaches.
func (c *robotsCache) check(ctx context.Context, address *url.URL) error {
	origin := address.Scheme + "://" + address.Host
	rules, known := c.rules[origin]
	if !known {
		var err error
		if rules, err = c.read(ctx, origin); err != nil {
			return err
		}
		c.rules[origin] = rules
	}
	path := address.EscapedPath()
	if path == "" {
		path = "/"
	}
	if address.RawQuery != "" {
		path += "?" + address.RawQuery
	}
	allowed, err := rules.allowed(ctx, path)
	if err != nil {
		return err
	}
	if !allowed {
		return refuseFetch("The site's robots.txt does not let AgentLand read %s.", address.Host)
	}
	return nil
}

// read fetches an origin's robots.txt through the same checked connections.
// An address agentland_fetch refuses is that refusal; a robots.txt that cannot
// be reached otherwise disallows everything.
func (c *robotsCache) read(ctx context.Context, origin string) (robotsRules, error) {
	request, err := http.NewRequestWithContext(ctx, "GET", origin+"/robots.txt", nil)
	if err != nil {
		return robotsDenyAll, nil
	}
	request.Header.Set("User-Agent", c.fetcher.userAgent)
	response, err := c.fetcher.client(nil).Do(request)
	if err != nil {
		var refusal *webFetchRefusal
		if errors.As(err, &refusal) {
			return nil, refusal
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return robotsDenyAll, nil
	}
	defer response.Body.Close()
	switch {
	case response.StatusCode >= 200 && response.StatusCode <= 299:
		data, err := io.ReadAll(io.LimitReader(response.Body, webFetchRobotsLimit))
		if err != nil {
			// One that did not arrive in full may have lost rules.
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			return robotsDenyAll, nil
		}
		return parseRobots(ctx, data, webFetchAgentToken)
	case response.StatusCode >= 400 && response.StatusCode <= 499:
		return robotsAllowAll, nil
	default:
		return robotsDenyAll, nil
	}
}
