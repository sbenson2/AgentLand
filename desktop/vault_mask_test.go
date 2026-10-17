package host

import (
	"strings"
	"testing"
)

func TestVaultMaskKeepsHashesAndIDs(t *testing.T) {
	for _, kept := range []string{
		"merged 364daa28c0ffee1234567890abcdef0123456789 into main",                 // git SHA-1
		"sha256 3fa9c1e2b7d4aa0e6f4c1b2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a", // SHA-256
		"digest 3FA9C1E2B7D4AA0E6F4C1B2D3E4F5A6B7C8D9E0F",                           // upper-case hex
		"mixed-case hex DeadBeef0123456789ABCDEFabcdef0123456789",
		"session 550e8400-e29b-41d4-a716-446655440000 resumed",
		"request 550E8400-E29B-41D4-A716-446655440000",
		"opencode-session-0123456789abcdefghijklmnop", // lower case and digits only
		"tl_0123456789abcdef0123456789abcdef",
		"/Users/me/Developer/AgentLand/desktop/archive_vault_test.go",
	} {
		if got := maskVaultSecrets(kept); got != kept {
			t.Errorf("masked %q to %q", kept, got)
		}
	}
	// The Always rules hide the same hashes; the vault keeps them readable.
	if sha := "commit 364daa28c0ffee1234567890abcdef0123456789"; maskAlwaysSecrets(sha) == sha {
		t.Fatal("maskAlwaysSecrets no longer masks hex runs; the vault variant is not needed")
	}
}

func TestVaultMaskStillHidesSecrets(t *testing.T) {
	for _, test := range []struct{ text, secret string }{
		{"export GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789", "ghp_"},
		{"password: hunter2", "hunter2"},
		{`API_KEY="plain words here"`, "plain words here"},
		{"curl -H 'Authorization: Bearer abc.def.ghi-jkl'", "abc.def"},
		{"git clone https://me:s3cret@example.com/repo.git", "s3cret"},
		{"mysql --password s3cret-value", "s3cret-value"},
		{"key sk-proj-abcdefghijklmnopqrstuvwx", "sk-proj"},
		{"aws AKIAIOSFODNN7EXAMPLE", "AKIAIOSFODNN7EXAMPLE"},
		{"jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U", "eyJhbGci"},
		{"opaque aB3dE5gH7jK9mN1pQ3rS5tU7vW9xY1zA3bC5", "aB3dE5gH7"},
	} {
		got := maskVaultSecrets(test.text)
		if strings.Contains(got, test.secret) || !strings.Contains(got, "…") {
			t.Errorf("%q masked to %q", test.text, got)
		}
	}
}
