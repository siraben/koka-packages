# kktest

The test framework the rest of this tree is tested with: assertions that say
what they expected and what they got, nested groups, expected failures, a
watchdog that bounds a hanging test, temporary directories, property testing
with shrinking, and the timing helpers the benchmarks use.  It is deliberately
*not* a general-purpose testing ecosystem: there is no mocking, no fixtures, no
parallel execution, no coverage tracking, no test discovery of its own (that is
`koka test`'s job, at the file level), and no reporter other than one
deterministic line per case.  It exists so that eleven packages can be tested
the same way, not to compete with anything.

## Public API

### `kktest/runner` — cases, groups, and running them

| declaration | signature | what it is |
| --- | --- | --- |
| `test` | `(name : string, action : () -> io (), expect-fail : bool = False, timeout-s : int = 60) : suite` | One case.  `expect-fail` passes only if the body throws; `timeout-s` arms a watchdog, 0 disables it |
| `group` | `(name : string, items : list<suite>) : suite` | A named subtree; names are joined with `/` |
| `run-tests` | `(items : list<suite>) : io a` | Run everything in order, print a summary, and `exit(0)` or `exit(1)` |
| `flatten` | `(items : list<suite>, path : string = "") : div list<test-case>` | The cases in source order, with their full paths |
| `test-case` | `struct { name; expect-fail; timeout-s; action }` | What `flatten` yields |
| `suite` | `type { Case(case); Group(name, items) }` | A suite is a tree so groups nest in one list literal |

### `kktest/assert` — assertions

| declaration | signature | what it is |
| --- | --- | --- |
| `assert-true` | `(cond : bool, msg : string = "expected True") : exn ()` | |
| `assert-false` | `(cond : bool, msg : string = "expected False") : exn ()` | |
| `assert-equal` | `(actual : a, expected : a, msg : string = "", ?(==), ?show) : exn ()` | Reports both values on failure |
| `assert-not-equal` | `(actual : a, unexpected : a, msg : string = "", ?(==), ?show) : exn ()` | |
| `assert-contains` / `assert-not-contains` | `(actual : string, expected : string, msg : string = "") : exn ()` | String containment with both strings in the failure report |
| `assert-just` | `(actual : maybe<a>, msg : string = "", ?show) : exn a` | Extract the value or fail without inventing a default |
| `assert-nothing` | `(actual : maybe<a>, msg : string = "", ?show) : exn ()` | |
| `assert-less` / `assert-at-most` | `(actual : a, upper : a, msg : string = "", …) : exn ()` | Strict and inclusive upper-bound assertions |
| `assert-throws` | `(action : () -> io a, containing : string = "", msg : string = "…") : io ()` | With `containing`, the message must contain it, so the test cannot pass on the wrong error |
| `assert-ok` | `(action : () -> io a, msg : string = "") : io a` | Fails with the exception's message if `action` throws, and returns its result otherwise |
| `assert-fail` | `(msg : string) : exn a` | Fail directly |
| `is-assertion` | `(e : exception) : bool` | Was this a failed check rather than a crash? |
| `assert-marker` | `: string` | The prefix `is-assertion` looks for |

### `kktest/prop` — property testing

| declaration | signature | what it is |
| --- | --- | --- |
| `check` | `(g : gen<a>, prop : (a) -> io bool, runs : int = 100, seed : int = 0x5EED, max-size : int = 60) : io ()` | Run `prop` on generated values; on failure, shrink and report the shrunk value with the seed.  A property that *throws* is reported as having thrown, with the exception's message |
| `gen` | `struct { generate : (rng, int) -> div (rng, a); shrink : (a) -> list<a>; display : (a) -> string }` | A generator |
| `gen-const` | `(value : a, ?show) : gen<a>` | A fixed edge-case value |
| `gen-map` | `(source : gen<a>, map : a -> b, unmap : b -> a, ?show) : gen<b>` | Transform a generator while retaining source-domain shrinking |
| `map-no-shrink` | `(source : gen<a>, map : a -> b, ?show) : gen<b>` | One-way transform without shrinking |
| `gen-maybe` | `(elem : gen<a>, nothing-every : int = 4) : gen<maybe<a>>` | Optional values, shrinking first to `Nothing` |
| `gen-one-of` | `(first : gen<a>, rest : list<gen<a>> = [], ?show) : gen<a>` | Uniform choice among one or more generators; the type of the call prevents an empty choice set |
| `gen-int` | `(lo : int, hi : int) : gen<int>` | Exactly `[lo, hi]`.  Shrinks towards zero; the size budget does not narrow an explicit range |
| `gen-int` | `(lo : maybe<int> = Nothing, hi : maybe<int> = Nothing) : gen<int>` | A bound left `Nothing` is the size budget's to choose, and grows with the run number |
| `gen-nat` | `(hi : int = 1000000) : gen<int>` | `[0, min(hi, size)]` — unlike `gen-int`, the size budget *does* narrow an explicit bound |
| `gen-bool` | `() : gen<bool>` | |
| `gen-string` | `(alphabet : string = "a…z0…9 ") : gen<string>` | The default alphabet contains nothing that needs escaping |
| `gen-text` | `() : gen<string>` | Quotes, backslashes, control characters, and 2-, 3- and 4-octet UTF-8.  Use this for anything about encoding |
| `gen-list` | `(elem : gen<a>) : gen<list<a>>` | Shrinks by dropping elements first, then by shrinking the head |
| `gen-pair` | `(ga : gen<a>, gb : gen<b>) : gen<(a, b)>` | |

### `kktest/random` — the generator behind `check`

| declaration | signature | what it is |
| --- | --- | --- |
| `rng` | `(seed : int = 0x2545F491) : rng` | splitmix64 state, threaded explicitly so a shrinking run can replay it |
| `next` | `(r : rng) : (rng, int64)` | |
| `next-below` | `(r : rng, bound : int) : (rng, int)` | |
| `next-range` | `(r : rng, lo : int, hi : int) : (rng, int)` | |
| `next-bool` | `(r : rng) : (rng, bool)` | |

### `kktest/sys` and `kktest/tmp` — the OS bits a runner needs

| declaration | signature | what it is |
| --- | --- | --- |
| `exit` | `(code : int) : io a` | Terminate now.  A Koka program otherwise exits 0 even after an uncaught exception |
| `mono-ms` | `() : io int` | Monotonic milliseconds; only differences mean anything |
| `set-watchdog` | `(seconds : int, msg : string) : io ()` | A real alarm, so a hang is bounded.  0 disarms |
| `make-temp-dir` | `(pre : string = "kktest") : io string` | |
| `remove-tree` | `(path : string) : io ()` | Missing paths are not an error |
| `path-exists` | `(path : string) : io bool` | |
| `with-temp-dir` | `(action : (string) -> io a, pre : string = "kktest") : io a` | Fresh directory, removed afterwards either way |
| `with-temp-file` | `(action : (string) -> io a, name : string = "tmp.dat", pre : string = "kktest") : io a` | A path inside a fresh directory; the file itself is not created |

### `kktest/bench` — timing and reporting for the benchmarks

| declaration | signature | what it is |
| --- | --- | --- |
| `measure` | `(label : string, size : int, action : () -> io int, trials : int = 3) : io measurement` | Run `action` `trials` times, keep the fastest |
| `report` | `(title : string, rows : list<measurement>) : io ()` | Print one Markdown table plus the checksum |
| `rate` | `(m : measurement) : string` | Units per second, or `-` when the run was under a millisecond |
| `measurement` | `struct { label; size; ms; check }` | |

## Complexity

| operation | cost |
| --- | --- |
| `run-tests` over `n` cases | O(n), in source order, one process |
| `check` with `r` runs | O(r) generator calls, plus shrinking only on failure |
| shrinking a counterexample | at most 200 steps, each taking the first failing candidate |
| `flatten` over a suite of `n` cases | O(n) |

Measured on this machine (AMD Ryzen 9 5950X, 32 threads, 126 GiB, Linux 7.0.1
x86_64, Koka 3.2.7, `--release`, fastest of 3):

| what | n | ms | units/s |
| --- | ---: | ---: | ---: |
| `splitmix64` `next-below` | 2 000 000 | 401 | 4 987 531 |
| `splitmix64` `next-below` | 8 000 000 | 1 569 | 5 098 789 |
| `check`: n passing runs of a `list<int>` | 2 000 | 6 | 333 333 |
| `check`: n passing runs of a `list<int>` | 8 000 | 26 | 307 692 |
| `check`: n failures found and shrunk | 2 000 | 4 | 500 000 |
| `check`: n failures found and shrunk | 8 000 | 18 | 444 444 |

Both pairs scale linearly in `n`, which is what "`check` costs `runs` generator
calls" means.  The generator is the expensive part: about 5 million
`next-below` calls per second, or roughly 200 ns each, because every step
converts between Koka's arbitrary-precision `:int` and `:int64`.

The failure rows were 5 and 20 ms before shrinking stopped evaluating every
candidate to then use only the first one that failed.

## Worked example

```koka
import kktest/assert
import kktest/runner
import kktest/prop

fun main()
  run-tests([
    group("arithmetic", [
      test("adding is commutative on two examples", fn()
        assert-equal(2 + 3, 3 + 2)
        assert-equal(0 + 7, 7)
      ),
      test("division by zero throws", fn()
        assert-throws(fn() 1 / 0)
      ),
      test("adding is commutative in general", fn()
        check(gen-pair(gen-int(), gen-int()), fn(p) p.fst + p.snd == p.snd + p.fst)
      ),
    ]),
  ])
```

Put that in a file under the package's `test` directory and `koka test` compiles
it, runs it, and reports a non-zero exit status or an uncaught exception as a
failure.

## Limits

* **One process per test file.**  The watchdog is a real alarm and takes the
  whole program with it, so a test that hangs kills its siblings in the same
  file.  The message names the case that was running.
* **No isolation between cases.**  They share a process and any global state
  they touch.  Cases run in the order given, and that order is part of the
  contract, not an implementation detail.
* **Cases run sequentially.**  There is no parallelism and no plan for any.
* **`expect-fail` accepts any exception.**  It does not check *why* the body
  failed.  Use `assert-throws(.., containing = "…")` when that matters.
* **`check`'s `max-size` bounds generated structures, not an explicit range.**
  `gen-int(-500, 500)` really does produce values across that range; only a
  bound left `Nothing` is chosen by the size budget.  The two used to be told
  apart by comparing against the default value, so `gen-int(-1000000, 500)` —
  an explicit range that happened to name the default — was silently clamped,
  and a generator that under-generates has nothing to report it.
* **`gen-nat` is the exception**, and knowingly so: its explicit `hi` *is*
  narrowed by the size budget, so `gen-nat(50)` generates `[0, min(50, size)]`.
  Making it behave like `gen-int` would change what an existing caller in
  another package generates.
* **Shrinking is greedy and depth-bounded** (200 steps).  It takes the first
  simpler candidate that still fails, so it finds a local minimum, not the
  global one.
* **`kktest/random` is not for anything security related.**  splitmix64 is
  chosen because it is short, stateless beyond one word, and reproducible.
* **`mono-ms` has millisecond resolution.**  A benchmark of anything faster
  than that has to repeat the work; `kktest/bench` takes the fastest of several
  runs but cannot invent resolution it does not have.
