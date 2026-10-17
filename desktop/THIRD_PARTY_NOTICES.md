# AgentLand desktop host dependency notices

This notice applies only to the Go module in this `desktop/` directory. It
records the dependencies pinned by `go.mod` and retains their reproduced
license texts for a future host-binary distribution.

- Go runtime and standard library: [`licenses/Go-LICENSE.txt`](licenses/Go-LICENSE.txt)
- `github.com/gorilla/websocket` v1.5.3: [`licenses/GORILLA-WEBSOCKET-LICENSE.txt`](licenses/GORILLA-WEBSOCKET-LICENSE.txt)
- `golang.org/x/sys` v0.31.0: [`licenses/X-SYS-LICENSE.txt`](licenses/X-SYS-LICENSE.txt)

## Local archive (SQLite)

The local archive uses `modernc.org/sqlite` v1.37.0, a pure-Go translation of
SQLite 3.49.1 built with FTS5. These modules are compiled into
`agentland-host`; the set differs slightly by platform (checked with
`GOOS=… GOARCH=… go list -deps ./cmd/agentland-host` for darwin, linux and
windows on amd64 and arm64):

| Module | Version | License | Text | Compiled for |
|---|---|---|---|---|
| `modernc.org/sqlite` | v1.37.0 | BSD-3-Clause | [`MODERNC-SQLITE-LICENSE.txt`](licenses/MODERNC-SQLITE-LICENSE.txt) | all |
| SQLite, translated inside `modernc.org/sqlite` | 3.49.1 | Public domain | [`SQLITE-LICENSE.txt`](licenses/SQLITE-LICENSE.txt) | all |
| `modernc.org/libc` | v1.62.1 | BSD-3-Clause; contains code translated from musl libc (MIT) and code derived from Go (BSD-3-Clause) | [`MODERNC-LIBC-LICENSE.txt`](licenses/MODERNC-LIBC-LICENSE.txt), [`MODERNC-LIBC-COPYRIGHT-MUSL.txt`](licenses/MODERNC-LIBC-COPYRIGHT-MUSL.txt), [`MODERNC-LIBC-LICENSE-GO.txt`](licenses/MODERNC-LIBC-LICENSE-GO.txt) | all |
| `modernc.org/mathutil` | v1.7.1 | BSD-3-Clause | [`MODERNC-MATHUTIL-LICENSE.txt`](licenses/MODERNC-MATHUTIL-LICENSE.txt) | all |
| `modernc.org/memory` | v1.9.1 | BSD-3-Clause; contains code from mmap-go (BSD-3-Clause) and code derived from Go (BSD-3-Clause) | [`MODERNC-MEMORY-LICENSE.txt`](licenses/MODERNC-MEMORY-LICENSE.txt), [`MODERNC-MEMORY-LICENSE-MMAP-GO.txt`](licenses/MODERNC-MEMORY-LICENSE-MMAP-GO.txt), [`MODERNC-MEMORY-LICENSE-GO.txt`](licenses/MODERNC-MEMORY-LICENSE-GO.txt) | all |
| `github.com/dustin/go-humanize` | v1.0.1 | MIT | [`DUSTIN-GO-HUMANIZE-LICENSE.txt`](licenses/DUSTIN-GO-HUMANIZE-LICENSE.txt) | all |
| `github.com/remyoudompheng/bigfft` | v0.0.0-20230129092748-24d4a6f8daec | BSD-3-Clause | [`REMYOUDOMPHENG-BIGFFT-LICENSE.txt`](licenses/REMYOUDOMPHENG-BIGFFT-LICENSE.txt) | all |
| `golang.org/x/exp` | v0.0.0-20250305212735-054e65f0b394 | BSD-3-Clause | [`X-EXP-LICENSE.txt`](licenses/X-EXP-LICENSE.txt) | all |
| `github.com/google/uuid` | v1.6.0 | BSD-3-Clause | [`GOOGLE-UUID-LICENSE.txt`](licenses/GOOGLE-UUID-LICENSE.txt) | darwin, linux |
| `github.com/mattn/go-isatty` | v0.0.20 | MIT | [`MATTN-GO-ISATTY-LICENSE.txt`](licenses/MATTN-GO-ISATTY-LICENSE.txt) | darwin, windows |
| `github.com/ncruces/go-strftime` | v0.1.9 | MIT | [`NCRUCES-GO-STRFTIME-LICENSE.txt`](licenses/NCRUCES-GO-STRFTIME-LICENSE.txt) | darwin, windows |

`modernc.org/memory` also ships a `LICENSE-LOGO` file that only credits its
project logo image, which is not part of the host.

These modules entered the module graph (`go list -m all`) with
`modernc.org/sqlite` through the tests and tools of the dependencies above.
They are not compiled into `agentland-host`; their texts are kept so every
module in the graph has its notice:

| Module | Version | License | Text |
|---|---|---|---|
| `github.com/google/go-cmp` | v0.6.0 | BSD-3-Clause | [`GOOGLE-GO-CMP-LICENSE.txt`](licenses/GOOGLE-GO-CMP-LICENSE.txt) |
| `github.com/google/pprof` | v0.0.0-20250317173921-a4b03ec1a45e | Apache-2.0 | [`GOOGLE-PPROF-LICENSE.txt`](licenses/GOOGLE-PPROF-LICENSE.txt) |
| `golang.org/x/mod` | v0.24.0 | BSD-3-Clause | [`X-MOD-LICENSE.txt`](licenses/X-MOD-LICENSE.txt) |
| `golang.org/x/sync` | v0.12.0 | BSD-3-Clause | [`X-SYNC-LICENSE.txt`](licenses/X-SYNC-LICENSE.txt) |
| `golang.org/x/tools` | v0.31.0 | BSD-3-Clause | [`X-TOOLS-LICENSE.txt`](licenses/X-TOOLS-LICENSE.txt) |
| `modernc.org/cc/v4` | v4.25.2 | BSD-3-Clause | [`MODERNC-CC-LICENSE.txt`](licenses/MODERNC-CC-LICENSE.txt) |
| `modernc.org/ccgo/v4` | v4.25.1 | BSD-3-Clause | [`MODERNC-CCGO-LICENSE.txt`](licenses/MODERNC-CCGO-LICENSE.txt) |
| `modernc.org/fileutil` | v1.3.0 | BSD-3-Clause | [`MODERNC-FILEUTIL-LICENSE.txt`](licenses/MODERNC-FILEUTIL-LICENSE.txt) |
| `modernc.org/gc/v2` | v2.6.5 | BSD-3-Clause, with the Go license for code derived from Go | [`MODERNC-GC-LICENSE.txt`](licenses/MODERNC-GC-LICENSE.txt) |
| `modernc.org/opt` | v0.1.4 | BSD-3-Clause | [`MODERNC-OPT-LICENSE.txt`](licenses/MODERNC-OPT-LICENSE.txt) |
| `modernc.org/sortutil` | v1.2.1 | BSD-3-Clause | [`MODERNC-SORTUTIL-LICENSE.txt`](licenses/MODERNC-SORTUTIL-LICENSE.txt) |
| `modernc.org/strutil` | v1.2.1 | BSD-3-Clause | [`MODERNC-STRUTIL-LICENSE.txt`](licenses/MODERNC-STRUTIL-LICENSE.txt) |
| `modernc.org/token` | v1.1.0 | BSD-3-Clause | [`MODERNC-TOKEN-LICENSE.txt`](licenses/MODERNC-TOKEN-LICENSE.txt) |

The license files are byte-for-byte copies from each module's source as the Go
toolchain downloaded it through the Go checksum database (`go mod verify`
passes).

The exact original companion notice is preserved in
[`ARCHIVED_THIRD_PARTY_NOTICES.md`](ARCHIVED_THIRD_PARTY_NOTICES.md). PocketCPU
was the prototype the host was first written for; the host's own code is
released under AgentLand's MIT license (see [`README.md`](README.md)). OpenCode
remains a separately installed interoperating service and is not included here.
