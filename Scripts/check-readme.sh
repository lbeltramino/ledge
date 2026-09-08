#!/bin/bash
# Fails when the counts quoted in the README no longer match reality.
#
# They have drifted twice. A number in a README is a claim, and an unchecked
# claim is one that will be wrong eventually — so this checks it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/Ledge.app}"
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

TESTS=$(swift run ledge-tests 2>&1 | strip_ansi | grep -oE '[0-9]+ tests' | grep -oE '[0-9]+' | head -1)
CHECKS=$("$APP/Contents/MacOS/Ledge" --selftest 2>&1 | grep -c '✓')

CLAIMED_TESTS=$(grep -oE '[0-9]+ unit tests' README.md | grep -oE '[0-9]+' | head -1)
CLAIMED_CHECKS=$(grep -oE '[0-9]+ geometry checks' README.md | grep -oE '[0-9]+' | head -1)

fail=0
if [ "$TESTS" != "$CLAIMED_TESTS" ]; then
  echo "README says $CLAIMED_TESTS unit tests; there are $TESTS"
  fail=1
fi
if [ "$CHECKS" != "$CLAIMED_CHECKS" ]; then
  echo "README says $CLAIMED_CHECKS geometry checks; there are $CHECKS"
  fail=1
fi

[ "$fail" = 0 ] && echo "README counts match: $TESTS tests, $CHECKS checks"
exit "$fail"
