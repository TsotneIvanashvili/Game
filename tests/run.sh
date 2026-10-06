#!/usr/bin/env sh
# Runs the pure-logic test suite in a standalone Luau VM. See docs/TESTING.md.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
luaurun "$ROOT/tests/spec.luau" "$ROOT"
