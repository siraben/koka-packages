#!/usr/bin/env bash
set -euo pipefail
python3 generate_fixture.py build/storage_fixture.bin
mkdir -p build
../../../../../kk --release -v0 \
  --builddir=build/koka-scope \
  -i".;../../../../fileio/src;../../../../bytes/src;../../../../resource/src" \
  -o build/scope_koka \
  scope-koka.kk
