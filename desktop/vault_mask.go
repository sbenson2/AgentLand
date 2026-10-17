package host

import (
	"regexp"
	"strings"
	"unicode"
)

// vaultUUID is a UUID in either case.
var vaultUUID = regexp.MustCompile(`^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$`)

// maskVaultSecrets is maskAlwaysSecrets for vault notes. Named secrets,
// authorization values and well-known token formats are masked by the same
// rules, but a long opaque run is masked only when it mixes upper case,
// lower case and digits and is neither hex nor a UUID, so the commits,
// digests and IDs a chat names stay readable.
func maskVaultSecrets(text string) string {
	for _, rule := range alwaysSecretPatterns {
		text = rule.pattern.ReplaceAllString(text, rule.replace)
	}
	return alwaysOpaque.ReplaceAllStringFunc(text, func(run string) string {
		if vaultHex(run) || vaultUUID.MatchString(run) {
			return run
		}
		upper, lower, digits := false, false, false
		for _, r := range run {
			upper = upper || unicode.IsUpper(r)
			lower = lower || unicode.IsLower(r)
			digits = digits || unicode.IsDigit(r)
		}
		if upper && lower && digits {
			return "…"
		}
		return run
	})
}

func vaultHex(run string) bool {
	return strings.Trim(run, "0123456789abcdefABCDEF") == ""
}
