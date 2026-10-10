# MANAGER

Modern VPS manager inspired by the classic SSHPlus Manager experience, rebuilt for current Debian/Ubuntu systems.

> This repository is a clean modern implementation. It does not blindly execute the old SSHPlus binaries or overwrite system configuration files from legacy repositories.

## Goals

- Keep the simple terminal menu that made SSHPlus convenient.
- Manage SSH users without replacing the whole `sshd_config`.
- Add modern server diagnostics and service status.
- Add optional DNS ad blocking for VPN/private-network clients.
- Prefer auditable shell code, systemd and distribution packages.
- Never flush the entire firewall or download opaque executables as root.

## Current modules

- **System**: OS, kernel, uptime, memory, disk, IP addresses and important service state.
- **SSH users**: list, create, delete, change password/expiration and apply per-user login limits through PAM limits.
- **DNS Ad Block**: optional dnsmasq-based blocker with atomic blocklist updates, custom sources and a systemd update timer.
- **Self update**: reruns the installer from this repository.

## Supported systems

Designed for recent **Ubuntu** and **Debian** releases using `apt` and `systemd`.

## Install

```bash
sudo -i
curl -fsSL https://raw.githubusercontent.com/SrTristeSad/MANAGER/main/install.sh | bash
```

Then run:

```bash
manager
```

or the classic alias:

```bash
menu
```

## DNS ad blocking

The ad blocker is intentionally conservative. It does **not** expose an open recursive DNS resolver to the internet and it does not alter firewall rules automatically.

By default it listens on `127.0.0.1`. From the Manager menu you can change the listening address to an IP that belongs to your VPN/private network.

Default upstream resolvers:

- Cloudflare `1.1.1.1`
- Quad9 `9.9.9.9`

Default blocklist:

- StevenBlack hosts list

You can add or remove list URLs in `/etc/manager/adblock/sources.list`.

## Layout

```text
manager                 Main terminal menu
install.sh              Installer/updater
lib/common.sh            Shared helpers
modules/system.sh        System information
modules/ssh_users.sh     SSH user management
modules/adblock.sh       DNS ad blocker
VERSION                  Current version
```

## Legacy SSHPlus

SSHPlus Manager was originally developed by **@crazy_vpn** and became the basis for many community forks. MANAGER preserves the idea of a simple VPS administration menu while replacing obsolete and risky implementation details with current, readable code.

## Safety notes

Before enabling DNS on a public-facing interface, restrict UDP/TCP 53 to the networks that should use it. The module deliberately leaves firewall policy under the administrator's control.
