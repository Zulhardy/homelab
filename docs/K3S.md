# k3s (Kubernetes) on the homelab

| Node | Role | IP | Environment label |
|---|---|---|---|
| ops01 (was docker01) | k3s **server** (control plane). No app pods | 192.168.0.102 | none |
| prd01 (was linux01) | k3s **agent**: PRD apps | 192.168.0.103 | `node-restriction.kubernetes.io/env=prd` |
| dev01 | k3s **agent**: DEV apps | 192.168.0.104 | `node-restriction.kubernetes.io/env=dev` |

Version: `v1.37.2+k3s1`, downloaded from the GitHub release and checked against a pinned SHA-256.
The `get.k3s.io` install script is deliberately not used (it is an unpinned remote script).
Node names are pinned to the inventory names (`node-name` in `/etc/rancher/k3s/config.yaml`).

Included with k3s: Traefik (ingress), Klipper-lb (service load balancer), Metrics Server (needed for autoscaling),
CoreDNS, Flannel networking, local-path storage. k3s runs containers with its own containerd; Docker isn't used.

## How DEV and PRD are kept apart

1. **Node labels**: `k3s.yml` labels prd01 and dev01 from the server. Labels under `node-restriction.kubernetes.io/`
   can't be set by a node on itself (NodeRestriction), so a compromised dev01 can't claim to be `prd`.
2. **Namespaces**: every app gets `<app>-dev` and `<app>-prd` ([`onboard-app.sh`](../scripts/onboard-app.sh)), each
   annotated `scheduler.alpha.kubernetes.io/node-selector: node-restriction.kubernetes.io/env=<env>`.
3. **PodNodeSelector** (an API-server admission plugin, enabled in `k3s.yml`) adds that rule to every pod in the
   namespace and rejects pods that ask for a different environment. App manifests don't need a `nodeSelector`.
4. **Credentials**: the DEV deployer can only change `<app>-dev`, the PRD deployer only `<app>-prd`, and OpenBao
   gives PRD credentials only to approved jobs ([AUTOMATION.md](AUTOMATION.md)).
5. **Addresses**: DEV apps are reached at `<app>.192.168.0.104.nip.io`, PRD at `<app>.192.168.0.103.nip.io`.

Pods in namespaces without the annotation (Traefik, CoreDNS, metrics-server in `kube-system`) can run on any node.

## Install or update (run on ops01)

Normally the homelab pipeline does this after an approved merge. By hand:

```bash
cd ~/homelab && git pull
eval "$(ssh-agent -s)" && ssh-add          # if not already loaded in this terminal
cd ansible
ansible-playbook playbooks/base.yml playbooks/k3s.yml -K
```

The playbook stops on its own if UFW is active or the `vxlan` kernel module is missing, so nothing is opened or changed
without you deciding.

## Check it

```bash
kubectl get nodes -L node-restriction.kubernetes.io/env   # ops01, prd01, dev01 Ready; prd01=prd, dev01=dev
kubectl get pods -A -o wide                               # app pods: *-dev on dev01, *-prd on prd01
kubectl top nodes
```

`~/.kube/config` on ops01 is a **cluster-admin** credential, readable only by your admin user (`k3s_admin_user` in `group_vars/all.yml`). Never commit it.

## Renaming nodes

k3s knows a node by its name. When a node is renamed (e.g. docker01 → ops01, linux01 → prd01), it joins as a
**new** node and the old entry stays behind as `NotReady`. The pods on the old entry are only moved once it is
removed. Removing it is up to you (deletions are always done by you, not the pipeline):

```bash
kubectl get nodes                           # old names show NotReady
kubectl delete node docker01 linux01        # only the OLD names; never ops01, prd01 or dev01
kubectl -n kube-system get secrets | grep node-password   # old <name>.node-password.k3s entries
kubectl -n kube-system delete secret docker01.node-password.k3s linux01.node-password.k3s
```

## Services

| VM | Service | Stop / start |
|---|---|---|
| ops01 | `k3s` | `sudo systemctl stop k3s` / `sudo systemctl start k3s` |
| prd01, dev01 | `k3s-agent` | `sudo systemctl stop k3s-agent` / `sudo systemctl start k3s-agent` |

## If the API server doesn't start after this change

[Unverified] PodNodeSelector is a standard Kubernetes admission plugin and should be built into k3s. If `k3s` on ops01
keeps restarting after `k3s.yml` adds it (`sudo journalctl -u k3s -n 50` mentions the admission plugin), remove the
`kube-apiserver-arg` lines from `/etc/rancher/k3s/config.yaml`, run `sudo systemctl restart k3s`, and report it so
the playbook can be fixed. DEV/PRD separation then relies on the deploy credentials only.
