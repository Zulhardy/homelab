# OpenBao (secrets vault) on docker01

OpenBao is an open-source secrets vault (a community fork of HashiCorp Vault). In this homelab it will act as the
**credential broker**: the deploy pipeline will log in with GitHub's short-lived OIDC token and receive a
Kubernetes login that expires after minutes, so no long-lived cluster credential is stored for the pipeline.

| | |
|---|---|
| Version | 2.7.3, official `.deb` from the GitHub release, checked against a pinned SHA-256 |
| Runs on | docker01, as the `openbao` system user (hardened systemd unit from the package) |
| Listens on | `https://127.0.0.1:8200` only. Not reachable from the network. |
| TLS | Self-signed certificate for `127.0.0.1` and `localhost`; public part at `/etc/openbao/tls-ca.crt` |
| Data | `/opt/openbao/data` (encrypted at rest by OpenBao) |
| Client settings | `/etc/profile.d/openbao.sh` sets `BAO_ADDR` and `BAO_CACERT` for every login shell |

## Install (run on docker01)

```bash
cd ~/homelab && git pull
cd ansible
ansible-playbook playbooks/openbao.yml -K
```

The last task prints `OpenBao is NOT initialised yet and sealed.` That's expected.

## Initialise (one time only, by you)

Initialising creates:

- **3 unseal keys.** Any **2** of them unlock ("unseal") the vault after a restart.
- **1 root token**: full admin access to the vault.

> **Do not screenshot, paste or save this output anywhere except your password manager.**
> Anyone with 2 unseal keys and the data folder, or with the root token, can read every secret.

Open a **new terminal** on docker01 (so `BAO_ADDR` is set), then:

```bash
bao operator init -key-shares=3 -key-threshold=2
```

1. Copy the 3 `Unseal Key` lines and the `Initial Root Token` into your password manager, as separate entries.
2. Run `clear` to wipe them from the screen.

## Unseal (after initialising, and after every docker01 reboot)

OpenBao starts **sealed** every time the service restarts. While sealed, it can't hand out anything, and
automatic deploys will fail until you unseal it.

```bash
bao operator unseal     # paste unseal key 1 when asked (input is hidden)
bao operator unseal     # paste unseal key 2
bao status              # "Sealed  false" means it's ready
```

## Check it

```bash
bao status
```

| Field | Expected after init + unseal |
|---|---|
| Initialized | true |
| Sealed | false |
| Version | 2.7.3 |

Exit codes: `0` = unsealed, `2` = sealed, `1` = error (e.g. the service isn't running: `sudo systemctl status openbao`).

## Root token

You'll need the root token once, for the next step (configuring GitHub login and Kubernetes credentials).
After that it should be **revoked**. A new one can be generated later from the unseal keys if ever needed
(`bao operator generate-root`).

## Optional: the web UI

The UI only listens on docker01's loopback. From your PC, open an SSH tunnel and browse to it:

```bash
ssh -L 8200:127.0.0.1:8200 zulhardy@192.168.0.102
# then open https://127.0.0.1:8200/ui on your PC (accept the self-signed certificate warning)
```

## Emergency stop

```bash
bao operator seal          # locks the vault immediately (needs a token with permission, e.g. root)
sudo systemctl stop openbao
```

Either one stops all credential minting, so automatic deploys stop too.
