#!/usr/bin/env bash
# onboard-app.sh APP -> lets the devops-projects pipeline deploy APP to DEV and PRD:
#   Kubernetes: namespaces APP-dev and APP-prd, each pinned to its environment's nodes (dev01 / prd01) through
#               the node-selector annotation (enforced by the API server's PodNodeSelector plugin), each with a
#               ServiceAccount "deployer" + Role (only inside that namespace); the OpenBao broker may mint their tokens
#   OpenBao:    kubernetes/roles/dev-APP and prd-APP -> 10-minute tokens for the matching deployer
# Safe to run again (everything is "apply"/"write").
#
# Which apps: the allowed-apps list homelab_apps (ansible/inventory/group_vars/all.yml). The app's code lives in
# zulhardy-lab/devops-projects; nothing of it is needed here.
# Needs admin access to both: an admin kubeconfig (KUBECONFIG) and an OpenBao token allowed to write
# kubernetes/roles/* (BAO_TOKEN). Called by the homelab pipeline (scripts/ci-homelab.sh) and by the bootstrap.
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:?usage: onboard-app.sh APP}"

if ! [[ "${app}" =~ ^[a-z0-9]([-a-z0-9]{0,38}[a-z0-9])?$ ]]; then  # + "-dev"/"-prd" stays a valid namespace
  echo "App name '${app}' must be lowercase letters, digits and '-', 1-40 characters (it becomes a namespace)." >&2
  exit 1
fi
case "${app}" in default|openbao|kube-*) echo "'${app}' is a reserved namespace name." >&2; exit 1 ;; esac

for env in dev prd; do
  ns="${app}-${env}"
  echo "== Onboarding ${app} (${env}, namespace ${ns})"
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace "${ns}" homelab.zulhardy/app="${app}" homelab.zulhardy/env="${env}" --overwrite
  kubectl annotate namespace "${ns}" --overwrite \
    "scheduler.alpha.kubernetes.io/node-selector=node-restriction.kubernetes.io/env=${env}"
  sed "s|APP_NAMESPACE|${ns}|g" ansible/files/k8s/app-deployer-rbac.yaml.tmpl | kubectl apply -f -
  bao write "kubernetes/roles/${env}-${app}" \
    allowed_kubernetes_namespaces="${ns}" \
    service_account_name=deployer \
    token_default_ttl=10m \
    token_max_ttl=30m
done
echo "Onboarded ${app} (dev and prd)."
