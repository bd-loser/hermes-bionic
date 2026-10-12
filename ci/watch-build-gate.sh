#!/usr/bin/env bash
# Run history is durable state and only needs actions:read, unlike variables.
set -euo pipefail
pause() {
  echo 'paused=true' >> "$GITHUB_OUTPUT"
  echo "$*" >> "$GITHUB_STEP_SUMMARY"
}
if ! runs="$(gh run list --repo "$OURS" --workflow build.yml --branch main \
    --limit 1 --json status,conclusion,url)"; then
  pause 'Cannot check build history; no automatic build will be dispatched.'
  exit 0
fi
status="$(jq -r '.[0].status // empty' <<< "$runs")"
conclusion="$(jq -r '.[0].conclusion // empty' <<< "$runs")"
url="$(jq -r '.[0].url // empty' <<< "$runs")"
if [ -n "$status" ] && [ "$status" != completed ]; then
  pause "Build still running: $url. Waiting before dispatching another."
elif [ -n "$status" ] && [ "$conclusion" != success ] && [ "${FORCE:-false}" != true ]; then
  pause "Automatic builds paused after $conclusion: $url. Run build manually after fixing it, or run this watcher with force=true."
fi
