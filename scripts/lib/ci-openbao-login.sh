# shellcheck shell=bash
# Sourced by pipeline scripts running on docker01's runner. Logs in to OpenBao with the job's GitHub OIDC token.
#
#   openbao_login            -> exports BAO_ADDR, BAO_CACERT, BAO_TOKEN (OpenBao session, 10 minutes)
#   openbao_logout           -> revokes BAO_TOKEN (call from an EXIT trap)
#   openbao_k8s_token ROLE NS FILE -> writes a 10-minute Kubernetes token for ROLE in NS to FILE
#
# OpenBao role "homelab-platform" only accepts tokens from this repo's main branch and the
# homelab.yml / apps.yml workflows (set up by scripts/bootstrap-automation.sh).

export BAO_ADDR="https://127.0.0.1:8200"
export BAO_CACERT="/etc/openbao/tls-ca.crt"
OPENBAO_AUDIENCE="openbao-homelab"
OPENBAO_ROLE="homelab-platform"

openbao_login() {
  : "${ACTIONS_ID_TOKEN_REQUEST_URL:?Not running in GitHub Actions with id-token: write}"
  : "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:?Not running in GitHub Actions with id-token: write}"
  if ! bao status >/dev/null 2>&1; then
    echo "OpenBao is sealed or not running on docker01. Check: sudo systemctl status openbao" >&2
    return 1
  fi
  local jwt
  jwt="$(python3 -I -c '
import json, os, sys, urllib.parse, urllib.request
url = os.environ["ACTIONS_ID_TOKEN_REQUEST_URL"] + "&audience=" + urllib.parse.quote(sys.argv[1])
req = urllib.request.Request(url, headers={"Authorization": "bearer " + os.environ["ACTIONS_ID_TOKEN_REQUEST_TOKEN"]})
with urllib.request.urlopen(req, timeout=30) as r:
    sys.stdout.write(json.load(r)["value"])
' "${OPENBAO_AUDIENCE}")"
  BAO_TOKEN="$(printf '%s' "${jwt}" | bao write -field=token "auth/jwt-github/login" role="${OPENBAO_ROLE}" jwt=-)"
  export BAO_TOKEN
}

openbao_logout() {
  if [ -n "${BAO_TOKEN:-}" ]; then
    bao token revoke -self >/dev/null 2>&1 || true
    unset BAO_TOKEN
  fi
}

openbao_k8s_token() {
  local role="$1" ns="$2" file="$3"
  ( umask 077 && bao write -field=service_account_token "kubernetes/creds/${role}" \
      kubernetes_namespace="${ns}" ttl=10m > "${file}" )
}

# write_kubeconfig FILE TOKEN_FILE NAMESPACE -> a kubeconfig that uses ONLY that token (no admin certificate)
write_kubeconfig() {
  local file="$1" token_file="$2" ns="$3"
  ( umask 077 && cat > "${file}" <<KCFG
apiVersion: v1
kind: Config
clusters:
  - name: homelab
    cluster:
      server: https://127.0.0.1:6443
      certificate-authority: /etc/rancher/k3s/server-ca.crt
users:
  - name: pipeline
    user:
      tokenFile: ${token_file}
contexts:
  - name: pipeline@homelab
    context:
      cluster: homelab
      user: pipeline
      namespace: ${ns}
current-context: pipeline@homelab
KCFG
  )
}
