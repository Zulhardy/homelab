#!/usr/bin/env bash
# App pipeline steps that run on ops01's runner (.github/workflows/apps.yml). GitHub Actions only.
#
#   ci-apps.sh check-onboarded '["app1","app2"]'  -> prints the JSON list of apps NOT yet onboarded
#                                                   (OpenBao role apps-check: read-only)
#   ci-apps.sh onboard APP                        -> namespaces, deployers, OpenBao roles for DEV and PRD
#                                                   (environment "platform", approved; 10-minute admin token)
#   ci-apps.sh deploy APP dev|prd                 -> deploy with that environment's 10-minute deployer token,
#                                                   then smoke-test through the Ingress
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/ci-openbao-login.sh
source scripts/lib/ci-openbao-login.sh
# shellcheck source=scripts/lib/envs.sh
source scripts/lib/envs.sh

[ -r /etc/rancher/k3s/server-ca.crt ] || { echo "Missing /etc/rancher/k3s/server-ca.crt (k3s.yml not applied yet)" >&2; exit 1; }

work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/apps.XXXXXX")"
chmod 700 "${work}"
cleanup() { openbao_logout; rm -rf "${work}"; }
trap cleanup EXIT

case "${1:-}" in
  check-onboarded)
    apps_json="${2:?missing apps JSON}"
    openbao_login apps-check >/dev/null
    python3 -I -c 'import json,sys; print("\n".join(json.loads(sys.argv[1])))' "${apps_json}" | while read -r app; do
      if ! bao read "kubernetes/roles/dev-${app}" >/dev/null 2>&1 || ! bao read "kubernetes/roles/prd-${app}" >/dev/null 2>&1; then
        echo "${app}"
      fi
    done | python3 -I -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))'
    ;;

  onboard)
    app="${2:?missing APP}"
    echo "== Approval gate"; require_protected_environment platform
    echo "== OpenBao login (platform)"; openbao_login platform
    openbao_k8s_token homelab-platform openbao "${work}/admin.jwt"
    write_kubeconfig "${work}/admin.kubeconfig" "${work}/admin.jwt" default
    KUBECONFIG="${work}/admin.kubeconfig" scripts/onboard-app.sh "${app}"
    ;;

  deploy)
    app="${2:?missing APP}"; env="${3:?missing ENV}"
    env_check "${env}"
    if [ -f "apps/${app}/deploy.disabled" ]; then
      echo "Deploying ${app} is switched off (apps/${app}/deploy.disabled). Not deploying." >&2; exit 1
    fi
    if [ "${env}" = "prd" ]; then echo "== Approval gate"; require_protected_environment prd; fi
    echo "== OpenBao login (apps-${env})"; openbao_login "apps-${env}"
    openbao_k8s_token "${env}-${app}" "${app}-${env}" "${work}/deployer.jwt"
    write_kubeconfig "${work}/deployer.kubeconfig" "${work}/deployer.jwt" "${app}-${env}"
    KUBECONFIG="${work}/deployer.kubeconfig" scripts/deploy.sh "${app}" "${env}"

    echo "== Smoke test (${env})"
    host="$(env_host "${app}" "${env}")"; ip="$(env_node_ip "${env}")"
    if ! compgen -G "apps/${app}/k8s/[0-9][0-9]-*ingress*.yaml" >/dev/null; then
      echo "${app} has no Ingress: nothing reachable from outside to smoke-test."
    elif [ -x "apps/${app}/tests/integration.sh" ]; then
      ok=""
      for _ in $(seq 1 20); do curl -s -o /dev/null -H "Host: ${host}" "http://${ip}/" && { ok=1; break; }; sleep 3; done
      [ -n "${ok}" ] || { echo "Ingress ${host} not answering." >&2; exit 1; }
      "apps/${app}/tests/integration.sh" "http://${ip}" "${host}"
    else
      echo "FAIL: ${app} has an Ingress but no apps/${app}/tests/integration.sh" >&2; exit 1
    fi
    ;;

  *) echo "usage: ci-apps.sh check-onboarded JSON | onboard APP | deploy APP dev|prd" >&2; exit 1 ;;
esac
