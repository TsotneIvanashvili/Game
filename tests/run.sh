#!/usr/bin/env sh
# Runs every tests/spec*.luau suite in a standalone Luau VM. See docs/TESTING.md.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for spec in "$ROOT"/tests/spec*.luau; do
	echo "== $(basename "$spec")"
	luaurun "$spec" "$ROOT"
done
