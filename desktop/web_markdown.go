package host

import (
	"context"
	"html"
	"net/url"
	"strconv"
	"strings"
)

// HTML to Markdown for agentland_fetch: a small tokenizer (the standard
// library has no HTML parser, and the host takes no new dependency for one)
// and a writer for what a model needs from a page: headings, paragraphs,
// lists, links, emphasis, code, quotes and tables. Scripts, styles, forms,
// navigation, hidden elements and the like are left out. The output stops
// growing at limit bytes; fetchToolText cuts it to what the model gets.
//
// A hostile page costs at most linear work: at most htmlTokenLimit tokens are
// kept, with only the attributes the writer reads; end tags find their start
// tag through a count per name, on a stack at most htmlDepthLimit deep; the
// writer only appends to its buffer or cuts its end; and the read's deadline
// is checked every htmlCheckEvery tokens.

const (
	htmlTokenLimit = 100_000
	htmlDepthLimit = 512
	htmlCheckEvery = 1024
)

// htmlAttributes are the attributes the writer reads; the others are
// skipped as the tag is read.
type htmlAttributes struct {
	href, alt, start string
	hidden           bool
}

// htmlToken is a start tag, an end tag or text.
type htmlToken struct {
	kind        byte // 's' start, 'e' end, 't' text
	selfClosing bool
	name        string
	text        string
	attrs       *htmlAttributes // nil when the tag has none the writer reads
}

// htmlRawText are elements whose content is text up to their end tag.
var htmlRawText = map[string]bool{"script": true, "style": true, "textarea": true, "title": true, "xmp": true, "iframe": true, "noembed": true, "noframes": true, "noscript": true, "plaintext": true}

// htmlVoid are elements without an end tag.
var htmlVoid = map[string]bool{"area": true, "base": true, "br": true, "col": true, "embed": true, "hr": true, "img": true, "input": true, "link": true, "meta": true, "param": true, "source": true, "track": true, "wbr": true}

// htmlSkipped are elements left out with everything in them.
var htmlSkipped = map[string]bool{"head": true, "script": true, "style": true, "noscript": true, "template": true, "svg": true, "math": true, "canvas": true,
	"iframe": true, "object": true, "video": true, "audio": true, "map": true, "nav": true, "aside": true, "footer": true, "form": true, "button": true,
	"select": true, "textarea": true, "dialog": true, "menu": true}

// htmlBlocks start and end a paragraph.
var htmlBlocks = map[string]bool{"p": true, "div": true, "section": true, "article": true, "main": true, "header": true, "figure": true, "figcaption": true,
	"address": true, "details": true, "summary": true, "dl": true, "dt": true, "dd": true, "table": true, "center": true, "fieldset": true, "caption": true}

// tokenizeHTML splits a page into tokens (at most maxTokens) and returns its
// <title>, or ctx's error once it ends.
func tokenizeHTML(ctx context.Context, page string, maxTokens int) ([]htmlToken, string, error) {
	// Each "<" starts at most one tag and one text.
	tokens := make([]htmlToken, 0, min(maxTokens, 2*strings.Count(page, "<")+1))
	title := ""
	for index := 0; index < len(page) && len(tokens) < maxTokens; {
		if len(tokens)%htmlCheckEvery == 0 {
			if err := ctx.Err(); err != nil {
				return nil, "", err
			}
		}
		open := strings.IndexByte(page[index:], '<')
		if open < 0 {
			tokens = append(tokens, htmlToken{kind: 't', text: page[index:]})
			break
		}
		if open > 0 {
			tokens = append(tokens, htmlToken{kind: 't', text: page[index : index+open]})
		}
		index += open
		rest := page[index:]
		switch {
		case strings.HasPrefix(rest, "<!--"):
			end := strings.Index(rest[4:], "-->")
			if end < 0 {
				return tokens, title, nil
			}
			index += 4 + end + 3
			continue
		case strings.HasPrefix(rest, "<![CDATA["):
			end := strings.Index(rest, "]]>")
			if end < 0 {
				return tokens, title, nil
			}
			tokens = append(tokens, htmlToken{kind: 't', text: html.EscapeString(rest[9:end])})
			index += end + 3
			continue
		case strings.HasPrefix(rest, "<!") || strings.HasPrefix(rest, "<?"):
			end := strings.IndexByte(rest, '>')
			if end < 0 {
				return tokens, title, nil
			}
			index += end + 1
			continue
		}
		closing := strings.HasPrefix(rest, "</")
		start := 1
		if closing {
			start = 2
		}
		nameEnd := start
		for nameEnd < len(rest) && isHTMLNameByte(rest[nameEnd]) {
			nameEnd++
		}
		if nameEnd == start {
			// A lone "<" is text.
			tokens = append(tokens, htmlToken{kind: 't', text: "<"})
			index++
			continue
		}
		name := strings.ToLower(rest[start:nameEnd])
		attrs, selfClosing, length := parseHTMLAttributes(rest, nameEnd)
		if length < 0 {
			return tokens, title, nil
		}
		index += length
		if closing {
			tokens = append(tokens, htmlToken{kind: 'e', name: name})
			continue
		}
		tokens = append(tokens, htmlToken{kind: 's', name: name, attrs: attrs, selfClosing: selfClosing || htmlVoid[name]})
		if htmlRawText[name] && !selfClosing {
			end := indexFold(page[index:], "</"+name)
			if end < 0 {
				end = len(page) - index
			}
			if name == "title" && title == "" {
				title = html.UnescapeString(page[index : index+end])
			}
			index += end
		}
	}
	return tokens, title, nil
}

func isHTMLNameByte(b byte) bool {
	return b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' || b == '-' || b == ':' || b == '_'
}

// indexFold finds needle, which starts with "<", in text, ignoring ASCII case.
func indexFold(text, needle string) int {
	for index := 0; index+len(needle) <= len(text); {
		next := strings.IndexByte(text[index:], '<')
		if next < 0 {
			return -1
		}
		index += next
		if index+len(needle) <= len(text) && strings.EqualFold(text[index:index+len(needle)], needle) {
			return index
		}
		index++
	}
	return -1
}

func isHTMLSpace(b byte) bool { return b == ' ' || b == '\t' || b == '\n' || b == '\r' || b == '\f' }

// parseHTMLAttributes reads a tag's attributes from position at to its ">"
// and returns those the writer reads (nil for none), whether the tag closes
// itself and the tag's length; -1 when the tag never ends.
func parseHTMLAttributes(tag string, at int) (*htmlAttributes, bool, int) {
	var attrs *htmlAttributes
	keep := func() *htmlAttributes {
		if attrs == nil {
			attrs = &htmlAttributes{}
		}
		return attrs
	}
	seen := map[string]bool(nil)
	selfClosing := false
	for index := at; index < len(tag); {
		switch c := tag[index]; {
		case c == '>':
			return attrs, selfClosing, index + 1
		case c == '/':
			selfClosing = true
			index++
		case isHTMLSpace(c):
			index++
		default:
			selfClosing = false
			nameEnd := index
			for nameEnd < len(tag) && !isHTMLSpace(tag[nameEnd]) && tag[nameEnd] != '/' && tag[nameEnd] != '>' && tag[nameEnd] != '=' {
				nameEnd++
			}
			name := tag[index:nameEnd]
			index = nameEnd
			for index < len(tag) && isHTMLSpace(tag[index]) {
				index++
			}
			value := ""
			if index < len(tag) && tag[index] == '=' {
				index++
				for index < len(tag) && isHTMLSpace(tag[index]) {
					index++
				}
				if index < len(tag) && (tag[index] == '"' || tag[index] == '\'') {
					quote := tag[index]
					end := strings.IndexByte(tag[index+1:], quote)
					if end < 0 {
						return nil, false, -1
					}
					value = tag[index+1 : index+1+end]
					index += end + 2
				} else {
					end := index
					for end < len(tag) && !isHTMLSpace(tag[end]) && tag[end] != '>' {
						end++
					}
					value = tag[index:end]
					index = end
				}
			}
			// The first of a repeated attribute counts; only the writer's
			// attributes are kept.
			lower := strings.ToLower(name)
			switch lower {
			case "href", "alt", "start", "hidden", "aria-hidden":
			default:
				continue
			}
			if seen[lower] {
				continue
			}
			if seen == nil {
				seen = map[string]bool{}
			}
			seen[lower] = true
			switch lower {
			case "href":
				keep().href = html.UnescapeString(value)
			case "alt":
				keep().alt = html.UnescapeString(value)
			case "start":
				keep().start = value
			case "hidden":
				keep().hidden = true
			case "aria-hidden":
				if strings.EqualFold(strings.TrimSpace(value), "true") {
					keep().hidden = true
				}
			}
		}
	}
	return nil, false, -1
}

// markdownWriter builds the Markdown in a buffer that only grows at its end
// or is cut back, up to limit bytes.
type markdownWriter struct {
	out   []byte
	limit int
	pre   int
	// text is len(out) just after the last byte other than ASCII white space.
	text int
}

func (w *markdownWriter) full() bool { return len(w.out) >= w.limit }

func (w *markdownWriter) last() byte {
	if len(w.out) == 0 {
		return '\n'
	}
	return w.out[len(w.out)-1]
}

// newlines ends the output with at least count line breaks (none at the
// start).
func (w *markdownWriter) newlines(count int) {
	if len(w.out) == 0 {
		return
	}
	have := 0
	for have < count && have < len(w.out) && w.out[len(w.out)-1-have] == '\n' {
		have++
	}
	for ; have < count; have++ {
		w.raw("\n")
	}
}

// raw writes text as it is, up to the limit.
func (w *markdownWriter) raw(text string) {
	room := w.limit - len(w.out)
	if room <= 0 {
		return
	}
	clipped, _ := clipText(text, room)
	w.out = append(w.out, clipped...)
	for end := len(clipped); end > 0; end-- {
		if !isMarkdownSpace(clipped[end-1]) {
			w.text = len(w.out) - len(clipped) + end
			break
		}
	}
}

func isMarkdownSpace(b byte) bool {
	return b == ' ' || b == '\t' || b == '\n' || b == '\v' || b == '\f' || b == '\r'
}

// write writes page text: runs of white space as one space, except in pre.
func (w *markdownWriter) write(text string) {
	if w.full() {
		return
	}
	text = html.UnescapeString(text)
	if w.pre > 0 {
		w.raw(text)
		return
	}
	fields := strings.Fields(text)
	if len(fields) == 0 {
		if text != "" && w.last() != ' ' && w.last() != '\n' {
			w.raw(" ")
		}
		return
	}
	if startsWithSpace(text) && w.last() != ' ' && w.last() != '\n' {
		w.raw(" ")
	}
	for index, field := range fields {
		if index > 0 {
			w.raw(" ")
		}
		w.raw(field)
	}
	if endsWithSpace(text) {
		w.raw(" ")
	}
}

func startsWithSpace(text string) bool {
	return text != "" && strings.TrimLeft(text, " \t\n\r\f ") != text
}

func endsWithSpace(text string) bool {
	return text != "" && strings.TrimRight(text, " \t\n\r\f ") != text
}

type markdownList struct {
	ordered bool
	number  int
}

// htmlToMarkdown converts a page and returns its title and Markdown, or
// ctx's error once it ends.
func htmlToMarkdown(ctx context.Context, page string, base *url.URL, limit int) (string, string, error) {
	tokens, title, err := tokenizeHTML(ctx, page, htmlTokenLimit)
	if err != nil {
		return "", "", err
	}
	// Each start tag's matching end tag, so skipped and hidden elements end
	// there; one that never ends is not skipped. An end tag with no open
	// element of its name is ignored at once; one with such an element
	// closes it and every element opened after it, and is marked -1, so
	// emphasis and code end only where they began.
	ends := make([]int32, len(tokens))
	var open []int32
	openByName := map[string]int{}
	for index, token := range tokens {
		switch token.kind {
		case 's':
			if !token.selfClosing && len(open) < htmlDepthLimit {
				open = append(open, int32(index))
				openByName[token.name]++
			}
		case 'e':
			if openByName[token.name] == 0 {
				continue
			}
			for len(open) > 0 {
				top := open[len(open)-1]
				open = open[:len(open)-1]
				openByName[tokens[top].name]--
				if tokens[top].name == token.name {
					ends[top], ends[index] = int32(index), -1
					break
				}
			}
		}
	}
	w := &markdownWriter{limit: limit}
	var lists []markdownList
	// A link's start in the output and the writer's text mark before it.
	type linkState struct {
		start, text int
		href        string
	}
	var links []linkState
	row := 0
	none := &htmlAttributes{}
	for index, steps := 0, 0; index < len(tokens) && !w.full(); index, steps = index+1, steps+1 {
		if steps%htmlCheckEvery == 0 {
			if err := ctx.Err(); err != nil {
				return "", "", err
			}
		}
		token := tokens[index]
		if token.kind == 't' {
			w.write(token.text)
			continue
		}
		name := token.name
		attrs := token.attrs
		if attrs == nil {
			attrs = none
		}
		if token.kind == 's' {
			if end := int(ends[index]); end > index && (htmlSkipped[name] || attrs.hidden) {
				index = end
				continue
			}
			switch {
			case len(name) == 2 && name[0] == 'h' && name[1] >= '1' && name[1] <= '6':
				w.newlines(2)
				w.raw(strings.Repeat("#", int(name[1]-'0')) + " ")
			case htmlBlocks[name]:
				w.newlines(2)
			case name == "br":
				w.raw("\n")
			case name == "hr":
				w.newlines(2)
				w.raw("---")
				w.newlines(2)
			case name == "ul" || name == "ol":
				if len(lists) == 0 {
					w.newlines(2)
				}
				number := 1
				if start, err := strconv.Atoi(attrs.start); err == nil && start >= 0 && start < 1_000_000 {
					number = start
				}
				if len(lists) < htmlDepthLimit {
					lists = append(lists, markdownList{ordered: name == "ol", number: number})
				}
			case name == "li":
				w.newlines(1)
				marker := "- "
				depth := min(max(len(lists), 1), 8)
				if len(lists) > 0 && lists[len(lists)-1].ordered {
					marker = strconv.Itoa(lists[len(lists)-1].number) + ". "
					lists[len(lists)-1].number++
				}
				w.raw(strings.Repeat("  ", depth-1) + marker)
			case name == "pre":
				w.newlines(2)
				w.raw("```\n")
				w.pre++
			case name == "code" && w.pre == 0:
				w.raw("`")
			case name == "strong" || name == "b":
				w.raw("**")
			case name == "em" || name == "i":
				w.raw("*")
			case name == "blockquote":
				w.newlines(2)
				w.raw("> ")
			case name == "tr":
				w.newlines(1)
				row = 0
			case name == "td" || name == "th":
				if row > 0 {
					w.raw(" | ")
				}
				row++
			case name == "img":
				if alt := plainChatLine(attrs.alt); alt != "" {
					w.write(" " + alt + " ")
				}
			case name == "a" && len(links) < htmlDepthLimit:
				// An empty href is the page itself, which the model has.
				href := ""
				if raw := strings.TrimSpace(attrs.href); raw != "" {
					if target, err := base.Parse(raw); err == nil && (target.Scheme == "http" || target.Scheme == "https") && target.User == nil {
						target.Fragment, target.RawFragment = "", ""
						href = target.String()
					}
				}
				links = append(links, linkState{start: len(w.out), text: w.text, href: href})
				if href != "" {
					w.raw("[")
				}
			}
			continue
		}
		switch {
		case len(name) == 2 && name[0] == 'h' && name[1] >= '1' && name[1] <= '6', htmlBlocks[name], name == "blockquote":
			w.newlines(2)
		case name == "ul" || name == "ol":
			if len(lists) > 0 {
				lists = lists[:len(lists)-1]
			}
			if len(lists) == 0 {
				w.newlines(2)
			}
		case name == "pre":
			if w.pre > 0 {
				w.newlines(1)
				w.raw("```")
				w.newlines(2)
				w.pre--
			}
		case name == "code" && w.pre == 0 && ends[index] < 0:
			w.raw("`")
		case (name == "strong" || name == "b") && ends[index] < 0:
			w.raw("**")
		case (name == "em" || name == "i") && ends[index] < 0:
			w.raw("*")
		case name == "a":
			if len(links) == 0 {
				continue
			}
			link := links[len(links)-1]
			links = links[:len(links)-1]
			if link.href == "" || link.start >= len(w.out) {
				continue
			}
			if w.text <= link.start+1 {
				// A link without text is left out: its "[" is cut away.
				w.out, w.text = w.out[:link.start], link.text
				continue
			}
			w.raw("](" + link.href + ")")
		}
	}
	return plainChatLine(title), tidyMarkdown(string(w.out)), nil
}

// tidyMarkdown trims each line's end and keeps at most one blank line in a
// row outside code blocks.
func tidyMarkdown(text string) string {
	var out strings.Builder
	blank := 0
	fenced := false
	for _, line := range strings.Split(text, "\n") {
		if !fenced {
			line = strings.TrimRight(line, " \t")
		}
		if strings.HasPrefix(line, "```") {
			fenced = !fenced
		}
		if strings.TrimSpace(line) == "" && !fenced {
			blank++
			if blank > 1 {
				continue
			}
		} else {
			blank = 0
		}
		out.WriteString(line)
		out.WriteByte('\n')
	}
	return strings.TrimSpace(out.String())
}
