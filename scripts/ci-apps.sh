#!/usr/bin/env bash
# ci-apps.sh APP -> onboard (if new) and deploy one app. Runs ONLY in GitHub Actions on docker01's runner
# (.github/workflows/apps.yml, deploy job).
#
#   1. Log in to OpenBao with the job's GitHub OIDC token
#   2. Onboard: 10-minute ADMIN Kubernetes token -> scripts/onboard-app.sh (no-op if already onboarded)
#   3. Deploy:  10-minute token for the app's own "deployer" account -> scripts/deploy.sh
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/ci-openbao-login.sh
source scripts/lib/ci-openbao-login.sh
app="${1:?usage: ci-apps.sh APP}"

[ -r /etc/rancher/k3s/server-ca.crt ] || { echo "Missing /etc/rancher/k3s/server-ca.crt (k3s.yml not applied yet)" >&2; exit 1; }

work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/apps.XXXXXX")"
chmod 700 "${work}"
cleanup() { openbao_logout; rm -rf "${work}"; }
trap cleanup EXIT

echo "== 1. OpenBao login"
openbao_login

echo "== 2. Onboard ${app} (admin token, 10 minutes)"
openbao_k8s_token homelab-platform openbao "${work}/admin.jwt"
write_kubeconfig "${work}/admin.kubeconfig" "${work}/admin.jwt" default
KUBECONFIG="${work}/admin.kubeconfig" scripts/onboard-app.sh "${app}"
rm -f "${work}/admin.jwt" "${work}/admin.kubeconfig"

echo "== 3. Deploy ${app} (deployer token, 10 minutes, namespace ${app} only)"
openbao_k8s_token "${app}-deployer" "${app}" "${work}/deployer.jwt"
write_kubeconfig "${work}/deployer.kubeconfig" "${work}/deployer.jwt" "${app}"
KUBECONFIG="${work}/deployer.kubeconfig" scripts/deploy.sh "${app}"
