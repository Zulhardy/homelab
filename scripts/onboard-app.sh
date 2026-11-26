#!/usr/bin/env bash
# onboard-app.sh APP -> lets the pipeline deploy apps/APP:
#   Kubernetes: namespace APP, ServiceAccount "deployer" + Role (only inside APP), broker may mint its tokens
#   OpenBao:    kubernetes/roles/APP-deployer -> 10-minute tokens for APP/deployer
# Safe to run again (everything is "apply"/"write").
#
# Needs admin access to both: an admin kubeconfig (KUBECONFIG) and an OpenBao token allowed to write
# kubernetes/roles/* (BAO_TOKEN). Called by the apps pipeline (scripts/ci-apps.sh) and by the bootstrap.
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:?usage: onboard-app.sh APP}"

if ! [[ "${app}" =~ ^[a-z0-9]([-a-z0-9]{0,38}[a-z0-9])?$ ]]; then
  echo "App name '${app}' must be lowercase letters, digits and '-', 1-40 characters (it becomes a namespace)." >&2
  exit 1
fi
case "${app}" in default|openbao|kube-*) echo "'${app}' is a reserved namespace name." >&2; exit 1 ;; esac
[ -d "apps/${app}/k8s" ] || { echo "apps/${app}/k8s not found" >&2; exit 1; }

if kubectl get namespace "${app}" >/dev/null 2>&1 && \
   kubectl -n "${app}" get rolebinding openbao-mint-deployer-token >/dev/null 2>&1 && \
   bao read "kubernetes/roles/${app}-deployer" >/dev/null 2>&1; then
  echo "${app} is already onboarded."
  exit 0
fi

echo "== Onboarding ${app}"
kubectl create namespace "${app}" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "${app}" homelab.zulhardy/app=true --overwrite
sed "s|APP_NAMESPACE|${app}|g" ansible/files/k8s/app-deployer-rbac.yaml.tmpl | kubectl apply -f -

bao write "kubernetes/roles/${app}-deployer" \
  allowed_kubernetes_namespaces="${app}" \
  service_account_name=deployer \
  token_default_ttl=10m \
  token_max_ttl=30m
echo "Onboarded ${app}."
