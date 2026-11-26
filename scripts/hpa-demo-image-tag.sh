#!/usr/bin/env bash
# Prints the image reference for the hpa-demo app: tagged with the last commit that changed apps/hpa-demo/app.
# Used by both the build pipeline and the deploy script, so they always agree on the exact image.
set -euo pipefail
cd "$(dirname "$0")/.."
sha="$(git log -1 --format=%H -- apps/hpa-demo/app)"
if [ -z "$sha" ]; then
  echo "No commit found for apps/hpa-demo/app (is this a full git clone?)" >&2
  exit 1
fi
echo "ghcr.io/zulhardy/hpa-demo:sha-${sha}"
