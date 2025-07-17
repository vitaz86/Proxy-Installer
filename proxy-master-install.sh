#!/bin/bash

# ====================================================================
#   Proxy Master Installer by Vitaz86
#   Интерактивный скрипт для безопасной установки и настройки
#   Squid, Dante и Fail2ban на Ubuntu 24.04.
# ====================================================================

# --- Цвета для вывода ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_BLUE='\033[0;34m'
C_YELLOW='\033[1;33m'

# --- Функции проверки ---
function isRoot() {
	if [ "$EUID" -ne 0 ]; then
		return 1
	fi
}

function checkOS() {
	source /etc/os-release
	if [[ "$ID" != "ubuntu" || "$VERSION_ID" != "24.04" ]]; then
		echo -e "${C_RED}Ошибка: Этот скрипт предназначен только для Ubuntu 24.04.${C_RESET}"
		echo "У вас $PRETTY_NAME. Установка прервана."
		exit 1
	fi
}

# --- Основная логика ---

clear
echo -e "${C_BLUE}=======================================================${C_RESET}"
echo -e "${C_BLUE}==   Proxy Master Installer - Установщик Прокси    ==${C_RESET}"
echo -e "${C_BLUE}=======================================================${C_RESET}"
echo
echo "Этот скрипт поможет вам установить и безопасно настроить:"
echo "  • HTTPS прокси (Squid)"
echo "  • SOCKS5 прокси (Dante)"
echo "  • Защиту от атак (Fail2ban)"
echo
read -n1 -r -p "Нажмите любую клавишу, чтобы начать, или Ctrl+C для отмены..."
echo
echo

# --- Проверки ---
if ! isRoot; then
	echo -e "${C_RED}Ошибка: Пожалуйста, запустите этот скрипт от имени root (sudo ./script.sh).${C_RESET}"
	exit 1
fi
checkOS

# --- Сбор данных от пользователя ---
echo -e "${C_YELLOW}--- Шаг 1: Сбор информации ---${C_RESET}"

# Выбор режима аутентификации
PS3="Выберите режим аутентификации (цифру): "
select AUTH_MODE in "Пароль + Белый список IP (Гибрид)" "Только Пароль" "Только Белый список IP"; do
    case $REPLY in
        1|2|3) break;;
        *) echo "Неверный выбор. Пожалуйста, введите 1, 2 или 3.";;
    esac
done

# Сбор IP для белого списка
if [[ "$AUTH_MODE" == *"Белый список IP"* ]]; then
    echo "Введите IP-адреса для белого списка, разделяя их пробелом."
    read -rp "Пример: 8.8.8.8 1.1.1.1: " -e WHITELIST_IPS
fi

# Сбор пользователей и паролей
USERS=()
if [[ "$AUTH_MODE" == *"Пароль"* ]]; then
    echo "Теперь добавим пользователей. Оставьте имя пустым, чтобы закончить."
    while true; do
        read -rp "Введите имя пользователя: " username
        if [ -z "$username" ]; then
            break
        fi
        USERS+=("$username")
    done
fi

read -rp "Введите порт для Squid (HTTPS) [1-65535]: " -e -i 3128 SQUID_PORT
read -rp "Введите порт для Dante (SOCKS5) [1-65535]: " -e -i 1080 DANTE_PORT

echo
echo -e "${C_GREEN}Информация собрана. Начинаем установку...${C_RESET}"
echo

# --- Установка и настройка ---

# Пакеты
echo -e "${C_YELLOW}--- Шаг 2: Установка пакетов ---${C_RESET}"
apt-get update > /dev/null
apt-get install -y squid dante-server apache2-utils fail2ban
echo "Пакеты установлены."
echo

# Пользователи и пароли
if [ ${#USERS[@]} -gt 0 ]; then
    echo -e "${C_YELLOW}--- Шаг 3: Создание пользователей и паролей ---${C_RESET}"
    FIRST_USER=true
    for user in "${USERS[@]}"; do
        echo "-> Создание пользователя '$user'..."
        # Системный пользователь для Dante
        if ! id "$user" &>/dev/null; then
            useradd -r -s /bin/false "$user"
        fi
        echo "Задайте пароль для Dante для пользователя '$user':"
        passwd "$user"

        # Пользователь htpasswd для Squid
        echo "Повторите пароль для Squid для пользователя '$user':"
        if [ "$FIRST_USER" = true ]; then
            htpasswd -c /etc/squid/passwd "$user"
            FIRST_USER=false
        else
            htpasswd /etc/squid/passwd "$user"
        fi
    done
    echo "Пользователи и пароли настроены."
    echo
fi

# Конфигурация Squid
echo -e "${C_YELLOW}--- Шаг 4: Настройка Squid ---${C_RESET}"
SQUID_CONF="/etc/squid/squid.conf"
mv $SQUID_CONF ${SQUID_CONF}.bak

echo "# Konfiguratsiya Squid" > $SQUID_CONF
if [[ "$AUTH_MODE" == *"Пароль"* ]]; then
cat <<EOF >> $SQUID_CONF
auth_param basic program /usr/lib/squid/basic_ncsa_auth /etc/squid/passwd
auth_param basic realm "Squid Proxy"
acl authenticated proxy_auth REQUIRED
EOF
fi
if [[ "$AUTH_MODE" == *"Белый список IP"* ]]; then
    echo "acl whitelist src $WHITELIST_IPS" >> $SQUID_CONF
fi

cat <<EOF >> $SQUID_CONF

# Pravila dostupa
http_access allow localhost
EOF

if [ "$AUTH_MODE" == "Пароль + Белый список IP (Гибрид)" ]; then
    echo "http_access allow whitelist" >> $SQUID_CONF
    echo "http_access allow authenticated" >> $SQUID_CONF
elif [ "$AUTH_MODE" == "Только Пароль" ]; then
    echo "http_access allow authenticated" >> $SQUID_CONF
elif [ "$AUTH_MODE" == "Только Белый список IP" ]; then
    echo "http_access allow whitelist" >> $SQUID_CONF
fi
cat <<EOF >> $SQUID_CONF
http_access deny all

# Port i anonimnost
http_port $SQUID_PORT
via off
forwarded_for off
EOF
echo "Squid настроен."
echo

# Конфигурация Dante
echo -e "${C_YELLOW}--- Шаг 5: Настройка Dante ---${C_RESET}"
DANTE_CONF="/etc/danted.conf"
EXTERNAL_INTERFACE=$(ip route get 8.8.8.8 | awk -- '{printf $5}')
mv $DANTE_CONF ${DANTE_CONF}.bak

cat <<EOF > $DANTE_CONF
logoutput: /var/log/danted.log
internal: 0.0.0.0 port = $DANTE_PORT
external: $EXTERNAL_INTERFACE
user.privileged: root
user.notprivileged: nobody

# Pravila klienta
EOF

if [ "$AUTH_MODE" == "Пароль + Белый список IP (Гибрид)" ]; then
    for ip in $WHITELIST_IPS; do
        echo "client pass { from: $ip/32 to: 0.0.0.0/0 method: none }" >> $DANTE_CONF
    done
    echo "client pass { from: 0.0.0.0/0 to: 0.0.0.0/0 method: username }" >> $DANTE_CONF
elif [ "$AUTH_MODE" == "Только Пароль" ]; then
    echo "client pass { from: 0.0.0.0/0 to: 0.0.0.0/0 method: username }" >> $DANTE_CONF
elif [ "$AUTH_MODE" == "Только Белый список IP" ]; then
    for ip in $WHITELIST_IPS; do
        echo "client pass { from: $ip/32 to: 0.0.0.0/0 method: none }" >> $DANTE_CONF
    done
fi
echo "client block { from: 0.0.0.0/0 to: 0.0.0.0/0 log: connect error }" >> $DANTE_CONF

cat <<EOF >> $DANTE_CONF

# Pravila dlya ustanovlennyh soedineniy
pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    command: bind connect udpassociate
    log: error
}
EOF
echo "Dante настроен."
echo

# Конфигурация Fail2ban
echo -e "${C_YELLOW}--- Шаг 6: Настройка Fail2ban ---${C_RESET}"
cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local

cat <<EOF > /etc/fail2ban/filter.d/squid.conf
[Definition]
failregex = ^\s*\d+\.\d+\s+\d+\s+<HOST>\s+TCP_DENIED/\d+
EOF

cat <<EOF > /etc/fail2ban/filter.d/dante.conf
[Definition]
failregex = pam_authenticate\(\): error in service \((\S+)\) getting password from user \((\S+)\) through <HOST>
EOF

cat <<EOF >> /etc/fail2ban/jail.local

[sshd]
enabled = true
maxretry = 3
bantime = 1h

[squid]
enabled = true
port    = $SQUID_PORT
logpath = /var/log/squid/access.log
maxretry = 5
bantime = 2h

[dante]
enabled = true
port    = $DANTE_PORT
logpath = /var/log/danted.log
maxretry = 5
bantime = 2h
EOF
echo "Fail2ban настроен."
echo

# --- Перезапуск служб ---
echo -e "${C_YELLOW}--- Шаг 7: Перезапуск служб ---${C_RESET}"
systemctl restart squid > /dev/null
systemctl enable squid > /dev/null
systemctl restart danted > /dev/null
systemctl enable danted > /dev/null
systemctl restart fail2ban > /dev/null
systemctl enable fail2ban > /dev/null
echo "Службы перезапущены и добавлены в автозагрузку."
echo

# --- Итоги ---
SERVER_IP=$(hostname -I | awk '{print $1}')
clear
echo -e "${C_GREEN}=======================================================${C_RESET}"
echo -e "${C_GREEN}🎉 Установка и настройка успешно завершены! 🎉${C_RESET}"
echo -e "${C_GREEN}=======================================================${C_RESET}"
echo
echo "Данные для подключения к вашим прокси-серверам:"
echo "  ${C_BLUE}IP-адрес сервера:${C_RESET}  ${SERVER_IP}"
echo
echo -e "  ${C_YELLOW}HTTPS Прокси (Squid):${C_RESET}"
echo "    Порт: $SQUID_PORT"
echo
echo -e "  ${C_YELLOW}SOCKS5 Прокси (Dante):${C_RESET}"
echo "    Порт: $DANTE_PORT"
echo
echo -e "  ${C_YELLOW}Метод доступа:${C_RESET} $AUTH_MODE"

if [ ${#USERS[@]} -gt 0 ]; then
    echo -e "  ${C_YELLOW}Пользователи:${C_RESET} ${USERS[*]}"
fi
if [[ -n "$WHITELIST_IPS" ]]; then
    echo -e "  ${C_YELLOW}Белый список IP:${C_RESET} $WHITELIST_IPS"
fi
echo
echo "Проверить статус служб можно командами:"
echo "  'sudo systemctl status squid'"
echo "  'sudo systemctl status danted'"
echo "  'sudo fail2ban-client status'"
echo
echo -e "${C_GREEN}=======================================================${C_RESET}"