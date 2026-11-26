#!/usr/bin/env bash
# Builds and pushes the hpa-demo image to GitHub Container Registry (GHCR).
# Called by .github/workflows/hpa-demo-image.yml. Expects GITHUB_TOKEN and GITHUB_ACTOR in the environment;
# the token is GitHub's short-lived per-run token, never a stored secret.
set -euo pipefail
cd "$(dirname "$0")/.."

image="$(scripts/hpa-demo-image-tag.sh)"
echo "Building ${image}"

echo "${GITHUB_TOKEN:?GITHUB_TOKEN not set}" | docker login ghcr.io -u "${GITHUB_ACTOR:?GITHUB_ACTOR not set}" --password-stdin
trap 'docker logout ghcr.io >/dev/null' EXIT

# The tag is the last commit that changed the app. If only manifests or scripts changed, that image
# already exists: reuse it instead of building a different image under the same tag.
if docker manifest inspect "${image}" >/dev/null 2>&1; then
  echo "${image} already exists, not rebuilding."
  exit 0
fi

docker build --platform linux/amd64 -t "${image}" apps/hpa-demo/app
docker push "${image}"
echo "Pushed ${image}"
