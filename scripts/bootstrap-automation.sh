#!/usr/bin/env bash
# ONE-TIME bootstrap, run by you, on ops01, as your normal user (not with sudo).
# After this, the only manual step in the homelab is reviewing and merging pull requests.
#
# It asks for: your sudo password, and 2 of your 3 OpenBao unseal/recovery keys. Nothing is written to disk
# except a sudo password file in a private temp folder that is deleted on exit.
#
#  0. base.yml      : hostnames from the inventory (ops01, prd01, dev01)
#  1. openbao.yml   : auto-unseal key file + root-only admin socket (OpenBao restarts, migration pending)
#  2. migrate       : switch OpenBao from unseal keys to auto-unseal (your keys become recovery keys)
#  3. root token    : temporary, created over the admin socket from 2 recovery keys; revoked at the end
#  4. k3s.yml       : joins dev01, pins node names, DEV/PRD node labels + PodNodeSelector, publishes the CA cert
#  5. Kubernetes    : broker + pipeline admin account (cluster-admin, used only through 10-minute tokens)
#  6. OpenBao       : SSH certificate authority, Kubernetes roles, policies, GitHub OIDC login roles:
#                     platform (this repo's homelab.yml) and projects-check / projects-dev / projects-prd
#                     (zulhardy-lab/devops-projects' apps.yml: deploy only)
#  7. automation    : "automation" user on every VM, sshd trusts OpenBao-signed certificates
#  8. apps          : onboards every app in homelab_apps (ansible/inventory/group_vars/all.yml) into DEV and PRD
#  9. self-tests    : SSH as automation with a fresh certificate; DEV/PRD deployer token permissions;
#                     GitHub environments exist with the right approval settings (homelab: platform;
#                     devops-projects: dev, prd)
# 10. root token revoked
# Safe to run again.
set -euo pipefail
cd "$(dirname "$0")/.."

# Repo IDs from the GitHub API (gh api repos/OWNER/REPO --jq .id). They never change, even if a repo is renamed or
# transferred, and a new repo with the same name gets a different ID. Checked on 2026-11-27.
REPO="zulhardy-lab/homelab"
REPO_ID="1473136403"
PROJECTS_REPO="zulhardy-lab/devops-projects"
PROJECTS_REPO_ID="1473714389"
WF_PREFIX="${REPO}/.github/workflows"
PROJECTS_WF_PREFIX="${PROJECTS_REPO}/.github/workflows"
SOCK="/run/openbao/admin.sock"

[ "$(id -u)" -ne 0 ] || { echo "Run this as your normal user, not with sudo." >&2; exit 1; }
for c in bao kubectl ansible-playbook ansible-inventory python3 ssh ssh-keygen sudo.ws; do
  command -v "${c}" >/dev/null || { echo "Missing command: ${c}" >&2; exit 1; }
done
# shellcheck source=/dev/null
[ -n "${BAO_ADDR:-}" ] || source /etc/profile.d/openbao.sh
# shellcheck source=scripts/lib/homelab-apps.sh
source scripts/lib/homelab-apps.sh
apps_list="$(homelab_apps inventory/hosts.ini)"  # fails here, before any change, if the list is broken
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

echo "== 0. Base: hostnames ops01 / prd01 / dev01"
ap base.yml

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

# --- Policies: one per pipeline job type. Each GitHub job only gets what its stage needs.
bao policy write projects-check - <<'POLICY'
# devops-projects apps.yml "onboarded" job (no approval): may only see which apps are onboarded.
path "kubernetes/roles/*" { capabilities = ["read"] }
POLICY
bao policy write projects-dev - <<'POLICY'
# devops-projects apps.yml "deploy-dev" job (GitHub environment "dev", no approval): DEV deployer tokens only.
path "kubernetes/creds/dev-*" { capabilities = ["update"] }
POLICY
bao policy write projects-prd - <<'POLICY'
# devops-projects apps.yml "deploy-prd" job (GitHub environment "prd", approval required): PRD deployer tokens only.
path "kubernetes/creds/prd-*" { capabilities = ["update"] }
POLICY
bao policy write platform - <<'POLICY'
# homelab.yml "apply" (GitHub environment "platform", approval required): playbooks + onboarding homelab_apps.
path "ssh-client-signer/sign/automation"   { capabilities = ["update"] }                     # 10-minute SSH certs
path "kubernetes/creds/homelab-platform"   { capabilities = ["update"] }                     # 10-minute cluster-admin
path "kubernetes/roles/*"                  { capabilities = ["create", "update", "read"] }   # onboard allowed apps
POLICY

bao auth list -format=json | grep -q '"jwt-github/"' || bao auth enable -path=jwt-github jwt
bao write auth/jwt-github/config \
  oidc_discovery_url="https://token.actions.githubusercontent.com" \
  bound_issuer="https://token.actions.githubusercontent.com"

# jwt_role NAME POLICY REPO_ID WORKFLOWS_JSON [ENVIRONMENT]
# Every role: one repo (by id), main only, push or manual run, named workflow files only, 10-minute session.
# ENVIRONMENT: the GitHub environment the job must run in. GitHub only puts it in the token after the
# environment's protection rules (required reviewers) have passed.
jwt_role() {
  local name="$1" policy="$2" repo_id="$3" wfs="$4" env="${5:-}" env_claim=""
  [ -n "${env}" ] && env_claim=", \"environment\": \"${env}\""
  bao write "auth/jwt-github/role/${name}" - <<ROLE
{
  "role_type": "jwt",
  "user_claim": "sub",
  "bound_audiences": ["openbao-homelab"],
  "bound_claims": {
    "repository_id": "${repo_id}",
    "ref": "refs/heads/main",
    "event_name": ["push", "workflow_dispatch"],
    "job_workflow_ref": ${wfs}${env_claim}
  },
  "token_policies": ["${policy}"],
  "token_ttl": "10m",
  "token_max_ttl": "15m"
}
ROLE
}
homelab_wf="[\"${WF_PREFIX}/homelab.yml@refs/heads/main\"]"
projects_wf="[\"${PROJECTS_WF_PREFIX}/apps.yml@refs/heads/main\"]"
jwt_role platform       platform       "${REPO_ID}"          "${homelab_wf}"  platform
jwt_role projects-check projects-check "${PROJECTS_REPO_ID}" "${projects_wf}"
jwt_role projects-dev   projects-dev   "${PROJECTS_REPO_ID}" "${projects_wf}" dev
jwt_role projects-prd   projects-prd   "${PROJECTS_REPO_ID}" "${projects_wf}" prd

# Older setups (replaced by the roles above). Deleting OpenBao login roles/policies only removes access.
# apps-*: the homelab repo's own apps pipeline, before the apps moved to devops-projects.
for old in homelab-platform hpa-demo-deploy apps-check apps-dev apps-prd; do
  bao delete "auth/jwt-github/role/${old}" >/dev/null 2>&1 || true
  bao policy delete "${old}" >/dev/null 2>&1 || true
done
bao delete kubernetes/roles/hpa-demo-deployer >/dev/null 2>&1 || true

echo "== 7. automation user + SSH certificate trust on every VM"
ap automation-access.yml

# Apps to onboard / test: the allowed-apps list homelab_apps (read above).
mapfile -t deploy_apps < <(printf '%s\n' "${apps_list}" | sed '/^$/d')

echo "== 8. Onboard allowed apps (homelab_apps)"
for a in "${deploy_apps[@]}"; do scripts/onboard-app.sh "${a}"; done
[ "${#deploy_apps[@]}" -gt 0 ] || echo "  No apps to onboard."

echo "== 9. Self-tests"
ssh-keygen -q -t ed25519 -N '' -f "${work}/id"
bao write -field=signed_key ssh-client-signer/sign/automation public_key=@"${work}/id.pub" valid_principals=automation > "${work}/id-cert.pub"
for h in 127.0.0.1 192.168.0.103 192.168.0.104; do
  out="$(ssh -i "${work}/id" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
          "automation@${h}" 'sudo -n true && echo "$(hostname): automation can sudo"' 2>&1)" || true
  printf '  %-16s %s\n' "${h}" "${out}"
done
[ "${#deploy_apps[@]}" -gt 0 ] || echo "  No onboarded apps: DEV/PRD deployer tests skipped (they run once an app is onboarded)."
for app in "${deploy_apps[@]}"; do
  for env in dev prd; do
    other="$([ "${env}" = dev ] && echo prd || echo dev)"
    ns="${app}-${env}"
    ( umask 077 && bao write -field=service_account_token "kubernetes/creds/${env}-${app}" kubernetes_namespace="${ns}" ttl=10m > "${work}/t" )
    kc() { kubectl --kubeconfig=/dev/null --server=https://127.0.0.1:6443 --certificate-authority="${work}/ca.crt" --token="$(cat "${work}/t")" "$@" 2>/dev/null; }
    printf '  %-30s deploy:%s  secrets:%s  kube-system:%s  %s:%s\n' "${ns} deployer" \
      "$(kc auth can-i patch deployments -n "${ns}" || true)" \
      "$(kc auth can-i get secrets -n "${ns}" || true)" \
      "$(kc auth can-i patch deployments -n kube-system || true)" \
      "${other}" "$(kc auth can-i patch deployments -n "${app}-${other}" || true)"
  done
done
echo "  Expected: all 3 hosts 'automation can sudo'; each deployer deploy:yes, everything else no"
echo "  Nodes and their environment label (expected: prd01 prd, dev01 dev, ops01 none):"
kubectl get nodes -L node-restriction.kubernetes.io/env | sed 's/^/    /'
echo "  App namespaces and the nodes they are pinned to:"
kubectl get namespaces -l homelab.zulhardy/app \
  -o custom-columns='NAMESPACE:.metadata.name,NODES:.metadata.annotations.scheduler\.alpha\.kubernetes\.io/node-selector' | sed 's/^/    /'
old_nodes="$(kubectl get nodes -o name | sed 's|node/||' | grep -vxE 'ops01|prd01|dev01' || true)"
[ -z "${old_nodes}" ] || echo "  Old node entries to remove yourself (docs/K3S.md, 'Renaming nodes'): ${old_nodes//$'\n'/ }"

echo "== GitHub repos and environments (approval gates)"
for pair in "${REPO}:${REPO_ID}" "${PROJECTS_REPO}:${PROJECTS_REPO_ID}"; do
  python3 -I - "https://api.github.com/repos/${pair%%:*}" "${pair##*:}" <<'PY' || true
import json, sys, urllib.request
url, want = sys.argv[1], sys.argv[2]
try:
    with urllib.request.urlopen(urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"}), timeout=30) as r:
        got = str(json.load(r).get("id"))
except Exception as e:
    print(f"  {url}: could not read ({e})"); sys.exit(0)
print(f"  {url.rsplit('/repos/', 1)[1]:32} id {got} (expected {want})  {'OK' if got == want else 'CHECK: update the repo IDs at the top of this script'}")
PY
done
for check in "${REPO}:platform" "${PROJECTS_REPO}:dev" "${PROJECTS_REPO}:prd"; do
  repo="${check%%:*}"; env="${check##*:}"
  python3 -I - "https://api.github.com/repos/${repo}/environments/${env}" "${repo}/${env}" <<'PY' || true
import json, sys, urllib.request
url, env = sys.argv[1], sys.argv[2]
try:
    with urllib.request.urlopen(urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"}), timeout=30) as r:
        rules = [x.get("type") for x in json.load(r).get("protection_rules", [])]
except Exception as e:
    print(f"  {env:36} MISSING ({e}). Create it: see docs/AUTOMATION.md"); sys.exit(0)
gated = "required_reviewers" in rules
want = not env.endswith("/dev")
status = "OK" if gated == want else "CHECK"
print(f"  {env:36} required reviewers: {'yes' if gated else 'no'} (expected {'yes' if want else 'no'})  {status}")
PY
done

echo
echo "Bootstrap done. BACK UP the auto-unseal key now (see docs/OPENBAO.md, 'Back up the seal key')."
