#!/usr/bin/env bash
# Homelab pipeline: applies the Ansible playbooks to every VM after a merge. Runs ONLY in GitHub Actions,
# on ops01's runner (.github/workflows/homelab.yml).
#
#   0. Check the GitHub environment "platform" still requires approval (the job only starts after approval)
#   1. Log in to OpenBao with the job's GitHub OIDC token (role "platform")
#   2. Create a throwaway SSH key and have OpenBao sign it: certificate for user "automation", valid 10 minutes
#   3. Run the playbooks over SSH as "automation" (passwordless sudo, certificate-only login)
#
# runner.yml is NOT run here: it would restart this runner in the middle of its own job, and it needs a
# fresh registration token anyway.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/ci-openbao-login.sh
source scripts/lib/ci-openbao-login.sh

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
cd ansible
for pb in "${PLAYBOOKS[@]}"; do
  echo "---- ${pb}"
  ansible-playbook -i inventory/automation.ini "playbooks/${pb}" --private-key "${work}/id"
done
