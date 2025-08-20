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
   The script installs the necessary packages (`squid`, `dante-server`, `apache2-utils`, `fail2ban`) and guides you through configuration.

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
