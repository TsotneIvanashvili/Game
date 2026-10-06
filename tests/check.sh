#!/usr/bin/env sh
# Full local verification: compile every file with Luau, lint, format check, unit tests.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0
for f in $(find src tests -name '*.luau'); do
	if ! luaurun tests/compile_check.luau "$f" >/dev/null 2>/tmp/compile_err.txt; then
		echo "COMPILE ERROR: $f"; cat /tmp/compile_err.txt; fail=1
	fi
done
[ "$fail" = 0 ] || exit 1
echo "compile: ok"
selene src tests
stylua --check src tests
tests/run.sh
