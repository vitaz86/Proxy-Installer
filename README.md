# Proxy-Installer

An interactive Bash script for installing and configuring an HTTPS proxy (Squid) and a SOCKS5 proxy (Dante) with password or IP white list protection on Ubuntu.

## Features
- Supports Ubuntu 22.04 LTS and 24.04 LTS
- Installs Squid (HTTPS) and Dante (SOCKS5) with Fail2ban protection
- Optional installation of Unbound DNS resolver for faster DNS queries
- **Advanced Performance Optimizations**: Comprehensive system tuning including BBR TCP congestion control, network stack optimizations, buffer configurations, and proxy-specific settings for maximum throughput and reduced latency
- **Automatic Resource Detection**: Detects system resources (CPU cores, RAM, disk) and automatically selects optimized configurations for low-end VPS (1-2 cores, 1-2 GB RAM) or high-performance servers
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
- Choose whether to apply performance optimizations (system tuning and proxy configurations)
- Choose the authentication mode (hybrid, password only, or IP whitelist only)
- Add whitelisted IP addresses (with validation)
- Create users and set passwords (with validation for usernames)
- Select ports for Squid and Dante (with validation for port numbers)
- Optionally install Unbound DNS resolver

The script performs system checks (internet, disk space) and validates all inputs. After completion, it displays the connection details for the configured proxies. Running the script again detects existing installations and offers to perform a full cleanup before reinstalling.

For Unbound, you can flush DNS cache with: `sudo unbound-control flush_zone .`

## Performance Optimizations
The script includes comprehensive optimizations for maximum proxy performance:

### System-Level Tuning
- **Network Stack**: BBR congestion control, optimized TCP/UDP buffers, connection limits, and interface settings
- **Kernel Parameters**: Memory management, process limits, and I/O optimizations
- **Ulimits**: Increased file descriptors, processes, and memory limits

### Proxy-Specific Configurations
- **Squid**: Optimized caching, connection pooling, memory usage, and concurrency settings
- **Dante**: Tuned thread counts, buffer sizes, and connection timeouts

### Resource-Aware Optimization
- **User Choice**: You can choose whether to apply optimizations during installation
- **Automatic Detection**: When optimizations are enabled, script detects CPU cores, RAM, and disk space
- **Low-Resource Mode**: For VPS with ≤2 CPU cores or ≤2 GB RAM, uses conservative settings to prevent overload
- **High-Performance Mode**: For servers with >2 cores and >2 GB RAM, applies aggressive optimizations
- **Default Mode**: If optimizations are disabled, uses minimal default configurations

### Included Configuration Files
- `squid.conf` / `squid-low.conf`: Squid configurations (high-performance / low-resource)
- `danted.conf` / `danted-low.conf`: Dante configurations (high-performance / low-resource)
- `system-tune.sh` / `system-tune-low.sh`: System optimization scripts (only applied when optimizations are enabled)

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
- The script uses optimized template files that can be customized:
  - `squid.conf` / `squid-low.conf`: Base Squid configurations
  - `danted.conf` / `danted-low.conf`: Base Dante configurations
  - `system-tune.sh` / `system-tune-low.sh`: System optimization scripts
- Restart the services after manual changes:
  ```bash
  sudo systemctl restart squid danted fail2ban unbound
  ```

## Uninstall
Run the installer again and accept the cleanup option to remove installed packages, configuration files, created users, and firewall rules. Note that backup files (.bak) are preserved for recovery.

## License
This project is licensed under the GPL-3.0. See [LICENSE](LICENSE) for details.
