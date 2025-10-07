#!/bin/bash

# ====================================================================
#   Advanced Proxy Installer v6 by vitaz86
#   Продуманный интерактивный скрипт для безопасной установки и
#   переустановки Squid, Dante и Fail2ban на Ubuntu 22.04 и 24.04.
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

# --- Начало ---
clear
echo -e "${C_BLUE}=======================================================${C_RESET}"
echo -e "${C_BLUE}==   Advanced Proxy Installer v4 - vitaz86 ==${C_RESET}"
echo -e "${C_BLUE}=======================================================${C_RESET}"
echo
echo "Этот скрипт установит Squid, Dante и Fail2ban."

# --- Проверки системы ---
if ! isRoot; then echo -e "${C_RED}Ошибка: Запустите скрипт с правами root (sudo).${C_RESET}"; exit 1; fi
checkOS

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
    echo -e "\nВведите IP-адреса для белого списка (через пробел):"
    read -rp "Пример: 8.8.8.8 1.1.1.1: " -e WHITELIST_IPS
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
        USERS+=("$username")
    done
fi

echo -e "\nУкажите порты для прокси."
read -rp "Порт для Squid (HTTPS) [1-65535]: " -e -i 3128 SQUID_PORT
read -rp "Порт для Dante (SOCKS5) [1-65535]: " -e -i 1080 DANTE_PORT

echo -e "\nУстановить Unbound DNS resolver для ускорения DNS-запросов?"
read -p "(y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then INSTALL_UNBOUND=true; fi

echo -e "\n${C_GREEN}Отлично! Начинаем установку...${C_RESET}"
sleep 2

# --- Фаза 2: Установка и настройка ---
echo -e "\n${C_YELLOW}--- Шаг 2: Установка пакетов ---${C_RESET}"
apt-get update > /dev/null || { echo -e "${C_RED}Не удалось обновить списки пакетов.${C_RESET}"; exit 1; }
apt-get install -y squid dante-server apache2-utils fail2ban || { echo -e "${C_RED}Не удалось установить необходимые пакеты.${C_RESET}"; exit 1; }
if [ "$INSTALL_UNBOUND" = true ]; then
    apt-get install -y unbound || { echo -e "${C_RED}Не удалось установить unbound.${C_RESET}"; exit 1; }
fi
echo "Пакеты успешно установлены."
echo -e "\n${C_YELLOW}--- Шаг 2.5: Включение BBR (TCP Congestion Control) ---${C_RESET}"
echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
sysctl -p > /dev/null
echo "BBR успешно включен для улучшения производительности сети."

if [ ${#USERS[@]} -gt 0 ]; then
    echo -e "\n${C_YELLOW}--- Шаг 3: Создание пользователей и паролей ---${C_RESET}"
    FIRST_USER=true
    for user in "${USERS[@]}"; do
        echo "-> Настройка пользователя '$user'..."
        useradd -r -s /bin/false "$user"
        echo "   - Задайте пароль для Dante (SOCKS5):"
        passwd "$user"
        echo "   - Повторно введите пароль для Squid (HTTPS):"
        if [ "$FIRST_USER" = true ]; then htpasswd -c /etc/squid/passwd "$user"; FIRST_USER=false; else htpasswd /etc/squid/passwd "$user"; fi
    done
fi

echo -e "\n${C_YELLOW}--- Шаг 4: Настройка конфигураций ---${C_RESET}"
SQUID_CONF="/etc/squid/squid.conf"
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

DANTE_CONF="/etc/danted.conf"
EXTERNAL_INTERFACE=$(ip route get 8.8.8.8 | awk -- '{printf $5}')
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

echo -e "\n${C_YELLOW}--- Шаг 5: Перезапуск служб ---${C_RESET}"
if ! systemctl restart squid || ! systemctl enable squid; then
    echo -e "${C_RED}Не удалось перезапустить или включить службу squid.${C_RESET}"
    exit 1
fi
if ! systemctl restart danted || ! systemctl enable danted; then
    echo -e "${C_RED}Не удалось перезапустить или включить службу danted.${C_RESET}"
    exit 1
fi
if ! systemctl restart fail2ban || ! systemctl enable fail2ban; then
    echo -e "${C_RED}Не удалось перезапустить или включить службу fail2ban.${C_RESET}"
    exit 1
fi
if [ "$INSTALL_UNBOUND" = true ]; then
    if ! systemctl restart unbound || ! systemctl enable unbound; then
        echo -e "${C_RED}Не удалось перезапустить или включить службу unbound.${C_RESET}"
        exit 1
    fi
    echo "Unbound DNS resolver успешно установлен и запущен."
fi
echo "Службы успешно перезапущены и добавлены в автозагрузку."

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
