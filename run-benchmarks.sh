#!/usr/bin/env bash
# Run every package's benchmark.
#
#   ./run-benchmarks.sh                 # all packages
#   ./run-benchmarks.sh bytes hashmap   # named packages only
#   KOKA_BENCH_FLAGS=-v1 ./run-benchmarks.sh
#
# Each package has a `bench/` directory holding a small executable Koka project
# whose `main` prints one Markdown table.  This script builds and runs each of
# them and prints the tables under a header describing the machine, so a table
# pasted into a README says what it was measured on.
#
# Benchmarks are built with `--release` (-O2, no debug info).  `run-tests.sh`
# deliberately does not: tests want the assertions and the faster build, and a
# benchmark of a debug build measures the wrong thing.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KOKA="${KOKA:-$here/../kk}"
FLAGS="${KOKA_BENCH_FLAGS:--v0}"

# Same order as run-tests.sh: dependency order, so a package that fails to
# build is reported before everything that depends on it.
all=(kktest bytes strbuilder hashmap resource fileio json logging runtime sqlite http)

packages=("$@")
[ ${#packages[@]} -eq 0 ] && packages=("${all[@]}")

# ---------------------------------------------------------------------------
# What this was measured on.  A benchmark number without this is not a result.
# ---------------------------------------------------------------------------
cpu="$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo 2>/dev/null | head -1)"
[ -n "$cpu" ] || cpu="$(uname -p 2>/dev/null || echo unknown)"
cores="$(nproc 2>/dev/null || echo '?')"
mem="$(awk '/^MemTotal:/ {printf "%.0f GiB", $2/1048576}' /proc/meminfo 2>/dev/null)"
# `kk` runs the compiler inside `nix develop`, which prints a banner of its own
# first, so pick the line that actually names the compiler rather than the
# first line of output.
kokaver="$("$KOKA" --version 2>/dev/null | grep -m1 -E '^Koka [0-9]')"

echo "# koka-packages benchmarks"
echo
echo "| | |"
echo "| ---------- | ------------------------------------------------ |"
echo "| machine    | ${cpu} (${cores} threads), ${mem:-unknown} RAM |"
echo "| os         | $(uname -s) $(uname -r) $(uname -m) |"
echo "| compiler   | ${kokaver:-unknown} |"
echo "| build      | --release (-O2), fastest of 3 runs per row |"
echo "| date       | $(date -u '+%Y-%m-%d %H:%M UTC') |"

failed=()
for p in "${packages[@]}"; do
  if [ ! -f "$here/$p/bench/koka.toml" ]; then
    echo "no benchmark for package: $p" >&2
    failed+=("$p")
    continue
  fi
  if ( cd "$here/$p/bench" && "$KOKA" run --release $FLAGS ); then :; else failed+=("$p"); fi
done

echo
if [ ${#failed[@]} -eq 0 ]; then
  echo "all benchmarks ran"
else
  printf 'failed: %s\n' "${failed[*]}"
  exit 1
fi
