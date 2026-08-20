# Proxy-Installer

Интерактивный Bash-скрипт для установки и настройки прямого HTTP/HTTPS-прокси (Squid, метод CONNECT) и SOCKS5-прокси (Dante) с доступом по паролю и/или белому списку IP на Debian и Ubuntu.

## Возможности
- Debian 11+ / Ubuntu 20.04+ и производные (Linux Mint, Pop!_OS и другие системы с apt)
- Устанавливает Squid (HTTP CONNECT) и Dante (SOCKS5) с защитой Fail2ban
- Опциональный Unbound DNS **только на 127.0.0.1** (для Squid, без публикации резолвера в интернет)
- Опциональный тюнинг BBR/sysctl через `/etc/sysctl.d/` (без дублирования строк в `sysctl.conf`; пропускается, если ядро не поддерживает)
- Интерактивный мастер с проверкой режима доступа, пользователей, IPv4/IPv6/CIDR и портов
- Проверки системы: интернет (ICMP не обязателен), диск, ОС, занятые порты, порт SSH
- Настройка firewall: **сначала всегда разрешается SSH** (UFW или уже активный firewalld)
- Не перезаписывает существующий `jail.local` Fail2ban — добавляется отдельный drop-in
- Запоминает созданных пользователей прокси, повторно вводить их для очистки не нужно
- Резервные копии конфигураций перед перезаписью
- При повторном запуске: полная очистка или только обновление конфигурации

## Требования
- Debian 11+, Ubuntu 20.04+ или производный дистрибутив
- Права root
- Интерактивный терминал (не передавайте скрипт в bash через конвейер)

## Установка
Скрипт устанавливает пакеты (`squid`, `dante-server`, `apache2-utils`, `fail2ban`, `ufw`) и опционально `unbound`, затем проводит через настройку.

1. Скачайте скрипт или клонируйте репозиторий:
   ```bash
   curl -O https://raw.githubusercontent.com/vitaz86/Proxy-Installer/refs/heads/main/proxy-installer.sh
   ```
   или
   ```bash
   wget https://raw.githubusercontent.com/vitaz86/Proxy-Installer/refs/heads/main/proxy-installer.sh
   ```
   или
   ```bash
   git clone https://github.com/vitaz86/Proxy-Installer.git
   cd Proxy-Installer
   ```
2. Сделайте скрипт исполняемым, если нужно:
   ```bash
   chmod +x proxy-installer.sh
   ```
3. Запустите установщик:
   ```bash
   sudo ./proxy-installer.sh
   ```

**Не** передавайте установщик в bash через конвейер. Меню требуют TTY:
```bash
# ПЛОХО
curl -fsSL https://raw.githubusercontent.com/vitaz86/Proxy-Installer/refs/heads/main/proxy-installer.sh | sudo bash
```

Проверка синтаксиса (без root и без установки):
```bash
bash proxy-installer.sh --selftest
```

## Использование
Следуйте подсказкам:
- Режим доступа (гибридный, только пароль или только белый список IP)
- Адреса белого списка (IPv4, IPv6 или CIDR, например `192.168.1.0/24`)
- Пользователи и пароли (Dante — системный пароль, Squid — `/etc/squid/passwd`)
- Порты Squid и Dante
- Опционально Unbound и сетевые оптимизации
- Опционально включение UFW (порт SSH разрешается до включения)

После завершения выводятся данные подключения. Повторный запуск предлагает полную очистку или перезапись конфигурации.

## Устранение неполадок
- При сетевых ошибках проверьте исходящий HTTPS (пинг ICMP не обязателен).
- Логи: `/var/log/squid/access.log`, `/var/log/danted.log`, `/var/log/fail2ban.log`
- Статус служб: `sudo systemctl status squid danted fail2ban unbound`
- Firewall: `sudo ufw status` (копия правил: `/etc/ufw/ufw.rules.backup`) или `sudo firewall-cmd --list-ports`
- Проверка конфига Squid: `sudo squid -k parse`
- Состояние установщика (порты и пользователи): `/etc/proxy-installer/`
- Squid — это **прямой прокси** (HTTP CONNECT), он не перехватывает TLS.

## Кастомизация
- Перезапустите скрипт, чтобы сменить режим доступа или порты.
- Ручная настройка — в сгенерированных файлах (сохраняются копии `.bak.*` с меткой времени):
  - `/etc/squid/squid.conf`
  - `/etc/danted.conf`
  - `/etc/fail2ban/jail.d/proxy-installer.local`
  - `/etc/fail2ban/filter.d/dante-proxy-installer.conf`
  - `/etc/sysctl.d/99-proxy-installer.conf`
- После ручных правок:
  ```bash
  sudo systemctl restart squid danted fail2ban
  ```

## Деинсталляция
Запустите установщик снова и выберите полную очистку. Удаляются учётные записи прокси, конфиги пакетов, drop-in sysctl/Unbound и правила firewall для портов прокси. Ранее установленный Fail2ban не снимается. Файлы `.bak.*` сохраняются.

## Лицензия
Этот проект лицензирован под GPL-3.0. См. [LICENSE](LICENSE) для деталей.
