# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A single Bash script (`core/ubuntu/setup-vless.sh`) that fully automates the deployment of a **VLESS + XTLS-Reality VPN server** (Xray-core) on Ubuntu 20.04–24.04 or Debian 11/12. The script runs interactively on the target server as root; there is no build system, no dependencies to install locally, and no tests.

## Running the script

The script must be run **on a remote Ubuntu/Debian server as root**. It cannot be tested locally on macOS. To deploy:

```bash
sudo bash setup-vless.sh
# or directly from GitHub:
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/AndreyBulachev/YourVPN/main/core/ubuntu/setup-vless.sh)"
```

To validate Bash syntax without executing:
```bash
bash -n core/ubuntu/setup-vless.sh
```

To lint with shellcheck (install via `brew install shellcheck`):
```bash
shellcheck core/ubuntu/setup-vless.sh
```

## Script architecture

The script is structured as 10 sequential steps gated by `set -Eeuo pipefail`:

1. **System update** — `apt-get update && upgrade`
2. **Utilities** — installs curl, openssl, ufw, qrencode, jq, etc.
3. **UFW firewall** — detects SSH port from `sshd_config`, opens SSH + 443/tcp + 443/udp
4. **BBR + sysctl** — writes `/etc/sysctl.d/99-xray.conf` with TCP tuning
5. **Xray-core install** — runs the official XTLS install script from GitHub
6. **Key generation** — UUID via `xray uuid`, X25519 keypair via `xray x25519`, Short ID via `openssl rand -hex 8`
7. **Server address detection** — tries three public IP APIs, falls back to manual input
8. **Dest site selection** — interactive menu (6 presets + custom); validates TLS 1.3 + reachability before accepting
9. **Config write** — generates `/usr/local/etc/xray/config.json` from a heredoc with all generated values substituted
10. **Validate + start** — `jq empty` for JSON syntax, `xray run -test` for semantic validation, then `systemctl enable && restart xray`

**Final output:** prints server params, the VLESS URI, and a QR code; saves everything to `/root/xray-client.txt` (chmod 600).

## Key constants and paths

| Constant | Value |
|---|---|
| Xray config | `/usr/local/etc/xray/config.json` |
| Xray logs | `/var/log/xray/` |
| Sysctl tuning | `/etc/sysctl.d/99-xray.conf` |
| Client output | `/root/xray-client.txt` |
| VLESS port | `443` |

## Post-install server management

```bash
systemctl status xray        # check status
systemctl restart xray       # restart after config edits
journalctl -u xray -f        # live logs
```

## Style conventions

- Helper functions: `step()`, `ok()`, `info()`, `warn()`, `die()` for all user-facing output
- `die()` always exits with error; never use bare `exit 1`
- `set +e` / `set -e` brackets around commands that are intentionally allowed to fail
- All file paths are `readonly` constants at the top of the script
- The `check_site()` function requires both TLS 1.3 AND HTTP reachability (2xx/3xx) to pass; HTTP/2 is checked but non-blocking
