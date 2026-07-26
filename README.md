# koka-packages

Foundational Koka libraries for the Milestone-4 reference service.  Each
directory is a separate package with its own `koka.toml`; they depend on each
other by path.

| package      | what it is                                                        |
| ------------ | ----------------------------------------------------------------- |
| `kktest`     | the test framework: assertions, groups, expected failures, watchdog timeouts, temporary directories, property testing with shrinking |
| `bytes`      | immutable byte sequences, slices, an append builder, integer encoding, hashing |
| `strbuilder` | non-quadratic string building with JSON escaping                  |
| `hashmap`    | a persistent hash map and hash set                                 |
| `resource`   | scoped acquire / use / release, correct under cancellation         |
| `fileio`     | file handles, streaming reads, atomic replace, temporary files, metadata |

Everything above is used by the reference service; nothing here is general
ecosystem work.

## Building and testing

These need the compiler from the sibling `koka` checkout, which provides the
project commands and the `[native]` support they rely on:

```sh
../kk build          # inside a package directory
../kk test
./run-tests.sh       # every package, in dependency order
```

Under the native sanitizers:

```sh
ASAN_OPTIONS=detect_leaks=1 KOKA_TEST_FLAGS=--fasan ./run-tests.sh
```

The whole suite is expected to pass with zero leaks; `kktest` deliberately
exits through `exit(3)` rather than `_exit(2)` so LeakSanitizer's atexit check
actually runs.

## Conventions

**Effect rows.**  Koka only subsumes *closed* effect rows.  A function that
discharges an effect with `try` and then raises it again cannot be written with
a polymorphic tail like `<exn|e>`; such helpers are fixed to `io` (which
already contains `exn`).  Anything that must work under a future cancellation
handler -- `resource/scope`'s core combinators above all -- stays fully
polymorphic and never discharges an effect it re-raises.

**Native resources.**  Every descriptor, buffer and handle is released through
`resource/scope`, so release ordering and cancellation behaviour are decided in
one place.  Raw C pointers are wrapped with a free function so the runtime
reclaims them even on a path that skips the explicit release.

**Reserved words.**  `prefix`, `raw`, `handle` and `use` are Koka keywords and
cannot be used as identifiers.  This bites when translating C-shaped APIs.

**Tests.**  Every package has tests, and every test file is an executable whose
`main` calls `run-tests`.  `koka test` compiles and runs each one and reports a
non-zero exit status *or* an uncaught exception as a failure.
