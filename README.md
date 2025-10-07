# Proxy-Installer

An interactive Bash script for installing and configuring an HTTPS proxy (Squid) and a SOCKS5 proxy (Dante) with password or IP white list protection on Ubuntu.

## Features
- Supports Ubuntu 22.04 LTS and 24.04 LTS
- Installs Squid (HTTPS) and Dante (SOCKS5) with Fail2ban protection
- Optional installation of Unbound DNS resolver for faster DNS queries
- Enables BBR TCP congestion control and network optimizations for better performance
- Automatically configures Fail2ban rules for increased security and protection against burglary
- Interactive wizard with input validation for authentication mode, user creation, IP whitelisting, and custom ports
- Comprehensive error handling and system checks (internet connectivity, disk space, existing users)
- Automatic firewall (UFW) configuration with conflict detection and backup
- Backup of existing configurations before overwriting
- Optional cleanup of previous installations
- Modular code structure for maintainability

## Requirements
- Ubuntu 22.04 LTS or 24.04 LTS
- Root privileges

## Installation
The script installs the necessary packages (`squid`, `dante-server`, `apache2-utils`, `fail2ban`, `ufw`) and optionally `unbound`, then guides you through configuration with comprehensive checks.
These commands downloading script (or cloning the repo), then running the script from disk.

1. Download script or clone the repository:
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

DON'T USE one line bash commands that download and stream the installer directly into bash and execute it in one step, because they can't run interactive .SH script menus!!!
Examples (BAD for this .SH script):
   ```bash
   curl -fsSL https://raw.githubusercontent.com/vitaz86/Proxy-Installer/refs/heads/main/proxy-installer.sh | sudo bash
   wget -qO- https://raw.githubusercontent.com/vitaz86/Proxy-Installer/refs/heads/main/proxy-installer.sh | sudo bash
   ```

## Usage
Follow the prompts to:
- Choose the authentication mode (hybrid, password only, or IP whitelist only)
- Add whitelisted IP addresses (with validation)
- Create users and set passwords (with validation for usernames)
- Select ports for Squid and Dante (with validation for port numbers)
- Optionally install Unbound DNS resolver

The script performs system checks (internet, disk space) and validates all inputs. After completion, it displays the connection details for the configured proxies. Running the script again detects existing installations and offers to perform a full cleanup before reinstalling.

For Unbound, you can flush DNS cache with: `sudo unbound-control flush_zone .`

## Troubleshooting
- If the script fails with network errors, ensure internet connectivity.
- Check logs: `/var/log/squid/access.log`, `/var/log/danted.log`, `/var/log/fail2ban.log`
- Services status: `sudo systemctl status squid danted fail2ban unbound`
- Firewall: `sudo ufw status` (rules backup: `/etc/ufw/ufw.rules.backup`)
- If ports are in use, choose different ones or free them.
- If firewall conflicts detected, disable conflicting services (e.g., firewalld).

## Customization
- Rerun the script to change authentication settings or ports.
- Manual tuning can be done in the generated configuration files (backups are created as .bak):
  - `/etc/squid/squid.conf` (and `/etc/squid/squid.conf.bak`)
  - `/etc/danted.conf` (and `/etc/danted.conf.bak`)
  - `/etc/fail2ban/jail.local` (and `/etc/fail2ban/jail.local.bak`)
  - `/etc/fail2ban/filter.d/dante.conf` (and `/etc/fail2ban/filter.d/dante.conf.bak`)
- Restart the services after manual changes:
  ```bash
  sudo systemctl restart squid danted fail2ban unbound
  ```

## Uninstall
Run the installer again and accept the cleanup option to remove installed packages, configuration files, created users, and firewall rules. Note that backup files (.bak) are preserved for recovery.

## License
This project is licensed under the GPL-3.0. See [LICENSE](LICENSE) for details.
