#!/usr/bin/env bash
# Run history is durable state and only needs actions:read, unlike variables.
set -euo pipefail
pause() {
  echo 'paused=true' >> "$GITHUB_OUTPUT"
  echo "$*" >> "$GITHUB_STEP_SUMMARY"
}
# A paused watcher must still tell the truth: exiting 0 here made a failed
# build show up as a green watch-upstream run, hiding the red build behind
# it. The pause stays (no re-dispatch every 12h), but the run goes red with
# an annotation pointing at the build to fix.
fail_paused() {
  pause "$*"
  echo "::error title=Watcher paused after a failed build::$*"
  exit 1
}
if ! runs="$(gh run list --repo "$OURS" --workflow build.yml --branch main \
    --limit 1 --json status,conclusion,url)"; then
  pause 'Cannot check build history; no automatic build will be dispatched.'
  echo "::warning::Cannot check build history; no automatic build will be dispatched."
  exit 0
fi
status="$(jq -r '.[0].status // empty' <<< "$runs")"
conclusion="$(jq -r '.[0].conclusion // empty' <<< "$runs")"
url="$(jq -r '.[0].url // empty' <<< "$runs")"
if [ -n "$status" ] && [ "$status" != completed ]; then
  pause "Build still running: $url. Waiting before dispatching another."
elif [ -n "$status" ] && [ "$conclusion" != success ] && [ "${FORCE:-false}" != true ]; then
  fail_paused "Automatic builds paused after $conclusion: $url. Run build manually after fixing it, or run this watcher with force=true."
elif [ -n "$status" ] && [ "$conclusion" != success ]; then
  # force=true: deliberately leave paused unset so the dispatch steps run.
  echo "::warning::Last build was $conclusion ($url); dispatching anyway because force=true."
fi
