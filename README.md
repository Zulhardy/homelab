# homelab
This is a repo for my Devops Homelab

A free workspace on two Ubuntu VMs (Hyper-V) used to build and test a group capstone project:
a cloud-hosted web application with a database, deployed to Microsoft Azure.

- **This repo** sets up the workspace itself (VMs, Docker, Ansible, CI runner). It stays at home.
- **The capstone project** (website, database, pipelines) lives in its own repository (name not decided yet).
  It is on GitHub for now and moves to Azure DevOps later, where it runs on temporary Azure resources.
  This repo is not part of that move.

| Machine | Role |
|---|---|
| VM1 — docker01 (192.168.0.102) | Control node: Ansible, GitHub Actions self-hosted runner, image builds |
| VM2 — linux01 (192.168.0.103) | Runs the capstone project's app and database locally (Docker Compose) for testing |

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
