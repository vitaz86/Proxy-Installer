# Proxy-Installer

An interactive Bash script for installing and configuring an HTTPS proxy (Squid) and a SOCKS5 proxy (Dante) with Fail2ban protection on Ubuntu 22.04 and 24.04.

## Features
- Supports Ubuntu 22.04 LTS and 24.04 LTS
- Installs Squid (HTTPS) and Dante (SOCKS5)
- Automatically configures Fail2ban rules for both proxies
- Interactive wizard for authentication mode, user creation, IP whitelisting and custom ports
- Optional cleanup of previous installations

## Requirements
- Ubuntu 22.04 LTS or 24.04 LTS
- Root privileges

## Installation
The script installs the necessary packages (`squid`, `dante-server`, `apache2-utils`, `fail2ban`) and guides you through configuration.

### Installation Method 1 (fast)
These command download and stream the installer directly into bash and execute it in one step.
   ```bash
   wget -qO- https://raw.githubusercontent.com/vitaz86/Proxy-Installer/refs/heads/main/proxy-installer.sh | sudo bash
   ```

### Installation Method 2 (fast)
These command stream the installer directly into bash and execute it in one step.
   ```bash
   curl -fsSL https://raw.githubusercontent.com/vitaz86/Proxy-Installer/refs/heads/main/proxy-installer.sh | sudo bash
   ```

### Installation Method 3 (reviewing before run)
For safety, consider reviewing the script before piping it into bash.
These commands cloning the repo and running the script from disk.
1. Clone the repository:
   ```bash
   git clone https://github.com/vitaz86/Proxy-Installer.git
   ```
2. Enter the directory:
   ```bash
   cd Proxy-Installer
   ```
3. Make the script executable if needed:
   ```bash
   chmod +x proxy-installer.sh
   ```
4. Run the installer:
   ```bash
   sudo ./proxy-installer.sh
   ```

### Installation Method 4 (reviewing before run)
1. Download the script:
   ```bash
   wget https://raw.githubusercontent.com/vitaz86/Proxy-Installer/refs/heads/main/proxy-installer.sh
   ```
2. Make the script executable if needed:
   ```bash
   chmod +x proxy-installer.sh
   ```
3. Run the installer:
   ```bash
   sudo ./proxy-installer.sh
   ```

To review the script run:
   ```bash
   nano proxy-installer.sh
   ```

## Usage
Follow the prompts to:
- choose the authentication mode (hybrid, password only or IP whitelist only)
- add whitelisted IP addresses
- create users and set passwords
- select ports for Squid and Dante

After completion, the script displays the connection details for the configured proxies. Running the script again detects existing installations and offers to perform a full cleanup before reinstalling.

## Customization
- Rerun the script to change authentication settings or ports.
- Manual tuning can be done in the generated configuration files:
  - `/etc/squid/squid.conf`
  - `/etc/danted.conf`
  - `/etc/fail2ban/jail.local`
- Restart the services after manual changes:
  ```bash
  sudo systemctl restart squid danted fail2ban
  ```

## Uninstall
Run the installer again and accept the cleanup option to remove installed packages, configuration files and created users.

## License
This project is licensed under the GPL-3.0. See [LICENSE](LICENSE) for details.
