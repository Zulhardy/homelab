# Automation: everything after merge

**People review and merge pull requests, and approve high-risk steps. Everything else is automatic.**

Two repos share the homelab, through one self-hosted runner on ops01 registered at organization level (`zulhardy-lab`):

| Repo | Owns | Can do on the homelab |
|---|---|---|
| **homelab** (this repo) | VMs, k3s, OpenBao, Ansible, the runner, **which apps may run** (`homelab_apps`) | Anything, after the `platform` approval |
| **[devops-projects](https://github.com/zulhardy-lab/devops-projects)** | The apps (code, manifests, tests), their images | Deploy onboarded apps only: DEV without approval, PRD after the `prd` approval |

| Step | Repo | Approval? | Why |
|---|---|---|---|
| Lint and security scan of a PR | both | No | Can't change anything running |
| App tests, image build and scan | devops-projects | No | Can't change anything running |
| Deploy to **DEV** (dev01) | devops-projects | No (environment `dev`) | DEV is for trying changes |
| Deploy to **PRD** (prd01) | devops-projects | **Yes**, environment `prd` | Production |
| Homelab infrastructure (`ansible/`: VMs, k3s, OpenBao, SSH) | homelab | **Yes**, environment `platform` | Can change anything on the VMs |
| Onboarding an app (namespaces, accounts, vault roles) | homelab | **Yes**, environment `platform` (same run) | Creates cluster-wide objects with an admin token |

| You merge a change to… | Pipeline | What happens |
|---|---|---|
| `ansible/**` (including `homelab_apps`), `scripts/ci-homelab.sh`, `scripts/onboard-app.sh`, `scripts/lib/**` | [`homelab.yml`](../.github/workflows/homelab.yml) | Waits for approval, then `base.yml`, `k3s.yml`, `openbao.yml`, `automation-access.yml` on all VMs, then onboards every app in `homelab_apps` |
| Anything else here (docs, other scripts) | none after merge | Only the PR checks |

## How approvals are enforced

1. **GitHub** won't start a job in environment `prd` or `platform` until a required reviewer approves it.
2. **OpenBao** checks the job's GitHub OIDC token, which names the repo (by ID), the workflow file, the branch, and
   the environment (only once the job has started, i.e. after approval). Each login role accepts one repo, one
   workflow file and one environment:

| OpenBao role | Accepts jobs from | Environment | Can get (10 minutes) |
|---|---|---|---|
| `platform` | homelab `homelab.yml` | `platform` | SSH certificates for `automation`; cluster-admin tokens; create Kubernetes roles for the allowed apps |
| `projects-check` | devops-projects `apps.yml` | none | Read which apps are onboarded. Nothing else |
| `projects-dev` | devops-projects `apps.yml` | `dev` | Tokens for the DEV deployers (`kubernetes/creds/dev-*`) |
| `projects-prd` | devops-projects `apps.yml` | `prd` | Tokens for the PRD deployers (`kubernetes/creds/prd-*`) |

All roles also require: branch `main`, a push or manual run, audience `openbao-homelab`.
A DEV job can't get PRD credentials, devops-projects can't get admin credentials, and nothing gets admin
credentials without an approved `platform` job from this repo.

3. The scripts also refuse to continue if the `prd` / `platform` environment has lost its required reviewers
   (`require_protected_environment` in [`ci-openbao-login.sh`](../scripts/lib/ci-openbao-login.sh), and its copy in
   devops-projects).

## Tests and scans (this repo)

| Check | When | Fails the pipeline when |
|---|---|---|
| Lint ([`lint.sh`](../scripts/lint.sh)): yamllint, ansible syntax-check, ansible-lint, shellcheck | Every PR | Any error |
| Repo scan ([`security-scan.sh repo`](../scripts/security-scan.sh)) | Every PR | Any secret; a HIGH/CRITICAL misconfiguration; a CRITICAL vulnerability that has a fix |

App tests (unit, integration, image scan, smoke tests) run in devops-projects.

Everything HIGH and above is printed in the log even when it doesn't fail the run. To accept a specific finding,
add its ID to a `.trivyignore` file at the repo root, with a comment saying why, in a pull request.

All of this runs on free resources: GitHub-hosted runners and environments are free for public repos, Trivy is
open source, and DEV/PRD run on the homelab VMs.

## One-time setup (manual, once)

### 1. GitHub settings (yours to do)

**This repo** → **Settings → Environments → New environment**:

| Name | Required reviewers | Deployment branches |
|---|---|---|
| `platform` | **yourself** (your GitHub user; leave "Prevent self-review" off if you're the only reviewer), admin bypass off | **Selected branches** → `main` |

**devops-projects** → **Settings → Environments**:

| Name | Required reviewers | Deployment branches |
|---|---|---|
| `dev` | none | **Selected branches** → `main` |
| `prd` | **yourself**, admin bypass off | **Selected branches** → `main` |

The names must match exactly: OpenBao checks them. The old `dev` and `prd` environments in this repo are no longer
used by any workflow here; whether to delete them is up to you.

Then, in each repo, **Settings → Rules → Rulesets → protect-main → Require status checks**: **`lint`** and
**`quality`**.

**Organization** (`zulhardy-lab`) → **Settings → Actions → Runner groups**: the group holding the ops01 runner must
**allow public repositories**, with repository access limited to `homelab` and `devops-projects`. See
[BOOTSTRAP.md, step 6](BOOTSTRAP.md#step-6--install-the-github-actions-runner-on-ops01).

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
| 6 | OpenBao: SSH certificate authority, Kubernetes roles, policies and login roles `platform`, `projects-check`, `projects-dev`, `projects-prd`; removes the old `apps-*` roles |
| 7 | `automation-access.yml`: `automation` user on every VM; sshd trusts OpenBao-signed certificates |
| 8 | Onboards every app in `homelab_apps` into DEV and PRD |
| 9 | Self-tests (below), a check of both repo IDs and of the GitHub environments |
| 10 | **Revokes the temporary root token** |

The repo IDs (`REPO_ID`, `PROJECTS_REPO_ID`) are at the top of the script. A repo's ID survives renames and
transfers, and a new repo with the same name gets a different one, so OpenBao trusts the repo itself, not its name.

Expected self-test output (with hpa-demo in `homelab_apps`; with an empty list the deployer lines are skipped):

```
  127.0.0.1        ops01: automation can sudo
  192.168.0.103    prd01: automation can sudo
  192.168.0.104    dev01: automation can sudo
  hpa-demo-dev deployer          deploy:yes  secrets:no  kube-system:no  prd:no
  hpa-demo-prd deployer          deploy:yes  secrets:no  kube-system:no  dev:no
  ...
  zulhardy-lab/homelab             id 1473136403 (expected 1473136403)  OK
  zulhardy-lab/devops-projects     id 1473714389 (expected 1473714389)  OK
  zulhardy-lab/homelab/platform        required reviewers: yes (expected yes)  OK
  zulhardy-lab/devops-projects/dev     required reviewers: no (expected no)  OK
  zulhardy-lab/devops-projects/prd     required reviewers: yes (expected yes)  OK
```

It's safe to run again. Afterwards, **back up the auto-unseal key** ([OPENBAO.md](OPENBAO.md#back-up-the-auto-unseal-key)).

## Adding an app

The app itself goes into **devops-projects** (layout and manifest rules:
[its README](https://github.com/zulhardy-lab/devops-projects#adding-a-project)). Letting it run on the homelab is a
platform decision, made here:

1. In a pull request here, add the name to `homelab_apps` in
   [`ansible/inventory/group_vars/all.yml`](../ansible/inventory/group_vars/all.yml), e.g. `homelab_apps: [hpa-demo]`.
2. Merge, then approve the homelab run (`platform`). After the playbooks it runs
   [`onboard-app.sh`](../scripts/onboard-app.sh) for every listed app: namespaces `<name>-dev` / `<name>-prd` pinned
   to dev01 / prd01, a `deployer` account per namespace and a read-only `app-reader` account for the app's own
   pods ([`app-deployer-rbac.yaml.tmpl`](../ansible/files/k8s/app-deployer-rbac.yaml.tmpl)), OpenBao roles
   `dev-<name>` / `prd-<name>`.
3. In devops-projects, the next merge (or a manual run of its `apps` workflow) deploys the app to DEV, then PRD
   after approval. Until step 2 is done, its pipeline warns "not onboarded" and doesn't deploy.

| Rule | Why |
|---|---|
| `<name>`: lowercase letters, digits, `-`; max 40 characters; not `default`, `openbao`, `kube-*` | It becomes the namespaces `<name>-dev` / `<name>-prd` (checked by `onboard-app.sh`) |
| Allowed object types: Deployment, StatefulSet, Service, ConfigMap, PersistentVolumeClaim, Ingress, HorizontalPodAutoscaler, Job | That's what the `deployer` accounts may create. Need more, e.g. Secrets? Change the RBAC template in a PR here |
| No deletes | The deployer can't delete anything. Removing objects or a whole app is a manual step on purpose |
| App pods can only read, and only if they ask | A pod that sets `serviceAccountName: app-reader` may read its own namespace's pods, autoscalers and pod CPU/memory (e.g. hpa-demo's dashboard). No Secrets, no writes, nothing outside the namespace. Other pods get the default account: no permissions |

**Removing an app**: take it out of `homelab_apps`. That only stops future onboarding; the homelab run then warns
that the app is still onboarded. Deleting its namespaces (`kubectl delete namespace <name>-dev <name>-prd`) and its
OpenBao roles (`bao delete kubernetes/roles/dev-<name>`, `.../prd-<name>`) is yours to do, by hand.

## What the pipelines may do (accepted trade-offs)

| Identity | Can do | Only when |
|---|---|---|
| `automation` (SSH, all VMs) | Anything, with sudo | Approved `platform` job from homelab `homelab.yml` on `main`, 10-minute certificate |
| `homelab-platform` (Kubernetes) | Anything in the cluster (cluster-admin) | Approved `platform` job, 10-minute token; used only for onboarding |
| `<app>-dev/deployer` | Create/update that app's objects in `<app>-dev` | `dev` job from devops-projects `apps.yml` on `main`, 10-minute token |
| `<app>-prd/deployer` | Create/update that app's objects in `<app>-prd` | Approved `prd` job from devops-projects `apps.yml` on `main`, 10-minute token |
| `<app>-<env>/app-reader` | Read pods, autoscalers and pod metrics in its own namespace | Pods of that app that name it (`serviceAccountName: app-reader`) |

**An approved homelab run can change anything** on the VMs and in the cluster. The review before merge, and the
approval, are the controls. The shared runner means a devops-projects job runs on the same machine as OpenBao; it
still only gets the credentials its OpenBao role allows.

What stays manual, on purpose: review and merge; approvals; the one-time setup above; `runner.yml`;
**deleting** apps, namespaces, nodes or data.

## Troubleshooting

Find the run under the repo's **Actions** tab, open the job, and read the step log.

| Message | Cause | Fix |
|---|---|---|
| Job shows **Waiting** | It needs approval (`prd` or `platform`) | Open the run → **Review deployments** → approve |
| Job stays **Queued** in devops-projects | The org runner group doesn't allow that repo, or public repos | Organization → Settings → Actions → Runner groups (setup step 1) |
| `has no required reviewers. Refusing to continue` | The `prd` / `platform` environment lost its protection | Re-add the reviewer (setup step 1) |
| `claim "environment" is missing` / `does not match` | Job ran without (or in the wrong) environment | Expected if the workflow was edited; environments must match the table above |
| `error validating claims` / `permission denied` at login | Not the expected repo / workflow / `main` | Renamed a workflow or recreated a repo? Update `WF_PREFIX` / the repo IDs in the bootstrap and re-run it |
| `<app> is not onboarded on the homelab` (devops-projects) | The app isn't in `homelab_apps`, or the homelab run wasn't approved yet | "Adding an app" above |
| `homelab_apps must be a list of app names` | The list in `group_vars/all.yml` isn't a YAML list | Write it as `[a, b]` or one `- name` per line |
| `OpenBao is sealed or not running` | OpenBao stopped, or the seal key file is missing | `sudo systemctl status openbao`; see [OPENBAO.md](OPENBAO.md) |
| `Permission denied (publickey)` in a playbook | `automation` certificate not trusted on that VM | Re-run the bootstrap (step 7) |
| `forbidden` during a deploy | Object type the `deployer` can't create | Change the manifests, or extend the RBAC template in a PR here |
| `pods ... is forbidden: pod node label selector conflicts` | A manifest asks for the other environment's node | Remove its `nodeSelector` |
| Security scan gate failed | Secret, misconfiguration or fixable CRITICAL vulnerability | Fix it. Only if it's a false positive: `.trivyignore` in a PR |

To re-run a failed job: open the run → **Re-run jobs**. To run a pipeline by hand: **Actions** → pick the
workflow → **Run workflow** (on `main`).
