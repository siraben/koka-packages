#!/usr/bin/env bash
set -euo pipefail

mkdir -p build
../../../../../../kk --release -v0 \
  --builddir=build/koka-cache \
  -i../../../../../http/src\;../../../../../strbuilder/src\;../../../../../bytes/src \
  -o build/koka \
  koka.kk
