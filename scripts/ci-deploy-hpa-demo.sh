#!/usr/bin/env bash
# Automatic deploy of hpa-demo. Runs ONLY inside the GitHub Actions deploy job, on docker01's runner.
#
#   1. Ask GitHub for a short-lived OIDC identity token (audience "openbao-homelab")
#   2. Log in to OpenBao with it        -> OpenBao session, 10 minutes, can only ask for a deployer token
#   3. Ask OpenBao for a deployer token -> Kubernetes token, 10 minutes, namespace hpa-demo only
#   4. Deploy with scripts/hpa-demo.sh deploy, using a throwaway kubeconfig
#   5. Revoke the OpenBao session; delete the kubeconfig
#
# No credential is stored anywhere: every token is created for this run and expires on its own.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${ACTIONS_ID_TOKEN_REQUEST_URL:?Not running in GitHub Actions with id-token: write}"
: "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:?Not running in GitHub Actions with id-token: write}"

export BAO_ADDR="https://127.0.0.1:8200"
export BAO_CACERT="/etc/openbao/tls-ca.crt"
K8S_API="https://127.0.0.1:6443"
K8S_CA="/etc/rancher/k3s/server-ca.crt"
AUDIENCE="openbao-homelab"

[ -r "${K8S_CA}" ] || { echo "Missing ${K8S_CA}. Re-run ansible/playbooks/k3s.yml on docker01." >&2; exit 1; }

work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/deploy.XXXXXX")"
chmod 700 "${work}"
cleanup() {
  if [ -n "${BAO_TOKEN:-}" ]; then bao token revoke -self >/dev/null 2>&1 || true; fi
  rm -rf "${work}"
}
trap cleanup EXIT

echo "== OpenBao status"
if ! bao status >/dev/null 2>&1; then
  echo "OpenBao is sealed or not running on docker01. Unseal it (bao operator unseal, twice) and re-run this job." >&2
  exit 1
fi

echo "== 1. GitHub OIDC token (audience ${AUDIENCE})"
python3 -I - "${AUDIENCE}" > "${work}/github.jwt" <<'PY'
import json, os, sys, urllib.parse, urllib.request
url = os.environ["ACTIONS_ID_TOKEN_REQUEST_URL"] + "&audience=" + urllib.parse.quote(sys.argv[1])
req = urllib.request.Request(url, headers={"Authorization": "bearer " + os.environ["ACTIONS_ID_TOKEN_REQUEST_TOKEN"]})
with urllib.request.urlopen(req, timeout=30) as r:
    sys.stdout.write(json.load(r)["value"])
PY

echo "== 2. Log in to OpenBao"
BAO_TOKEN="$(bao write -field=token auth/jwt-github/login role=hpa-demo-deploy jwt=- < "${work}/github.jwt")"
export BAO_TOKEN
rm -f "${work}/github.jwt"

echo "== 3. Short-lived Kubernetes token for hpa-demo/deployer"
bao write -field=service_account_token kubernetes/creds/hpa-demo-deployer \
  kubernetes_namespace=hpa-demo ttl=10m > "${work}/k8s.jwt"

cat > "${work}/kubeconfig" <<KCFG
apiVersion: v1
kind: Config
clusters:
  - name: homelab
    cluster:
      server: ${K8S_API}
      certificate-authority: ${K8S_CA}
users:
  - name: deployer
    user:
      tokenFile: ${work}/k8s.jwt
contexts:
  - name: deployer@homelab
    context:
      cluster: homelab
      user: deployer
      namespace: hpa-demo
current-context: deployer@homelab
KCFG
chmod 600 "${work}/kubeconfig" "${work}/k8s.jwt"
export KUBECONFIG="${work}/kubeconfig"

echo "== 4. Deploy"
kubectl auth can-i patch deployments -n hpa-demo >/dev/null
scripts/hpa-demo.sh deploy

echo "== Deployed image"
kubectl -n hpa-demo get deploy hpa-demo -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
