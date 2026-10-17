package host

// plainAttachmentTypes are the attachment types a chat of provider takes:
// photos and UTF-8 text files, and PDFs except for Codex. Chat in the
// workspaces takes every type the host does (workspaceChatProvider).
func plainAttachmentTypes(provider string) []string {
	types := []string{"image/png", "image/jpeg", "image/gif", "image/webp", "text/plain", "text/markdown", "text/csv", "application/json"}
	if provider != "codex" {
		types = append(types, "application/pdf")
	}
	return types
}
