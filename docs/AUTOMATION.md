# Automation: what happens after you merge

**Reviewing and merging pull requests, and approving the risky steps, are done manually. Everything else is
automatic.** This guide explains how that works, step by step: which pipelines run, what they're allowed to do,
how approvals are enforced, the one-time setup, how to add an app, and what to do when something fails.

New here? Read the [README](../README.md) first: it explains the words used below (runner, OpenBao, namespace...).

## Contents

- [Two repos, one runner](#two-repos-one-runner)
- [What needs an approval, and why](#what-needs-an-approval-and-why)
- [What runs when you merge](#what-runs-when-you-merge)
- [How approvals are enforced](#how-approvals-are-enforced)
- [Tests and scans in this repo](#tests-and-scans-in-this-repo)
- [One-time setup](#one-time-setup)
- [Adding an app](#adding-an-app)
- [Removing an app](#removing-an-app)
- [What the pipelines are allowed to do](#what-the-pipelines-are-allowed-to-do)
- [Troubleshooting](#troubleshooting)

## Two repos, one runner

Two repositories share the homelab. Both use **one runner on ops01**, registered to the `zulhardy-lab` organization:

| Repo | Owns | May do on the homelab |
|---|---|---|
| **homelab** (this one) | The VMs, k3s, OpenBao, Ansible, the runner, and **which apps may run** (`homelab_apps`) | Anything, after the `platform` approval |
| **[devops-projects](https://github.com/zulhardy-lab/devops-projects)** | The apps: code, Kubernetes files, tests, images | Deploy onboarded apps only: DEV straight away, PRD after the `prd` approval |

## What needs an approval, and why

| Step | Repo | Approval? | Why |
|---|---|---|---|
| Lint and security scan of a PR | both | No | It can't change anything that's running |
| App tests, image build and scan | devops-projects | No | It can't change anything that's running |
| Deploy to **DEV** (dev01) | devops-projects | No (environment `dev`) | DEV is for trying changes |
| Deploy to **PRD** (prd01) | devops-projects | **Manual** (environment `prd`) | It's production |
| Homelab changes (`ansible/`: VMs, k3s, OpenBao, SSH) | homelab | **Manual** (environment `platform`) | It can change anything on the VMs |
| Onboarding an app (namespaces, accounts, vault roles) | homelab | **Manual** (same `platform` run) | It creates cluster-wide objects with an admin token |

## What runs when you merge

| You merge a change to… | Pipeline | What happens |
|---|---|---|
| `ansible/**` (including `homelab_apps`), `scripts/ci-homelab.sh`, `scripts/onboard-app.sh`, `scripts/lib/**` | [`homelab.yml`](../.github/workflows/homelab.yml) | 1. Waits for the `platform` approval. 2. Runs `base.yml`, `k3s.yml`, `openbao.yml` and `automation-access.yml` on all VMs. 3. Onboards every app in `homelab_apps` |
| Anything else here (docs, other scripts) | None after the merge | Only the PR checks ran |

✅ To watch it: 🌐 the repo's **Actions** tab → **homelab** → the newest run. A run that's **Waiting** needs your
approval: **Review deployments** → tick `platform` → **Approve and deploy**.

## How approvals are enforced

An approval is only useful if it can't be skipped. Here it's checked **three times**:

**1. GitHub won't start the job.** A job in environment `prd` or `platform` waits until a required reviewer
approves it.

**2. OpenBao won't hand out the credentials.** Every pipeline run gets a signed ID card from GitHub (an **OIDC
token**). It names the repo (by its ID), the workflow file, the branch, and the environment. The environment is
only on the card once the job has started, i.e. after approval. OpenBao has one login role per kind of job, and
each accepts exactly one repo, one workflow file and one environment:

| OpenBao login role | Accepts jobs from | Environment | Can get, for 10 minutes |
|---|---|---|---|
| `platform` | homelab `homelab.yml` | `platform` | SSH certificates for `automation`; cluster-admin tokens; creating Kubernetes roles for the allowed apps |
| `projects-check` | devops-projects `apps.yml` | none | Which apps are onboarded. Nothing else |
| `projects-dev` | devops-projects `apps.yml` | `dev` | Tokens for the DEV deploy accounts (`kubernetes/creds/dev-*`) |
| `projects-prd` | devops-projects `apps.yml` | `prd` | Tokens for the PRD deploy accounts (`kubernetes/creds/prd-*`) |

All roles also require branch `main`, a push or manual run, and audience `openbao-homelab`. So a DEV job can't get
PRD credentials, devops-projects can't get admin credentials, and nothing gets admin credentials without an approved
`platform` job from this repo.

**3. The scripts check the environment's protection.** If the `prd` or `platform` environment has lost its required
reviewers, the scripts refuse to continue (`require_protected_environment` in
[`ci-openbao-login.sh`](../scripts/lib/ci-openbao-login.sh), and its copy in devops-projects).

## Tests and scans in this repo

| Check | When | Fails the pipeline when |
|---|---|---|
| Lint ([`lint.sh`](../scripts/lint.sh)): yamllint, Ansible syntax check, ansible-lint, shellcheck | Every PR | Any error |
| Repo scan ([`security-scan.sh repo`](../scripts/security-scan.sh)) | Every PR | Any secret; a HIGH or CRITICAL misconfiguration; a CRITICAL vulnerability that has a fix |

App tests (unit tests, integration tests, image scans, smoke tests) run in devops-projects.

Everything HIGH and above is printed in the log, even when it doesn't fail the run. To accept a specific finding
(a false positive), add its ID to a `.trivyignore` file at the repo root, with a comment saying why, in a pull
request.

All of this is free: GitHub's runners and environments are free for public repos, Trivy is open source, and DEV and
PRD run on the homelab VMs.

## One-time setup

You do this once, by hand. It's what gives the pipelines their powers in the first place.

### Step 1: GitHub settings

🌐 **This repo** → **Settings** → **Environments** → **New environment**:

| Name | Required reviewers | Deployment branches |
|---|---|---|
| `platform` | **Yourself** (your own GitHub account; leave "Prevent self-review" off if you're the only reviewer), admin bypass off | **Selected branches** → `main` |

🌐 **devops-projects** → **Settings** → **Environments**:

| Name | Required reviewers | Deployment branches |
|---|---|---|
| `dev` | None | **Selected branches** → `main` |
| `prd` | **Yourself**, admin bypass off | **Selected branches** → `main` |

⚠️ The names must match exactly: OpenBao checks them. (Older `dev` and `prd` environments in *this* repo aren't used
by anything here any more; deleting them is up to you.)

🌐 In **each** repo: **Settings** → **Rules** → **Rulesets** → `protect-main` → **Require status checks** →
**`lint`** and **`quality`**.

🌐 **Organization** (`zulhardy-lab`) → **Settings** → **Actions** → **Runner groups**: the group with the ops01
runner must **allow public repositories**, and only the `homelab` and `devops-projects` repos. See
[BOOTSTRAP.md, Part 9](BOOTSTRAP.md#part-9--install-the-github-runner).

✅ Both repos show their environments, and the runner group lists the two repos.

### Step 2: Run the bootstrap

The bootstrap, [`scripts/bootstrap-automation.sh`](../scripts/bootstrap-automation.sh), sets up OpenBao, the
Kubernetes accounts and the VM access that the pipelines use.

🖥️ **On ops01**, as your own admin user (not with `sudo`), in the repo folder:

```bash
cd ~/homelab && git pull
scripts/bootstrap-automation.sh
```

It asks for your **sudo password** and **2 of your 3 OpenBao recovery keys** (nothing you type is shown), then:

| Step | What it does |
|---|---|
| 0 | `base.yml`: hostnames ops01 / prd01 / dev01; takes the runner user out of the `docker` group |
| 1 | `openbao.yml`: the auto-unseal key file and the root-only admin socket; restarts OpenBao |
| 2 | Switches OpenBao to **auto-unseal** (skipped if already done). Your 3 keys become **recovery keys** |
| 3 | Creates a **temporary root token** (over the admin socket, from 2 recovery keys) |
| 4 | `k3s.yml`: joins dev01, fixes the node names, labels the DEV/PRD nodes, turns on PodNodeSelector, publishes the cluster's certificate |
| 5 | Kubernetes: the `openbao-broker` and `homelab-platform` (cluster-admin) accounts in namespace `openbao` |
| 6 | OpenBao: the SSH certificate authority, the Kubernetes roles, the policies and the login roles `platform`, `projects-check`, `projects-dev`, `projects-prd`; removes the old `apps-*` roles |
| 7 | `automation-access.yml`: the `automation` user on every VM; sshd trusts certificates signed by OpenBao |
| 8 | Onboards every app in `homelab_apps` into DEV and PRD |
| 9 | Self-tests (below), and checks both repos' IDs and the GitHub environments |
| 10 | **Revokes the temporary root token** |

Why repo **IDs**? A repo's ID stays the same through renames and transfers, and a new repo with the same name gets a
different one. So OpenBao trusts the repo itself, not just its name. The IDs (`REPO_ID`, `PROJECTS_REPO_ID`) are at
the top of the script.

✅ The self-tests print something like this (with hpa-demo in `homelab_apps`; with an empty list, the deployer
lines are skipped):

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

Running it again is safe. **Afterwards, back up the auto-unseal key** ([OPENBAO.md](OPENBAO.md#back-up-the-auto-unseal-key)).

## Adding an app

The app itself goes into **devops-projects** (its layout and rules:
[its README](https://github.com/zulhardy-lab/devops-projects#add-your-own-project)). Allowing it to run on the
homelab is a platform decision, made here:

**Step 1:** In a pull request here, add the app's name to `homelab_apps` in
[`ansible/inventory/group_vars/all.yml`](../ansible/inventory/group_vars/all.yml), e.g. `homelab_apps: [hpa-demo]`.

**Step 2:** Merge it, then approve the homelab run (`platform`). After the playbooks, it runs
[`onboard-app.sh`](../scripts/onboard-app.sh) for every app on the list, which creates:
- the namespaces `<name>-dev` and `<name>-prd`, tied to dev01 and prd01;
- a `deployer` account in each, which the pipeline uses to deploy, and a read-only `app-reader` account the app's
  own pods may use ([`app-deployer-rbac.yaml.tmpl`](../ansible/files/k8s/app-deployer-rbac.yaml.tmpl));
- the OpenBao roles `dev-<name>` and `prd-<name>`.

✅ The run's log shows the onboarding step for your app.

**Step 3:** In devops-projects, the next merge (or **Actions** → **apps** → **Run workflow**) deploys the app to DEV,
then to PRD after approval. Until step 2 is done, its pipeline warns "not onboarded" and doesn't deploy.

| Rule | Why |
|---|---|
| `<name>`: lowercase letters, digits and `-`; up to 40 characters; not `default`, `openbao` or `kube-*` | It becomes the namespaces `<name>-dev` and `<name>-prd` (`onboard-app.sh` checks it) |
| Only these object types: Deployment, StatefulSet, Service, ConfigMap, PersistentVolumeClaim, Ingress, HorizontalPodAutoscaler, Job | That's what the `deployer` accounts may create. Need more, e.g. Secrets? Change the RBAC template in a PR here |
| Nothing gets deleted by the pipeline | The `deployer` can't delete anything. Removing objects or a whole app is a manual step, on purpose |
| App pods can only **read**, and only if they ask | A pod that sets `serviceAccountName: app-reader` may read its own namespace's pods, autoscalers and pod CPU/memory (e.g. hpa-demo's dashboard). No Secrets, no changes, nothing outside the namespace. Other pods get the default account, which has no permissions |

## Removing an app

**Step 1:** Take it out of `homelab_apps`, in a pull request. That only stops future onboarding: the next homelab run
warns that the app is still onboarded.

**Step 2:** Delete it from the cluster yourself. This is deliberately manual, because it deletes things.

🖥️ **On ops01:**

```bash
kubectl delete namespace <name>-dev <name>-prd
```

and remove its OpenBao roles (`bao delete kubernetes/roles/dev-<name>` and `kubernetes/roles/prd-<name>`), which
needs an admin token (see [OPENBAO.md](OPENBAO.md#admin-work-needs-recovery-keys)).

## What the pipelines are allowed to do

| Identity | Can do | Only when |
|---|---|---|
| `automation` (SSH, all VMs) | Anything, with sudo | An approved `platform` job from homelab `homelab.yml` on `main`, with a 10-minute certificate |
| `homelab-platform` (Kubernetes) | Anything in the cluster (cluster-admin) | An approved `platform` job, 10-minute token; only used for onboarding |
| `<app>-dev/deployer` | Create and update that app's objects in `<app>-dev` | A `dev` job from devops-projects `apps.yml` on `main`, 10-minute token |
| `<app>-prd/deployer` | Create and update that app's objects in `<app>-prd` | An approved `prd` job from devops-projects `apps.yml` on `main`, 10-minute token |
| `<app>-<env>/app-reader` | Read pods, autoscalers and pod metrics in its own namespace | The app's own pods, if they name it (`serviceAccountName: app-reader`) |

⚠️ **Accepted trade-off: an approved homelab run can change anything** on the VMs and in the cluster. Reviewing the
PR before merging, and the approval, are the controls. Because the runner is shared, a devops-projects job runs on
the same machine as OpenBao, but it still only gets the credentials its OpenBao role allows.

What stays manual, on purpose: reviewing and merging; approvals; the one-time setup above; `runner.yml`; and
**deleting** apps, namespaces, nodes or data.

## Troubleshooting

To find out what went wrong: 🌐 the repo's **Actions** tab → open the run → open the job → read the failed step's log.

| You see | Why | What to do |
|---|---|---|
| The job says **Waiting** | It needs approval (`prd` or `platform`) | Open the run → **Review deployments** → approve |
| A devops-projects job stays **Queued** | The runner group doesn't allow that repo, or public repos | Organization → **Settings** → **Actions** → **Runner groups** (setup step 1) |
| `has no required reviewers. Refusing to continue` | The `prd` or `platform` environment lost its protection | Add the reviewer back (setup step 1) |
| `claim "environment" is missing` / `does not match` | The job ran without its environment, or in the wrong one | Expected if the workflow was edited; environments must match the table above |
| `error validating claims` / `permission denied` when logging in | Not the expected repo, workflow or branch | Renamed a workflow or recreated a repo? Update `WF_PREFIX` or the repo IDs in the bootstrap and run it again |
| `<app> is not onboarded on the homelab` (devops-projects) | The app isn't in `homelab_apps`, or the homelab run wasn't approved yet | See [Adding an app](#adding-an-app) |
| `homelab_apps must be a list of app names` | The list in `group_vars/all.yml` isn't written as a YAML list | Write it as `[a, b]`, or one `- name` per line |
| `OpenBao is sealed or not running` | OpenBao stopped, or its unseal key file is missing | 🖥️ `sudo systemctl status openbao`; see [OPENBAO.md](OPENBAO.md) |
| `Permission denied (publickey)` in a playbook | That VM doesn't trust the `automation` certificate | Run the bootstrap again (its step 7) |
| `forbidden` during a deploy | The app's files ask for an object type the `deployer` can't create | Change the files, or extend the RBAC template in a PR here |
| `pods ... is forbidden: pod node label selector conflicts` | A file asks for the other environment's node | Remove its `nodeSelector` |
| The security scan failed | A secret, an unsafe setting, or a fixable CRITICAL vulnerability | Fix it. Only if it's a false positive: add it to `.trivyignore` in a PR |

To run a failed job again: open the run → **Re-run jobs**. To start a pipeline by hand: **Actions** → pick the
workflow → **Run workflow** (on `main`).
