# homelab
This is a repo for my Devops Homelab

Phase 1 of a school DevOps project: a free homelab on two Ubuntu VMs (Hyper-V), built to move later
to Azure Repos, Azure Pipelines and temporary Azure resources.

| Machine | Role |
|---|---|
| VM1 — docker01 (192.168.0.102) | Control node: Ansible, GitHub Actions self-hosted runner, image builds |
| VM2 — linux01 (192.168.0.103) | App runtime: Docker / Docker Compose |

## Layout

```
ansible/            Ansible config, inventory, playbooks
scripts/            Pipeline logic (workflow YAML only calls these)
.github/workflows/  Thin CI wrappers
docs/BOOTSTRAP.md   One-time manual setup
CLAUDE.md           Rules for the AI agent working in this repo
```

## Getting started

Follow [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md).

## Change process

All changes go through pull requests. The `lint` check runs on the self-hosted runner (VM1).
A human reviews and merges.
