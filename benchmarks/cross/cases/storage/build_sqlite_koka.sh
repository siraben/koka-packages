#!/usr/bin/env bash
set -euo pipefail
mkdir -p build
../../../../../kk --release -v0 \
  --builddir=build/koka-sqlite \
  -i".;../../../../sqlite/src;../../../../bytes/src;../../../../resource/src" \
  --cclib=sqlite3 \
  -o build/sqlite_koka \
  sqlite-koka.kk
