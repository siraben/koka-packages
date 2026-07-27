#!/usr/bin/env bash
set -euo pipefail
python3 generate_lookup_db.py build/lookup_fixture.db
mkdir -p build
../../../../../kk --release -v0 \
  --builddir=build/koka-lookup \
  -i".;../../../../sqlite/src;../../../../bytes/src;../../../../resource/src" \
  --cclib=sqlite3 \
  -o build/lookup_koka \
  lookup-koka.kk
