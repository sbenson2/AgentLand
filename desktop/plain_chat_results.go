package host

import (
	"encoding/json"
	"net/url"
	"strings"
	"unicode"
	"unicode/utf8"
)

// Sources and memory on tool parts (docs/HOST-API.md "Sources and memory on
// tool parts"): a completed websearch part names the pages OpenCode's search
// returned, parsed from its output; a completed agentland_fetch part the page
// it read, and a completed agentland_memory_save part the entry it stored,
// both from the metadata the tool server put in its MCP result (OpenCode
// 1.18.31 copies a tool result's metadata member into the part's
// state.metadata, session/tools.ts).

// plainChatLine is text as one line of what can be seen: each run of white
// space (Unicode White_Space, line breaks included) becomes one space, and
// of the rest only letters, marks, numbers, punctuation and symbols are kept
// that are not default-ignorable. Control, format (the bidirectional
// controls and tag characters among them), private-use, surrogate and
// unassigned code points, Unicode's other Default_Ignorable_Code_Point
// characters (variation selectors, the combining grapheme joiner, the Hangul
// fillers) and the blank Braille pattern are dropped, so no text hides in
// characters that show nothing. The ends are trimmed. Memory text
// (memory.go) and source titles are cleaned this way, and the apps clean what
// they show the same way (AgentLandCore's PlainChatText).
func plainChatLine(text string) string {
	var out strings.Builder
	gap := false
	for _, r := range strings.ToValidUTF8(text, "�") {
		switch {
		case unicode.Is(unicode.White_Space, r):
			gap = true
		case plainChatShown(r):
			if gap && out.Len() > 0 {
				out.WriteByte(' ')
			}
			gap = false
			out.WriteRune(r)
		}
	}
	return out.String()
}

// plainChatBrailleBlank is U+2800 BRAILLE PATTERN BLANK, a symbol that shows
// nothing.
const plainChatBrailleBlank = 0x2800

// plainChatShown reports whether plainChatLine keeps a character that is not
// white space: letters (L), marks (M), numbers (N), punctuation (P) and
// symbols (S), except the default-ignorable ones and the blank Braille
// pattern. Default_Ignorable_Code_Point is Other_Default_Ignorable_Code_Point
// with the format characters (Cf) and variation selectors, less white space
// and a few format characters, all of which go here anyway.
func plainChatShown(r rune) bool {
	switch {
	case r == plainChatBrailleBlank, unicode.In(r, unicode.Other_Default_Ignorable_Code_Point, unicode.Variation_Selector):
		return false
	case unicode.In(r, unicode.L, unicode.M, unicode.N, unicode.P, unicode.S):
		return true
	}
	return false
}

// chatToolResultMetadata is what the tool server puts in a result's
// metadata, under "agentland": the page a fetch read, the entry a save
// stored or a forget removed.
type chatToolResultMetadata struct {
	AgentLand *chatToolAgentLand `json:"agentland,omitempty"`
}

type chatToolAgentLand struct {
	Source *ChatToolSource `json:"source,omitempty"`
	Memory *ChatToolMemory `json:"memory,omitempty"`
}

// ocToolMetadata is the member of an OpenCode tool part's state.metadata the
// host reads: agentland, kept raw. The rest (a bash part's metadata can be
// large) is skipped, and metadata of another shape reads as none, so it can
// never fail a transcript.
type ocToolMetadata struct {
	AgentLand json.RawMessage
}

func (m *ocToolMetadata) UnmarshalJSON(data []byte) error {
	var fields struct {
		AgentLand json.RawMessage `json:"agentland"`
	}
	if json.Unmarshal(data, &fields) == nil && string(fields.AgentLand) != "null" {
		m.AgentLand = fields.AgentLand
	}
	return nil
}

// chatToolResults returns what a completed tool part carries besides its own
// fields; agentland is the part's metadata member of that name.
func chatToolResults(name, output string, agentland json.RawMessage) ChatToolResults {
	switch name {
	case chatToolWebsearch:
		return ChatToolResults{Sources: websearchSources(output)}
	case chatToolFetch, chatToolMemorySave, chatToolMemoryForget:
		var meta chatToolAgentLand
		if len(agentland) == 0 || json.Unmarshal(agentland, &meta) != nil {
			return ChatToolResults{}
		}
		if name == chatToolFetch {
			if source := meta.Source; source != nil {
				if cleaned, ok := plainChatSource(source.Title, source.URL); ok {
					return ChatToolResults{Sources: []ChatToolSource{cleaned}}
				}
			}
			return ChatToolResults{}
		}
		if memory := meta.Memory; memory != nil {
			if cleaned, ok := plainChatMemory(memory.ID, memory.Text); ok {
				return ChatToolResults{Memory: &cleaned}
			}
		}
	}
	return ChatToolResults{}
}

// plainChatSource returns a source as tool parts carry it: an http or https
// URL of at most 2,048 bytes with a host and without user information, and a
// title on one line of at most 200 bytes, the URL's host name when there is
// none.
func plainChatSource(title, raw string) (ChatToolSource, bool) {
	if raw == "" || len(raw) > chatToolSourceURLLimit || !utf8.ValidString(raw) || strings.IndexFunc(raw, func(r rune) bool { return unicode.IsSpace(r) || unicode.IsControl(r) }) >= 0 {
		return ChatToolSource{}, false
	}
	address, err := url.Parse(raw)
	if err != nil || (address.Scheme != "http" && address.Scheme != "https") || address.Host == "" || address.Hostname() == "" || address.User != nil || address.Opaque != "" {
		return ChatToolSource{}, false
	}
	title = plainChatTitle(title)
	if title == "" {
		title = plainChatTitle(address.Hostname())
	}
	return ChatToolSource{Title: title, URL: raw}, true
}

// plainChatTitle is a source title: one line, at most 200 bytes, cut at a
// character boundary.
func plainChatTitle(text string) string {
	line := plainChatLine(text)
	if len(line) <= chatToolSourceTitleLimit {
		return line
	}
	clipped, _ := clipText(line, chatToolSourceTitleLimit)
	return strings.TrimRight(clipped, " ")
}

// plainChatMemory returns a memory entry as tool parts carry it: an ID of
// 1–64 printable bytes and text on one line, at most the memory's limit.
func plainChatMemory(id, text string) (ChatToolMemory, bool) {
	if id == "" || len(id) > memoryIDLimit || !utf8.ValidString(id) || strings.IndexFunc(id, func(r rune) bool { return unicode.IsSpace(r) || unicode.IsControl(r) }) >= 0 {
		return ChatToolMemory{}, false
	}
	text = plainChatLine(text)
	if text == "" {
		return ChatToolMemory{}, false
	}
	if utf8.RuneCountInString(text) > memoryMaxTotalChars {
		text = string([]rune(text)[:memoryMaxTotalChars])
	}
	return ChatToolMemory{ID: id, Text: text}, true
}

// archiveToolResults is what the archive keeps of a tool part's sources and
// memory entry: the sources tool parts may carry (at most 20) and a valid
// entry; nothing is left nil, so a tool without them is stored as before.
func archiveToolResults(results ChatToolResults) ChatToolResults {
	var kept ChatToolResults
	for _, source := range results.Sources {
		if len(kept.Sources) == chatToolSourcesLimit {
			break
		}
		if cleaned, ok := plainChatSource(source.Title, source.URL); ok {
			kept.Sources = append(kept.Sources, cleaned)
		}
	}
	if results.Memory != nil {
		if cleaned, ok := plainChatMemory(results.Memory.ID, results.Memory.Text); ok {
			kept.Memory = &cleaned
		}
	}
	return kept
}

// websearchSources parses the results OpenCode's search returned: Exa's
// results, each a "Title: …" line followed by a "URL: …" line, or a JSON
// object with a results list of {title, url}. At most 20, each address once.
func websearchSources(output string) []ChatToolSource {
	var sources []ChatToolSource
	add := func(title, raw string) bool {
		if source, ok := plainChatSource(title, strings.TrimSpace(raw)); ok {
			for _, known := range sources {
				if known.URL == source.URL {
					return len(sources) < chatToolSourcesLimit
				}
			}
			sources = append(sources, source)
		}
		return len(sources) < chatToolSourcesLimit
	}
	if trimmed := strings.TrimSpace(output); strings.HasPrefix(trimmed, "{") {
		var parsed struct {
			Results []struct {
				Title string `json:"title"`
				URL   string `json:"url"`
			} `json:"results"`
		}
		if json.Unmarshal([]byte(trimmed), &parsed) == nil {
			for _, result := range parsed.Results {
				if !add(result.Title, result.URL) {
					break
				}
			}
			return sources
		}
	}
	lines := strings.Split(output, "\n")
	for index := 1; index < len(lines); index++ {
		address, isURL := strings.CutPrefix(strings.TrimRight(lines[index], "\r"), "URL: ")
		title, isTitle := strings.CutPrefix(strings.TrimRight(lines[index-1], "\r"), "Title: ")
		if !isURL || !isTitle {
			continue
		}
		// A result starts a block: the output's first line, or one after a
		// blank line or the separator.
		if index >= 2 {
			if before := strings.TrimSpace(lines[index-2]); before != "" && before != "---" {
				continue
			}
		}
		if title == "N/A" {
			title = ""
		}
		if !add(title, address) {
			break
		}
	}
	return sources
}
