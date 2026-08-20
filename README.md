# Proxy-Installer

An interactive Bash script for installing and configuring a forward HTTP/HTTPS proxy (Squid, CONNECT method) and a SOCKS5 proxy (Dante) with password and/or IP-whitelist access on Debian and Ubuntu.

## Features
- Debian 11+ / Ubuntu 20.04+ and derivatives (Linux Mint, Pop!_OS, and other apt-based systems)
- Installs Squid (HTTP CONNECT) and Dante (SOCKS5) with Fail2ban protection
- Optional Unbound DNS resolver bound to **127.0.0.1 only** (used by Squid, not exposed to the internet)
- Optional BBR/sysctl tuning via `/etc/sysctl.d/` (no duplicate lines in `sysctl.conf`; skipped if the kernel cannot apply it)
- Interactive wizard with validation for authentication mode, users, IPv4/IPv6/CIDR whitelist, and ports
- System checks: internet (ICMP is not required), disk space, OS, occupied ports, SSH port
- Firewall setup that **always allows SSH first** (UFW, or firewalld if that is already active)
- Does not overwrite an existing Fail2ban `jail.local`; uses a drop-in jail instead
- Tracks created proxy users so cleanup does not need them typed in again
- Backup of existing configurations before overwriting
- Full cleanup or in-place reconfigure on rerun

## Requirements
- Debian 11+, Ubuntu 20.04+, or a Debian/Ubuntu derivative
- Root privileges
- An interactive terminal (do not pipe the script into bash)

## Installation
The script installs the necessary packages (`squid`, `dante-server`, `apache2-utils`, `fail2ban`, `ufw`) and optionally `unbound`, then guides you through configuration.

1. Download the script or clone the repository:
   ```bash
   curl -O https://raw.githubusercontent.com/vitaz86/Proxy-Installer/refs/heads/main/proxy-installer.sh
   ```
   or
   ```bash
   wget https://raw.githubusercontent.com/vitaz86/Proxy-Installer/refs/heads/main/proxy-installer.sh
   ```
   or
   ```bash
   git clone https://github.com/vitaz86/Proxy-Installer.git
   cd Proxy-Installer
   ```
2. Make the script executable if needed:
   ```bash
   chmod +x proxy-installer.sh
   ```
3. Run the installer:
   ```bash
   sudo ./proxy-installer.sh
   ```

Do **not** pipe the installer into bash. Interactive menus need a TTY:
```bash
# BAD
curl -fsSL https://raw.githubusercontent.com/vitaz86/Proxy-Installer/refs/heads/main/proxy-installer.sh | sudo bash
```

Syntax/self-check (no root, no install):
```bash
bash proxy-installer.sh --selftest
```

## Usage
Follow the prompts to:
- Choose the authentication mode (hybrid, password only, or IP whitelist only)
- Add whitelist addresses (IPv4, IPv6, or CIDR such as `192.168.1.0/24`)
- Create users and set passwords (Dante uses the system password; Squid uses `/etc/squid/passwd`)
- Select ports for Squid and Dante
- Optionally install Unbound and apply network optimizations
- Optionally enable UFW (SSH is allowed before UFW is turned on)

After completion, the script prints connection details. Running it again detects an existing install and offers a full cleanup or a config-only rewrite.

## Troubleshooting
- If the script fails with network errors, confirm outbound HTTPS (ICMP ping is not required).
- Check logs: `/var/log/squid/access.log`, `/var/log/danted.log`, `/var/log/fail2ban.log`
- Service status: `sudo systemctl status squid danted fail2ban unbound`
- Firewall: `sudo ufw status` (rules backup: `/etc/ufw/ufw.rules.backup`) or `sudo firewall-cmd --list-ports`
- Squid config test: `sudo squid -k parse`
- Installer state (ports and created users): `/etc/proxy-installer/`
- Squid is a **forward proxy** (HTTP CONNECT). It does not intercept TLS.

## Customization
- Rerun the script to change authentication settings or ports.
- Manual tuning can be done in the generated configuration files (timestamped `.bak.*` copies are kept):
  - `/etc/squid/squid.conf`
  - `/etc/danted.conf`
  - `/etc/fail2ban/jail.d/proxy-installer.local`
  - `/etc/fail2ban/filter.d/dante-proxy-installer.conf`
  - `/etc/sysctl.d/99-proxy-installer.conf`
- Restart the services after manual changes:
  ```bash
  sudo systemctl restart squid danted fail2ban
  ```

## Uninstall
Run the installer again and choose full cleanup. Tracked proxy users, package configs, sysctl drop-in, Unbound drop-in, and proxy firewall rules are removed. Pre-existing Fail2ban is left installed if it was already on the system. Timestamped `.bak.*` files are preserved.

## License
This project is licensed under the GPL-3.0. See [LICENSE](LICENSE) for details.
