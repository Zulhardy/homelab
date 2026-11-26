#!/usr/bin/env bash
# Builds and pushes the hpa-demo image to GitHub Container Registry (GHCR).
# Called by .github/workflows/hpa-demo-image.yml. Expects GITHUB_TOKEN and GITHUB_ACTOR in the environment;
# the token is GitHub's short-lived per-run token, never a stored secret.
set -euo pipefail
cd "$(dirname "$0")/.."

image="$(scripts/hpa-demo-image-tag.sh)"
echo "Building ${image}"

echo "${GITHUB_TOKEN:?GITHUB_TOKEN not set}" | docker login ghcr.io -u "${GITHUB_ACTOR:?GITHUB_ACTOR not set}" --password-stdin
docker build --platform linux/amd64 -t "${image}" apps/hpa-demo/app
docker push "${image}"
docker logout ghcr.io

echo "Pushed ${image}"
