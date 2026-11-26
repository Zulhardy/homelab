#!/usr/bin/env bash
# ONE-TIME bootstrap, run by a HUMAN on docker01 as your normal user (not with sudo).
# After this, the only manual step in the homelab is reviewing and merging pull requests.
#
# It asks for: your sudo password, and 2 of your 3 OpenBao unseal/recovery keys. Nothing is written to disk
# except a sudo password file in a private temp folder that is deleted on exit.
#
#  1. openbao.yml   : auto-unseal key file + root-only admin socket (OpenBao restarts, migration pending)
#  2. migrate       : switch OpenBao from unseal keys to auto-unseal (your keys become recovery keys)
#  3. root token    : temporary, created over the admin socket from 2 recovery keys; revoked at the end
#  4. k3s.yml       : publishes the cluster CA certificate for the pipeline
#  5. Kubernetes    : broker + pipeline admin account (cluster-admin, used only through 10-minute tokens)
#  6. OpenBao       : SSH certificate authority, Kubernetes roles, policy, GitHub OIDC login for the pipelines
#  7. automation    : "automation" user on both VMs, sshd trusts OpenBao-signed certificates
#  8. apps          : onboards every existing apps/*/
#  9. self-tests    : SSH as automation with a fresh certificate; deployer and admin token permissions
# 10. root token revoked
# Safe to run again.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO_ID="1473136403"   # Zulhardy/homelab, from the GitHub API (never changes, even if renamed)
WF_PREFIX="Zulhardy/homelab/.github/workflows"
SOCK="/run/openbao/admin.sock"

[ "$(id -u)" -ne 0 ] || { echo "Run this as your normal user, not with sudo." >&2; exit 1; }
for c in bao kubectl ansible-playbook python3 ssh ssh-keygen sudo.ws; do
  command -v "${c}" >/dev/null || { echo "Missing command: ${c}" >&2; exit 1; }
done
# shellcheck source=/dev/null
[ -n "${BAO_ADDR:-}" ] || source /etc/profile.d/openbao.sh
kubectl auth can-i '*' '*' --all-namespaces >/dev/null 2>&1 || { echo "Your kubectl isn't cluster admin (check ~/.kube/config)." >&2; exit 1; }

work="$(mktemp -d)"
chmod 700 "${work}"
cleanup() {
  if [ -n "${BAO_TOKEN:-}" ]; then
    bao token revoke -self >/dev/null 2>&1 && echo "== Temporary root token revoked."
  fi
  rm -rf "${work}"
}
trap cleanup EXIT

read -rsp "Your sudo password (hidden): " sudo_pw; echo
printf '%s' "${sudo_pw}" > "${work}/become"
printf '%s\n' "${sudo_pw}" | sudo.ws -S -p '' -v
unset sudo_pw
read -rsp "OpenBao unseal/recovery key 1 (hidden): " k1; echo
read -rsp "OpenBao unseal/recovery key 2 (hidden): " k2; echo
keys_json="$(python3 -I -c 'import json,sys; print(json.dumps({"keys": sys.argv[1:]}))' "${k1}" "${k2}")"
unset k1 k2

ap() { ( cd ansible && ansible-playbook -i inventory/hosts.ini "playbooks/$1" --become-password-file "${work}/become" ); }

echo "== 1. OpenBao: auto-unseal key + admin socket"
ap openbao.yml

echo "== 2. Migrate to auto-unseal (no-op if already done)"
for _ in $(seq 1 20); do sudo.ws test -S "${SOCK}" && break; sleep 1; done
printf '%s' "${keys_json}" | sudo.ws python3 -I scripts/lib/bao-admin-socket.py "${SOCK}" migrate
bao status >/dev/null || { echo "OpenBao is still sealed." >&2; exit 1; }

echo "== 3. Temporary root token"
BAO_TOKEN="$(printf '%s' "${keys_json}" | sudo.ws python3 -I scripts/lib/bao-admin-socket.py "${SOCK}" generate-root)"
export BAO_TOKEN
unset keys_json
bao token lookup >/dev/null

echo "== 4. k3s: publish the cluster CA certificate"
ap k3s.yml

echo "== 5. Kubernetes: broker and pipeline admin accounts"
kubectl apply -f ansible/files/k8s/openbao-broker.yaml
for _ in $(seq 1 30); do
  kubectl -n openbao get secret openbao-broker-token -o jsonpath='{.data.token}' 2>/dev/null | grep -q . && break
  sleep 2
done
( umask 077
  kubectl -n openbao get secret openbao-broker-token -o jsonpath='{.data.token}' | base64 -d > "${work}/broker.jwt"
  kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "${work}/ca.crt" )

echo "== 6. OpenBao: engines, roles, policy, GitHub login"
bao secrets list -format=json | grep -q '"kubernetes/"' || bao secrets enable -path=kubernetes kubernetes
bao write kubernetes/config kubernetes_host="https://127.0.0.1:6443" \
  kubernetes_ca_cert=@"${work}/ca.crt" service_account_jwt=@"${work}/broker.jwt" disable_local_ca_jwt=true
bao write kubernetes/roles/homelab-platform allowed_kubernetes_namespaces=openbao \
  service_account_name=homelab-platform token_default_ttl=10m token_max_ttl=30m

bao secrets list -format=json | grep -q '"ssh-client-signer/"' || bao secrets enable -path=ssh-client-signer ssh
if ! bao read ssh-client-signer/config/ca >/dev/null 2>&1; then
  bao write ssh-client-signer/config/ca generate_signing_key=true key_type=ed25519
fi
bao write ssh-client-signer/roles/automation - <<'ROLE'
{
  "key_type": "ca",
  "allow_user_certificates": true,
  "allowed_users": "automation",
  "default_user": "automation",
  "allowed_extensions": "permit-pty",
  "default_extensions": {"permit-pty": ""},
  "ttl": "10m",
  "max_ttl": "15m"
}
ROLE

bao policy write homelab-platform - <<'POLICY'
# The homelab pipelines (homelab.yml, apps.yml on main).
path "ssh-client-signer/sign/automation" { capabilities = ["update"] }  # 10-minute SSH certs for "automation"
path "kubernetes/creds/*"                { capabilities = ["update"] }  # 10-minute Kubernetes tokens
path "kubernetes/roles/*"                { capabilities = ["create", "update", "read"] }  # onboard new apps
POLICY

bao auth list -format=json | grep -q '"jwt-github/"' || bao auth enable -path=jwt-github jwt
bao write auth/jwt-github/config \
  oidc_discovery_url="https://token.actions.githubusercontent.com" \
  bound_issuer="https://token.actions.githubusercontent.com"
bao write auth/jwt-github/role/homelab-platform - <<ROLE
{
  "role_type": "jwt",
  "user_claim": "sub",
  "bound_audiences": ["openbao-homelab"],
  "bound_claims": {
    "repository_id": "${REPO_ID}",
    "ref": "refs/heads/main",
    "event_name": ["push", "workflow_dispatch"],
    "job_workflow_ref": [
      "${WF_PREFIX}/homelab.yml@refs/heads/main",
      "${WF_PREFIX}/apps.yml@refs/heads/main"
    ]
  },
  "token_policies": ["homelab-platform"],
  "token_ttl": "10m",
  "token_max_ttl": "15m"
}
ROLE
# Old single-app setup (replaced by homelab-platform)
bao delete auth/jwt-github/role/hpa-demo-deploy >/dev/null 2>&1 || true
bao policy delete hpa-demo-deploy >/dev/null 2>&1 || true

echo "== 7. automation user + SSH certificate trust on both VMs"
ap automation-access.yml

echo "== 8. Onboard existing apps"
for d in apps/*/k8s; do
  [ -d "${d}" ] && scripts/onboard-app.sh "$(basename "$(dirname "${d}")")"
done

echo "== 9. Self-tests"
ssh-keygen -q -t ed25519 -N '' -f "${work}/id"
bao write -field=signed_key ssh-client-signer/sign/automation public_key=@"${work}/id.pub" valid_principals=automation > "${work}/id-cert.pub"
for h in 127.0.0.1 192.168.0.103; do
  out="$(ssh -i "${work}/id" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
          "automation@${h}" 'sudo -n true && echo "$(hostname): automation can sudo"' 2>&1)" || true
  printf '  %-16s %s\n' "${h}" "${out}"
done
for d in apps/*/k8s; do
  [ -d "${d}" ] || continue
  app="$(basename "$(dirname "${d}")")"
  ( umask 077 && bao write -field=service_account_token "kubernetes/creds/${app}-deployer" kubernetes_namespace="${app}" ttl=10m > "${work}/t" )
  kc() { kubectl --kubeconfig=/dev/null --server=https://127.0.0.1:6443 --certificate-authority="${work}/ca.crt" --token="$(cat "${work}/t")" "$@" 2>/dev/null; }
  printf '  %-30s deploy:%s  secrets:%s  kube-system:%s\n' "${app} deployer" \
    "$(kc auth can-i patch deployments -n "${app}" || true)" \
    "$(kc auth can-i get secrets -n "${app}" || true)" \
    "$(kc auth can-i patch deployments -n kube-system || true)"
done
echo "  Expected: both hosts 'automation can sudo'; each app deploy:yes secrets:no kube-system:no"

echo
echo "Bootstrap done. BACK UP the auto-unseal key now (see docs/OPENBAO.md, 'Back up the seal key')."
