# shellcheck shell=bash
# Sourced. homelab_apps [INVENTORY] -> prints the allowed apps (homelab_apps in ansible/inventory/group_vars/all.yml),
# one per line. Read through Ansible itself, so it sees exactly what the playbooks see. Fails if the value isn't a
# list of names. Run from the repo root.
homelab_apps() {
  local inv="${1:-inventory/hosts.ini}"
  ( cd ansible && ansible-inventory -i "${inv}" --host ops01 ) | python3 -I -c '
import json, sys
apps = json.load(sys.stdin).get("homelab_apps") or []
if not isinstance(apps, list) or not all(isinstance(a, str) for a in apps):
    sys.exit("homelab_apps must be a list of app names (ansible/inventory/group_vars/all.yml)")
print("\n".join(apps))'
}
