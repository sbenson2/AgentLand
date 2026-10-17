package host

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

// The app-server schema snapshot is the contract fixture for the Codex
// engine. It was generated from the installed Codex without experimental
// API:
//
//	CODEX_HOME=<throwaway> codex app-server generate-json-schema --out testdata/codex/0.156.1/schema
//
// (only the combined bundle is kept). When Codex updates, generate the new
// version beside it and run this test against it.
const codexSchemaFixture = "testdata/codex/0.156.1/schema/codex_app_server_protocol.schemas.json"

type codexSchema struct{ root map[string]any }

func loadCodexSchema(t *testing.T) codexSchema {
	t.Helper()
	data, err := os.ReadFile(codexSchemaFixture)
	if err != nil {
		t.Fatal(err)
	}
	var root map[string]any
	if err := json.Unmarshal(data, &root); err != nil {
		t.Fatal(err)
	}
	return codexSchema{root: root}
}

func (s codexSchema) definition(name string) map[string]any {
	definitions, _ := s.root["definitions"].(map[string]any)
	if strings.HasPrefix(name, "v2/") {
		v2, _ := definitions["v2"].(map[string]any)
		node, _ := v2[strings.TrimPrefix(name, "v2/")].(map[string]any)
		return node
	}
	node, _ := definitions[name].(map[string]any)
	return node
}

// alternatives follows $ref and returns the node with every variant of its
// allOf, anyOf and oneOf.
func (s codexSchema) alternatives(node map[string]any) []map[string]any {
	if node == nil {
		return nil
	}
	if ref, ok := node["$ref"].(string); ok {
		return s.alternatives(s.definition(strings.TrimPrefix(ref, "#/definitions/")))
	}
	result := []map[string]any{node}
	for _, key := range []string{"allOf", "anyOf", "oneOf"} {
		list, _ := node[key].([]any)
		for _, item := range list {
			if child, ok := item.(map[string]any); ok {
				result = append(result, s.alternatives(child)...)
			}
		}
	}
	return result
}

// field finds a property of node (in any variant); "[]" steps into arrays.
func (s codexSchema) field(node map[string]any, path string) (map[string]any, bool) {
	current := []map[string]any{node}
	for _, step := range strings.Split(path, ".") {
		next := []map[string]any{}
		for _, candidate := range current {
			for _, variant := range s.alternatives(candidate) {
				if step == "[]" {
					if items, ok := variant["items"].(map[string]any); ok {
						next = append(next, items)
					}
					continue
				}
				properties, _ := variant["properties"].(map[string]any)
				if value, ok := properties[step]; ok {
					if child, ok := value.(map[string]any); ok {
						next = append(next, child)
					} else {
						next = append(next, map[string]any{})
					}
				}
			}
		}
		if len(next) == 0 {
			return nil, false
		}
		current = next
	}
	return current[0], true
}

// method returns the params schema of a method in a union (ClientRequest,
// ServerNotification, ServerRequest, ClientNotification).
func (s codexSchema) method(union, name string) (map[string]any, bool) {
	for _, variant := range s.alternatives(s.definition(union)) {
		properties, _ := variant["properties"].(map[string]any)
		method, _ := properties["method"].(map[string]any)
		values, _ := method["enum"].([]any)
		if len(values) == 1 && values[0] == name {
			params, _ := properties["params"].(map[string]any)
			if params == nil {
				params = map[string]any{}
			}
			return params, true
		}
	}
	return nil, false
}

// allows reports whether a string value is one of the node's enums or tag
// values.
func (s codexSchema) allows(node map[string]any, value string) bool {
	for _, variant := range s.alternatives(node) {
		if values, ok := variant["enum"].([]any); ok {
			for _, item := range values {
				if item == value {
					return true
				}
			}
		}
		properties, _ := variant["properties"].(map[string]any)
		if tag, ok := properties["type"].(map[string]any); ok {
			if values, ok := tag["enum"].([]any); ok && len(values) == 1 && values[0] == value {
				return true
			}
		}
	}
	return false
}

// itemVariant returns the ThreadItem variant of one type.
func (s codexSchema) itemVariant(kind string) (map[string]any, bool) {
	for _, variant := range s.alternatives(s.definition("v2/ThreadItem")) {
		properties, _ := variant["properties"].(map[string]any)
		tag, _ := properties["type"].(map[string]any)
		if values, ok := tag["enum"].([]any); ok && len(values) == 1 && values[0] == kind {
			return variant, true
		}
	}
	return nil, false
}

// TestCodexSchemaHasWhatTheEngineUses checks every method, field and value
// the Codex engine sends or reads against the snapshot.
func TestCodexSchemaHasWhatTheEngineUses(t *testing.T) {
	schema := loadCodexSchema(t)
	uses := []struct {
		union, method string
		fields        []string
	}{
		{"ClientRequest", "initialize", []string{"clientInfo.name", "clientInfo.title", "clientInfo.version"}},
		{"ClientNotification", "initialized", nil},
		{"ClientRequest", "thread/start", []string{"cwd", "approvalPolicy", "approvalsReviewer", "sandbox", "model"}},
		{"ClientRequest", "thread/resume", []string{"threadId", "excludeTurns", "cwd", "approvalPolicy", "approvalsReviewer", "sandbox", "model"}},
		{"ClientRequest", "thread/fork", []string{"threadId", "lastTurnId", "excludeTurns", "cwd", "approvalPolicy", "approvalsReviewer", "sandbox", "model"}},
		{"ClientRequest", "thread/revert", []string{"threadId", "beforeTurnId"}},
		{"ClientRequest", "thread/unsubscribe", []string{"threadId"}},
		{"ClientRequest", "thread/read", []string{"threadId", "includeTurns"}},
		{"ClientRequest", "turn/start", []string{"threadId", "input", "clientUserMessageId", "model", "effort", "approvalPolicy", "approvalsReviewer", "sandboxPolicy"}},
		{"ClientRequest", "turn/interrupt", []string{"threadId", "turnId"}},
		{"ClientRequest", "turn/steer", []string{"threadId", "expectedTurnId", "input"}},
		{"ClientRequest", "model/list", []string{"cursor"}},
		{"ServerNotification", "turn/started", []string{"threadId", "turn.id"}},
		{"ServerNotification", "turn/completed", []string{"threadId", "turn.id", "turn.status", "turn.error.message", "turn.error.codexErrorInfo"}},
		{"ServerNotification", "item/started", []string{"threadId", "turnId", "item", "startedAtMs"}},
		{"ServerNotification", "item/completed", []string{"threadId", "turnId", "item", "completedAtMs"}},
		{"ServerNotification", "item/agentMessage/delta", []string{"threadId", "turnId", "itemId", "delta"}},
		{"ServerNotification", "item/reasoning/summaryTextDelta", []string{"threadId", "turnId", "itemId", "delta", "summaryIndex"}},
		{"ServerNotification", "item/reasoning/summaryPartAdded", []string{"threadId", "turnId", "itemId", "summaryIndex"}},
		{"ServerNotification", "item/reasoning/textDelta", []string{"threadId", "turnId", "itemId", "delta"}},
		{"ServerNotification", "item/commandExecution/outputDelta", []string{"threadId", "turnId", "itemId", "delta"}},
		{"ServerNotification", "item/fileChange/outputDelta", []string{"threadId", "turnId", "itemId", "delta"}},
		{"ServerNotification", "item/fileChange/patchUpdated", []string{"threadId", "turnId", "itemId", "changes.[].path", "changes.[].kind", "changes.[].diff"}},
		{"ServerNotification", "turn/plan/updated", []string{"threadId", "turnId", "explanation", "plan.[].step", "plan.[].status"}},
		{"ServerNotification", "turn/diff/updated", []string{"threadId", "turnId", "diff"}},
		{"ServerNotification", "thread/status/changed", []string{"threadId", "status"}},
		{"ServerNotification", "thread/tokenUsage/updated", []string{"threadId", "turnId", "tokenUsage.total.inputTokens", "tokenUsage.total.cachedInputTokens", "tokenUsage.total.cacheWriteInputTokens", "tokenUsage.total.outputTokens", "tokenUsage.total.reasoningOutputTokens", "tokenUsage.total.totalTokens", "tokenUsage.last.inputTokens"}},
		{"ServerNotification", "error", []string{"threadId", "turnId", "willRetry", "error.message", "error.codexErrorInfo"}},
		{"ServerNotification", "serverRequest/resolved", []string{"threadId", "requestId"}},
		{"ServerNotification", "item/autoApprovalReview/completed", []string{"threadId", "turnId", "review.status", "review.rationale", "action"}},
		{"ServerNotification", "warning", []string{"threadId", "message"}},
		{"ServerNotification", "thread/closed", []string{"threadId"}},
		{"ServerRequest", "item/commandExecution/requestApproval", []string{"threadId", "turnId", "itemId", "reason", "command", "commandActions.[].command"}},
		{"ServerRequest", "item/fileChange/requestApproval", []string{"threadId", "turnId", "itemId", "reason", "grantRoot"}},
		{"ServerRequest", "item/permissions/requestApproval", []string{"threadId", "turnId", "itemId", "reason", "permissions"}},
		{"ServerRequest", "item/tool/requestUserInput", []string{"threadId", "turnId", "itemId", "questions.[].id", "questions.[].header", "questions.[].question", "questions.[].isOther", "questions.[].isSecret", "questions.[].options.[].label", "questions.[].options.[].description"}},
		{"ServerRequest", "mcpServer/elicitation/request", nil},
	}
	for _, use := range uses {
		params, ok := schema.method(use.union, use.method)
		if !ok {
			t.Errorf("%s %s is not in the snapshot", use.union, use.method)
			continue
		}
		for _, field := range use.fields {
			if _, ok := schema.field(params, field); !ok {
				t.Errorf("%s %s has no %s", use.union, use.method, field)
			}
		}
	}
	responses := []struct {
		definition string
		fields     []string
	}{
		{"InitializeResponse", []string{"userAgent"}},
		{"v2/ThreadStartResponse", []string{"thread.id"}},
		{"v2/ThreadForkResponse", []string{"thread.id", "thread.forkedFromId"}},
		{"v2/ThreadRevertResponse", []string{"thread"}},
		{"v2/TurnStartResponse", []string{"turn.id"}},
		{"v2/ModelListResponse", []string{"data.[].id", "data.[].model", "data.[].displayName", "data.[].hidden", "data.[].defaultReasoningEffort", "data.[].supportedReasoningEfforts.[].reasoningEffort", "nextCursor"}},
		{"CommandExecutionRequestApprovalResponse", []string{"decision"}},
		{"FileChangeRequestApprovalResponse", []string{"decision"}},
		{"PermissionsRequestApprovalResponse", []string{"permissions", "scope"}},
		{"ToolRequestUserInputResponse", []string{"answers"}},
		{"JSONRPCError", []string{"id", "error.code", "error.message"}},
	}
	for _, response := range responses {
		node := schema.definition(response.definition)
		if node == nil {
			t.Errorf("%s is not in the snapshot", response.definition)
			continue
		}
		for _, field := range response.fields {
			if _, ok := schema.field(node, field); !ok {
				t.Errorf("%s has no %s", response.definition, field)
			}
		}
	}
	// Values the engine sends.
	for definition, values := range map[string][]string{
		"v2/SandboxMode":                   {"read-only", "workspace-write", "danger-full-access"},
		"v2/AskForApproval":                {"on-request", "never"},
		"v2/ApprovalsReviewer":             {"user", "auto_review"},
		"v2/SandboxPolicy":                 {"readOnly", "workspaceWrite", "dangerFullAccess"},
		"v2/UserInput":                     {"text", "localImage"},
		"CommandExecutionApprovalDecision": {"accept", "acceptForSession", "decline", "cancel"},
		"FileChangeApprovalDecision":       {"accept", "acceptForSession", "decline"},
		"PermissionGrantScope":             {"turn", "session"},
		"v2/TurnStatus":                    {"completed", "interrupted", "failed"},
		"v2/CommandExecutionStatus":        {"inProgress", "completed", "failed", "declined"},
		"v2/PatchApplyStatus":              {"inProgress", "completed", "failed", "declined"},
		"v2/TurnPlanStepStatus":            {"pending", "inProgress", "completed"},
		"v2/GuardianApprovalReviewStatus":  {"approved", "denied", "timedOut"},
		"v2/CodexErrorInfo":                {"unauthorized", "contextWindowExceeded", "usageLimitExceeded", "cyberPolicy"},
		"v2/PatchChangeKind":               {"add", "delete", "update"},
		"v2/ThreadStatus":                  {"idle", "active", "systemError"},
		"v2/ThreadActiveFlag":              {"waitingOnApproval", "waitingOnUserInput"},
	} {
		node := schema.definition(definition)
		for _, value := range values {
			if !schema.allows(node, value) {
				t.Errorf("%s does not allow %q", definition, value)
			}
		}
	}
	if _, ok := schema.field(schema.definition("v2/UserInput"), "path"); !ok {
		t.Error("UserInput localImage has no path")
	}
	for _, key := range []string{"acceptWithExecpolicyAmendment", "applyNetworkPolicyAmendment"} {
		if _, ok := schema.field(schema.definition("CommandExecutionApprovalDecision"), key); !ok {
			t.Errorf("CommandExecutionApprovalDecision has no %s", key)
		}
	}
	// The thread items the engine shows, with the fields it reads.
	for kind, fields := range map[string][]string{
		"userMessage":         {"id", "clientId", "content"},
		"agentMessage":        {"id", "text", "questions.[].title", "questions.[].options"},
		"plan":                {"id", "text"},
		"reasoning":           {"id", "summary", "content"},
		"commandExecution":    {"id", "command", "commandActions", "aggregatedOutput", "exitCode", "status"},
		"fileChange":          {"id", "changes.[].path", "changes.[].kind", "changes.[].diff", "status"},
		"mcpToolCall":         {"id", "server", "tool", "arguments", "result.content", "error.message", "status"},
		"dynamicToolCall":     {"id", "tool", "namespace", "arguments", "contentItems", "status"},
		"webSearch":           {"id", "query", "action"},
		"imageView":           {"id", "path"},
		"imageGeneration":     {"id", "status", "revisedPrompt", "savedPath"},
		"collabAgentToolCall": {"id", "tool", "prompt", "status"},
		"contextCompaction":   {"id"},
		"enteredReviewMode":   {"id", "review"},
		"exitedReviewMode":    {"id", "review"},
	} {
		variant, ok := schema.itemVariant(kind)
		if !ok {
			t.Errorf("ThreadItem %s is not in the snapshot", kind)
			continue
		}
		for _, field := range fields {
			if _, ok := schema.field(variant, field); !ok {
				t.Errorf("ThreadItem %s has no %s", kind, field)
			}
		}
	}
	// availableDecisions is experimental API in this schema, which the host
	// does not request; Codex 0.156.1 sent it anyway in the contract run. The
	// engine uses it when present and Codex's usual decisions otherwise.
	params, _ := schema.method("ServerRequest", "item/commandExecution/requestApproval")
	if _, ok := schema.field(params, "availableDecisions"); ok {
		t.Log("availableDecisions is now stable API")
	}
	// The checks can fail: thread/rollback was replaced by thread/revert, and
	// turn/start has no such field.
	if _, ok := schema.method("ClientRequest", "thread/rollback"); ok {
		t.Error("thread/rollback is in the snapshot")
	}
	if turnStart, _ := schema.method("ClientRequest", "turn/start"); turnStart != nil {
		if _, ok := schema.field(turnStart, "noSuchField"); ok {
			t.Error("the schema walker accepts any field")
		}
	}
	// Newer runtimes require this capability for general-chat environment isolation.
	if _, ok := schema.field(schema.definition("InitializeCapabilities"), "experimentalApi"); !ok {
		t.Error("InitializeCapabilities has no experimentalApi field")
	}
}
