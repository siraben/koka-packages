#!/usr/bin/env bash
set -euo pipefail
python3 generate_fixture.py build/storage_fixture.bin
mkdir -p build
g++ -O3 -DNDEBUG -std=c++17 -Wall -Wextra -pedantic \
  scope.cpp -o build/scope_cpp
