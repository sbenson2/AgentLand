# iroh-ffi (AgentLand build)

AgentLand builds iroh's Swift bindings itself, from pinned upstream source plus the
patches in `patches/`, instead of using the released IrohLib 1.1.0. The released
package is built on iroh 1.0.2 and cannot turn off iroh's router port mapping, cannot
trust a relay certificate that is not publicly trusted, and aborts the process on
`watchAddr` and on a second `setLogLevel`.

- **Upstream:** https://github.com/n0-computer/iroh-ffi
- **Commit:** `3103bf5295be6d50c5272ff7a426e9b539f3f587` (main, 2026-07-28, "feat(services): add
  preset_iroh_services for authenticated relays (#284)"). It is after v1.1.0 and includes the
  merged but unreleased fixes #280 (`SendStream.stopped` no longer holds the stream lock, which
  deadlocked `writeAll`) and #281 (`watch*` spawn on the endpoint's runtime handle instead of
  panicking with "there is no reactor running").
- **License:** MIT OR Apache-2.0, texts in `licenses/` (copied from that commit).
- **Built by:** `scripts/build-iroh-ffi.sh` (outputs in `shared/AgentLandIroh/Frameworks/`,
  not committed; the generated `shared/AgentLandIroh/Sources/IrohLib/IrohLib.swift` is committed).
- **Record:** `IrohLib.sha256`, the SHA-256 of every file of the built `IrohLib.xcframework`
  (the three static libraries, headers, module maps and `Info.plist`). See "The record" below.

## Patches

Applied in order with `git apply`. Each is a commit made with `git format-patch`.

1. `0001-Build-on-iroh-1.2.0-and-rustls-0.23.45-without-a-por.patch`: iroh, iroh-base and
   iroh-relay 1.2.0 (netwatch 0.19.3, which stops rescanning interfaces on every routing-table
   miss, the idle CPU cost measured with 1.1.0; noq 1.3.0; relay reconnect and drain fixes),
   rustls 0.23.45 and rustls-webpki 0.103.15. No code that asks a router for a port mapping is
   compiled:
   - iroh is built without its default `portmapper` feature (`metrics`, `fast-apple-datapath`
     and `tls-ring` stay), so its port mapper is iroh's no-op stub whatever an endpoint sets.
   - iroh-services and the `services` module (`ServicesClient`, `preset_iroh_services`) are
     removed: iroh-services depends on the `portmapper` crate itself, its network diagnostics
     probe the router with UPnP, PCP and NAT-PMP, its client pushes metrics to
     services.iroh.computer, and through irpc-iroh it turned iroh's default features back on.
   - `iroh-js` leaves the workspace (it depends on iroh with default features; not built here).

   `Cargo.lock` only loses packages (portmapper, igd-next, iroh-services, irpc, the napi
   crates among them). The build script fails if `portmapper` or `igd-next` is in it.
2. `0002-EndpointBuilder-no-panics-and-a-refused-address-keep.patch`: `EndpointBuilder` never
   panics. Upstream's `bind_addr` dropped the builder when iroh refused the address, and every
   later call then panicked (first "EndpointBuilder consumed", then the poisoned mutex); calls
   after `bind()` did too, and a panic through the FFI ends the app. Bind addresses are now
   checked on a scratch builder when set and applied when the builder binds, so a refused
   address leaves the builder as it was. After `bind()`, methods that return a `Result` fail
   ("EndpointBuilder was already used by bind()") and the others (`apply_*`, `alpns`,
   `relay_mode`) do nothing and log a warning: no endpoint can be made from a used builder.
3. `0003-Endpoint-options-relay-TLS-roots-fixed-port-external.patch`: new `EndpointOptions`
   fields and `EndpointBuilder` methods:
   - `relayTlsRoots` (`RelayTlsRoots`, iroh's `Builder::ca_tls_config`), the capability of open
     upstream PR #288 shaped for our use (not tied to the n0 preset, no platform verifier). It was
     made for a relay on the Mac, which the owner's final design dropped; the apps leave it unset
     (n0's relays use the Mozilla roots), and it stays in the patch, with its tests, unused:
     - `.custom(certs:)` (`CaTlsConfig::custom_roots`): only these DER certificates, a private
       CA or the relay's own self-signed certificate. Hostname and validity are still checked.
     - `.embeddedPlus(certs:)` (`CaTlsConfig::embedded().with_extra_roots`): the Mozilla roots
       and these certificates. iroh applies one TLS setting to every relay of an endpoint, so
       this is what lets one endpoint use the Mac's relay and, as the opt-in fallback, n0's.
       The cost: any public CA can then also vouch for the Mac relay's name. Use `.custom`
       while the fallback is off.
     - `.embedded`: iroh's default (Mozilla roots).
     - An empty list, or a certificate that does not parse, fails the bind instead of being
       skipped.
   - `bindPort`: binds `0.0.0.0:<port>` (required) and `[::]:<port>` (when IPv6 is up); refused
     together with another bind address.
   - `externalAddrs` / `EndpointBuilder.externalAddr`: addresses to advertise, such as our own
     router mapping. `Endpoint.addExternalAddr`/`removeExternalAddr` (already upstream) change
     them at runtime.
   - Rust tests for the options and their refusals, and for which certificate chains each
     `RelayTlsRoots` accepts (letsencrypt.org's chain from rustls-platform-verifier 0.7.0's test
     data, checked at a time it was valid, and a private test CA's certificate valid until 2126;
     `testdata/relay-tls/`).
4. `0004-set_log_level-can-be-called-more-than-once.patch`: the first call installs the
   subscriber with a reloadable level; later calls change the level instead of panicking
   through the FFI. If the process already has a global subscriber, the call does nothing.
5. `0005-Endpoint-bind-defaults-to-the-minimal-preset.patch`: `EndpointOptions.preset` left
   unset now means `presetMinimal()` (no relays, no address lookup) instead of `presetN0()`, so
   an endpoint that forgets the preset never uses n0's relays or publishes to n0's DNS. n0 is
   used only when `presetN0()` or a relay mode naming its relays is chosen.
6. `0006-Accepting-connect_with_timeout-a-server-handshake-wi.patch`:
   `Accepting.connectWithTimeout(timeoutMs:)` gives up on a server-side handshake that has not
   completed in time and drops it, which closes the attempt (dropping the last reference to a
   noq connection closes it). A handshake otherwise lasts until it goes idle, and every
   authenticated packet from the peer, Initial packets included, restarts the idle timers, so a
   peer could hold one open as long as it kept sending; Swift cannot cancel `connect()`.
   `IrohPeerGate` uses it for its handshake deadline.
7. `0007-Update-lru-to-0.18.2-for-RUSTSEC-2026-0253.patch`: updates only `lru`
   and its registry checksum in `Cargo.lock`, taking the upstream panic-safety
   fix in `LruCache::pop`. The rest of the dependency graph is unchanged.

`presetMinimal()` itself is unchanged: no relays, no address lookup (no n0 DNS or pkarr),
crypto provider only.

## The record

`IrohLib.sha256` lists every file of `IrohLib.xcframework` with its SHA-256, in `shasum -c`
format. `scripts/verify-iroh-ffi.sh RECORD XCFRAMEWORK` checks a framework against it (the same
files, the same hashes):

- `scripts/build-iroh-ffi.sh` checks every fresh build before it replaces the framework in
  `shared/AgentLandIroh/Frameworks/`, and stops on a mismatch.
- The AgentLandIroh package's `VerifyIrohLib` build tool plugin checks the installed framework
  before the `IrohLib` target compiles, in SwiftPM and in Xcode, and again whenever a file of
  the framework, the record or the script changes. A library the record does not list (built
  before a patch changed, taken from another checkout, or replaced) fails the build before
  anything links it.

The record holds for one toolchain, pinned in `scripts/build-iroh-ffi.sh`: Rust 1.94.1 and
Xcode 26.6 (17F113), whose clang is `Apple clang version 21.0.0 (clang-2100.1.1.101)`. ring and
blake3 compile C and assembly with that clang and the libraries embed its version, so another
Xcode builds other bytes. So the script:

- checks the selected Xcode (`xcode-select -p`, or `DEVELOPER_DIR`) and its clang before it takes
  the lock or builds anything, `--update-record` included, and stops with a message that names
  the pinned and the found versions; `--check-xcode` runs only this check;
- compiles C with that Xcode's clang and SDKs: `CC` is set to it and `SDKROOT` unset, so cc-rs
  passes the Xcode's SDK for every target. (Through `/usr/bin/cc` the macOS slice was compiled
  against the Command Line Tools' SDK, which Software Update replaces on its own.)
- maps the Xcode's path to `/xcode` in the libraries, both as xcrun reports it (the clang and SDK
  paths the compiler gets) and resolved (clang's own headers), so where the pinned Xcode is
  installed does not matter, and turns off xcrun's cache (`xcrun_nocache=1`) so every lookup
  answers for the selected Xcode;
- passes the path flags whole, so the Xcode, the work directory and `CARGO_HOME` may be at paths
  with spaces (`/Applications/Xcode 26.6.app` beside a newer Xcode): cargo gets them as
  `CARGO_ENCODED_RUSTFLAGS` (separated by 0x1f; it splits `RUSTFLAGS` at every space), cc-rs gets
  each `-ffile-prefix-map` in single quotes with `CC_SHELL_ESCAPED_FLAGS=1` (without it, cc-rs
  1.2.67 splits `CFLAGS` at every space and clang got the Xcode's path in pieces);
- sorts the libraries in the xcframework's `Info.plist` by identifier: `xcodebuild
  -create-xcframework` lists them in no fixed order (two builds with the same Xcode gave two).

Builds with the pinned toolchain are byte-identical, with that Xcode at another path too (a
copy under the scratch directory rebuilt the recorded bytes, and so did one named
`Xcode 26.6.app` with a work directory named `work dir`). To move to another Xcode, change
`xcode_version`, `xcode_build` and `xcode_clang` in the script, rebuild with `--update-record`
(it lists the files whose SHA-256 changed) and commit the script and the record together; the
same goes for the upstream pin, a patch or Rust.

## Versions in the patched Cargo.lock

iroh 1.2.0, iroh-base 1.2.0, iroh-relay 1.2.0, iroh-dns 1.3.0, noq 1.3.0, netwatch 0.19.3,
rustls 0.23.45, rustls-webpki 0.103.15, ring 0.17.14, tokio 1.52.3, uniffi 0.31.2,
lru 0.18.2. The build uses Rust 1.94.1 and `--locked`.

### Security advisory disposition — 2026-10-02

The library now pins `lru 0.18.2`, the fix for
[RUSTSEC-2026-0253](https://rustsec.org/advisories/RUSTSEC-2026-0253.html).
The downloaded crate matched the Cargo registry checksum; an exact-version OSV
query returned no advisories. Its earlier 0.18.1 use-after-free requires
`LruCache::pop()` and a key whose `Drop`
panics, followed by continued use of the cache after unwinding. Both consumers
in the patched lockfile were checked:

- `iroh-relay 1.2.0`, `src/key_cache.rs`: `LruCache<PublicKey, ()>` uses
  `get_key_value` and `put`; `PublicKey` derives `Copy` in `iroh-base 1.2.0`,
  so it cannot implement `Drop`.
- `n0-dns-resolver 0.1.0`, `src/resolver/cache.rs`: `LruCache<u64, CacheEntry>`
  uses `get`, `put` and `clear`; its integer keys have no destructor.

Neither consumer calls `pop`, and neither key can meet the panic prerequisite.
The old pinned usage did not meet the advisory's prerequisites. The library
nevertheless takes the upstream fix, with all three Apple slices rebuilt and
their integrity record and notices regenerated together. Reassess advisories
whenever the graph or cache usage changes.
The `atomic-polyfill` and `paste` advisories from the same scan are maintenance
notices. A target-specific `cargo tree --locked --offline -e normal` check found
neither in the normal iOS or macOS dependency graph (`paste` is on netwatch's
Linux path). They are not linked Apple-app vulnerabilities; their lockfile
entries remain for other platforms or build/development dependencies.

## Linked crates and their licenses

`crates.tsv` lists the crates in iroh-ffi's normal dependency graph for Apple targets (from
`cargo metadata`, without proc-macro crates; a superset of what LTO keeps). Most are MIT and/or
Apache-2.0. Others: Unicode-3.0 (ICU crates via `url`/`idna`), BSD-2/3-Clause
(`curve25519-dalek`, `ed25519-dalek`, `subtle`, `arrayref`, `sha1_smol`), ISC (`ring` with
Apache-2.0, `rustls-webpki`, `untrusted`), CDLA-Permissive-2.0 (`webpki-roots`), BSL-1.0 option
(`ryu`), CC0 option (`blake3`) and MPL-2.0 (`uniffi*`; unmodified, source at their upstreams).
The generated `IrohLib.swift` comes from uniffi's templates.

`crate-licenses.txt` lists iroh-ffi and every crate of `crates.tsv` with its license
expression, followed by iroh-ffi's texts (`licenses/`) and every license, copying or notice file
those crates ship, byte for byte (`scripts/collect-iroh-ffi-notices.py`, run after a build: it
reads the patched checkout and the downloaded crates with `cargo metadata --locked --offline`).
The same script writes the same text to `ios/AgentLand/IrohLib-NOTICES.txt`. Both apps link the
library: the Mac bundle's `ThirdPartyNotices` carries `licenses/LICENSE-MIT`,
`licenses/LICENSE-APACHE` and `crate-licenses.txt` (`macos/BuildPhases/third-party-notices.sh`);
the iPhone and iPad app (through `shared/AgentLandRemoteAccess`) carries `IrohLib-NOTICES.txt`
and shows it in Settings → About. Seventeen crates ship no license file. For `iroh-base` and
`iroh-dns`, from the iroh repository, the notices use that repository's LICENSE-APACHE and
LICENSE-MIT, which are `licenses/`' texts byte for byte; for the other fifteen (the uniffi
crates, the objc2 family, `block2`, `dispatch2`, `netwatch`) their license expressions are
listed. Run the script again, and commit both files, whenever `crates.tsv` changes;
`scripts/collect-iroh-ffi-notices.py --check` writes nothing and fails when either is out of
date.

## Updating the pin

1. Clone upstream, check out the new commit, `git am` the patches (fix any that no longer
   apply, then `git format-patch --zero-commit --no-signature --no-stat -o patches <commit>..`
   with a neutral author such as `AgentLand <agentland@localhost>`).
2. Change `upstream_commit` in `scripts/build-iroh-ffi.sh` and the commit above.
3. Run `scripts/build-iroh-ffi.sh --update-record` and `scripts/collect-iroh-ffi-notices.py`,
   commit the regenerated `IrohLib.swift`, `crates.tsv`, `crate-licenses.txt`,
   `ios/AgentLand/IrohLib-NOTICES.txt` and
   `IrohLib.sha256`, and run the package tests (see `shared/AgentLandIroh/README.md`) and the
   Mac's (`macos/README.md`, "Remote access").

The build script holds a lock on its work directory (default
`~/Library/Caches/AgentLand/iroh-ffi`, shared by all checkouts and worktrees) for the whole run,
so two checkouts never build from each other's patched source; a second run waits.

Run iroh-ffi's own Rust tests only under `shared/AgentLandIroh/Tests/router-ports-denied.sb`,
and leave out the three upstream tests that use the n0 preset and dial every local address
(LAN and Tailscale ones included), which also reaches n0's DNS:

```sh
sandbox-exec -f shared/AgentLandIroh/Tests/router-ports-denied.sb cargo test --locked --lib -- \
  --skip test_connect_echo_roundtrip --skip test_uni_stream \
  --skip test_send_stream_stopped_does_not_block_write_all
```

With the port mapper compiled out no test can ask the router for a mapping; the profile
refuses the port-mapping ports anyway.
