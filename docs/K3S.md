# k3s (Kubernetes) on the homelab

| Node | Role | IP |
|---|---|---|
| docker01 | k3s **server** (control plane) | 192.168.0.102 |
| linux01 | k3s **agent** (runs workloads) | 192.168.0.103 |

Version: `v1.37.2+k3s1`, downloaded from the GitHub release and checked against a pinned SHA-256.
The `get.k3s.io` install script is deliberately not used (it is an unpinned remote script).

Included with k3s: Traefik (ingress), Klipper-lb (service load balancer), Metrics Server (needed for autoscaling),
CoreDNS, Flannel networking, local-path storage.

## Install (run on docker01)

```bash
cd ~/homelab && git pull
eval "$(ssh-agent -s)" && ssh-add          # if not already loaded in this terminal
cd ansible
ansible-playbook playbooks/k3s.yml -K
```

The playbook stops on its own if UFW is active or the `vxlan` kernel module is missing, so nothing is opened or changed
without you deciding.

## Check it

Open a **new terminal** first (the playbook adds `KUBECONFIG` to your `~/.bashrc`), or run `source ~/.bashrc`.

```bash
kubectl get nodes -o wide        # docker01 and linux01, both Ready
kubectl get pods -A              # coredns, traefik, metrics-server, local-path-provisioner: Running
kubectl top nodes                # works once Metrics Server is up (about a minute)
```

`~/.kube/config` on docker01 is a **cluster-admin** credential, readable only by `zulhardy`. Never commit it.
The pipeline will get its own, more limited credential later.

## Services

| VM | Service | Stop / start |
|---|---|---|
| docker01 | `k3s` | `sudo systemctl stop k3s` / `sudo systemctl start k3s` |
| linux01 | `k3s-agent` | `sudo systemctl stop k3s-agent` / `sudo systemctl start k3s-agent` |

Docker stays installed and keeps working. k3s uses its own container runtime (containerd), so images built with
Docker are not automatically visible to Kubernetes; they are pushed to a registry first.
