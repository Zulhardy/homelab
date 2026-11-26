# Homelab Bootstrap (one-time, done by the human)

After these steps, changes reach the VMs through pull requests and the runner on docker01, not by hand.
Every step that involves a password, key, or token is yours to do. The agent never handles them.

## Before you start

- [ ] Both VMs have fixed IPs (static or DHCP reservation in your router).
- [ ] Both VMs can reach the internet (outbound HTTPS).
- [ ] VM1 can reach VM2 over SSH on port 22.
- [x] Ubuntu version: 26.04.1 LTS on both VMs.
- [x] docker01 already has Docker from Docker's official repo (docker-ce 5:29.10.0). The playbook pins both VMs to the same versions.

## Step 1 — GitHub repository

1. Create a **public** repository.
2. Push the files from this skeleton to `main` (first commit only; everything after goes through PRs).
3. Protect `main` (Settings → Branches → Add rule, or Settings → Rules → Rulesets):
   - Require a pull request before merging
   - Require status checks to pass → `lint`
   - Block force pushes and deletion
4. Settings → Actions → General → "Approval for running fork pull request workflows from contributors":
   choose the strictest option (require approval for **all** outside collaborators).
   Never approve a run from someone else's PR without reading every changed file, especially `.github/workflows/`.
5. Settings → Code security: turn on secret scanning and push protection.

## Step 2 — Prepare docker01 (VM1, control node)

Run on docker01 as `zulhardy`:

```bash
# Ansible + git from Ubuntu's repositories
sudo apt update
sudo apt install -y ansible git

# SSH key for VM1 -> VM2 (this is YOUR key as the admin; protect it with a passphrase)
ssh-keygen -t ed25519 -C "docker01-admin"
ssh-copy-id zulhardy@192.168.0.103        # asks for linux01's account password (last time it will)

# Load the key into ssh-agent so neither you nor Ansible gets the passphrase prompt.
# Repeat these two lines each time you log in to docker01.
eval "$(ssh-agent -s)"
ssh-add                                   # type the key's passphrase once

ssh zulhardy@192.168.0.103 'hostname'     # should print: linux01, with no prompt
# If it asks "Enter passphrase for key ...", the agent isn't loaded: run the two lines above.
# If it asks "zulhardy@192.168.0.103's password", ssh-copy-id didn't work: run it again.

# Allow Ansible to use sudo on VM2 (you'll type VM2's sudo password with -K below)
```

## Step 3 — Get the code onto docker01

The repo is public, so no key is needed to clone it:

```bash
git clone https://github.com/zulhardy/homelab.git ~/homelab
```

## Step 4 — Fill in the placeholders

Edit on docker01 (and later commit through a PR):

- `ansible/inventory/hosts.ini` → already filled in (docker01 / linux01)
- `ansible/inventory/group_vars/all.yml` → already filled in (`zulhardy/homelab`)

## Step 5 — Install Docker on both VMs

```bash
cd ~/homelab/ansible
ansible all -m ping -K            # both should reply "pong"

# Dry run first: shows what would change without changing anything
ansible-playbook playbooks/docker.yml -K --check --diff

# Then the real run
ansible-playbook playbooks/docker.yml -K
```

`-K` asks for the sudo password. You type it; it is not stored.

## Step 6 — Install the GitHub Actions runner on docker01

1. GitHub repo → Settings → Actions → Runners → **New self-hosted runner** → Linux.
   Copy only the **token** from the `./config.sh ... --token XXXX` line. It is short-lived, so run the next
   command right away.
2. Run:

```bash
cd ~/homelab/ansible
ansible-playbook playbooks/runner.yml -K
# paste the token when prompted (input is hidden, and the task is marked no_log)
```

3. GitHub repo → Settings → Actions → Runners should show `docker01` as **Idle**.

## Step 7 — Test the safety controls

- [ ] Open a test PR → the `lint` check runs on a GitHub-hosted runner (not docker01) and passes.
- [ ] Try `git push origin main` directly → it is rejected (branch protection).
- [ ] Emergency stop: `sudo systemctl stop 'actions.runner.*'` on docker01 → runner shows **Offline** in GitHub.
      Then start it again: `sudo systemctl start 'actions.runner.*'`.

## Security notes

- The runner user `gha-runner` is in the `docker` group. Docker group membership is effectively root on docker01.
  Because the repo is public, the runner is only used by workflows that run after you merge to `main`.
- The inventory contains private LAN addresses (192.168.0.x) and your username. These are not secrets, but they are public.
- Your admin SSH key on docker01 can reach VM2. A separate, limited `deploy` user for the pipeline comes in the next step.
