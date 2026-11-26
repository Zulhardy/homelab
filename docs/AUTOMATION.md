# Automation: everything after merge

**The only manual step is reviewing and merging a pull request.** After that:

| You merge a change to… | Pipeline | What happens automatically |
|---|---|---|
| `ansible/**` | [`homelab.yml`](../.github/workflows/homelab.yml) | Playbooks applied to both VMs: Docker, k3s, OpenBao, automation access |
| `apps/**` | [`apps.yml`](../.github/workflows/apps.yml) | Changed apps detected → images built → **new apps onboarded** → deployed → rollout checked |
| Shared pipeline files (`scripts/`, the workflows) | Both, as relevant | All apps rebuilt/redeployed (images are reused when the app code didn't change) |

No pipeline holds a stored password, key or token. Each job:

1. asks GitHub for a short-lived **OIDC identity token** (proves: this repo, `main`, this workflow file);
2. logs in to **OpenBao** with it (10-minute session, policy `homelab-platform`);
3. receives only what that step needs, valid **10 minutes**:
   - an **SSH certificate** for the `automation` user (homelab playbooks), or
   - a **Kubernetes token**: cluster-admin for onboarding a new app, or the app's own `deployer` for deploying.

## One-time bootstrap (manual, once)

Something has to grant the pipelines these powers the first time. That's [`scripts/bootstrap-automation.sh`](../scripts/bootstrap-automation.sh).
Run it on **docker01**, as `zulhardy` (not with sudo), from the repo folder:

```bash
cd ~/homelab && git pull
scripts/bootstrap-automation.sh
```

It asks for your **sudo password** and **2 of your 3 OpenBao keys** (all hidden), then:

| Step | What it does |
|---|---|
| 1 | `openbao.yml`: creates the auto-unseal key file and the root-only admin socket; OpenBao restarts |
| 2 | Migrates OpenBao to **auto-unseal**. Your 3 keys become **recovery keys** |
| 3 | Creates a **temporary root token** (over the admin socket, from 2 recovery keys) |
| 4 | `k3s.yml`: publishes the cluster CA certificate for the pipeline |
| 5 | Kubernetes: `openbao-broker` and `homelab-platform` (cluster-admin) accounts in namespace `openbao` |
| 6 | OpenBao: SSH certificate authority, Kubernetes roles, policy `homelab-platform`, GitHub OIDC login |
| 7 | `automation-access.yml`: `automation` user on both VMs; sshd trusts OpenBao-signed certificates |
| 8 | Onboards every existing app in `apps/` |
| 9 | Self-tests (see below) |
| 10 | **Revokes the temporary root token** |

Expected self-test output:

```
  127.0.0.1        docker01: automation can sudo
  192.168.0.103    linux01: automation can sudo
  hpa-demo deployer              deploy:yes  secrets:no  kube-system:no
```

It's safe to run again. Afterwards, **back up the auto-unseal key** ([OPENBAO.md](OPENBAO.md#back-up-the-auto-unseal-key)).

## Adding an app

Create a folder under `apps/`, open a pull request, merge. That's it: the pipeline onboards it on first deploy.

```
apps/<name>/
  app/Dockerfile          optional: if present, built to ghcr.io/zulhardy/<name>:sha-<commit>
  k8s/10-*.yaml           Kubernetes manifests, NUMBERED, applied in order to namespace <name>
  k8s/20-*.yaml
  k8s/<other>.yaml        not numbered = not deployed automatically (e.g. load-generator.yaml)
  README.md
```

Rules:

| Rule | Why |
|---|---|
| `<name>`: lowercase letters, digits, `-`; max 40 characters; not `default`, `openbao`, `kube-*` | It becomes the Kubernetes namespace |
| Don't create the Namespace in the manifests | Onboarding creates it |
| Use `image: APP_IMAGE` for your own image | Replaced with the exact image built for this commit |
| Use `host: APP_INGRESS_HOST` in an Ingress | Replaced with `<name>.192.168.0.102.nip.io` |
| Only these object types are allowed: Deployment, StatefulSet, Service, ConfigMap, PersistentVolumeClaim, Ingress, HorizontalPodAutoscaler, Job | That's what the app's `deployer` account may create (see [`app-deployer-rbac.yaml.tmpl`](../ansible/files/k8s/app-deployer-rbac.yaml.tmpl)). Need more, e.g. Secrets? Change that template in a PR |
| No deletes | The deployer can't delete anything. Removing objects or a whole app is a manual step on purpose |

See [`apps/hpa-demo`](../apps/hpa-demo/) for a complete example.

## What the pipelines may do (accepted trade-offs)

| Identity | Can do | Only when |
|---|---|---|
| `automation` (SSH, both VMs) | Anything, with sudo | Job from `homelab.yml` on `main`, 10-minute certificate |
| `homelab-platform` (Kubernetes) | Anything in the cluster (cluster-admin) | Job from `apps.yml` or `homelab.yml` on `main`, 10-minute token; used only for onboarding |
| `<app>/deployer` (Kubernetes) | Create/update that app's objects in its own namespace | Same, 10-minute token |
| OpenBao policy `homelab-platform` | Get the credentials above; create Kubernetes roles for new apps | Same. It **can't** change policies, login methods or the SSH CA |

**Merging to `main` can change anything** on both VMs and in the cluster. The review before merge is the control.

What stays manual, on purpose:

- **Review and merge**
- **The one-time bootstrap** above (granting powers can't be done by the thing receiving them)
- **`runner.yml`**: it would restart the runner during its own job, and needs a fresh registration token
- **Deleting** apps or data

## Troubleshooting

Find the failed run under the repo's **Actions** tab, open the job, and read the step log.

| Message | Cause | Fix |
|---|---|---|
| `OpenBao is sealed or not running` | OpenBao service stopped, or the seal key file is missing | `sudo systemctl status openbao`; see [OPENBAO.md](OPENBAO.md) |
| `error validating claims` / `permission denied` at login | The job isn't from `homelab.yml`/`apps.yml` on `main` of this repo | Expected for other branches/workflows. Renamed a workflow? Update `WF_PREFIX` lines in the bootstrap and re-run it |
| `Permission denied (publickey)` in a playbook | `automation` certificate not trusted on that VM | Re-run the bootstrap (step 7) |
| `forbidden` during deploy | The app uses an object type the `deployer` can't create | Change the manifests, or extend the RBAC template in a PR |
| `Missing /etc/rancher/k3s/server-ca.crt` | `k3s.yml` hasn't run since this was added | Actions → **homelab** → **Run workflow**, or re-run the bootstrap |

To re-run a failed job: open the run → **Re-run jobs**. To run a pipeline by hand: **Actions** → pick the
workflow → **Run workflow** (on `main`).
