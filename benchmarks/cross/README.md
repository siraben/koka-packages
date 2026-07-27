# Cross-language package benchmarks

This suite gives the packages the same style of figure as the Koka compiler's
Perceus benchmarks. It measures representative operations in Koka and common
C++, Go, and Python libraries, then normalizes execution time and peak resident
memory to Koka (`1.00x`, lower is better).

![Cross-language results](figures/cross-language.svg)

## Reproduce

```sh
nix shell nixpkgs#gcc nixpkgs#go --command \
  python3 benchmarks/cross/run.py --collect
```

The collector builds every implementation, performs one warmup, runs each
program ten times in rotating language order, and requires every language to
print the same checksum. To regenerate SVG from the committed samples:

```sh
python3 benchmarks/cross/run.py
```

## Method

- Execution time is whole-process wall time, including startup and shutdown.
- Peak RSS is the process's post-`exec` Linux `VmHWM`.
- Each bar is the arithmetic mean of ten runs, normalized to Koka.
- Koka builds with `--release`, C++ with GCC `-O3 -DNDEBUG`, Go with `go build`,
  and Python runs on CPython.
- Generated file and database fixtures are build inputs and are created before
  timing.
- Raw samples, standard deviations, tool versions, commands, and checksums are
  committed in [results.json](results.json).

## Representative operations

| package | operation | equivalent work | languages |
| --- | --- | --- | --- |
| `bytes` | builder | append 80k fixed chunks and finish a fresh value | Koka, C++, Go, Python |
| `bytes` | delimiter search | repeatedly find every delimiter in the same 8 MiB buffer | Koka, C++, Go, Python |
| `strbuilder` | text builder | append 80k fixed strings and finish a fresh value | Koka, C++, Go, Python |
| `hashmap` | insert and lookup | insert integer pairs, then look up every key in reverse | Koka, C++, Go, Python |
| `json` | generation | encode the same compact 2,000-integer array | Koka, Go, Python |
| `json` | parsing | parse the same compact 2,000-integer array | Koka, Go, Python |
| `logging` | level filtering | reject an INFO record with eight fields at ERROR level | Koka, Go, Python |
| `logging` | enabled formatting | render an enabled structured record with eight fields | Koka, Go, Python |
| `http` | parse and render | parse one request and render one response | Koka, Go |
| `runtime` | bounded channel | send and receive the same integer sequence | Koka, Go, Python |
| `sqlite` | prepared inserts | bind and insert rows in one transaction | Koka, Python |
| `sqlite` | indexed lookup | execute bound primary-key lookups through one statement | Koka, Python |
| `fileio` | streaming read | checksum a 64 MiB file in 64 KiB chunks | Koka, C++, Go, Python |
| `fileio` | whole-file read | load and checksum the same 64 MiB file | Koka, C++, Go, Python |
| `resource` | scoped lifetime | acquire, use, and release a file handle per iteration | Koka, C++, Go, Python |

Exact operation contracts and source paths are in the recursive manifests below
`cases/`.
