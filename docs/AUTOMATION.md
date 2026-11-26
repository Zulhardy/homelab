# Automation: everything after merge

**People review and merge pull requests, and approve high-risk steps. Everything else is automatic.**

| Step | Approval? | Why |
|---|---|---|
| Lint, unit tests, integration tests, security scans, image build | No | Can't change anything running |
| Deploy to **DEV** (dev01) | No | DEV is for trying changes |
| Deploy to **PRD** (prd01) | **Yes**, GitHub environment `prd` | Production |
| Homelab infrastructure (`ansible/`: VMs, k3s, OpenBao, SSH) | **Yes**, environment `platform` | Can change anything on the VMs |
| Onboarding a **new** app (namespaces, accounts, vault roles) | **Yes**, environment `platform` | Creates cluster-wide objects with an admin token |

| You merge a change to… | Pipeline | What happens |
|---|---|---|
| `ansible/**` | [`homelab.yml`](../.github/workflows/homelab.yml) | Waits for approval, then `base.yml`, `k3s.yml`, `openbao.yml`, `automation-access.yml` on all VMs |
| `apps/**` | [`apps.yml`](../.github/workflows/apps.yml) | Tests + scans → build, integration test, image scan → publish → (approval if new app) onboard → **DEV** + smoke test → approval → **PRD** + smoke test |
| Shared pipeline files (`scripts/`, the workflows) | Both, as relevant | All apps re-tested and redeployed (images are reused when the app code didn't change, but re-tested and re-scanned) |

## How approvals are enforced

1. **GitHub** won't start a job in environment `prd` or `platform` until a required reviewer approves it.
2. **OpenBao** checks the job's GitHub OIDC token, which names the environment only once the job has started
   (after approval). Each login role accepts one environment:

| OpenBao role | Accepts jobs from | Environment | Can get (10 minutes) |
|---|---|---|---|
| `apps-check` | `apps.yml` | none | Read which apps are onboarded. Nothing else |
| `apps-dev` | `apps.yml` | `dev` | Tokens for the DEV deployers (`kubernetes/creds/dev-*`) |
| `apps-prd` | `apps.yml` | `prd` | Tokens for the PRD deployers (`kubernetes/creds/prd-*`) |
| `platform` | `homelab.yml`, `apps.yml` | `platform` | SSH certificates for `automation`; cluster-admin tokens; create Kubernetes roles for new apps |

All roles also require: this repo (by ID), branch `main`, a push or manual run, audience `openbao-homelab`.
A DEV job can't get PRD credentials, and nothing gets admin credentials without an approved `platform` job.

3. The scripts also refuse to continue if the `prd` / `platform` environment has lost its required reviewers
   (`require_protected_environment` in [`ci-openbao-login.sh`](../scripts/lib/ci-openbao-login.sh)).

## Tests and scans

| Check | When | Fails the pipeline when |
|---|---|---|
| Lint ([`lint.sh`](../scripts/lint.sh)): yamllint, ansible syntax-check, ansible-lint, shellcheck | Every PR | Any error |
| Unit tests ([`unit-test.sh`](../scripts/unit-test.sh)) | PR and after merge | A test fails, or the app has **no** unit tests |
| Integration test ([`integration-test.sh`](../scripts/integration-test.sh)) | PR and after merge, against the built container (read-only, no capabilities) | `apps/<app>/tests/integration.sh` fails |
| Repo scan ([`security-scan.sh repo`](../scripts/security-scan.sh)) | PR and after merge | Any secret; a HIGH/CRITICAL misconfiguration; a CRITICAL vulnerability that has a fix |
| Image scan ([`security-scan.sh image`](../scripts/security-scan.sh)) | PR and before every push to GHCR | A CRITICAL vulnerability with a fix, or a secret in the image |
| Smoke test ([`ci-apps.sh`](../scripts/ci-apps.sh)) | After each DEV and PRD deploy | `integration.sh` fails against the app's real address |

Everything HIGH and above is printed in the log even when it doesn't fail the run. To accept a specific finding,
add its ID to a `.trivyignore` file at the repo root, with a comment saying why, in a pull request.

All of this runs on free resources: GitHub-hosted runners and environments are free for public repos, Trivy is
open source, and DEV/PRD run on the homelab VMs.

## One-time setup (manual, once)

### 1. GitHub environments (repo settings: yours to do)

GitHub repo → **Settings → Environments → New environment**, three times:

| Name | Required reviewers | Deployment branches |
|---|---|---|
| `dev` | none | **Selected branches** → `main` |
| `prd` | **yourself** (your GitHub user; leave "Prevent self-review" off if you're the only reviewer) | **Selected branches** → `main` |
| `platform` | **yourself** | **Selected branches** → `main` |

The names must match exactly: OpenBao checks them.

Then **Settings → Rules → Rulesets → protect-main → Require status checks**: add **`quality`** (it covers lint,
tests and scans). You can keep `lint` too.

### 2. Bootstrap

Something has to grant the pipelines their powers the first time. That's
[`scripts/bootstrap-automation.sh`](../scripts/bootstrap-automation.sh). Run it on **ops01**, as your own admin user
(not with sudo), from the repo folder. It asks for your **sudo password** and **2 of your 3 OpenBao keys** (all
hidden), then:

| Step | What it does |
|---|---|
| 0 | `base.yml`: hostnames ops01 / prd01 / dev01; runner user out of the `docker` group |
| 1 | `openbao.yml`: auto-unseal key file and root-only admin socket; OpenBao restarts |
| 2 | Migrates OpenBao to **auto-unseal** (no-op if done). Your 3 keys become **recovery keys** |
| 3 | Creates a **temporary root token** (over the admin socket, from 2 recovery keys) |
| 4 | `k3s.yml`: joins dev01, pins node names, DEV/PRD node labels, PodNodeSelector, publishes the CA certificate |
| 5 | Kubernetes: `openbao-broker` and `homelab-platform` (cluster-admin) accounts in namespace `openbao` |
| 6 | OpenBao: SSH certificate authority, Kubernetes roles, policies and login roles `apps-check`, `apps-dev`, `apps-prd`, `platform` |
| 7 | `automation-access.yml`: `automation` user on every VM; sshd trusts OpenBao-signed certificates |
| 8 | Onboards every existing app into DEV and PRD |
| 9 | Self-tests (below) and a check of the GitHub environments |
| 10 | **Revokes the temporary root token** |

Expected self-test output (names after the rename):

```
  127.0.0.1        ops01: automation can sudo
  192.168.0.103    prd01: automation can sudo
  192.168.0.104    dev01: automation can sudo
  hpa-demo-dev deployer          deploy:yes  secrets:no  kube-system:no  prd:no
  hpa-demo-prd deployer          deploy:yes  secrets:no  kube-system:no  dev:no
  ...
  dev       required reviewers: no (expected no)  OK
  prd       required reviewers: yes (expected yes)  OK
  platform  required reviewers: yes (expected yes)  OK
```

It's safe to run again. Afterwards, **back up the auto-unseal key** ([OPENBAO.md](OPENBAO.md#back-up-the-auto-unseal-key)).

## Adding an app

Create a folder under `apps/`, open a pull request, merge, approve the onboarding once, then approve PRD deploys.

```
apps/<name>/
  app/Dockerfile          optional: if present, built to ghcr.io/zulhardy/<name>:sha-<commit>; must EXPOSE a port
  k8s/10-*.yaml           Kubernetes manifests, NUMBERED, applied in order to <name>-dev, then <name>-prd
  k8s/20-*.yaml
  k8s/<other>.yaml        not numbered = not deployed automatically (e.g. load-generator.yaml)
  tests/test_*.py         REQUIRED unit tests (Python unittest), or an executable tests/unit.sh for other languages
  tests/integration.sh    REQUIRED if there is a Dockerfile or an Ingress: integration.sh BASE_URL [HOST_HEADER]
  README.md
  deploy.disabled         optional: if present, the app is tested, scanned and built, but NOT onboarded or deployed
```

| Rule | Why |
|---|---|
| `<name>`: lowercase letters, digits, `-`; max 40 characters; not `default`, `openbao`, `kube-*` | It becomes the namespaces `<name>-dev` / `<name>-prd` |
| Don't put a Namespace or `namespace:` in the manifests | The pipeline applies them to the right environment's namespace |
| Use `image: APP_IMAGE` for your own image | Replaced with the exact image built for this commit (same image in DEV and PRD) |
| Use `host: APP_INGRESS_HOST` in an Ingress | DEV: `<name>.192.168.0.104.nip.io`, PRD: `<name>.192.168.0.103.nip.io` |
| `APP_ENV` is replaced with `dev` or `prd` | If a manifest needs to differ per environment (e.g. replicas) |
| No `nodeSelector` / `nodeName` needed | Kubernetes places DEV pods on dev01 and PRD pods on prd01 |
| Allowed object types: Deployment, StatefulSet, Service, ConfigMap, PersistentVolumeClaim, Ingress, HorizontalPodAutoscaler, Job | That's what the `deployer` accounts may create ([`app-deployer-rbac.yaml.tmpl`](../ansible/files/k8s/app-deployer-rbac.yaml.tmpl)). Need more, e.g. Secrets? Change that template in a PR |
| No deletes | The deployer can't delete anything. Removing objects or a whole app is a manual step on purpose |

See [`apps/hpa-demo`](../apps/hpa-demo/) for a complete example. Its deploys are currently switched off
(`apps/hpa-demo/deploy.disabled`).

### Switching deploys off or on

- **Off**: add `apps/<name>/deploy.disabled` (a short note saying why) in a pull request. Tests, scans and the
  image build still run; onboarding and the DEV/PRD deploys are skipped. Anything already running stays as it is
  (removing it is a manual step).
- **On**: delete that file in a pull request. After merging, approve the onboarding once (`platform`); DEV deploys
  automatically, PRD after approval.

## What the pipelines may do (accepted trade-offs)

| Identity | Can do | Only when |
|---|---|---|
| `automation` (SSH, all VMs) | Anything, with sudo | Approved `platform` job from `homelab.yml` on `main`, 10-minute certificate |
| `homelab-platform` (Kubernetes) | Anything in the cluster (cluster-admin) | Approved `platform` job, 10-minute token; used only for onboarding |
| `<app>-dev/deployer` | Create/update that app's objects in `<app>-dev` | `dev` job from `apps.yml` on `main`, 10-minute token |
| `<app>-prd/deployer` | Create/update that app's objects in `<app>-prd` | Approved `prd` job from `apps.yml` on `main`, 10-minute token |

**An approved homelab run can change anything** on the VMs and in the cluster. The review before merge, and the
approval, are the controls.

What stays manual, on purpose: review and merge; approvals; the one-time setup above; `runner.yml`;
**deleting** apps, namespaces, nodes or data.

## Troubleshooting

Find the run under the repo's **Actions** tab, open the job, and read the step log.

| Message | Cause | Fix |
|---|---|---|
| Job shows **Waiting** | It needs approval (`prd` or `platform`) | Open the run → **Review deployments** → approve |
| `has no required reviewers. Refusing to continue` | The `prd` / `platform` environment lost its protection | Re-add the reviewer (setup step 1) |
| `claim "environment" is missing` / `does not match` | Job ran without (or in the wrong) environment | Expected if the workflow was edited; environments must match the table above |
| `error validating claims` / `permission denied` at login | Not `homelab.yml`/`apps.yml` on `main` of this repo | Renamed a workflow? Update `WF_PREFIX` in the bootstrap and re-run it |
| `OpenBao is sealed or not running` | OpenBao stopped, or the seal key file is missing | `sudo systemctl status openbao`; see [OPENBAO.md](OPENBAO.md) |
| `Permission denied (publickey)` in a playbook | `automation` certificate not trusted on that VM | Re-run the bootstrap (step 7) |
| `forbidden` during deploy | Object type the `deployer` can't create | Change the manifests, or extend the RBAC template in a PR |
| `pods ... is forbidden: pod node label selector conflicts` | A manifest asks for the other environment's node | Remove its `nodeSelector` |
| `FAIL: ... has no unit tests` / `no executable .../integration.sh` | Required tests missing | Add them (see "Adding an app") |
| Security scan gate failed | Secret, misconfiguration or fixable CRITICAL vulnerability | Fix it (update the base image digest, fix the manifest). Only if it's a false positive: `.trivyignore` in a PR |

To re-run a failed job: open the run → **Re-run jobs**. To run a pipeline by hand: **Actions** → pick the
workflow → **Run workflow** (on `main`).
