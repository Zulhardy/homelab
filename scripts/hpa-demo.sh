#!/usr/bin/env bash
# Load-balancing + autoscaling demo. Run on docker01 as your user (uses your kubeconfig).
#
#   scripts/hpa-demo.sh deploy       deploy the app, Service, Ingress and autoscaler
#   scripts/hpa-demo.sh test         call the app 10 times and show which pod answered
#   scripts/hpa-demo.sh load-start   start the load generator (pushes CPU up)
#   scripts/hpa-demo.sh watch        watch the autoscaler and pods (Ctrl+C to stop watching)
#   scripts/hpa-demo.sh load-stop    stop the load generator (autoscaler scales back down)
#   scripts/hpa-demo.sh status       show everything in the hpa-demo namespace
#   scripts/hpa-demo.sh delete       remove the whole demo
set -euo pipefail
cd "$(dirname "$0")/.."

ns=hpa-demo
k8s=apps/hpa-demo/k8s
host="hpa-demo.192.168.0.102.nip.io"

case "${1:-}" in
  deploy)
    git fetch --quiet --unshallow 2>/dev/null || true
    image="$(scripts/hpa-demo-image-tag.sh)"
    echo "Deploying ${image}"
    kubectl apply -f "${k8s}/00-namespace.yaml"
    sed "s|ghcr.io/zulhardy/hpa-demo:REPLACED_BY_SCRIPT|${image}|" "${k8s}/10-deployment.yaml" | kubectl apply -f -
    kubectl apply -f "${k8s}/20-service.yaml" -f "${k8s}/30-ingress.yaml" -f "${k8s}/40-hpa.yaml"
    kubectl -n "${ns}" rollout status deploy/hpa-demo --timeout=180s
    ;;
  test)
    for _ in $(seq 1 10); do curl -s "http://${host}/" || curl -s -H "Host: ${host}" http://192.168.0.102/; done
    ;;
  load-start)
    kubectl apply -f "${k8s}/load-generator.yaml"
    ;;
  watch)
    watch -n 5 "kubectl -n ${ns} get hpa hpa-demo; echo; kubectl -n ${ns} get pods -o wide; echo; kubectl -n ${ns} top pods 2>/dev/null"
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
    sed -n '2,11p' "$0"
    exit 1
    ;;
esac
