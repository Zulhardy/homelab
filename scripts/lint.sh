#!/usr/bin/env bash
# Lint checks for every PR. Pipeline YAML only calls this script, so the same
# check can move to Azure Pipelines later without rewriting the logic.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "== yamllint =="
yamllint -d relaxed .

echo "== ansible syntax-check =="
cd ansible
for pb in playbooks/*.yml; do
  ansible-playbook --syntax-check "$pb"
done

echo "== ansible-lint =="
ansible-lint playbooks/

echo "== shellcheck =="
cd ..
command -v shellcheck >/dev/null || { echo "shellcheck not installed" >&2; exit 1; }
shellcheck scripts/*.sh scripts/lib/*.sh
shopt -s nullglob
app_scripts=(apps/*/tests/*.sh)
[ "${#app_scripts[@]}" -eq 0 ] || shellcheck "${app_scripts[@]}"

echo "All checks passed."
