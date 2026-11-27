# k3s: the homelab's Kubernetes cluster

**Kubernetes** runs apps in containers across several machines: it starts them, restarts them if they crash, spreads
web traffic across them, and adds or removes copies as needed. **k3s** is a small, complete version of Kubernetes
that fits on modest VMs like these.

This guide explains how the cluster is laid out, how DEV and PRD are kept apart, and how to install, check and look
after it.

## Contents

- [Words you'll see](#words-youll-see)
- [The cluster at a glance](#the-cluster-at-a-glance)
- [How DEV and PRD are kept apart](#how-dev-and-prd-are-kept-apart)
- [Install or update the cluster](#install-or-update-the-cluster)
- [Check that it works](#check-that-it-works)
- [Renaming a node](#renaming-a-node)
- [Stopping and starting k3s](#stopping-and-starting-k3s)
- [If the API server doesn't start](#if-the-api-server-doesnt-start)

## Words you'll see

| Word | Meaning |
|---|---|
| **Node** | One machine in the cluster: ops01, prd01 or dev01 |
| **Server / control plane** | The "brain" that decides what runs where. Here: ops01 |
| **Agent / worker** | A node that runs the app containers. Here: prd01 and dev01 |
| **Pod** | One running copy of an app (one or more containers) |
| **Namespace** | A separate area of the cluster. Each app gets `<app>-dev` and `<app>-prd` |
| **Label** | A tag on an object, e.g. "this node is for PRD", that other rules can match on |
| **kubectl** | The command-line tool for talking to Kubernetes |
| **API server** | The part of the control plane that `kubectl` and everything else talks to |

## The cluster at a glance

| Node | Role | IP | Environment label |
|---|---|---|---|
| ops01 | k3s **server** (control plane). Runs no app pods | 192.168.0.102 | none |
| prd01 | k3s **agent**: PRD apps | 192.168.0.103 | `node-restriction.kubernetes.io/env=prd` |
| dev01 | k3s **agent**: DEV apps | 192.168.0.104 | `node-restriction.kubernetes.io/env=dev` |

- **Version:** `v1.37.2+k3s1`, downloaded from the official GitHub release and checked against a pinned SHA-256. The
  usual `get.k3s.io` install script isn't used on purpose: it's a script fetched from the internet that could change
  at any time.
- **Node names** are fixed to the names in the inventory (`node-name` in `/etc/rancher/k3s/config.yaml`).
- **Included with k3s:** Traefik (lets web traffic in), Klipper-lb (gives Services an address), metrics-server
  (measures CPU, needed for autoscaling), CoreDNS (lets pods find each other by name), Flannel (the network between
  nodes) and local-path storage. k3s runs containers with its own containerd: Docker isn't needed.

## How DEV and PRD are kept apart

Five layers, each one backing up the others:

**1. Node labels that a node can't fake.** `k3s.yml` labels prd01 as `prd` and dev01 as `dev`, from the server. Labels
under `node-restriction.kubernetes.io/` can't be set by a node on itself (a Kubernetes rule called NodeRestriction),
so even a broken-into dev01 couldn't claim to be `prd`.

**2. A namespace per environment.** Every app gets `<app>-dev` and `<app>-prd`
([`onboard-app.sh`](../scripts/onboard-app.sh)), each marked with the environment it belongs to
(`scheduler.alpha.kubernetes.io/node-selector: node-restriction.kubernetes.io/env=<env>`).

**3. PodNodeSelector puts every pod in the right place.** This Kubernetes feature (turned on in `k3s.yml`) adds the
namespace's environment rule to every pod in it, and refuses pods that ask for the other environment. So app files
don't need any placement rules of their own.

**4. Separate credentials.** The DEV deploy account can only change `<app>-dev`, the PRD one only `<app>-prd`, and
OpenBao only gives PRD credentials to approved jobs ([AUTOMATION.md](AUTOMATION.md)).

**5. Separate addresses.** DEV apps are at `<app>.192.168.0.104.nip.io`, PRD apps at `<app>.192.168.0.103.nip.io`.
([nip.io](https://nip.io) turns a name into the IP address inside it, so no DNS setup is needed.)

Pods in namespaces without an environment mark (Traefik, CoreDNS and metrics-server, in `kube-system`) can run on
any node.

## Install or update the cluster

Normally the homelab pipeline does this after an approved merge. To do it by hand:

🖥️ **On ops01:**

```bash
cd ~/homelab && git pull
eval "$(ssh-agent -s)" && ssh-add          # only if your SSH key isn't loaded in this terminal yet
cd ansible
ansible-playbook playbooks/base.yml playbooks/k3s.yml -K
```

`-K` makes Ansible ask for your sudo password.

The playbook stops by itself if the UFW firewall is on or the `vxlan` kernel module is missing, so nothing is opened
or changed without you deciding.

✅ It ends with a `PLAY RECAP` where every VM shows `failed=0`.

## Check that it works

🖥️ **On ops01:**

```bash
kubectl get nodes -L node-restriction.kubernetes.io/env
```

✅ ops01, prd01 and dev01 are all `Ready`, and the last column shows `prd` for prd01 and `dev` for dev01.

```bash
kubectl get pods -A -o wide
```

✅ App pods in `*-dev` namespaces are on dev01, and those in `*-prd` namespaces are on prd01.

```bash
kubectl top nodes
```

✅ It shows CPU and memory for each node. (If it says "metrics not available", wait a minute: metrics-server is
still starting.)

⚠️ `~/.kube/config` on ops01 is a **cluster-admin** credential: whoever has it controls the whole cluster. Only your
admin user (`k3s_admin_user` in `group_vars/all.yml`) can read it. Never copy it into the repo.

## Renaming a node

Kubernetes knows each node by its name. If a node is renamed (its name in the inventory changes), it joins the
cluster as a **new** node, and the old entry stays behind as `NotReady`. Pods on the old entry only move once it's
removed. Removing it is a deletion, so it's always done by you, not by the pipeline.

🖥️ **On ops01:**

**Step 1:** Find the old names.

```bash
kubectl get nodes
```

✅ The old names show `NotReady`.

**Step 2:** Delete only the **old** name(s). Never ops01, prd01 or dev01.

```bash
kubectl delete node <old-name>
```

**Step 3:** Remove the old node's password entry too.

```bash
kubectl -n kube-system get secrets | grep node-password   # lists <name>.node-password.k3s entries
kubectl -n kube-system delete secret <old-name>.node-password.k3s
```

## Stopping and starting k3s

| VM | Service | Stop / start |
|---|---|---|
| ops01 | `k3s` | `sudo systemctl stop k3s` / `sudo systemctl start k3s` |
| prd01, dev01 | `k3s-agent` | `sudo systemctl stop k3s-agent` / `sudo systemctl start k3s-agent` |

Stopping `k3s` on ops01 stops the control plane: the apps keep running on prd01 and dev01, but nothing can be changed
or rescheduled until it's back.

## If the API server doesn't start

[Unverified] PodNodeSelector is a standard Kubernetes feature and should be built into k3s. If `k3s` on ops01 keeps
restarting after `k3s.yml` turns it on:

**Step 1:** Look at the log.

```bash
sudo journalctl -u k3s -n 50
```

**Step 2:** If it mentions the admission plugin, remove the `kube-apiserver-arg` lines from
`/etc/rancher/k3s/config.yaml`, then restart:

```bash
sudo systemctl restart k3s
```

**Step 3:** Report it, so the playbook can be fixed. Until then, DEV and PRD are kept apart by the deploy credentials
only (layer 4 above).
