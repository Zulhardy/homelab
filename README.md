# homelab
This is a repo for my Devops Homelab

A free workspace on two Ubuntu VMs (Hyper-V) used to build and test a group capstone project:
a cloud-hosted web application with a database, deployed to Microsoft Azure.

- **This repo** sets up the workspace itself: VMs, Docker, Kubernetes (k3s), Ansible, CI/CD runner. It stays at home.
- **The capstone project** (website, database, pipelines) lives in its own repository (name not decided yet).
  It is on GitHub for now and moves to Azure DevOps later, where it runs on temporary Azure resources.
  This repo is not part of that move.


## The machines

| Machine | Specs | Role |
|---|---|---|
| docker01 (192.168.0.102) | Ubuntu 26.04.1, 4 CPU, 8 GB RAM, 38 GB disk | Control node: Ansible, GitHub Actions self-hosted runner, **k3s server** (Kubernetes control plane) |
| linux01 (192.168.0.103) | Ubuntu 26.04.1, 4 CPU, 8 GB RAM, 38 GB disk | **k3s agent**: runs the projects (see [Projects and packages](#projects-and-packages-built-and-tested-on-the-homelab-not-part-of-it)) |

## DevOps components

### Architecture at a glance

```mermaid
flowchart TB
    subgraph GH["GitHub - cloud"]
        REPO["Repo zulhardy/homelab"]
        GHA["GitHub Actions - hosted runners"]
        GHCR["GitHub Container Registry"]
    end
    subgraph D1["docker01 - 192.168.0.102"]
        ANS["Ansible control node"]
        RUN["Self-hosted runner - user gha-runner"]
        K3S["k3s server - control plane"]
        DK1["Docker"]
    end
    subgraph L1["linux01 - 192.168.0.103"]
        AG["k3s agent - runs project pods"]
        DK2["Docker"]
    end
    REPO -->|"triggers"| GHA
    GHA -->|"push image"| GHCR
    RUN -.->|"outbound HTTPS only"| REPO
    ANS -->|"SSH"| AG
    ANS -->|"local"| K3S
    K3S ---|"6443, 8472, 10250"| AG
    AG -->|"pull images"| GHCR
```

k3s ports between the nodes: 6443/tcp (Kubernetes API), 8472/udp (Flannel VXLAN networking), 10250/tcp (kubelet).

### Components in detail

| Area | Tool | Version | Where | What it does here | Managed by |
|---|---|---|---|---|---|
| **Version control & change management** | GitHub | n/a | Cloud | Single source of truth. `main` protected by the `protect-main` ruleset: PR required, `lint` must pass, no force push, no deletion | Repo settings (by hand) |
| **Continuous integration** | GitHub Actions (GitHub-hosted runners) | `ubuntu-24.04` image | Cloud | Lints every pull request; builds and publishes project images after merge | [`.github/workflows/`](.github/workflows/) |
| **Self-hosted CI/CD runner** | GitHub Actions runner | 2.338.2 | docker01 | Will run post-merge deploy jobs inside the home network. Connects **out** to GitHub only; no inbound ports | [`runner.yml`](ansible/playbooks/runner.yml) |
| **Configuration management / IaC** | Ansible | from Ubuntu 26.04 repos | docker01 → both VMs | Installs and configures everything on the VMs, idempotently (re-running changes only what differs) | [`ansible/`](ansible/) |
| **Containers** | Docker Engine + Compose plugin | 29.10.0 / 5.8.0 | Both VMs | Builds and runs containers outside Kubernetes. Versions pinned and put on apt hold | [`docker.yml`](ansible/playbooks/docker.yml) |
| **Container orchestration** | k3s (Kubernetes) | v1.37.2+k3s1 | docker01 = server, linux01 = agent | Runs project workloads as pods, restarts failed ones, spreads them across nodes | [`k3s.yml`](ansible/playbooks/k3s.yml), [K3S.md](docs/K3S.md) |
| **Ingress / external load balancing** | Traefik + Klipper-lb (bundled with k3s) | bundled | Both VMs, port 80/443 | Receives HTTP traffic on the VMs and routes it to the right Service by host name | k3s |
| **Internal load balancing** | Kubernetes Service | n/a | Cluster | Spreads requests across all ready pods of an app | Each project's manifests |
| **Autoscaling** | metrics-server (bundled) + HorizontalPodAutoscaler | bundled | Cluster | Measures pod CPU; the HPA adds or removes pods to hit a CPU target | Each project's manifests |
| **Service discovery** | CoreDNS (bundled) | bundled | Cluster | Lets pods find Services by name, e.g. `http://hpa-demo.hpa-demo.svc` | k3s |
| **Container registry** | GitHub Container Registry (GHCR) | n/a | Cloud | Stores the images built by the pipeline; the cluster pulls from here | Project pipelines |
| **Secrets & supply chain** | GitHub secret scanning + push protection; pinning | n/a | Cloud + repo | Blocks pushes containing known secret types. Runner and k3s verified by SHA-256, base images pinned by digest, Actions pinned by commit SHA | Repo settings, playbooks |
| **Secrets vault / credential broker** | OpenBao | 2.7.3 | docker01, 127.0.0.1:8200 only | Exchanges the deploy job's GitHub OIDC token for a 10-minute Kubernetes token. Sealed after every restart until unsealed with 2 of 3 keys | [`openbao.yml`](ansible/playbooks/openbao.yml), [`openbao-setup.sh`](scripts/openbao-setup.sh), [OPENBAO.md](docs/OPENBAO.md) |
| **Monitoring** | `kubectl top` via metrics-server | bundled | Cluster | Live CPU/memory per node and pod. No dashboards or alerting yet | n/a |

### How each layer is secured

| Layer | Control |
|---|---|
| Code | Every change via pull request; `lint` required; only humans merge |
| Pipeline | PR checks run on GitHub's runners, never on the homelab; fork PR workflows need approval; per-run tokens with minimum permissions (`contents: read`, `packages: write` only where needed) |
| Runner | Runs as non-root `gha-runner`; its directory is readable only by that user; reserved for post-merge jobs |
| VMs | Admin SSH by key; sudo still requires a password; Ansible uses classic `sudo.ws` (see [`ansible.cfg`](ansible/ansible.cfg)) |
| Kubernetes | Admin kubeconfig on docker01 only (mode 0600); agent join token in a root-only file; the pipeline only ever gets 10-minute tokens for a per-project `deployer` account (no secrets, no deletes, one namespace); project pods run non-root with read-only filesystems and no capabilities |
| Secrets | OpenBao on loopback only, TLS; root token revoked after setup; unseal keys held by the human in a password manager |
| Supply chain | No `latest` tags anywhere; downloads verified by checksum or digest; no `curl \| sh` install scripts |

### Planned

| Component | Purpose |
|---|---|
| LitmusChaos (pinned 3.33.0) | Chaos experiments, e.g. killing pods to show self-healing |
| Monitoring dashboards (e.g. Prometheus + Grafana) | History and alerts instead of only live `kubectl top` |

## Homelab pipelines (GitHub Actions)

| Workflow | When | Runs on | What it does |
|---|---|---|---|
| [`pr-checks.yml`](.github/workflows/pr-checks.yml) | Every pull request to `main` | GitHub-hosted runner | Lint: yamllint, Ansible syntax check, ansible-lint ([`scripts/lint.sh`](scripts/lint.sh)). Required to pass before merging. |

The self-hosted runner on docker01 is reserved for workflows that run **after** a merge to `main`.
Pull request checks never run on the homelab, because this repo is public.

## Projects and packages (built and tested on the homelab, not part of it)

These are separate projects that use the homelab as a place to build and run them. Each has its own folder,
pipeline and published package. They don't set up or change the homelab itself, and you don't need the homelab
to try them.

| Project | What it is | Folder and docs | Pipeline | Package |
|---|---|---|---|---|
| **hpa-demo** | Load balancing and autoscaling on Kubernetes (1 → 5 → 1 pods under load). Runs on any Kubernetes cluster with metrics-server. | [apps/hpa-demo](apps/hpa-demo/README.md) | [`hpa-demo-image.yml`](.github/workflows/hpa-demo-image.yml): on merge to `main` that changes hpa-demo, builds and pushes the image (GitHub-hosted runner), then deploys it automatically (docker01 runner, via OpenBao) | [`ghcr.io/zulhardy/hpa-demo`](https://github.com/zulhardy/homelab/pkgs/container/hpa-demo) |

## How the CI/CD pipeline works

CI/CD here is **GitHub Actions**. Every change, whether to the homelab or to a project, follows the same path:

```mermaid
flowchart LR
    A["Change on a branch"] --> B["Pull request to main"]
    B --> C["CI - pr-checks.yml - lint"]
    C -->|"fails"| A
    C -->|"passes"| D["Human review and merge"]
    D --> E{"What changed?"}
    E -->|"homelab files"| F["Human runs the playbook on docker01"]
    E -->|"project app"| G["Build - hpa-demo-image.yml"]
    G --> H["Publish image to GHCR"]
    H --> J["Deploy job on docker01 runner"]
    J --> K["OpenBao - 10-minute Kubernetes token"]
    K --> I["Deploy to k3s and check the rollout"]
```

| Stage | Type | Where it runs | Triggered by | Gate |
|---|---|---|---|---|
| **1. Lint** ([`pr-checks.yml`](.github/workflows/pr-checks.yml) → [`scripts/lint.sh`](scripts/lint.sh)) | CI | GitHub-hosted runner | Every pull request to `main` | Must pass before merge (ruleset on `main`) |
| **2. Review and merge** | Manual | GitHub | A human | Only humans merge; direct pushes to `main` are blocked |
| **3a. Apply homelab changes** (Ansible playbooks) | Manual CD | docker01 | A human running `ansible-playbook ... -K` | Needs the human's sudo password |
| **3b. Build and publish a project image** ([`hpa-demo-image.yml`](.github/workflows/hpa-demo-image.yml) → [`scripts/build-image.sh`](scripts/build-image.sh)) | CI/CD | GitHub-hosted runner | Merge to `main` that changes the project's app | Uses GitHub's short-lived per-run token, `packages: write` only |
| **4. Deploy the project** ([`scripts/ci-deploy-hpa-demo.sh`](scripts/ci-deploy-hpa-demo.sh) → [`scripts/hpa-demo.sh`](scripts/hpa-demo.sh) `deploy`) | **CD, automatic** | docker01 self-hosted runner | Stage 3b succeeding | Logs in to OpenBao with GitHub's OIDC token, gets a 10-minute Kubernetes token limited to the project's namespace, deploys exactly the image tag from 3b, and fails if the rollout isn't healthy |

Design choices:

- **Pipeline logic lives in [`scripts/`](scripts/)**, and the workflow YAML only calls it. This keeps the later
  move to Azure Pipelines small: only the thin YAML wrappers need rewriting.
- **Images are tagged with the commit that changed the app** (`sha-<commit>`, see
  [`scripts/hpa-demo-image-tag.sh`](scripts/hpa-demo-image-tag.sh)), never `latest`. Build and deploy compute the
  same tag, so what's deployed is always what was built.
- **Pull requests never run on the homelab.** The repo is public, so PR checks use GitHub's runners. The
  self-hosted runner on docker01 is reserved for post-merge jobs.
- **No stored deploy credentials.** The deploy job proves who it is with GitHub's OIDC token; OpenBao checks the
  repo, branch and workflow file, then hands out a Kubernetes token that expires after 10 minutes
  (see [docs/OPENBAO.md](docs/OPENBAO.md)).
- **If OpenBao is sealed** (e.g. after a docker01 reboot), deploys fail with a clear message until you unseal it.

## Layout

```
ansible/              Ansible config, inventory, playbooks (Docker, runner, k3s)
apps/                 Projects built and run on the homelab (not part of it), e.g. apps/hpa-demo
scripts/              Pipeline and demo logic (workflow YAML only calls these)
.github/workflows/    Thin CI/CD wrappers
docs/BOOTSTRAP.md     One-time manual setup of the VMs and the repo
docs/K3S.md           The Kubernetes cluster: install, check, stop/start
docs/OPENBAO.md       The secrets vault: install, initialise, unseal, GitHub OIDC + Kubernetes setup
CLAUDE.md             Rules for the AI agent working in this repo
```

## Security and safety

- **Every change goes through a pull request.** `main` is protected by a ruleset: PR required, `lint` must pass,
  no force pushes, no deletion.
- **No long-lived secrets in the repo.** Secret scanning and push protection are on. The image pipeline uses
  GitHub's short-lived per-run token.
- **Versions are pinned**: runner and k3s by checksum, container base images by digest, GitHub Actions by commit SHA.
- **Fork pull requests need approval** before any workflow runs.
- **Tested emergency stop**: `sudo systemctl stop actions.runner.zulhardy-homelab.docker01.service` on docker01.
- An AI agent helps write code here under the rules in [CLAUDE.md](CLAUDE.md). It can only propose changes as
  pull requests, holds no passwords, SSH keys or tokens, and doesn't run commands on the VMs.

## Getting started (rebuilding this homelab)

1. [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md): GitHub repo settings, SSH, Docker, runner
2. [docs/K3S.md](docs/K3S.md): the Kubernetes cluster
3. [docs/OPENBAO.md](docs/OPENBAO.md): the secrets vault used by automatic deploys

Projects in `apps/` have their own READMEs (see [Projects and packages](#projects-and-packages-built-and-tested-on-the-homelab-not-part-of-it)).

## Change process

All changes go through pull requests. The `lint` check runs on GitHub's hosted runners and must pass.
A human reviews and merges.

## Known gaps

- OpenBao has to be unsealed by hand after every docker01 reboot; until then, automatic deploys fail.
- `ansible-playbook playbooks/docker.yml --check` stops partway on a brand-new VM (the Docker service doesn't exist
  yet during a dry run). Real runs are fine.
- Ansible uses classic `sudo` (`sudo.ws`) because Ubuntu 26.04's `sudo-rs` isn't yet compatible with it
  (see [`ansible/ansible.cfg`](ansible/ansible.cfg)).
