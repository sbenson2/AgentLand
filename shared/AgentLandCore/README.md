# AgentLandCore

Foundation-only mobile protocol core for AgentLand's `/v1` host API. `ios/AgentLand.xcodeproj` and the Mac companion consume this package.

## Provenance

The protocol models and client surface were carried forward from the author's earlier PocketCPU prototype (its `AgentMobileCore` module and protocol notes). Product storage identifiers were newly scoped to `dev.agentland.client` and `agentland.*`; no data migration is provided.

## Security and delivery semantics

`ServerAddress` accepts HTTPS origins only and rejects credentials, queries, and fragments. `URLSessionTransport` uses an ephemeral session and declines redirects, so a bearer credential is not forwarded to a redirect target. It supports normal platform trust or an explicitly paired certificate SHA-256 fingerprint with hostname/validity checks; `PinnedTrustEvaluator` makes that decision for both its session and streaming tasks. Mutating methods surface uncertain delivery and never retry automatically. File writes distinguish revision conflicts from ambiguous delivery.

## Public integration surface

CLI or UI code can create `ServerAddress`, then `APIClient(address:token:)`, and call health, pairing, projects, session/message/interaction, terminal and file methods. `APITransport` is a protocol for production transport composition; the package contains no trust-all or test bypass transport. Workspace persistence scopes tabs/drafts by host/device identity, keeps editor base revisions, and includes backwards-compatible decoding that drops only unreadable tabs. `TerminalProgram` and `AgentProvider` name the terminal programs and chat agents a host offers. Terminal input chunking bounds UTF-8 messages and paste size.

The archive routes (`ArchiveWire.swift`, docs/HOST-API.md "Archive") are `archiveChanges`, `archiveChat`, `archiveSearch`, `archiveExport`, `archiveTerminalLogs`, `archiveTerminalLog` and `archiveDelete`, with `CapabilitiesResponse.archive` saying which of them a host offers. A change the client cannot read decodes as `.unreadable` rather than failing its page; `archiveDelete` reports `.deleted` only when the host confirms and never retries. `ChatContinueRequest` carries `throughMessageID` (for hosts listing `continueThrough`) and `contextChars`, each sent only when set.

The preview routes (`PreviewWire.swift`, docs/HOST-API.md "Preview (browser tab)") are `previewPorts`, `createPreviewSession`, `previewSessions` and `revokePreviewSession`; a `PreviewSessionGrant`'s secret never appears in its descriptions, and `httpCookie(for:)` makes the host-only, Secure, HttpOnly, SameSite=Strict cookie for the preview origin (`ServerAddress.previewOrigin(port:)`). `APIClient.serverTrust` is the paired certificate check, which the browser applies to the preview origin only. `CapabilitiesResponse.preview` is nil on hosts without it, or with an entry this version cannot read; a `schedules` entry from a host older than 2026-10-06 is ignored (schedules were removed).
