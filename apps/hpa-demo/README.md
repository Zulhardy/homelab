# hpa-demo: load balancing and autoscaling on k3s

A tiny Python web app that uses CPU on every request. It shows two things the capstone needs:

| Requirement | Kubernetes piece | File |
|---|---|---|
| Load balancing | Service (inside the cluster) + Traefik Ingress (from outside) | `k8s/20-service.yaml`, `k8s/30-ingress.yaml` |
| Scale out when busy, in when quiet | HorizontalPodAutoscaler, 1 to 5 pods at 50% CPU | `k8s/40-hpa.yaml` |

## How the image gets built

Merging a change under `apps/hpa-demo/app/` runs `.github/workflows/hpa-demo-image.yml` on GitHub's runners.
It builds the image and pushes it to `ghcr.io/zulhardy/hpa-demo:sha-<commit>`, using GitHub's short-lived token.
`scripts/hpa-demo-image-tag.sh` computes that tag, so the deploy script uses exactly the image that was built.

## Run the demo (on docker01)

```bash
cd ~/homelab && git pull
scripts/hpa-demo.sh deploy       # app + Service + Ingress + autoscaler
scripts/hpa-demo.sh test         # 10 requests: watch different pod names answer
scripts/hpa-demo.sh load-start   # start sending load
scripts/hpa-demo.sh watch        # see CPU go up and pods go 1 -> up to 5 (Ctrl+C to leave)
scripts/hpa-demo.sh load-stop    # stop the load; after about a minute pods go back down to 1
scripts/hpa-demo.sh delete       # remove everything
```

Open in a browser on your network: http://hpa-demo.192.168.0.102.nip.io/
(nip.io is a public DNS service that turns that name into 192.168.0.102.)
