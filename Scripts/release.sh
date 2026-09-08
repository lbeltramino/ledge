#!/bin/bash
# Cuts a release and waits for the *right* workflow run.
#
# Written after reporting a release as successful by reading the previous tag's
# run: `gh run list` immediately after a push returns whatever finished last,
# which is not the thing you just started. This waits for a run whose head
# branch is this tag, then verifies what actually got published.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:-}"
[ -n "$TAG" ] || { echo "usage: Scripts/release.sh v0.2.5 [message]"; exit 1; }
MESSAGE="${2:-Ledge $TAG}"
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)

git tag -a "$TAG" -m "$MESSAGE"
git push origin "$TAG"
echo "pushed $TAG, waiting for its run…"

RUN=""
for _ in $(seq 1 30); do
  RUN=$(gh run list --workflow=release.yml --limit 10 \
        --json databaseId,headBranch --jq "map(select(.headBranch == \"$TAG\")) | .[0].databaseId // empty")
  [ -n "$RUN" ] && break
  sleep 5
done
[ -n "$RUN" ] || { echo "no run appeared for $TAG"; exit 1; }

echo "run $RUN is the one for $TAG"
gh run watch "$RUN" --exit-status --interval 20 > /dev/null

# And confirm the artefact exists, rather than trusting a green tick.
ASSETS=$(gh api "repos/$REPO/releases/tags/$TAG" --jq '.assets | length')
[ "$ASSETS" -ge 2 ] || { echo "release $TAG published $ASSETS assets"; exit 1; }
echo "$TAG published with $ASSETS assets: $(gh api "repos/$REPO/releases/tags/$TAG" --jq '.html_url')"
