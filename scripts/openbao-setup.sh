#!/usr/bin/env bash
# One-time setup, run by a HUMAN on docker01 (needs your admin kubeconfig and OpenBao's root token).
# Safe to run again: every step overwrites the same settings.
#
# What it sets up:
#   Kubernetes: the "openbao-broker" account (+ its token), and hpa-demo's "deployer" account and permissions
#   OpenBao:    - "jwt-github" login: trusts GitHub Actions OIDC tokens from this repo's main branch,
#                 hpa-demo-image.yml workflow only
#               - "kubernetes" engine: mints 10-minute tokens for hpa-demo's deployer account
#               - policy "hpa-demo-deploy": a GitHub login may ask for exactly that, nothing else
#
# The root token is read without echo and never written to disk. At the end the script offers to revoke it.
set -euo pipefail
cd "$(dirname "$0")/.."

# Values the GitHub login is pinned to (from the GitHub API, 2026-11-26).
REPO_ID="1473136403"                    # Zulhardy/homelab; the numeric ID never changes, even if renamed
WORKFLOW_REF="Zulhardy/homelab/.github/workflows/hpa-demo-image.yml@refs/heads/main"
AUDIENCE="openbao-homelab"              # the deploy job asks GitHub for a token with this audience
K8S_API="https://127.0.0.1:6443"        # k3s API on docker01

: "${BAO_ADDR:?BAO_ADDR is not set. Open a new terminal, or run: source /etc/profile.d/openbao.sh}"
command -v bao >/dev/null || { echo "bao not found. Run ansible/playbooks/openbao.yml first." >&2; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl not found. Run ansible/playbooks/k3s.yml first." >&2; exit 1; }

if [ -z "${BAO_TOKEN:-}" ]; then
  read -rsp "OpenBao root token (input hidden): " BAO_TOKEN
  echo
  export BAO_TOKEN
fi
bao token lookup >/dev/null || { echo "That token doesn't work (or OpenBao is sealed: run 'bao status')." >&2; exit 1; }

workdir="$(mktemp -d)"
chmod 700 "${workdir}"
trap 'rm -rf "${workdir}"' EXIT

echo "== Kubernetes: broker account, hpa-demo namespace, deployer account and permissions"
kubectl apply -f ansible/files/k8s/openbao-broker.yaml
kubectl apply -f apps/hpa-demo/k8s/00-namespace.yaml
kubectl apply -f apps/hpa-demo/k8s/05-deploy-rbac.yaml

echo "== Waiting for the broker token"
for _ in $(seq 1 30); do
  if kubectl -n openbao get secret openbao-broker-token -o jsonpath='{.data.token}' 2>/dev/null | grep -q .; then break; fi
  sleep 2
done
kubectl -n openbao get secret openbao-broker-token -o jsonpath='{.data.token}' | base64 -d > "${workdir}/broker.jwt"
kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "${workdir}/ca.crt"
[ -s "${workdir}/broker.jwt" ] && [ -s "${workdir}/ca.crt" ] || { echo "Could not read broker token or cluster CA." >&2; exit 1; }

echo "== OpenBao: kubernetes secrets engine"
bao secrets list -format=json | grep -q '"kubernetes/"' || bao secrets enable -path=kubernetes kubernetes
bao write kubernetes/config \
  kubernetes_host="${K8S_API}" \
  kubernetes_ca_cert=@"${workdir}/ca.crt" \
  service_account_jwt=@"${workdir}/broker.jwt" \
  disable_local_ca_jwt=true
bao write kubernetes/roles/hpa-demo-deployer \
  allowed_kubernetes_namespaces=hpa-demo \
  service_account_name=deployer \
  token_default_ttl=10m \
  token_max_ttl=30m

echo "== OpenBao: policy"
bao policy write hpa-demo-deploy - <<'POLICY'
# A GitHub deploy login may only ask for a short-lived hpa-demo deployer token.
path "kubernetes/creds/hpa-demo-deployer" {
  capabilities = ["update"]
}
POLICY

echo "== OpenBao: GitHub Actions OIDC login"
bao auth list -format=json | grep -q '"jwt-github/"' || bao auth enable -path=jwt-github jwt
bao write auth/jwt-github/config \
  oidc_discovery_url="https://token.actions.githubusercontent.com" \
  bound_issuer="https://token.actions.githubusercontent.com"
bao write auth/jwt-github/role/hpa-demo-deploy - <<ROLE
{
  "role_type": "jwt",
  "user_claim": "sub",
  "bound_audiences": ["${AUDIENCE}"],
  "bound_claims": {
    "repository_id": "${REPO_ID}",
    "ref": "refs/heads/main",
    "event_name": ["push", "workflow_dispatch"],
    "job_workflow_ref": "${WORKFLOW_REF}"
  },
  "token_policies": ["hpa-demo-deploy"],
  "token_ttl": "10m",
  "token_max_ttl": "15m"
}
ROLE

# Kubernetes refuses service-account tokens shorter than 10 minutes.
echo "== Self-test: mint a deployer token and check what it can do"
bao write -format=json kubernetes/creds/hpa-demo-deployer kubernetes_namespace=hpa-demo ttl=10m > "${workdir}/creds.json"
python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["data"]["service_account_token"])' "${workdir}/creds.json" > "${workdir}/deployer.jwt"
# Use an empty kubeconfig so ONLY the deployer token is presented (your admin certificate would otherwise win).
: > "${workdir}/empty-kubeconfig"
k() {
  kubectl --kubeconfig="${workdir}/empty-kubeconfig" --server="${K8S_API}" \
    --certificate-authority="${workdir}/ca.crt" --token="$(cat "${workdir}/deployer.jwt")" "$@"
}
printf '  %-48s %s\n' "can patch deployments in hpa-demo:"   "$(k auth can-i patch deployments -n hpa-demo || true)"
printf '  %-48s %s\n' "can read secrets in hpa-demo:"        "$(k auth can-i get secrets -n hpa-demo || true)"
printf '  %-48s %s\n' "can patch deployments in kube-system:" "$(k auth can-i patch deployments -n kube-system || true)"
printf '  %-48s %s\n' "can create namespaces:"               "$(k auth can-i create namespaces || true)"
echo "  Expected: yes, no, no, no"

echo
echo "Setup done."
read -rp "Revoke the root token now? Recommended once the self-test above shows: yes, no, no, no [y/N] " answer
if [ "${answer}" = "y" ] || [ "${answer}" = "Y" ]; then
  bao token revoke -self
  echo "Root token revoked. You can delete it from your password manager."
  echo "If you ever need admin access again: bao operator generate-root (needs 2 unseal keys)."
else
  echo "Root token NOT revoked. Re-run this script and answer y, once you're happy with the result."
fi
