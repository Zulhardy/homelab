#!/usr/bin/env bash
# deploy.sh APP -> applies apps/APP/k8s/NN-*.yaml (numbered files only, in order) to namespace APP,
# then waits until every Deployment and StatefulSet in it is healthy.
#
# Works with any kubeconfig: yours (admin) or the pipeline's 10-minute deployer token.
# Placeholders replaced in the manifests:
#   APP_IMAGE          -> image built for this commit (or the APP_IMAGE environment variable, if set)
#   APP_INGRESS_HOST   -> ${APP_INGRESS_HOST:-APP.192.168.0.102.nip.io}
# Optional: SKIP_INGRESS=1 skips files with "ingress" in their name.
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:?usage: deploy.sh APP}"
dir="apps/${app}/k8s"
[ -d "${dir}" ] || { echo "${dir} not found" >&2; exit 1; }

image="${APP_IMAGE:-}"
if [ -z "${image}" ] && [ -f "apps/${app}/app/Dockerfile" ]; then
  image="$(scripts/image-tag.sh "${app}")"
fi
host="${APP_INGRESS_HOST:-${app}.192.168.0.102.nip.io}"

# Admins (you, onboarding) may create the namespace; the pipeline's deployer can't, by design.
if kubectl auth can-i create namespaces >/dev/null 2>&1; then
  kubectl create namespace "${app}" --dry-run=client -o yaml | kubectl apply -f -
fi

shopt -s nullglob
files=("${dir}"/[0-9][0-9]-*.yaml)
[ "${#files[@]}" -gt 0 ] || { echo "No numbered manifests (NN-name.yaml) in ${dir}" >&2; exit 1; }

echo "Deploying ${app}${image:+ with ${image}}"
for f in "${files[@]}"; do
  case "${f}" in *ingress*) if [ "${SKIP_INGRESS:-0}" = "1" ]; then echo "skip ${f}"; continue; fi ;; esac
  sed -e "s|APP_IMAGE|${image}|g" -e "s|APP_INGRESS_HOST|${host}|g" "${f}" | kubectl apply -n "${app}" -f -
done

for kind in deployment statefulset; do
  for obj in $(kubectl -n "${app}" get "${kind}" -o name 2>/dev/null); do
    kubectl -n "${app}" rollout status "${obj}" --timeout=180s
  done
done
echo "Deployed ${app}."
