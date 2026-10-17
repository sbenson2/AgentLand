package host

import (
	"net/url"
	"path"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

// Chat names (docs/HOST-API.md "Chat names"). Every chat's title has a
// source: a placeholder nobody chose ("default"), the provider's own title
// ("provider"), the host's free naming from the user's messages ("auto") or
// a name a device wrote ("device"). titleBasis is the newest message the
// title describes.

const (
	titleDefault  = "default"
	titleProvider = "provider"
	titleAuto     = "auto"
	titleDevice   = "device"

	// freeTitleCharacters bounds an auto title, "…" included;
	// deviceTitleCharacters a device's name.
	freeTitleCharacters   = 48
	deviceTitleCharacters = 60
)

// chatName is a chat's title with its source and basis.
type chatName struct {
	Title  string `json:"title"`
	Source string `json:"titleSource"`
	Basis  string `json:"titleBasis,omitempty"`
}

// chatPlaceholderTitles are titles nobody chose, compared ignoring case and
// surrounding white space: an agent's name alone (the host names Claude Code
// and Codex chats created without a title so: "Claude Code" and "Codex",
// and "Claude" and "ChatGPT" for part of 2026-10-12), the host's continue
// title without a source title, and the titles the apps create chats with,
// old and new ("Claude Code chat" and "Codex chat", and "Claude chat" and
// "ChatGPT chat" for part of 2026-10-12; saved chats keep theirs).
var chatPlaceholderTitles = map[string]bool{
	"": true, "opencode": true, "claude": true, "claude code": true, "codex": true, "chatgpt": true, "continued chat": true,
	"new chat": true, "opencode chat": true, "claude code chat": true, "codex chat": true, "claude chat": true, "chatgpt chat": true,
}

// openCodeUntitled is OpenCode 1.18.31's own untitled title
// (Session.isDefaultTitle).
var openCodeUntitled = regexp.MustCompile(`^(New session - |Child session - )\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$`)

func isPlaceholderTitle(title string) bool {
	return openCodeUntitled.MatchString(title) || chatPlaceholderTitles[strings.ToLower(strings.TrimSpace(title))]
}

// titleSourceFor is the source of a title nobody named through AgentLand: a
// placeholder is "default", anything else the provider's or the creator's.
func titleSourceFor(title string) string {
	if isPlaceholderTitle(title) {
		return titleDefault
	}
	return titleProvider
}

// Free naming: the host names a chat from a user message's text.

// chatTitleFillers are words that lead a clause without naming anything,
// longest first so "i want to" wins over nothing shorter.
var chatTitleFillers = [][]string{
	{"i", "would", "like", "to"},
	{"i'd", "like", "to"}, {"i", "want", "to"}, {"we", "need", "to"}, {"i", "need", "to"}, {"you", "need", "to"}, {"go", "ahead", "and"},
	{"can", "you"}, {"could", "you"}, {"would", "you"}, {"will", "you"}, {"let", "us"}, {"make", "sure"},
	{"so"}, {"ok"}, {"okay"}, {"now"}, {"first"}, {"also"}, {"then"}, {"and"}, {"but"}, {"hey"}, {"hi"},
	{"please"}, {"pls"}, {"lets"}, {"let's"}, {"just"}, {"maybe"},
}

// freeChatTitle names a chat from a user message, or returns "" when no
// clause of it qualifies ("yes", "continue", "status?"). The steps are in
// docs/HOST-API.md "Free naming".
func freeChatTitle(text string) string {
	for _, clause := range chatClauses(plainPromptText(text)) {
		words := dropChatFillers(strings.Fields(strings.TrimLeft(clause, "-*#>• \t")))
		long := 0
		for _, word := range words {
			if letterCount(word) >= 3 {
				long++
			}
		}
		if long >= 3 {
			return finishFreeTitle(words)
		}
	}
	return ""
}

// plainPromptText drops fenced code blocks and inline code marks, and
// shortens URLs to their host and file paths to their last component. Line
// breaks stay; other white space becomes single spaces.
func plainPromptText(text string) string {
	text = strings.NewReplacer("\r\n", "\n", "\r", "\n").Replace(text)
	var out strings.Builder
	fence := ""
	for _, line := range strings.Split(text, "\n") {
		trimmed := strings.TrimLeft(line, " \t")
		if fence != "" {
			if strings.HasPrefix(trimmed, fence) {
				fence = ""
			}
			continue
		}
		if strings.HasPrefix(trimmed, "```") || strings.HasPrefix(trimmed, "~~~") {
			fence = trimmed[:3]
			continue
		}
		words := strings.Fields(strings.ReplaceAll(line, "`", ""))
		for index, word := range words {
			words[index] = shortenPromptWord(word)
		}
		out.WriteString(strings.Join(words, " "))
		out.WriteByte('\n')
	}
	return out.String()
}

const (
	promptWordOpeners = `([{<"'“‘«`
	promptWordClosers = `.,;:!?)]}>"'”’»…`
)

var urlScheme = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9+.-]*://`)

// shortenPromptWord replaces a URL with its host name (a file URL with its
// last path component) and a file path with its last component, keeping the
// punctuation around the word.
func shortenPromptWord(word string) string {
	core := strings.TrimLeft(word, promptWordOpeners)
	lead := word[:len(word)-len(core)]
	trimmed := strings.TrimRight(core, promptWordClosers)
	trail := core[len(trimmed):]
	core = trimmed
	switch {
	case urlScheme.MatchString(core) || strings.HasPrefix(strings.ToLower(core), "www."):
		address := core
		if !urlScheme.MatchString(address) {
			address = "https://" + address
		}
		parsed, err := url.Parse(address)
		if err != nil {
			return word
		}
		name := parsed.Hostname()
		if name == "" {
			name = path.Base(strings.TrimRight(parsed.Path, "/"))
			if name == "." || name == "/" {
				name = ""
			}
		}
		core = name
	case isPromptPath(core):
		if last := path.Base(strings.TrimRight(core, "/")); last != "." && last != "/" && last != "" {
			core = last
		}
	}
	if core == "" {
		return strings.TrimSpace(lead + trail)
	}
	return lead + core + trail
}

// isPromptPath reports a word that names a file: it starts with "/", "./",
// "../" or "~/", or it holds a "/" and its last component has an extension.
func isPromptPath(word string) bool {
	if !strings.Contains(word, "/") {
		return false
	}
	for _, prefix := range []string{"/", "./", "../", "~/"} {
		if strings.HasPrefix(word, prefix) {
			return true
		}
	}
	last := word[strings.LastIndex(word, "/")+1:]
	dot := strings.LastIndex(last, ".")
	return dot > 0 && dot < len(last)-1 && strings.IndexFunc(last[dot+1:], unicode.IsLetter) >= 0
}

// chatClauses splits text at sentence ends (". ", "! ", "? ", "… " and at
// the end), line breaks, semicolons and commas.
func chatClauses(text string) []string {
	var clauses []string
	start := 0
	for index, r := range text {
		split := false
		switch r {
		case '\n', ';', ',':
			split = true
		case '.', '!', '?', '…':
			next := index + utf8.RuneLen(r)
			if next == len(text) {
				split = true
			} else {
				following, _ := utf8.DecodeRuneInString(text[next:])
				split = unicode.IsSpace(following)
			}
		}
		if split {
			clauses = append(clauses, text[start:index])
			start = index + utf8.RuneLen(r)
		}
	}
	return append(clauses, text[start:])
}

// dropChatFillers drops filler words from the front of a clause while one
// leads.
func dropChatFillers(words []string) []string {
	for {
		dropped := false
		for _, filler := range chatTitleFillers {
			if len(words) < len(filler) {
				continue
			}
			match := true
			for index, want := range filler {
				if fillerWord(words[index]) != want {
					match = false
					break
				}
			}
			if match {
				words, dropped = words[len(filler):], true
				break
			}
		}
		if !dropped {
			return words
		}
	}
}

// fillerWord is a word as the filler list spells it: lower case, ’ as ',
// without a trailing ":", "-" or dash.
func fillerWord(word string) string {
	word = strings.ToLower(strings.ReplaceAll(word, "’", "'"))
	return strings.TrimRight(word, ":-–—")
}

func letterCount(word string) int {
	count := 0
	for _, r := range word {
		if unicode.IsLetter(r) {
			count++
		}
	}
	return count
}

// finishFreeTitle joins a clause's words, capitalizes its first letter
// unless its first word already has a capital, and cuts it to 48 characters
// at a word boundary with "…".
func finishFreeTitle(words []string) string {
	title := strings.TrimRight(strings.Join(words, " "), " :;,.!?-–—")
	if first := words[0]; strings.IndexFunc(first, unicode.IsUpper) < 0 {
		if r, size := utf8.DecodeRuneInString(title); unicode.IsLower(r) {
			title = string(unicode.ToUpper(r)) + title[size:]
		}
	}
	runes := []rune(title)
	if len(runes) <= freeTitleCharacters {
		return title
	}
	keep := freeTitleCharacters - 1
	if runes[keep] != ' ' {
		boundary := -1
		for index := keep - 1; index > 0; index-- {
			if runes[index] == ' ' {
				boundary = index
				break
			}
		}
		if boundary > 0 {
			keep = boundary
		}
	}
	return strings.TrimRight(string(runes[:keep]), " :;,-–—") + "…"
}

// deviceTitleQuotes are the quotes cleanDeviceTitle removes from around a
// name.
const deviceTitleQuotes = "\"'`“”‘’«»„「」"

// cleanDeviceTitle cleans a name a device wrote: control characters
// dropped, white space collapsed and trimmed, surrounding quotes and a
// trailing period (not the last of an ellipsis) removed, again while any is
// there.
func cleanDeviceTitle(raw string) string {
	title := collapseTitleSpace(raw)
	for {
		before := title
		if runes := []rune(title); len(runes) >= 2 && strings.ContainsRune(deviceTitleQuotes, runes[0]) && strings.ContainsRune(deviceTitleQuotes, runes[len(runes)-1]) {
			title = strings.TrimSpace(string(runes[1 : len(runes)-1]))
		} else if len(runes) == 1 && strings.ContainsRune(deviceTitleQuotes, runes[0]) {
			title = ""
		}
		if strings.HasSuffix(title, ".") && !strings.HasSuffix(title, "..") {
			title = strings.TrimSpace(strings.TrimSuffix(title, "."))
		}
		if title == before {
			return title
		}
	}
}
