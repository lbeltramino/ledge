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

# The other thing that drifts: the command grows a verb and the README does not.
# Found by hand once, which is once too often.
LEDGE=".build/debug/ledge"
[ -x "$LEDGE" ] || LEDGE=".build/release/ledge"
if [ -x "$LEDGE" ]; then
  "$LEDGE" | grep -oE '^  ledge [a-z]+ ?[a-z]*' | sed 's/^  ledge //' \
    | awk '{print $1" "$2}' | sort -u > /tmp/ledge-verbs-binary
  grep -oE '`ledge [a-z]+ ?[a-z]*' README.md | sed 's/`ledge //' \
    | awk '{print $1" "$2}' | sort -u > /tmp/ledge-verbs-readme
  if ! diff -q /tmp/ledge-verbs-binary /tmp/ledge-verbs-readme > /dev/null; then
    echo "the README and the ledge command disagree about the verbs:"
    diff /tmp/ledge-verbs-binary /tmp/ledge-verbs-readme || true
    exit 1
  fi
  echo "README lists every verb the command has"
else
  echo "note: the ledge binary is not built, so its verbs were not checked"
fi
