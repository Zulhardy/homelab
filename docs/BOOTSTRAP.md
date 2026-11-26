# Homelab Bootstrap (one-time, done by the human)

> These are the first-time steps for a brand-new homelab: GitHub settings, SSH and the runner.
> After them, run the automation bootstrap in [AUTOMATION.md](AUTOMATION.md). From then on, merging a pull request
> is the only manual step.

After these steps, changes reach the VMs through pull requests and the runner on ops01, not by hand.
Every step that involves a password, key, or token is yours to do. The agent never handles them.

## Before you start

Three VMs (Hyper-V, Ubuntu 26.04.1 LTS, 4 CPU / 8 GB RAM each). `base.yml` sets the hostnames from the inventory.

| VM | IP | Role |
|---|---|---|
| ops01 (was docker01) | 192.168.0.102 | k3s control plane, runner, OpenBao, Ansible |
| prd01 (was linux01) | 192.168.0.103 | PRD apps |
| dev01 | 192.168.0.104 | DEV apps |

- [ ] All VMs have fixed IPs (static or DHCP reservation in your router).
- [ ] All VMs can reach the internet (outbound HTTPS).
- [ ] ops01 can reach prd01 and dev01 over SSH on port 22.
- [ ] The same user (`zulhardy`) exists on every VM. Using the same sudo password on all three keeps the
      bootstrap to one password prompt.
- Docker is **not** needed on the VMs (images are built on GitHub's runners; k3s has its own runtime).

## Step 1 — GitHub repository

1. Create a **public** repository.
2. Push the files from this skeleton to `main` (first commit only; everything after goes through PRs).
3. Protect `main` (Settings → Branches → Add rule, or Settings → Rules → Rulesets):
   - Require a pull request before merging
   - Require status checks to pass → `quality` (it includes lint, tests and scans)
   - Block force pushes and deletion
4. Settings → Actions → General → "Approval for running fork pull request workflows from contributors":
   choose the strictest option (require approval for **all** outside collaborators).
   Never approve a run from someone else's PR without reading every changed file, especially `.github/workflows/`.
5. Settings → Code security: turn on secret scanning and push protection.

## Step 2 — Prepare ops01 (control node)

Run on ops01 as `zulhardy`:

```bash
# Ansible + git from Ubuntu's repositories
sudo apt update
sudo apt install -y ansible git

# SSH key for VM1 -> VM2 (this is YOUR key as the admin; protect it with a passphrase)
ssh-keygen -t ed25519 -C "ops01-admin"
ssh-copy-id zulhardy@192.168.0.103        # prd01: asks for its account password (last time it will)
ssh-copy-id zulhardy@192.168.0.104        # dev01: same

# Load the key into ssh-agent so neither you nor Ansible gets the passphrase prompt.
# Repeat these two lines each time you log in to ops01.
eval "$(ssh-agent -s)"
ssh-add                                   # type the key's passphrase once

ssh zulhardy@192.168.0.103 'hostname'     # prints the hostname, with no prompt
ssh zulhardy@192.168.0.104 'hostname'
# If it asks "Enter passphrase for key ...", the agent isn't loaded: run the two lines above.
# If it asks "zulhardy@192.168.0.103's password", ssh-copy-id didn't work: run it again.

# Ansible uses sudo on the other VMs (you type the sudo password with -K)
```

## Step 3 — Get the code onto ops01

The repo is public, so no key is needed to clone it:

```bash
git clone https://github.com/zulhardy/homelab.git ~/homelab
```

## Step 4 — Fill in the placeholders

Edit on ops01 (and later commit through a PR):

- `ansible/inventory/hosts.ini` → already filled in (ops01 / prd01 / dev01)
- `ansible/inventory/group_vars/all.yml` → already filled in (`zulhardy/homelab`)

## Step 5 — Check Ansible reaches every VM

```bash
cd ~/homelab/ansible
ansible all -m ping -K            # ops01, prd01 and dev01 should all reply "pong"
ansible-playbook playbooks/base.yml -K --check --diff   # dry run: shows the hostname changes
```

`-K` asks for the sudo password. You type it; it is not stored.

## Step 6 — Install the GitHub Actions runner on ops01

1. GitHub repo → Settings → Actions → Runners → **New self-hosted runner** → Linux.
   Copy only the **token** from the `./config.sh ... --token XXXX` line. It is short-lived, so run the next
   command right away.
2. Run:

```bash
cd ~/homelab/ansible
ansible-playbook playbooks/runner.yml -K
# paste the token when prompted (input is hidden, and the task is marked no_log)
```

3. GitHub repo → Settings → Actions → Runners should show `ops01` as **Idle**, with the label `homelab`.

## Step 7 — Test the safety controls

- [ ] Open a test PR → the checks run on GitHub-hosted runners (not ops01) and `quality` passes.
- [ ] Try `git push origin main` directly → it is rejected (branch protection).
- [x] Emergency stop (tested 2026-11-26, as docker01). On ops01:
      - Stop: `sudo systemctl stop actions.runner.zulhardy-homelab.<runner name>.service` → runner shows **Offline** in GitHub
      - Start: `sudo systemctl start actions.runner.zulhardy-homelab.<runner name>.service` → back to **Idle**
      - `<runner name>` is `docker01` if the runner was registered before the rename, `ops01` if after
        (`systemctl list-units 'actions.runner.*'` shows it).
      - Use the full service name. A pattern like `'actions.runner.*'` works for stop but not for start,
        because systemd only matches patterns against services that are currently loaded.
      - `/opt/actions-runner` is readable only by `gha-runner`, so `cd` into it fails for your user.
        If you need its scripts: `sudo bash -c 'cd /opt/actions-runner && ./svc.sh status'`

## Security notes

- The runner user `gha-runner` is **not** in the `docker` group (that would be effectively root on ops01), and Docker
  isn't installed on the VMs. Because the repo is public, the runner is only used by workflows that run after you
  merge to `main`.
- The inventory contains private LAN addresses (192.168.0.x) and your username. These are not secrets, but they are public.
- Your admin SSH key on ops01 can reach prd01 and dev01. The pipeline uses its own `automation` user with 10-minute
  certificates instead ([AUTOMATION.md](AUTOMATION.md)).
