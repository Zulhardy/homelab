#!/usr/bin/env bash
# Load-balancing + autoscaling demo. Works on any Kubernetes cluster that has metrics-server.
#
#   scripts/hpa-demo.sh deploy       deploy the app, Service, (optional) Ingress and autoscaler
#   scripts/hpa-demo.sh test         send 10 requests from inside the cluster; shows which pod answered each one
#   scripts/hpa-demo.sh load-start   start the load generator (pushes CPU up)
#   scripts/hpa-demo.sh watch        watch the autoscaler and pods (Ctrl+C to stop watching)
#   scripts/hpa-demo.sh load-stop    stop the load generator (autoscaler scales back down)
#   scripts/hpa-demo.sh status       show everything in the hpa-demo namespace
#   scripts/hpa-demo.sh delete       remove the whole demo
#
# Optional settings (environment variables):
#   HPA_DEMO_IMAGE   image to deploy (default: the image built by this repo's pipeline for the current commit)
#   HPA_DEMO_HOST    host name for the Ingress (default: hpa-demo.192.168.0.102.nip.io, the author's homelab)
#   SKIP_INGRESS=1   don't create the Ingress (for clusters without Traefik, e.g. minikube, kind)
set -euo pipefail
cd "$(dirname "$0")/.."

ns=hpa-demo
k8s=apps/hpa-demo/k8s
host="${HPA_DEMO_HOST:-hpa-demo.192.168.0.102.nip.io}"
# busybox:1.37 pinned by digest; same image as the load generator
busybox="busybox@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec"

case "${1:-}" in
  deploy)
    image="${HPA_DEMO_IMAGE:-$(scripts/hpa-demo-image-tag.sh)}"
    echo "Deploying ${image}"
    # The pipeline's deployer account can't create namespaces (by design); an admin created it already.
    if kubectl auth can-i create namespaces >/dev/null 2>&1; then
      kubectl apply -f "${k8s}/00-namespace.yaml"
    fi
    sed "s|ghcr.io/zulhardy/hpa-demo:REPLACED_BY_SCRIPT|${image}|" "${k8s}/10-deployment.yaml" | kubectl apply -f -
    kubectl apply -f "${k8s}/20-service.yaml" -f "${k8s}/40-hpa.yaml"
    if [ "${SKIP_INGRESS:-0}" != "1" ]; then
      sed "s|host: REPLACED_BY_SCRIPT|host: ${host}|" "${k8s}/30-ingress.yaml" | kubectl apply -f -
      echo "Ingress host: http://${host}/"
    fi
    kubectl -n "${ns}" rollout status deploy/hpa-demo --timeout=180s
    ;;
  test)
    # Runs a short-lived pod inside the cluster, so it works without an Ingress or DNS.
    kubectl -n "${ns}" run "hpa-demo-test-$$" --rm -i --restart=Never --quiet \
      --image="${busybox}" \
      --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"t","image":"'"${busybox}"'","command":["sh","-c","for i in 1 2 3 4 5 6 7 8 9 10; do wget -q -O- http://hpa-demo/; done"],"securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}}]}}'
    ;;
  load-start)
    kubectl apply -f "${k8s}/load-generator.yaml"
    ;;
  watch)
    if command -v watch >/dev/null; then
      watch -n 5 "kubectl -n ${ns} get hpa hpa-demo; echo; kubectl -n ${ns} get pods -o wide; echo; kubectl -n ${ns} top pods 2>/dev/null"
    else
      kubectl -n "${ns}" get hpa hpa-demo --watch
    fi
    ;;
  load-stop)
    kubectl delete -f "${k8s}/load-generator.yaml" --ignore-not-found
    ;;
  status)
    kubectl -n "${ns}" get all,ingress,hpa
    ;;
  delete)
    kubectl delete namespace "${ns}" --ignore-not-found
    ;;
  *)
    sed -n '2,16p' "$0"
    exit 1
    ;;
esac
