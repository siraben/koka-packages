#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_file="${1:?expected a C++ source file}"
output_name="${2:?expected an output name}"

mkdir -p "$here/build"
exec g++ -O3 -DNDEBUG -std=c++20 "$here/$source_file" \
  -o "$here/build/$output_name"
