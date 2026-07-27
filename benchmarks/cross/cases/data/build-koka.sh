#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
kind="${1:?expected bytes or text}"
source_file="${2:?expected a Koka source file}"
output_name="${3:?expected an output name}"
koka="$here/../../../../../kk"

mkdir -p "$here/build"

case "$kind" in
  bytes)
    includes=(-i"$here/../../../../bytes/src")
    ;;
  hashmap)
    includes=(-i"$here/../../../../hashmap/src")
    ;;
  text)
    includes=(-i"$here/../../../../bytes/src" -i"$here/../../../../strbuilder/src")
    ;;
  *)
    echo "unknown Koka benchmark kind: $kind" >&2
    exit 2
    ;;
esac

exec "$koka" --release -v0 "${includes[@]}" \
  -o "$here/build/$output_name" "$here/$source_file"
