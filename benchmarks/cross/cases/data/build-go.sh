#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_file="${1:?expected a Go source file}"
output_name="${2:?expected an output name}"

mkdir -p "$here/build"
exec go build -o "$here/build/$output_name" "$here/$source_file"
