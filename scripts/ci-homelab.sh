#!/usr/bin/env bash
# Homelab pipeline: applies the Ansible playbooks to every VM after a merge. Runs ONLY in GitHub Actions,
# on ops01's runner (.github/workflows/homelab.yml).
#
#   0. Check the GitHub environment "platform" still requires approval (the job only starts after approval)
#   1. Log in to OpenBao with the job's GitHub OIDC token (role "platform")
#   2. Create a throwaway SSH key and have OpenBao sign it: certificate for user "automation", valid 10 minutes
#   3. Run the playbooks over SSH as "automation" (passwordless sudo, certificate-only login)
#   4. Onboard the allowed apps (homelab_apps in ansible/inventory/group_vars/all.yml): namespaces, deployer
#      accounts, OpenBao roles, with a 10-minute cluster-admin token. Safe to repeat. Apps that are onboarded but
#      no longer listed are only reported: removing them is a manual step.
#
# runner.yml is NOT run here: it would restart this runner in the middle of its own job, and it needs a
# fresh registration token anyway.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/ci-openbao-login.sh
source scripts/lib/ci-openbao-login.sh
# shellcheck source=scripts/lib/homelab-apps.sh
source scripts/lib/homelab-apps.sh

PLAYBOOKS=(base.yml k3s.yml openbao.yml automation-access.yml)

work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/homelab.XXXXXX")"
chmod 700 "${work}"
cleanup() { openbao_logout; rm -rf "${work}"; }
trap cleanup EXIT

echo "== 0. Approval gate"
require_protected_environment platform

echo "== 1. OpenBao login"
openbao_login platform

echo "== 2. 10-minute SSH certificate for 'automation'"
ssh-keygen -q -t ed25519 -N '' -C "homelab-pipeline-${GITHUB_RUN_ID:-local}" -f "${work}/id"
bao write -field=signed_key ssh-client-signer/sign/automation \
  public_key=@"${work}/id.pub" valid_principals=automation > "${work}/id-cert.pub"
chmod 600 "${work}/id" "${work}/id-cert.pub"

echo "== 3. Playbooks"
for pb in "${PLAYBOOKS[@]}"; do
  echo "---- ${pb}"
  ( cd ansible && ansible-playbook -i inventory/automation.ini "playbooks/${pb}" --private-key "${work}/id" )
done

echo "== 4. Onboard allowed apps (homelab_apps)"
list="$(homelab_apps inventory/automation.ini)"  # a broken list fails the run here (set -e)
mapfile -t apps < <(printf '%s\n' "${list}" | sed '/^$/d')
openbao_k8s_token homelab-platform openbao "${work}/admin.jwt"
write_kubeconfig "${work}/admin.kubeconfig" "${work}/admin.jwt" default
export KUBECONFIG="${work}/admin.kubeconfig"
if [ "${#apps[@]}" -eq 0 ]; then
  echo "homelab_apps is empty: nothing to onboard."
fi
for app in "${apps[@]}"; do
  scripts/onboard-app.sh "${app}"
done
labels="$(kubectl get namespaces -l homelab.zulhardy/app \
  -o jsonpath='{range .items[*]}{.metadata.labels.homelab\.zulhardy/app}{"\n"}{end}')"
mapfile -t onboarded < <(printf '%s\n' "${labels}" | sort -u | sed '/^$/d')
for app in "${onboarded[@]}"; do
  printf '%s\n' "${apps[@]}" | grep -qx "${app}" || \
    echo "::warning title=${app} not in homelab_apps::${app} is onboarded but no longer in homelab_apps. Not removed: removing an app is a manual step (docs/AUTOMATION.md)."
done
