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

# Every run there already is, before the tag exists.
#
# Matching on the tag alone is not enough: a first attempt that failed leaves a
# completed run whose head branch is this same tag, and in the seconds before
# the new run appears that old one is the only match. It was picked up once,
# watched, and reported as this release's failure — the same mistake this
# script was written to stop, one level down.
BEFORE=$(gh run list --workflow=release.yml --limit 20 --json databaseId --jq '[.[].databaseId] | join(" ")')
seen() { case " $BEFORE " in *" $1 "*) return 0;; *) return 1;; esac; }

git tag -a "$TAG" -m "$MESSAGE"
git push origin "$TAG"
echo "pushed $TAG, waiting for its run…"

RUN=""
for _ in $(seq 1 30); do
  for candidate in $(gh run list --workflow=release.yml --limit 10 \
        --json databaseId,headBranch --jq "map(select(.headBranch == \"$TAG\")) | .[].databaseId"); do
    seen "$candidate" || { RUN="$candidate"; break; }
  done
  [ -n "$RUN" ] && break
  sleep 5
done
[ -n "$RUN" ] || { echo "no new run appeared for $TAG"; exit 1; }

echo "run $RUN is the one for $TAG"
gh run watch "$RUN" --exit-status --interval 20 > /dev/null

# And confirm the artefact exists, rather than trusting a green tick.
ASSETS=$(gh api "repos/$REPO/releases/tags/$TAG" --jq '.assets | length')
[ "$ASSETS" -ge 2 ] || { echo "release $TAG published $ASSETS assets"; exit 1; }
echo "$TAG published with $ASSETS assets: $(gh api "repos/$REPO/releases/tags/$TAG" --jq '.html_url')"
