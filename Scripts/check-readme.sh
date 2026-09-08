#!/bin/bash
# Fails when the counts quoted in the README no longer match reality.
#
# They have drifted twice. A number in a README is a claim, and an unchecked
# claim is one that will be wrong eventually — so this checks it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/Ledge.app}"
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# Only the unit tests. Their count is a property of the code and is the same
# everywhere. The geometry total is not: several of its checks only run when the
# display has room for the case they cover, so it came to 443 on the machine
# this was written on and 441 on a CI runner. Asserting it would fail for a
# reason that says nothing about the code, so the README no longer claims it.
TESTS=$(swift run ledge-tests 2>&1 | strip_ansi | grep -oE '[0-9]+ tests' | grep -oE '[0-9]+' | head -1)
CLAIMED=$(grep -oE '[0-9]+ unit tests' README.md | grep -oE '[0-9]+' | head -1)

if [ "$TESTS" != "$CLAIMED" ]; then
  echo "README says $CLAIMED unit tests; there are $TESTS"
  exit 1
fi
echo "README count matches: $TESTS unit tests"
