#!/bin/bash

# ====================================================================
#   Advanced Proxy Installer v7 by vitaz86
#   Интерактивный скрипт для безопасной установки Прокси на Ubuntu 22.04 и 24.04.
# ====================================================================

# --- Цвета для красивого вывода ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_BLUE='\033[0;34m'
C_YELLOW='\033[1;33m'

# --- Функции ---
function isRoot() { if [ "$EUID" -ne 0 ]; then return 1; fi; }
function checkOS() {
        source /etc/os-release
        if [[ "$ID" != "ubuntu" || ( "$VERSION_ID" != "22.04" && "$VERSION_ID" != "24.04" ) ]]; then
                echo -e "${C_RED}Ошибка: Этот скрипт предназначен только для Ubuntu 22.04/24.04.${C_RESET}"
                exit 1
        fi
}

function cleanup() {
    echo -e "\n${C_YELLOW}--- Начало полной очистки предыдущей установки ---${C_RESET}"
    # Остановка и отключение служб
    systemctl stop squid danted fail2ban &>/dev/null
    systemctl disable squid danted fail2ban &>/dev/null
    echo "Службы остановлены."

    # Полное удаление пакетов вместе с конфигурациями
    apt-get purge -y squid dante-server apache2-utils fail2ban unbound &>/dev/null
    apt-get autoremove -y &>/dev/null
    echo "Пакеты и конфигурации удалены."

    # Удаление пользователей, если они существуют
    for user in "${USERS_TO_DELETE[@]}"; do
        if id "$user" &>/dev/null; then
            userdel -r "$user" &>/dev/null
            echo "Пользователь '$user' удален."
        fi
    done

    # Удаление оставшихся файлов
    rm -f /etc/squid/passwd
    rm -f /etc/fail2ban/jail.local
    rm -f /etc/fail2ban/filter.d/dante.conf
    echo "Оставшиеся файлы конфигурации удалены."
    echo -e "${C_GREEN}Очистка завершена.${C_RESET}"
    sleep 2
}

function validate_port() {
    local port=$1
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${C_RED}Ошибка: Порт должен быть числом от 1 до 65535.${C_RESET}"
        return 1
    fi
    return 0
}

function validate_username() {
    local username=$1
    if ! [[ "$username" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo -e "${C_RED}Ошибка: Имя пользователя может содержать только буквы, цифры, дефисы и подчеркивания.${C_RESET}"
        return 1
    fi
    return 0
}

function validate_ip() {
    local ip=$1
    if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(:[0-9]{1,5})?$ ]] && ! [[ "$ip" =~ ^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$ ]]; then
        echo -e "${C_RED}Ошибка: Неверный формат IP-адреса.${C_RESET}"
        return 1
    fi
    return 0
}

function validate_ips() {
    local ips=$1
    for ip in $ips; do
        if ! validate_ip "$ip"; then
            return 1
        fi
    done
    return 0
}

function detect_resources() {
    CPU_CORES=$(nproc)
    RAM_GB=$(free -g | awk 'NR==2{printf "%.0f", $2}')
    DISK_GB=$(df / | tail -1 | awk '{printf "%.0f", $2/1024/1024}')

    echo "Detected resources: $CPU_CORES CPU cores, $RAM_GB GB RAM, $DISK_GB GB disk"

    if [ "$CPU_CORES" -le 2 ] || [ "$RAM_GB" -le 2 ]; then
        LOW_RESOURCE=true
        echo "Low-resource VPS detected, using optimized low-resource configs."
    else
        LOW_RESOURCE=false
        echo "High-resource system detected, using full optimization configs."
    fi
}

function install_packages() {
    echo -e "\n${C_YELLOW}--- Шаг 2: Установка пакетов ---${C_RESET}"
    apt-get update -qq -o Acquire::Retries=3 || { echo -e "${C_RED}Не удалось обновить списки пакетов.${C_RESET}"; exit 1; }
    apt-get install -y -qq squid dante-server apache2-utils fail2ban || { echo -e "${C_RED}Не удалось установить необходимые пакеты.${C_RESET}"; exit 1; }
    if [ "$INSTALL_UNBOUND" = true ]; then
        apt-get install -y -qq unbound || { echo -e "${C_RED}Не удалось установить unbound.${C_RESET}"; exit 1; }
    fi
    echo "Пакеты успешно установлены."

    echo -e "\n${C_YELLOW}--- Шаг 2.5: Применение комплексной оптимизации системы ---${C_RESET}"
    detect_resources
    if [ "$LOW_RESOURCE" = true ] && [ -f "system-tune-low.sh" ]; then
        chmod +x system-tune-low.sh
        ./system-tune-low.sh
    elif [ -f "system-tune.sh" ]; then
        chmod +x system-tune.sh
        ./system-tune.sh
    else
        echo "system-tune.sh not found, applying basic optimizations..."
        echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
        echo "net.core.somaxconn = 65536" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_max_syn_backlog = 65536" >> /etc/sysctl.conf
        echo "net.ipv4.ip_local_port_range = 1024 65535" >> /etc/sysctl.conf
        echo "net.core.netdev_max_backlog = 5000" >> /etc/sysctl.conf
        sysctl -p > /dev/null
    fi
    echo "Оптимизация системы успешно применена."
}

function configure_services() {
    echo -e "\n${C_YELLOW}--- Шаг 4: Настройка конфигураций ---${C_RESET}"
    SQUID_CONF="/etc/squid/squid.conf"
    DANTE_CONF="/etc/danted.conf"
    JAIL_LOCAL="/etc/fail2ban/jail.local"
    DANTE_FILTER="/etc/fail2ban/filter.d/dante.conf"

    # Резервное копирование существующих конфигов
    if [ -f "$SQUID_CONF" ]; then cp "$SQUID_CONF" "$SQUID_CONF.bak"; fi
    if [ -f "$DANTE_CONF" ]; then cp "$DANTE_CONF" "$DANTE_CONF.bak"; fi
    if [ -f "$JAIL_LOCAL" ]; then cp "$JAIL_LOCAL" "$JAIL_LOCAL.bak"; fi
    if [ -f "$DANTE_FILTER" ]; then cp "$DANTE_FILTER" "$DANTE_FILTER.bak"; fi

    if [ "$LOW_RESOURCE" = true ] && [ -f "squid-low.conf" ]; then
        CONFIG_FILE="squid-low.conf"
    elif [ -f "squid.conf" ]; then
        CONFIG_FILE="squid.conf"
    else
        CONFIG_FILE=""
    fi

    if [ -n "$CONFIG_FILE" ]; then
        cp $CONFIG_FILE $SQUID_CONF
        # Customize based on user choices
        sed -i "s/http_port 3128/http_port $SQUID_PORT/" $SQUID_CONF
        if [ "$INSTALL_UNBOUND" = true ]; then
            echo "dns_nameservers 127.0.0.1" >> $SQUID_CONF
        fi
        # Add authentication and access rules
        if [[ "$AUTH_CHOICE" == "1" || "$AUTH_CHOICE" == "2" ]]; then
            sed -i 's/# auth_param basic program /usr/lib/squid/basic_ncsa_auth /etc/squid/passwd/auth_param basic program /usr/lib/squid/basic_ncsa_auth /etc/squid/passwd/' $SQUID_CONF
            sed -i 's/# auth_param basic realm "Squid Proxy"/auth_param basic realm "Squid Proxy"/' $SQUID_CONF
            sed -i 's/# acl authenticated proxy_auth REQUIRED/acl authenticated proxy_auth REQUIRED/' $SQUID_CONF
        fi
        if [[ "$AUTH_CHOICE" == "1" || "$AUTH_CHOICE" == "3" ]]; then
            sed -i "s/# acl whitelist src 192.168.1.0\/24/acl whitelist src $WHITELIST_IPS/" $SQUID_CONF
        fi
        # Update access rules
        sed -i 's/# http_access allow whitelist/http_access allow whitelist/' $SQUID_CONF
        sed -i 's/# http_access allow authenticated/http_access allow authenticated/' $SQUID_CONF
        if [[ "$AUTH_CHOICE" == "1" ]]; then
            sed -i 's/http_access allow whitelist/http_access allow whitelist/' $SQUID_CONF
            sed -i 's/http_access allow authenticated/http_access allow authenticated/' $SQUID_CONF
        elif [[ "$AUTH_CHOICE" == "2" ]]; then
            sed -i 's/http_access allow authenticated/http_access allow authenticated/' $SQUID_CONF
        elif [[ "$AUTH_CHOICE" == "3" ]]; then
            sed -i 's/http_access allow whitelist/http_access allow whitelist/' $SQUID_CONF
        fi
    else
        # Fallback to original generation
        {
            if [[ "$AUTH_CHOICE" == "1" || "$AUTH_CHOICE" == "2" ]]; then
                echo "auth_param basic program /usr/lib/squid/basic_ncsa_auth /etc/squid/passwd"; echo "auth_param basic realm \"Squid Proxy\""; echo "acl authenticated proxy_auth REQUIRED";
            fi
            if [[ "$AUTH_CHOICE" == "1" || "$AUTH_CHOICE" == "3" ]]; then echo "acl whitelist src $WHITELIST_IPS"; fi
            echo -e "\nhttp_access allow localhost"
            if [[ "$AUTH_CHOICE" == "1" ]]; then echo "http_access allow whitelist"; echo "http_access allow authenticated";
            elif [[ "$AUTH_CHOICE" == "2" ]]; then echo "http_access allow authenticated";
            elif [[ "$AUTH_CHOICE" == "3" ]]; then echo "http_access allow whitelist"; fi
            echo "http_access deny all"; echo -e "\nhttp_port $SQUID_PORT"; echo "via off"; echo "forwarded_for off";
            if [ "$INSTALL_UNBOUND" = true ]; then echo "dns_nameservers 127.0.0.1"; fi
        } > $SQUID_CONF
    fi

    EXTERNAL_INTERFACE=$(ip route get 8.8.8.8 | awk -- '{printf $5}')
    if [ -z "$EXTERNAL_INTERFACE" ]; then
        echo -e "${C_RED}Ошибка: Не удалось определить внешний сетевой интерфейс. Проверьте подключение к интернету.${C_RESET}"
        exit 1
    fi
    if [ "$LOW_RESOURCE" = true ] && [ -f "danted-low.conf" ]; then
        CONFIG_FILE="danted-low.conf"
    elif [ -f "danted.conf" ]; then
        CONFIG_FILE="danted.conf"
    else
        CONFIG_FILE=""
    fi

    if [ -n "$CONFIG_FILE" ]; then
        cp $CONFIG_FILE $DANTE_CONF
        # Customize
        sed -i "s/port = 1080/port = $DANTE_PORT/" $DANTE_CONF
        sed -i "s/external: eth0/external: $EXTERNAL_INTERFACE/" $DANTE_CONF
        if [ "$INSTALL_UNBOUND" = true ]; then
            sed -i 's/# resolve { nameserver 127.0.0.1 }/resolve { nameserver 127.0.0.1 }/' $DANTE_CONF
        fi
        # Update rules based on auth choice
        if [[ "$AUTH_CHOICE" == "1" ]]; then
            # Add whitelist rules
            for ip in $WHITELIST_IPS; do
                sed -i "/client pass { from: 0.0.0.0\/0 to: 0.0.0.0\/0 method: none }/i client pass { from: $ip/32 to: 0.0.0.0/0 method: none }" $DANTE_CONF
            done
            sed -i 's/client pass { from: 0.0.0.0\/0 to: 0.0.0.0\/0 method: none }/client pass { from: 0.0.0.0\/0 to: 0.0.0.0\/0 method: username log: error }/' $DANTE_CONF
        elif [[ "$AUTH_CHOICE" == "2" ]]; then
            sed -i 's/client pass { from: 0.0.0.0\/0 to: 0.0.0.0\/0 method: none }/client pass { from: 0.0.0.0\/0 to: 0.0.0.0\/0 method: username log: error }/' $DANTE_CONF
        elif [[ "$AUTH_CHOICE" == "3" ]]; then
            # Add whitelist rules
            for ip in $WHITELIST_IPS; do
                sed -i "/client pass { from: 0.0.0.0\/0 to: 0.0.0.0\/0 method: none }/i client pass { from: $ip/32 to: 0.0.0.0/0 method: none }" $DANTE_CONF
            done
        fi
    else
        # Fallback
        {
            echo "logoutput: /var/log/danted.log"; echo "internal: 0.0.0.0 port = $DANTE_PORT";
            echo "external: $EXTERNAL_INTERFACE"; echo "user.privileged: root"; echo "user.notprivileged: nobody";
            if [ "$INSTALL_UNBOUND" = true ]; then echo -e "\nresolve { nameserver 127.0.0.1 }"; fi
            echo -e "\n# Rules"
            if [[ "$AUTH_CHOICE" == "1" ]]; then
                for ip in $WHITELIST_IPS; do echo "client pass { from: $ip/32 to: 0.0.0.0/0 method: none }"; done
                echo "client pass { from: 0.0.0.0/0 to: 0.0.0.0/0 method: username log: error }";
            elif [[ "$AUTH_CHOICE" == "2" ]]; then echo "client pass { from: 0.0.0.0/0 to: 0.0.0.0/0 method: username log: error }";
            elif [[ "$AUTH_CHOICE" == "3" ]]; then
                for ip in $WHITELIST_IPS; do echo "client pass { from: $ip/32 to: 0.0.0.0/0 method: none }"; done
            fi
            echo "client block { from: 0.0.0.0/0 to: 0.0.0.0/0 log: connect error }";
            echo -e "\npass { from: 0.0.0.0/0 to: 0.0.0.0/0 command: bind connect udpassociate log: error }";
        } > $DANTE_CONF
    fi

    {
        echo "[DEFAULT]"; echo "bantime = 1h"; echo;
        echo "[sshd]"; echo "enabled = true"; echo "maxretry = 3"; echo;
        echo "[squid]"; echo "enabled = true"; echo "port = $SQUID_PORT"; echo "logpath = /var/log/squid/access.log"; echo "bantime = 2h"; echo;
        echo "[dante]"; echo "enabled = true"; echo "port = $DANTE_PORT"; echo "logpath = /var/log/danted.log"; echo "bantime = 2h";
    } > /etc/fail2ban/jail.local
    cat <<EOF > /etc/fail2ban/filter.d/dante.conf
[Definition]
failregex = pam_authenticate\(\): error in service \((\S+)\) getting password from user \((\S+)\) through <HOST>
EOF
    echo "Файлы конфигурации созданы."
}

function setup_firewall() {
    echo -e "\n${C_YELLOW}--- Настройка firewall ---${C_RESET}"

    # Проверка установки
    if ! dpkg -s ufw &>/dev/null; then
        apt-get install -y ufw &>/dev/null || { echo -e "${C_RED}Не удалось установить ufw.${C_RESET}"; exit 1; }
    fi

    # Проверка конфликтов с другими firewall
    if systemctl is-active firewalld --quiet 2>/dev/null; then
        echo -e "${C_YELLOW}Предупреждение: Обнаружен firewalld. UFW может конфликтовать. Рекомендуется отключить firewalld.${C_RESET}"
        read -p "Продолжить? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then exit 0; fi
    fi

    # Резервное копирование правил
    ufw status numbered > /etc/ufw/ufw.rules.backup 2>/dev/null || true

    # Добавление правил
    ufw allow $SQUID_PORT/tcp &>/dev/null
    ufw allow $DANTE_PORT/tcp &>/dev/null

    # Включение, если не активно
    if ! ufw status | grep -q "Status: active"; then
        ufw --force enable &>/dev/null
    else
        ufw reload &>/dev/null  # Перезагрузка правил
    fi

    echo "Firewall настроен."
}

function restart_services() {
    echo -e "\n${C_YELLOW}--- Шаг 5: Перезапуск служб ---${C_RESET}"
    if ! systemctl restart squid || ! systemctl enable squid || ! systemctl is-active squid --quiet; then
        echo -e "${C_RED}Не удалось перезапустить или включить службу squid.${C_RESET}"
        exit 1
    fi
    if ! systemctl restart danted || ! systemctl enable danted || ! systemctl is-active danted --quiet; then
        echo -e "${C_RED}Не удалось перезапустить или включить службу danted.${C_RESET}"
        exit 1
    fi
    if ! systemctl restart fail2ban || ! systemctl enable fail2ban || ! systemctl is-active fail2ban --quiet; then
        echo -e "${C_RED}Не удалось перезапустить или включить службу fail2ban.${C_RESET}"
        exit 1
    fi
    if [ "$INSTALL_UNBOUND" = true ]; then
        if ! systemctl restart unbound || ! systemctl enable unbound || ! systemctl is-active unbound --quiet; then
            echo -e "${C_RED}Не удалось перезапустить или включить службу unbound.${C_RESET}"
            exit 1
        fi
        echo "Unbound DNS resolver успешно установлен и запущен."
    fi
    echo "Службы успешно перезапущены и добавлены в автозагрузку."

    setup_firewall
}

# --- Начало ---
clear
echo -e "${C_BLUE}=======================================================${C_RESET}"
echo -e "${C_BLUE}==   Advanced Proxy Installer - vitaz86 ==${C_RESET}"
echo -e "${C_BLUE}=======================================================${C_RESET}"
echo
echo "Этот скрипт установит Squid, Dante и Fail2ban."

# --- Проверки системы ---
if ! isRoot; then echo -e "${C_RED}Ошибка: Запустите скрипт с правами root (sudo).${C_RESET}"; exit 1; fi
checkOS

# Проверка подключения к интернету
if ! ping -c 1 -W 5 8.8.8.8 &>/dev/null; then
    echo -e "${C_RED}Ошибка: Нет подключения к интернету.${C_RESET}"
    exit 1
fi

# Проверка свободного места на диске (минимум 500MB)
DISK_FREE=$(df / | tail -1 | awk '{print $4}')
if [ "$DISK_FREE" -lt 500000 ]; then
    echo -e "${C_RED}Ошибка: Недостаточно свободного места на диске (минимум 500MB).${C_RESET}"
    exit 1
fi

# --- Проверка и предложение очистки ---
if dpkg -s squid &>/dev/null || dpkg -s dante-server &>/dev/null; then
    echo -e "\n${C_YELLOW}Внимание! Обнаружена предыдущая установка Squid или Dante.${C_RESET}"
    echo "Чтобы гарантировать корректную работу, рекомендуется выполнить полную очистку."
    echo "Это удалит пакеты, старые конфигурации и пользователей, связанных с ними."
    read -p "Выполнить полную очистку и переустановку? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -e "\nВведите имена пользователей, созданных в прошлый раз, чтобы удалить их."
        read -rp "Можно несколько, через пробел: " USERS_TO_DELETE_INPUT
        IFS=' ' read -r -a USERS_TO_DELETE <<< "$USERS_TO_DELETE_INPUT"
        cleanup
    else
        echo -e "${C_RED}Установка прервана по вашему желанию.${C_RESET}"
        exit 0
    fi
fi

# --- Фаза 1: Сбор данных от пользователя ---
echo -e "\n${C_YELLOW}--- Шаг 1: Сбор информации для новой установки ---${C_RESET}"
# (Дальнейший код идентичен v3, так как он уже был исправлен и надежен)
echo "Выберите режим аутентификации для прокси-серверов."
PS3=$'\n'"Ваш выбор (введите цифру): "
select AUTH_MODE_TEXT in "Гибридный (пароль ИЛИ белый список IP)" "Только Пароль" "Только Белый список IP"; do
    AUTH_CHOICE=$REPLY
    case $AUTH_CHOICE in 1|2|3) break;; *) echo -e "${C_RED}Неверный выбор.${C_RESET}";; esac
done

WHITELIST_IPS=""
if [[ "$AUTH_CHOICE" == "1" || "$AUTH_CHOICE" == "3" ]]; then
    while true; do
        echo -e "\nВведите IP-адреса для белого списка (через пробел):"
        read -rp "Пример: 8.8.8.8 1.1.1.1: " -e WHITELIST_IPS
        if [[ "$AUTH_CHOICE" == "3" && -z "$WHITELIST_IPS" ]]; then
            echo -e "${C_RED}Для режима 'Только Белый список IP' требуется хотя бы один IP-адрес.${C_RESET}"
            continue
        fi
        if [ -n "$WHITELIST_IPS" ] && ! validate_ips "$WHITELIST_IPS"; then continue; fi
        break
    done
fi

USERS=()
if [[ "$AUTH_CHOICE" == "1" || "$AUTH_CHOICE" == "2" ]]; then
    echo -e "\nДобавьте пользователей. Оставьте имя пустым для завершения."
    while true; do
        read -rp "Имя пользователя: " username
        if [ -z "$username" ]; then
            if [ ${#USERS[@]} -eq 0 ]; then echo -e "${C_RED}Добавьте хотя бы одного пользователя.${C_RESET}"; continue; fi
            break
        fi
        if ! validate_username "$username"; then continue; fi
        USERS+=("$username")
    done
fi

echo -e "\nУкажите порты для прокси."
while true; do
    read -rp "Порт для Squid (HTTPS) [1-65535]: " -e -i 3128 SQUID_PORT
    if validate_port "$SQUID_PORT"; then break; fi
done
while true; do
    read -rp "Порт для Dante (SOCKS5) [1-65535]: " -e -i 1080 DANTE_PORT
    if validate_port "$DANTE_PORT"; then break; fi
done

echo -e "\nУстановить Unbound DNS resolver для ускорения DNS-запросов?"
read -p "(y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then INSTALL_UNBOUND=true; fi

echo -e "\n${C_GREEN}Отлично! Начинаем установку...${C_RESET}"
sleep 2

# --- Фаза 2: Установка и настройка ---
install_packages

if [ ${#USERS[@]} -gt 0 ]; then
    echo -e "\n${C_YELLOW}--- Шаг 3: Создание пользователей и паролей ---${C_RESET}"
    FIRST_USER=true
    for user in "${USERS[@]}"; do
        echo "-> Настройка пользователя '$user'..."
        if id "$user" &>/dev/null; then
            echo -e "${C_RED}Ошибка: Пользователь '$user' уже существует.${C_RESET}"
            exit 1
        fi
        if ! useradd -r -s /bin/false "$user"; then
            echo -e "${C_RED}Ошибка: Не удалось создать пользователя '$user'.${C_RESET}"
            exit 1
        fi
        echo "   - Задайте пароль для Dante (SOCKS5):"
        if ! passwd "$user"; then
            echo -e "${C_RED}Ошибка: Не удалось установить пароль для '$user'.${C_RESET}"
            exit 1
        fi
        echo "   - Повторно введите пароль для Squid (HTTPS):"
        if [ "$FIRST_USER" = true ]; then
            if ! htpasswd -c /etc/squid/passwd "$user"; then
                echo -e "${C_RED}Ошибка: Не удалось создать файл паролей Squid.${C_RESET}"
                exit 1
            fi
            FIRST_USER=false
        else
            if ! htpasswd /etc/squid/passwd "$user"; then
                echo -e "${C_RED}Ошибка: Не удалось добавить пользователя в файл паролей Squid.${C_RESET}"
                exit 1
            fi
        fi
    done
fi

configure_services

restart_services

# --- Итоги ---
SERVER_IP=$(hostname -I | awk '{print $1}')
clear
echo -e "${C_GREEN}=======================================================${C_RESET}"
echo -e "${C_GREEN}🎉 Установка и настройка успешно завершены! 🎉${C_RESET}"
echo -e "${C_GREEN}=======================================================${C_RESET}"
echo
echo "Данные для подключения к вашим прокси-серверам:"
echo -e "  ${C_BLUE}IP-адрес сервера:${C_RESET}  ${SERVER_IP}"
echo
echo -e "  ${C_YELLOW}HTTPS Прокси (Squid):${C_RESET}"; echo "    Порт: $SQUID_PORT"; echo
echo -e "  ${C_YELLOW}SOCKS5 Прокси (Dante):${C_RESET}"; echo "    Порт: $DANTE_PORT"; echo
echo -e "  ${C_YELLOW}Метод доступа:${C_RESET} $AUTH_MODE_TEXT"
if [ ${#USERS[@]} -gt 0 ]; then echo -e "  ${C_YELLOW}Пользователи:${C_RESET} ${USERS[*]}"; fi
if [[ -n "$WHITELIST_IPS" ]]; then echo -e "  ${C_YELLOW}Белый список IP:${C_RESET} $WHITELIST_IPS"; fi
if [ "$INSTALL_UNBOUND" = true ]; then echo -e "  ${C_YELLOW}Unbound DNS:${C_RESET} Установлен и запущен (127.0.0.1:53)"; fi
echo
echo -e "${C_GREEN}=======================================================${C_RESET}"
