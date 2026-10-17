# Paseo inspection — 2026-09-21

Inspected upstream [getpaseo/paseo at 135a3b4c9e49a28b9d16ced8fc0e45b4da9fc502](https://github.com/getpaseo/paseo/tree/135a3b4c9e49a28b9d16ced8fc0e45b4da9fc502). The separate checkout is `.evidence/paseo-inspection-20260921`; no Paseo package was installed, executed, or added to an AgentLand artifact. This is source inspection, not runtime testing or a security audit.

## License and commercial reuse

The pinned [LICENSE](https://github.com/getpaseo/paseo/blob/135a3b4c9e49a28b9d16ced8fc0e45b4da9fc502/LICENSE) puts Paseo's own code under Apache 2.0, with incorporated third-party code retaining its original terms. The upstream [August 27 licensing change](https://github.com/getpaseo/paseo/commit/a8734a972495cf343f628d1017e87775767aade5) explains older AGPL search results and forks.

Apache 2.0 permits commercial and proprietary derivatives. Distribution must retain the license and applicable notices, mark modified files, and preserve any applicable NOTICE. It does not grant use of Paseo's branding. Each selected module and its dependencies still needs its own provenance record; rebranding never transfers authorship of reused work. This license does not establish App Store approval.

The app is Expo/React Native; its Mac wrapper is Electron and its daemon is Node. Copying UI modules would not directly replace SwiftUI views. Backend reuse is legally plausible under the inspected terms, but adopting the whole daemon would be an architectural migration with a different API, auth, storage and update model.

## What is actually similar

Paseo manages coding agents on the user's machine, supports multiple provider CLIs, pairs mobile clients, and can route through an optional encrypted relay. Its [getting-started guide](https://paseo.sh/docs) describes a bundled daemon that starts with the desktop app. The similarity is substantial.

It also has real terminals. The [PTY implementation](https://github.com/getpaseo/paseo/blob/135a3b4c9e49a28b9d16ced8fc0e45b4da9fc502/packages/server/src/terminal/terminal.ts#L930) uses node-pty and a headless terminal emulator. A terminal-first AgentLand must distinguish itself through the actual mobile interaction and continuity, not by claiming Paseo lacks terminal support.

## Useful parts and integration decisions

| Area | Source finding | AgentLand decision |
|---|---|---|
| Desktop service | `packages/desktop/src/daemon/daemon-manager.ts` captures process ownership, has explicit readiness states and bounded stop. | Keep the native Mac controller and bundled runtime; setup, health, saved connection intent and cleanup are being verified against real disposable processes. |
| Terminal identity | `packages/app/src/terminal/runtime/terminal-stream-controller.ts` and client stream router reject events for old subscriptions. | Add cancellation and generation checks after AgentLand terminal polling awaits, including Reload of the same tab. No copied implementation or protocol change is needed. |
| Terminal reconnect | `terminal-session-controller.ts` orders snapshots and replay; `terminal.ts` captures screen, scrollback, cursor and revisions. | Valuable design for full terminal restoration. AgentLand currently has a bounded byte tail, not an emulator snapshot. Do not claim equivalent restoration until a snapshot protocol and real tests exist. |
| Terminal sizing | `terminal-size-ownership.ts` distinguishes an active size claim from a passive update. | Relevant when sharing a terminal across windows/devices. AgentLand currently isolates terminals by paired device and project; don't add a second ownership system without that feature. |
| Burst output | `terminal-output-coalescer.ts` and session-controller slow-consumer logic bound and coalesce delivery. | Measure representative PTY workloads; preserve the existing ordered input path and add bounds where a demonstrated renderer backlog exists. |
| Remote routing | [Connectivity](https://paseo.sh/docs/connectivity) offers direct/VPN paths and explicit relay enrollment. | A candidate for independent remote connectivity; use an owned/self-hosted endpoint, never silently depend on Paseo's hosted service. Direct HTTPS and Tailscale remain usable now. |
| Provider integration | Daemon adapters span several provider protocols. | A useful source for adapter contracts if AgentLand expands beyond OpenCode. Obtain permissive protocol SDKs directly upstream, with pins and notices. |

## Security decisions for any future relay reuse

The separate [official relay](https://github.com/getpaseo/paseo-relay) is an Elixir service with its own Apache 2.0 license. A relay entails a deployed service, monitoring, abuse handling and bandwidth costs; a one-time mobile purchase does not eliminate those costs. Self-hosting can keep routing under the owner's control.

Paseo's transport uses Curve25519/NaCl and treats the pairing offer as a secret. Inspection of `packages/relay/src/crypto.ts` and `encrypted-channel.ts` does not establish the stronger security claims in its website. In particular, authenticated encryption alone does not provide an application replay policy, and fresh keys across sessions do not prove rejection of a repeated frame within one session. The inspected handshake queue can also discard its oldest pending payload when full. Those are review requirements, not findings that we reproduced against Paseo's live service.

AgentLand must keep expiring enrollment, paired-device authorization/revocation, bounded buffers, origin checks and explicit uncertain-delivery handling if it adopts another transport. Never replace these with trust in a relay or retry queued terminal commands silently. Reusing a library is not a security audit.

## Product direction

Preserve the user's established terminal gestures and compact controls while implementing them against AgentLand's own host; the interface itself follows Apple's Human Interface Guidelines. Make workspace selection and pairing short. Keep long-running tools separate from mobile tab/view lifetimes. Assess Paseo-derived capabilities against that experience; feature-count parity with an agent dashboard is not the acceptance test for a mobile terminal workspace.
