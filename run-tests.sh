#!/usr/bin/env bash
# Run every package's tests.
#
#   ./run-tests.sh                 # all packages
#   ./run-tests.sh bytes hashmap   # named packages only
#   KOKA_TEST_FLAGS=--fasan ./run-tests.sh    # under the sanitizers
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KOKA="${KOKA:-$here/../kk}"
FLAGS="${KOKA_TEST_FLAGS:-}"

# Dependency order, so a failure is reported at its source rather than in
# everything that depends on it.
all=(kktest bytes strbuilder hashmap resource fileio json logging runtime sqlite http)

packages=("$@")
[ ${#packages[@]} -eq 0 ] && packages=("${all[@]}")

failed=()
for p in "${packages[@]}"; do
  if [ ! -f "$here/$p/koka.toml" ]; then
    echo "no such package: $p" >&2
    failed+=("$p")
    continue
  fi
  printf '\n=========== %s\n' "$p"
  if ( cd "$here/$p" && "$KOKA" test -v0 $FLAGS ); then :; else failed+=("$p"); fi
done

printf '\n===========\n'
if [ ${#failed[@]} -eq 0 ]; then
  echo "all packages passed"
else
  printf 'failed: %s\n' "${failed[*]}"
  exit 1
fi
