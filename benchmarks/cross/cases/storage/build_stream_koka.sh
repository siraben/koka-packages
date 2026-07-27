#!/usr/bin/env bash
set -euo pipefail
python3 generate_fixture.py build/storage_fixture.bin
mkdir -p build
../../../../../kk --release -v0 \
  --builddir=build/koka-stream \
  -i".;../../../../fileio/src;../../../../bytes/src;../../../../resource/src" \
  -o build/stream_koka \
  stream-koka.kk
