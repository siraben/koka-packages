# Package maturity audit

Audit date: 2026-07-27

This audit treats a package as mature when its stated scope has a useful
everyday API, validates dangerous inputs, represents absence and failure
explicitly, manages native resources on every exit path, tests boundary and
failure behaviour, documents complexity and deliberate omissions, and builds
reproducibly from reviewed lockfiles. It does not call an HTTP/1.1 package
immature merely because it is not an HTTP/2 framework, or a persistent map
immature because it is not a mutable table.

## Result

All eleven packages are complete within the scope stated in their README.
The audit added missing domain operations and, more importantly, closed
correctness and lifecycle gaps that could turn configuration mistakes, stale
handles, platform differences, or partial I/O into silent bad behaviour.

| package | audit finding and completed work | verification |
| --- | --- | ---: |
| `kktest` | Added string, option and ordering assertions; constant, mapped, optional and choice generators; brought self-tests under the structured runner and expanded temporary-resource checks. | 25 cases |
| `bytes` | Added suffix/contains/strip operations, multi-byte splitting, strict hex decoding, 64-bit endian codecs and boundary/property coverage. Made the native comparison's non-negative bound explicit so optimized downstream builds are warning-free. | 45 cases |
| `strbuilder` | Added reservation and common append combinators, strict UTF-8 finish, direct byte building, invalid-byte and reuse coverage. | 23 cases |
| `hashmap` | Added `alter`, `pop`, structural folds/traversals, keyed transforms, filtering and complete map/set union/intersection/difference algebra with documented bias. Removed avoidable intermediate-list allocation. | 61 cases |
| `resource` | Added dynamically acquired owned handles, combining scope cleanup with safe early release and use-after-release checks. | 18 cases |
| `fileio` | Removed fixed native path truncation and Linux errno assumptions; validated modes/sizes/permissions; added permission APIs; made atomic replacement apply permissions and sync both file and directory. | 29 cases |
| `json` | Added strict RFC 6901 string-form JSON Pointer lookup and construction, including escape and canonical array-index validation. | 46 cases |
| `logging` | Added composable scoped minimum levels and deterministic field redaction while preserving contextual field ordering. | 15 cases |
| `runtime` | Added direct event-loop tests for request IDs, completions, timers, cancellation, structured errors, listener lifecycle and handle-kind safety. | 38 cases |
| `sqlite` | Removed fixed native database-path truncation; validated timeout/native setup failures; exposed handle state; added nested savepoints and ordered, duplicate/rename-aware migrations. | 32 cases |
| `http` | Added fail-fast server configuration validation and live ephemeral-socket tests for fragmented/pipelined traffic, malformed requests, handler failures and request limits. | 52 cases |

The complete test run is 384 passing cases. Every package also has a
release-mode benchmark executable; all eleven benchmark programs compile and
run after this audit. Test and benchmark scripts use locked dependency
resolution.

## Deliberate boundaries

These are maintained scope decisions, not hidden omissions:

- `bytes` copies slices and uses a naive worst-case subsequence search;
  `strbuilder` is a byte-backed text builder with JSON escaping, not a general
  formatting engine.
- `hashmap` is persistent, iterates by hash, scans collision buckets linearly,
  and rebuilds collection algebra in O(n log n) rather than structurally
  merging trees.
- `resource` cannot use a synchronous `finally` across an async suspension;
  `runtime/task` owns that lifecycle. Very large synchronous scopes retain the
  documented O(k) release stack.
- `fileio` is blocking and POSIX-only. Whole-file reads are bounded. A
  directory-sync failure happens after the atomic rename is already visible,
  so it reports uncertain durability rather than pretending it rolled back.
- `json` is integer-valued and whole-buffered; it has no schema derivation,
  JSONPath, URI-fragment decoding, streaming parser or pretty printer.
- `logging` is synchronous and string-valued, with no rotation or background
  sink. Scoped redaction cannot rewrite destination-owned base fields.
- `runtime` is a cooperative single-threaded IPv4 TCP/DNS runtime. It has no
  detached tasks, UDP or TLS, and its raw completion queue has no explicit cap.
- `sqlite` is synchronous, has no pool or floating-point value type, and leaves
  query paging to callers. Migrations are forward-only and detect version/name
  drift, but do not store SQL checksums.
- `http` intentionally supports bounded, buffered HTTP/1.0 and HTTP/1.1 with
  Content-Length. It has no chunked bodies, streaming response API, TLS,
  HTTP/2, middleware framework, sessions or proxy features.

## Release-engineering decisions

The source and package contracts are mature, but public distribution still
requires repository-owner policy choices:

- Every manifest remains at `0.1.0`; selecting a `1.0.0` compatibility promise
  and release cadence is a maintainer decision.
- The repository has no license file. Only the copyright holder can choose and
  grant a license.
- The build currently relies on the workspace's sibling `kk` wrapper and Koka
  development environment. A hosted CI workflow should be added once the
  maintainer chooses the supported compiler installation channel and native
  platform matrix.

The native-heavy sanitizer command was attempted during the audit, but this
compiler configuration reported that `--fasan` was ignored. Normal file,
SQLite, runtime and HTTP native suites all pass; a sanitizer-enabled compiler
build remains the one verification item that needs an external toolchain
change rather than a package implementation change.
