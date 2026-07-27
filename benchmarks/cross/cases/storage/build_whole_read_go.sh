#!/usr/bin/env bash
set -euo pipefail
python3 generate_fixture.py build/storage_fixture.bin
mkdir -p build
go build -trimpath -ldflags=-s -o build/whole_read_go whole_read.go
