#!/usr/bin/env bash
# ====================================================================
#   Advanced Proxy Installer by vitaz86
#   Interactive installer for Squid (HTTP/HTTPS forward proxy) and
#   Dante (SOCKS5) with optional IP whitelist, Fail2ban and Unbound.
#   Debian 13+ / Ubuntu 24.04+ and derivatives (Mint, Pop!_OS, etc.).
# ====================================================================

if [[ -z "${BASH_VERSION:-}" ]] || ((BASH_VERSINFO[0] < 4)); then
    echo "This script requires Bash 4 or newer." >&2
    exit 1
fi

set -o pipefail
umask 022
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE="${NEEDRESTART_MODE:-a}"

# --- Colors ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_BLUE='\033[0;34m'
C_YELLOW='\033[1;33m'
SCRIPT_VERSION="2026.10.28"

# --- State ---
STATE_DIR="/etc/proxy-installer"
STATE_FILE="${STATE_DIR}/state"
USERS_FILE="${STATE_DIR}/created-users"
SYSCTL_FILE="/etc/sysctl.d/99-proxy-installer.conf"
UNBOUND_DROPIN="/etc/unbound/unbound.conf.d/proxy-installer.conf"
FAIL2BAN_JAIL="/etc/fail2ban/jail.d/proxy-installer.local"
FAIL2BAN_FILTER="/etc/fail2ban/filter.d/dante-proxy-installer.conf"
FAIL2BAN_SQUID_FILTER="/etc/fail2ban/filter.d/squid-proxy-installer.conf"
DANTE_DROPIN="/etc/systemd/system/danted.service.d/proxy-installer.conf"
LOGROTATE_FILE="/etc/logrotate.d/danted-proxy-installer"
SQUID_PASSWD="/etc/squid/passwd"
SQUID_CONF="/etc/squid/squid.conf"
DANTE_CONF="/etc/danted.conf"
DANTE_LOG="/var/log/danted.log"
INSTALL_LOG="/var/log/proxy-installer.log"
INSTALL_LOG_READY=0
DANTE_APT_LIST="/etc/apt/sources.list.d/proxy-installer-dante.list"
DANTE_APT_PIN="/etc/apt/preferences.d/proxy-installer-dante"

INSTALL_UNBOUND=false
APPLY_OPTIMIZATIONS=false
ENABLE_UFW=false
AUTH_CHOICE=""
AUTH_MODE_TEXT=""
WHITELIST_IPS=""
SQUID_PORT=""
DANTE_PORT=""
EXTERNAL_INTERFACE=""
EXTERNAL_IPV4=""
SERVER_IP=""
SSH_PORTS=()
IPV6_ENABLED=false
SQUID_HELPER=""
PROXY_USER="proxy"
DANTE_NOPRIV_USER="nobody"
DANTE_NOPRIV_GROUP="nogroup"
NOLOGIN_SHELL="/usr/sbin/nologin"
OS_ID=""
OS_VERSION_ID=""
OS_LIKE=""
USERS=()
USERS_TO_DELETE=()

# ====================================================================
# Helpers
# ====================================================================

log_write() {
    local level="$1"
    shift
    [[ "$INSTALL_LOG_READY" == "1" ]] || return 0
    [[ -n "$INSTALL_LOG" ]] || return 0
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$level" "$*" >> "$INSTALL_LOG" || return 0
    if [[ "${EUID}" -eq 0 ]]; then
        chown root:root "$INSTALL_LOG" 2>/dev/null || true
        chmod 600 "$INSTALL_LOG" 2>/dev/null || true
    fi
}

log_ok()   { log_write OK "$*";   echo -e "${C_GREEN}[+]${C_RESET} $*"; }
log_info() { log_write INFO "$*"; echo -e "${C_BLUE}[*]${C_RESET} $*"; }
log_warn() { log_write WARN "$*"; echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
log_err()  { log_write ERROR "$*"; echo -e "${C_RED}[x]${C_RESET} $*" >&2; }

init_install_log() {
    local previous_umask
    previous_umask="$(umask)"
    umask 077
    touch "$INSTALL_LOG"
    umask "$previous_umask"
    if [[ "${EUID}" -eq 0 ]]; then
        chown root:root "$INSTALL_LOG" 2>/dev/null || true
        chmod 600 "$INSTALL_LOG"
    fi
    INSTALL_LOG_READY=1
    log_write SESSION "======== новая установка: запуск ${SCRIPT_VERSION}, pid $$ ========"
}

die() {
    log_err "$*"
    exit 1
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

is_root() { [[ "${EUID}" -eq 0 ]]; }

is_tty() { [[ -t 0 && -t 1 ]]; }

print_banner() {
    echo -e "${C_BLUE}=======================================================${C_RESET}"
    echo -e "${C_BLUE}==   Advanced Proxy Installer ${SCRIPT_VERSION} - vitaz86   ==${C_RESET}"
    echo -e "${C_BLUE}=======================================================${C_RESET}"
    echo
    echo "Установка Squid (HTTP/HTTPS CONNECT) и Dante (SOCKS5)"
    echo "на Debian 13+ и Ubuntu 24.04+."
    echo "Меню: установка, переустановка и удаление отдельных частей."
    echo
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-}"
    local reply hint="y/n"

    case "$default" in
        y|Y) hint="Y/n" ;;
        n|N) hint="y/N" ;;
    esac

    while true; do
        read -r -p "${prompt} (${hint}): " reply || return 1
        reply="${reply:-$default}"
        reply="${reply,,}"
        case "$reply" in
            y|yes|д|да) return 0 ;;
            n|no|н|нет) return 1 ;;
            *) log_err "Пожалуйста, введите y или n." ;;
        esac
    done
}

backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        cp -a "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)"
    fi
}

# ====================================================================
# Validation
# ====================================================================

validate_port() {
    local port="$1"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || ((${#port} > 5)) || ((10#$port < 1 || 10#$port > 65535)); then
        log_err "Порт должен быть числом от 1 до 65535."
        return 1
    fi
    return 0
}

normalize_port() {
    echo "$((10#$1))"
}

is_ssh_port() {
    local port="$1" known
    for known in "${SSH_PORTS[@]}"; do
        [[ "$port" == "$known" ]] && return 0
    done
    return 1
}

validate_username() {
    local username="$1"
    local reserved="root daemon bin sys sync games man lp mail news uucp proxy www-data backup list nobody nogroup squid squid3 danted sockd unbound fail2ban sshd systemd-network systemd-resolve ubuntu admin debian user guest dnsmasq _apt"

    if [[ ${#username} -lt 1 || ${#username} -gt 32 ]]; then
        log_err "Имя пользователя: от 1 до 32 символов."
        return 1
    fi
    if ! [[ "$username" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]]; then
        log_err "Имя пользователя: только буквы, цифры, дефис и подчёркивание; начинаться с буквы или _."
        return 1
    fi
    for r in $reserved; do
        if [[ "$username" == "$r" ]]; then
            log_err "Имя '$username' зарезервировано системой."
            return 1
        fi
    done
    return 0
}

_ipv4_ok() {
    local ip="$1" o
    IFS='.' read -r -a o <<< "$ip"
    ((${#o[@]} == 4)) || return 1
    local oct
    for oct in "${o[@]}"; do
        [[ "$oct" =~ ^[0-9]+$ ]] || return 1
        [[ "$oct" =~ ^0[0-9]+$ ]] && return 1
        ((10#$oct >= 0 && 10#$oct <= 255)) || return 1
    done
    return 0
}

normalize_ip_list() {
    local raw="$1"
    raw="${raw//,/ }"
    raw="${raw//;/ }"
    raw="$(printf '%s' "$raw" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')"
    printf '%s' "$raw"
}

validate_ip_or_cidr() {
    local input="$1" addr prefix

    if [[ "$input" == *","* || "$input" == *";"* ]]; then
        log_err "Перечисляйте адреса через пробел: $input"
        return 1
    fi

    # Reject "IP:port" — that was previously accepted and then written into ACLs.
    if [[ "$input" == *:* && "$input" != *:*:* && "$input" == *.* ]]; then
        log_err "Укажите адрес без порта. Для подсети используйте CIDR, например 192.168.1.0/24."
        return 1
    fi

    if command_exists python3; then
        python3 - "$input" <<'PY'
import ipaddress, sys
value = sys.argv[1]
try:
    if "/" in value:
        ipaddress.ip_network(value, strict=False)
    else:
        ipaddress.ip_address(value)
except Exception:
    sys.exit(1)
sys.exit(0)
PY
        local rc=$?
        if ((rc != 0)); then
            log_err "Неверный IP или CIDR: $input"
            return 1
        fi
        return 0
    fi

    if [[ "$input" == */* ]]; then
        addr="${input%/*}"
        prefix="${input#*/}"
        if ! [[ "$prefix" =~ ^[0-9]+$ ]] || ((prefix < 0 || prefix > 32)); then
            log_err "Неверная маска CIDR: $input"
            return 1
        fi
    else
        addr="$input"
    fi
    if _ipv4_ok "$addr"; then
        return 0
    fi
    log_err "Неверный IP-адрес: $input (установите python3 для проверки IPv6)."
    return 1
}

validate_ips() {
    local ip
    for ip in $1; do
        validate_ip_or_cidr "$ip" || return 1
    done
    return 0
}

is_ipv6() {
    [[ "$1" == *:* ]]
}

cidr_for() {
    local ip="$1"
    if [[ "$ip" == */* ]]; then
        echo "$ip"
    elif is_ipv6 "$ip"; then
        echo "$ip/128"
    else
        echo "$ip/32"
    fi
}

port_in_use() {
    local port="$1" listeners=""
    if command_exists ss; then
        listeners="$(ss -lntuH 2>/dev/null | awk '{print $5}')"
    elif command_exists netstat; then
        listeners="$(netstat -lntu 2>/dev/null | awk '{print $4}')"
    else
        return 1
    fi
    grep -Eq ":${port}$" <<<"$listeners"
}

# True when another service (not squid/dante) already listens on the port.
port_held_by_foreign_service() {
    local port="$1" line
    if command_exists ss; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if [[ "$line" == *squid* || "$line" == *danted* || "$line" == *sockd* ]]; then
                continue
            fi
            return 0
        done < <(ss -lntupH 2>/dev/null | awk -v p=":${port}$" '$5 ~ p {print}')
        return 1
    fi
    port_in_use "$port"
}

# ====================================================================
# System detection
# ====================================================================

detect_os() {
    [[ -f /etc/os-release ]] || die "Не найден /etc/os-release. Неизвестная ОС."
    # shellcheck source=/dev/null
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_VERSION_ID="${VERSION_ID:-}"
    OS_LIKE="${ID_LIKE:-}"

    local debian_like=false
    case "$OS_ID" in
        debian|ubuntu|linuxmint|pop|elementary|zorin|kali|raspbian|devuan|neon|kubuntu|xubuntu|lubuntu)
            debian_like=true
            ;;
    esac
    [[ "$OS_LIKE" == *debian* || "$OS_LIKE" == *ubuntu* ]] && debian_like=true

    command_exists apt-get || die "Нужен пакетный менеджер apt (Debian/Ubuntu и производные)."
    [[ "$debian_like" == true ]] || die "Этот скрипт поддерживает Debian, Ubuntu и производные. Обнаружено: ${OS_ID:-unknown} ${OS_VERSION_ID}"

    case "$OS_ID" in
        ubuntu)
            local major="${OS_VERSION_ID%%.*}"
            if [[ "$major" =~ ^[0-9]+$ ]] && ((major < 24)); then
                die "Нужен Ubuntu 24.04 или новее (сейчас ${OS_VERSION_ID}). В Ubuntu 20.04 и 22.04 пакет dante-server старше 1.4.4 и уязвим (CVE-2024-54662), а исправленная сборка требует glibc 2.38."
            fi
            ;;
        debian|raspbian|devuan)
            local major="${OS_VERSION_ID%%.*}"
            if [[ "$major" =~ ^[0-9]+$ ]] && ((major < 13)); then
                die "Нужен Debian 13 или новее (сейчас ${OS_VERSION_ID}). В Debian 12 пакет dante-server 1.4.2 уязвим (CVE-2024-54662), а исправленная сборка 1.4.4 требует glibc 2.38."
            fi
            ;;
    esac

    # Derivatives (Mint, Zorin, elementary, Pop!_OS) use their own VERSION_ID.
    # focal and jammy are too old to run Dante 1.4.4.
    case "${UBUNTU_CODENAME:-}" in
        precise|trusty|xenial|bionic|focal|jammy)
            die "База Ubuntu слишком старая (${UBUNTU_CODENAME}). Нужен Ubuntu 24.04 (noble) или новее: более старый Dante уязвим (CVE-2024-54662)."
            ;;
    esac

    log_ok "ОС: ${PRETTY_NAME:-$OS_ID $OS_VERSION_ID}"
}

check_internet() {
    local ok=false
    if command_exists ping; then
        ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 && ok=true
        [[ "$ok" == false ]] && ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 && ok=true
    fi
    if [[ "$ok" == false ]] && command_exists curl; then
        curl -fsS --max-time 5 -o /dev/null https://deb.debian.org >/dev/null 2>&1 && ok=true
        [[ "$ok" == false ]] && curl -fsS --max-time 5 -o /dev/null https://1.1.1.1 >/dev/null 2>&1 && ok=true
    fi
    if [[ "$ok" == false ]] && command_exists wget; then
        wget -q --timeout=5 -O /dev/null https://deb.debian.org >/dev/null 2>&1 && ok=true
    fi
    if [[ "$ok" == false ]]; then
        timeout 5 bash -c 'echo >/dev/tcp/1.1.1.1/443' >/dev/null 2>&1 && ok=true
    fi
    [[ "$ok" == true ]] || die "Нет исходящего доступа в интернет (ICMP может быть закрыт — проверялись HTTPS и TCP/443)."
    log_ok "Доступ в интернет есть."
}

check_disk() {
    local free_kb
    free_kb="$(df -Pk / | awk 'NR==2 {print $4}')"
    [[ "$free_kb" =~ ^[0-9]+$ ]] || return 0
    if ((free_kb < 500000)); then
        die "Недостаточно места на диске (нужно ≥ 500 МБ свободно)."
    fi
}

detect_nologin() {
    if [[ -x /usr/sbin/nologin ]]; then
        NOLOGIN_SHELL="/usr/sbin/nologin"
    elif [[ -x /sbin/nologin ]]; then
        NOLOGIN_SHELL="/sbin/nologin"
    else
        NOLOGIN_SHELL="/bin/false"
    fi
}

detect_ssh_port() {
    local port="" seen=" "
    SSH_PORTS=()

    add_ssh_port() {
        local candidate="${1:-}"
        validate_port "$candidate" 2>/dev/null || return 0
        candidate="$(normalize_port "$candidate")"
        [[ "$seen" == *" $candidate "* ]] && return 0
        seen+="$candidate "
        SSH_PORTS+=("$candidate")
    }

    if command_exists sshd; then
        while read -r port; do
            add_ssh_port "$port"
        done < <(sshd -T 2>/dev/null | awk '/^port / {print $2}')
    fi
    if command_exists ss; then
        while read -r port; do
            add_ssh_port "$port"
        done < <(ss -lntupH 2>/dev/null | awk '/sshd/ {
            addr=$5
            sub(/.*:/, "", addr)
            gsub(/\]/, "", addr)
            print addr
        }')
    fi
    if ((${#SSH_PORTS[@]} == 0)); then
        if [[ -f /etc/ssh/sshd_config ]]; then
            port="$(awk 'BEGIN{IGNORECASE=1} /^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config)"
            add_ssh_port "$port"
        fi
    fi
    if ((${#SSH_PORTS[@]} == 0)); then
        SSH_PORTS=(22)
    fi
}

ipv6_is_enabled() {
    [[ -f /proc/net/if_inet6 ]] || return 1
    local disabled="0"
    disabled="$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)"
    [[ "$disabled" == "0" ]]
}

ensure_iproute() {
    if command_exists ip && command_exists ss; then
        return 0
    fi
    log_info "Ставлю iproute2, чтобы проверить интерфейс и занятые порты."
    apt-get update -qq -o Acquire::Retries=3 || die "Не удалось обновить списки пакетов (apt-get update)."
    apt-get install -y -qq iproute2 || die "Не удалось установить iproute2. Без него нельзя надёжно выбрать свободный порт."
    command_exists ss || die "После установки iproute2 команда ss недоступна."
}

detect_external_net() {
    local line=""
    line="$(ip -4 route get 1.1.1.1 2>/dev/null | head -n1)"
    if [[ -z "$line" ]]; then
        line="$(ip route get 1.1.1.1 2>/dev/null | head -n1)"
    fi
    if [[ -z "$line" ]]; then
        line="$(ip -4 route show default 2>/dev/null | head -n1)"
    fi

    EXTERNAL_INTERFACE="$(awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<<"$line")"
    EXTERNAL_IPV4="$(awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' <<<"$line")"

    if [[ -z "$EXTERNAL_INTERFACE" ]]; then
        EXTERNAL_INTERFACE="$(ip -o link show 2>/dev/null | awk -F': ' '$2 !~ /^(lo|docker|br-|veth|virbr|tun|tap)/ {print $2; exit}')"
    fi
    if [[ -z "$EXTERNAL_IPV4" && -n "$EXTERNAL_INTERFACE" ]]; then
        EXTERNAL_IPV4="$(ip -4 -o addr show dev "$EXTERNAL_INTERFACE" 2>/dev/null | awk '{print $4; exit}' | cut -d/ -f1)"
    fi
    if [[ -z "$EXTERNAL_IPV4" ]]; then
        EXTERNAL_IPV4="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi

    [[ -n "$EXTERNAL_INTERFACE" ]] || die "Не удалось определить внешний сетевой интерфейс."
    SERVER_IP="${EXTERNAL_IPV4:-unknown}"
}

detect_squid_helper() {
    local candidates=(
        /usr/lib/squid/basic_ncsa_auth
        /usr/libexec/squid/basic_ncsa_auth
        /usr/lib/squid3/basic_ncsa_auth
        /usr/lib64/squid/basic_ncsa_auth
        /usr/lib/squid3/ncsa_auth
    )
    local p
    for p in "${candidates[@]}"; do
        if [[ -x "$p" ]]; then
            SQUID_HELPER="$p"
            return 0
        fi
    done
    p="$(dpkg -L squid 2>/dev/null | grep -E '/basic_ncsa_auth$' | head -n1 || true)"
    if [[ -n "$p" && -x "$p" ]]; then
        SQUID_HELPER="$p"
        return 0
    fi
    return 1
}

detect_proxy_user() {
    if getent passwd proxy >/dev/null; then
        PROXY_USER="proxy"
    elif getent passwd squid >/dev/null; then
        PROXY_USER="squid"
    else
        PROXY_USER="proxy"
    fi
}

detect_dante_unprivileged() {
    if getent passwd nobody >/dev/null; then
        DANTE_NOPRIV_USER="nobody"
        DANTE_NOPRIV_GROUP="$(id -gn nobody 2>/dev/null || echo nogroup)"
    elif getent passwd nogroup >/dev/null; then
        DANTE_NOPRIV_USER="nobody"
        DANTE_NOPRIV_GROUP="nogroup"
    else
        DANTE_NOPRIV_USER="nobody"
        DANTE_NOPRIV_GROUP="nogroup"
    fi
}

ensure_dante_log() {
    touch "$DANTE_LOG"
    chown "${DANTE_NOPRIV_USER}:${DANTE_NOPRIV_GROUP}" "$DANTE_LOG" 2>/dev/null || chown nobody "$DANTE_LOG" 2>/dev/null || true
    chmod 640 "$DANTE_LOG"
}

state_get() {
    local key="$1"
    [[ -f "$STATE_FILE" ]] || return 0
    sed -n "s/^${key}=//p" "$STATE_FILE" | head -n1
}

state_set() {
    local key="$1" value="$2" tmp
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR" 2>/dev/null || true
    touch "$STATE_FILE"
    tmp="$(mktemp)"
    if [[ -f "$STATE_FILE" ]]; then
        grep -v "^${key}=" "$STATE_FILE" > "$tmp" || true
    fi
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$STATE_FILE"
    chmod 600 "$STATE_FILE" 2>/dev/null || true
}

remember_user() {
    mkdir -p "$STATE_DIR"
    touch "$USERS_FILE"
    if ! grep -qxF "$1" "$USERS_FILE" 2>/dev/null; then
        echo "$1" >> "$USERS_FILE"
    fi
}

read_tracked_users() {
    [[ -f "$USERS_FILE" ]] || return 0
    grep -v '^[[:space:]]*$' "$USERS_FILE" || true
}

# ====================================================================
# Cleanup
# ====================================================================

remove_ufw_port() {
    local port="$1" _
    command_exists ufw || return 0
    for _ in 1 2 3 4; do
        ufw --force delete allow "${port}/tcp" >/dev/null 2>&1 || break
    done
    for _ in 1 2 3 4; do
        ufw --force delete allow "${port}/udp" >/dev/null 2>&1 || break
    done
}

remove_firewalld_port() {
    local port="$1" proto
    command_exists firewall-cmd || return 0
    systemctl is-active firewalld >/dev/null 2>&1 || return 0
    for proto in tcp udp; do
        firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1 || true
    done
}

safe_delete_user() {
    local user="$1" uid home
    [[ -n "$user" ]] || return 0
    id "$user" >/dev/null 2>&1 || return 0
    if ! validate_username "$user" >/dev/null 2>&1; then
        log_err "Отказ удалять системную учётную запись '$user'."
        return 1
    fi
    uid="$(id -u "$user")"
    if [[ "$uid" == "0" ]]; then
        log_err "Отказ удалять root."
        return 1
    fi
    home="$(getent passwd "$user" | cut -d: -f6)"
    case "$home" in
        /|/root|/home|/etc|/usr|/var|"") userdel "$user" >/dev/null 2>&1 || true ;;
        *) userdel -r "$user" >/dev/null 2>&1 || userdel "$user" >/dev/null 2>&1 || true ;;
    esac
    log_info "Пользователь '$user' удалён."
}

cleanup() {
    echo -e "\n${C_YELLOW}--- Очистка предыдущей установки ---${C_RESET}"

    local old_squid old_dante
    old_squid="$(state_get SQUID_PORT)"
    old_dante="$(state_get DANTE_PORT)"
    [[ -n "$old_squid" ]] && remove_ufw_port "$old_squid"
    [[ -n "$old_dante" ]] && remove_ufw_port "$old_dante"
    [[ -n "$old_squid" ]] && remove_firewalld_port "$old_squid"
    [[ -n "$old_dante" ]] && remove_firewalld_port "$old_dante"
    if command_exists firewall-cmd && systemctl is-active firewalld >/dev/null 2>&1; then
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi

    systemctl stop squid danted 2>/dev/null || true
    systemctl disable squid danted 2>/dev/null || true
    log_info "Службы Squid и Dante остановлены."

    apt-get purge -y squid dante-server >/dev/null 2>&1 || true

    if [[ "$(state_get INSTALLED_UNBOUND)" == "1" ]]; then
        if [[ "$(state_get UNBOUND_PREEXISTED)" != "1" ]]; then
            systemctl stop unbound 2>/dev/null || true
            apt-get purge -y unbound >/dev/null 2>&1 || true
        fi
    fi
    rm -f "$UNBOUND_DROPIN"
    if [[ "$(state_get UNBOUND_PREEXISTED)" == "1" ]] && systemctl is-enabled unbound >/dev/null 2>&1; then
        systemctl try-restart unbound >/dev/null 2>&1 || true
    fi

    rm -f "$FAIL2BAN_JAIL" "$FAIL2BAN_FILTER" "$FAIL2BAN_SQUID_FILTER"
    rm -f "$DANTE_DROPIN"
    rmdir /etc/systemd/system/danted.service.d 2>/dev/null || true
    if command_exists systemctl; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    if systemctl is-active fail2ban >/dev/null 2>&1; then
        systemctl reload fail2ban >/dev/null 2>&1 || systemctl restart fail2ban >/dev/null 2>&1 || true
    fi
    if [[ "$(state_get INSTALLED_FAIL2BAN)" == "1" ]] && ! [[ "$(state_get FAIL2BAN_PREEXISTED)" == "1" ]]; then
        systemctl stop fail2ban 2>/dev/null || true
        apt-get purge -y fail2ban >/dev/null 2>&1 || true
    fi

    apt-get autoremove -y >/dev/null 2>&1 || true

    local user
    local tracked=()
    mapfile -t tracked < <(read_tracked_users)
    if ((${#tracked[@]} == 0)) && ((${#USERS_TO_DELETE[@]} > 0)); then
        tracked=("${USERS_TO_DELETE[@]}")
    fi
    for user in "${tracked[@]}"; do
        [[ -n "$user" ]] || continue
        safe_delete_user "$user" || true
    done

    rm -f "$SQUID_PASSWD" "$SYSCTL_FILE" "$LOGROTATE_FILE" "$DANTE_LOG"
    rm -f "$DANTE_APT_LIST" "$DANTE_APT_PIN"
    rm -rf "$STATE_DIR"
    log_ok "Очистка завершена."
    sleep 1
}

# ====================================================================
# Packages / sysctl / unbound
# ====================================================================

apt_install() {
    apt-get update -qq -o Acquire::Retries=3 || die "Не удалось обновить списки пакетов (apt-get update)."
    local pkg
    for pkg in "$@"; do
        if [[ "$pkg" == "dante-server" ]]; then
            ensure_dante_repository
            break
        fi
    done
    apt-get install -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" "$@" \
        || die "Не удалось установить пакеты: $*"
}

package_available() {
    apt-cache show "$1" 2>/dev/null | grep -q '^Package:'
}

dante_fallback_suite() {
    # Fixed release is 1.4.4 (CVE-2024-54662). Architectures without that
    # build are refused instead of receiving Debian 12's vulnerable 1.4.2.
    case "$1" in
        amd64|arm64|i386|ppc64el|riscv64|s390x) echo forky ;;
        *) return 1 ;;
    esac
}

# accept: the candidate is already 1.4.4 or newer
# replace: a fixed 1.4.4 build can run here (glibc 2.38 or newer)
# refuse: the only build is vulnerable and 1.4.4 cannot be installed
dante_candidate_action() {
    local os="$1" version_id="$2" pkgver="$3" glibc="${4:-}"
    local major="${version_id%%.*}"
    if dpkg --compare-versions "$pkgver" ge 1.4.4; then
        echo accept
        return 0
    fi
    if [[ -n "$glibc" ]]; then
        if dpkg --compare-versions "$glibc" ge 2.38; then
            echo replace
        else
            echo refuse
        fi
        return 0
    fi
    case "$os" in
        debian|raspbian|devuan)
            if [[ "$major" =~ ^[0-9]+$ ]] && ((major >= 13)); then
                echo replace
            else
                echo refuse
            fi
            ;;
        ubuntu|linuxmint|pop|elementary|zorin|neon|kubuntu|xubuntu|lubuntu)
            # 24.04 and newer have glibc >= 2.39. 20.04 and 22.04 do not.
            if [[ "$major" =~ ^[0-9]+$ ]] && ((major >= 24)); then
                echo replace
            else
                echo refuse
            fi
            ;;
        *) echo refuse ;;
    esac
}

glibc_version() {
    local raw=""
    raw="$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"
    if [[ "$raw" =~ ([0-9]+\.[0-9]+) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    raw="$(ldd --version 2>/dev/null | awk 'NR==1 {print $NF; exit}')"
    printf '%s\n' "$raw"
}

debian_archive_uri() {
    local uri=""
    uri="$(awk '
        /^URIs:/ {u=$2}
        /^Suites:/ && $2 !~ /security/ && u != "" {print u; exit}
    ' /etc/apt/sources.list.d/*.sources 2>/dev/null || true)"
    if [[ -z "$uri" && -f /etc/apt/sources.list ]]; then
        uri="$(awk '/^deb / && $0 !~ /security/ {print $2; exit}' /etc/apt/sources.list)"
    fi
    printf '%s\n' "${uri:-http://deb.debian.org/debian}"
}

debian_archive_keyring() {
    local key
    for key in \
        /usr/share/keyrings/debian-archive-keyring.gpg \
        /usr/share/keyrings/debian-archive-keyring.pgp \
        /etc/apt/trusted.gpg.d/debian-archive-keyring.gpg
    do
        if [[ -f "$key" ]]; then
            printf '%s\n' "$key"
            return 0
        fi
    done
    return 1
}

ensure_dante_repository() {
    local ver="" major="" action=""
    if package_available dante-server; then
        ver="$(apt-cache show dante-server | awk '/^Version:/ {print $2; exit}')"
    fi
    action="$(dante_candidate_action "$OS_ID" "$OS_VERSION_ID" "${ver:-0}" "$(glibc_version)")"
    case "$action" in
        accept)
            if [[ -n "$ver" ]]; then
                return 0
            fi
            ;;
        refuse)
            die "dante-server ${ver:-из этого выпуска} уязвим (CVE-2024-54662, исправлено в 1.4.4). На этой системе glibc старше 2.38, поэтому исправленную сборку поставить нельзя. Установка остановлена."
            ;;
        replace)
            if [[ -n "$ver" ]]; then
                log_warn "Доступен dante-server ${ver}. Он уязвим (CVE-2024-54662). Ставлю 1.4.4."
            fi
            ;;
    esac

    case "$OS_ID" in
        ubuntu|linuxmint|pop|elementary|zorin|neon|kubuntu|xubuntu|lubuntu)
            if [[ "$action" != "replace" ]]; then
                die "Пакет dante-server не найден. Включите репозиторий universe: add-apt-repository universe"
            fi
            ;;
    esac

    local arch suite uri keyring
    arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
    suite="$(dante_fallback_suite "$arch")" || die "Пакет dante-server отсутствует, а для архитектуры ${arch} нет сборки 1.4.4. Версию старше 1.4.4 ставить нельзя: она уязвима (CVE-2024-54662)."
    case "$OS_ID" in
        debian|raspbian|devuan) uri="$(debian_archive_uri)" ;;
        *) uri="http://deb.debian.org/debian" ;;
    esac
    if ! keyring="$(debian_archive_keyring)"; then
        apt-get install -y -qq debian-archive-keyring || die "Не удалось установить ключи архива Debian."
        keyring="$(debian_archive_keyring)" || die "Не найден ключ архива Debian."
    fi

    log_warn "В репозитории ${OS_ID} ${OS_VERSION_ID} нет dante-server 1.4.4."
    log_warn "Подключаю только dante-server 1.4.4 из Debian ${suite} (CVE-2024-54662 исправлен). Остальные пакеты из ${suite} запрещены."

    mkdir -p /etc/apt/sources.list.d /etc/apt/preferences.d
    write_dante_source() {
        printf 'deb [signed-by=%s] %s %s main\n' "$keyring" "$1" "$suite" > "$DANTE_APT_LIST"
    }
    cat > "$DANTE_APT_PIN" <<EOF
Package: dante-server
Pin: release n=${suite}
Pin-Priority: 990

Package: *
Pin: release n=${suite}
Pin-Priority: -1
EOF
    write_dante_source "$uri"
    if ! apt-get update -qq -o Acquire::Retries=3; then
        if [[ "$uri" != "http://deb.debian.org/debian" && "$uri" != "https://deb.debian.org/debian" ]]; then
            log_warn "Зеркало не отдаёт Debian ${suite}. Пробую deb.debian.org."
            write_dante_source "http://deb.debian.org/debian"
            if ! apt-get update -qq -o Acquire::Retries=3; then
                rm -f "$DANTE_APT_LIST" "$DANTE_APT_PIN"
                apt-get update -qq -o Acquire::Retries=3 || true
                die "Не удалось подключить Debian ${suite} для установки dante-server."
            fi
        else
            rm -f "$DANTE_APT_LIST" "$DANTE_APT_PIN"
            die "Не удалось обновить списки после подключения Debian ${suite}."
        fi
    fi
    ver="$(apt-cache show dante-server | awk '/^Version:/ {print $2; exit}')"
    if ! dpkg --compare-versions "$ver" ge 1.4.4; then
        rm -f "$DANTE_APT_LIST" "$DANTE_APT_PIN"
        die "В Debian ${suite} найден dante-server ${ver:-неизвестной версии}. Нужна версия 1.4.4 или новее (CVE-2024-54662)."
    fi
}

install_packages() {
    echo -e "\n${C_YELLOW}--- Шаг 2: Установка пакетов ---${C_RESET}"

    local pkgs=(squid dante-server apache2-utils fail2ban)
    command_exists curl || pkgs+=(curl)
    command_exists ip && command_exists ss || pkgs+=(iproute2)
    [[ "$INSTALL_UNBOUND" == true ]] && pkgs+=(unbound dns-root-data)

    local fail2ban_existed=0 unbound_existed=0
    dpkg -s fail2ban >/dev/null 2>&1 && fail2ban_existed=1
    dpkg -s unbound >/dev/null 2>&1 && unbound_existed=1

    apt_install "${pkgs[@]}"
    state_set INSTALLED_FAIL2BAN 1
    state_set FAIL2BAN_PREEXISTED "$fail2ban_existed"
    if [[ "$INSTALL_UNBOUND" == true ]]; then
        state_set INSTALLED_UNBOUND 1
        state_set UNBOUND_PREEXISTED "$unbound_existed"
    fi
    log_ok "Пакеты установлены."
}

apply_sysctl() {
    [[ "$APPLY_OPTIMIZATIONS" == true ]] || { log_info "Сетевые оптимизации пропущены."; return 0; }

    echo -e "\n${C_YELLOW}--- Шаг 2.5: Сетевые оптимизации ---${C_RESET}"
    mkdir -p /etc/sysctl.d
    local available="" bbr_ok=false fq_ok=false
    available="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)"
    [[ "$available" == *bbr* ]] && bbr_ok=true
    [[ -e /proc/sys/net/core/default_qdisc ]] && fq_ok=true

    {
        echo "# Generated by proxy-installer. Safe to delete."
        echo "net.core.somaxconn = 4096"
        echo "net.core.netdev_max_backlog = 5000"
        echo "net.ipv4.tcp_max_syn_backlog = 4096"
        echo "net.ipv4.tcp_fin_timeout = 15"
        echo "net.ipv4.tcp_slow_start_after_idle = 0"
        echo "net.ipv4.tcp_keepalive_time = 600"
        if [[ "$fq_ok" == true ]]; then
            echo "net.core.default_qdisc = fq"
        fi
        if [[ "$bbr_ok" == true ]]; then
            echo "net.ipv4.tcp_congestion_control = bbr"
        fi
    } > "$SYSCTL_FILE"

    if ! sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1; then
        log_warn "Часть sysctl-параметров не применилась (типично для OpenVZ/ограниченных ядер). Продолжаем."
    else
        if [[ "$bbr_ok" == true ]]; then
            log_ok "BBR и сетевые параметры применены через $SYSCTL_FILE (без дублирования в sysctl.conf)."
        else
            log_warn "BBR недоступен на этом ядре. Применены остальные параметры."
        fi
    fi
}

ensure_unbound_root_key() {
    # unbound refuses to start until this trust anchor exists. The package
    # helper copies it from dns-root-data, but that copy is skipped when the
    # recommended package was not installed.
    local key="/var/lib/unbound/root.key"
    mkdir -p /var/lib/unbound
    if getent passwd unbound >/dev/null 2>&1; then
        chown unbound:unbound /var/lib/unbound
    fi
    if [[ -x /usr/libexec/unbound-helper ]]; then
        /usr/libexec/unbound-helper root_trust_anchor_update || true
    fi
    if [[ ! -s "$key" && -r /usr/share/dns/root.key ]]; then
        if getent passwd unbound >/dev/null 2>&1; then
            install -o unbound -g unbound -m 644 /usr/share/dns/root.key "$key"
        else
            install -m 644 /usr/share/dns/root.key "$key"
        fi
    fi
    if [[ ! -s "$key" ]] && command_exists unbound-anchor; then
        unbound-anchor -a "$key" || true
        if getent passwd unbound >/dev/null 2>&1; then
            chown unbound:unbound "$key" 2>/dev/null || true
        fi
    fi
    [[ -s "$key" ]]
}

configure_unbound() {
    [[ "$INSTALL_UNBOUND" == true ]] || return 0
    echo -e "\n${C_YELLOW}--- Настройка Unbound (только localhost) ---${C_RESET}"

    if ss -lntH 2>/dev/null | awk '{print $5}' | grep -Eq '(^|[^0-9])127\.0\.0\.1:53$'; then
        log_warn "127.0.0.1:53 уже занят. Unbound может не запуститься; Squid останется на системном DNS."
    elif ss -lntH 2>/dev/null | awk '{print $5}' | grep -Eq '127\.0\.0\.53:53$'; then
        log_info "systemd-resolved слушает 127.0.0.53:53 — Unbound займёт 127.0.0.1:53."
    fi

    mkdir -p /etc/unbound/unbound.conf.d
    local threads
    threads="$(nproc 2>/dev/null || echo 1)"
    ((threads > 4)) && threads=4
    ((threads < 1)) && threads=1

    cat > "$UNBOUND_DROPIN" <<EOF
# Generated by proxy-installer. Listen on localhost only.
server:
    interface: 127.0.0.1
    port: 53
    do-ip4: yes
    do-ip6: no
    do-udp: yes
    do-tcp: yes
    do-not-query-localhost: no
    access-control: 127.0.0.0/8 allow
    access-control: ::1 allow
    access-control: 0.0.0.0/0 refuse
    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    qname-minimisation: yes
    prefetch: yes
    minimal-responses: yes
    cache-min-ttl: 60
    cache-max-ttl: 86400
    num-threads: ${threads}
    verbosity: 1
EOF

    if ! ensure_unbound_root_key; then
        log_warn "Не удалось создать /var/lib/unbound/root.key. Локальный DNS не будет включён."
        rm -f "$UNBOUND_DROPIN"
        INSTALL_UNBOUND=false
        return 0
    fi

    if ! unbound-checkconf >/dev/null 2>&1; then
        local check_out
        check_out="$(unbound-checkconf 2>&1 || true)"
        if [[ "$check_out" == *"root.key"* || "$check_out" == *"auto-trust-anchor-file"* ]]; then
            log_info "Ключ DNSSEC ещё не создан. Unbound создаст его при первом запуске."
        else
            log_warn "unbound-checkconf сообщил об ошибке. Локальный DNS не будет включён."
            printf '%s\n' "$check_out" >&2
            rm -f "$UNBOUND_DROPIN"
            INSTALL_UNBOUND=false
            return 0
        fi
    fi
    log_ok "Unbound настроен на 127.0.0.1:53 (без публикации резолвера в интернет)."
}

# ====================================================================
# Service configs
# ====================================================================

write_squid_conf() {
    local auth_block="" access_block="" dns_block="" self_acl="" self_deny="" port_block helper
    helper="${SQUID_HELPER:-/usr/lib/squid/basic_ncsa_auth}"

    if [[ "$AUTH_CHOICE" == "1" || "$AUTH_CHOICE" == "2" ]]; then
        auth_block=$(cat <<EOF
auth_param basic program ${helper} ${SQUID_PASSWD}
auth_param basic children 5
auth_param basic realm Squid Proxy
auth_param basic credentialsttl 2 hours
# Default casesensitive is off: Squid lowercases the username before
# basic_ncsa_auth. /etc/squid/passwd keeps the original name and a
# lowercase alias with the same password hash.
acl authenticated proxy_auth REQUIRED
EOF
)
    fi

    if [[ "$AUTH_CHOICE" == "1" || "$AUTH_CHOICE" == "3" ]]; then
        auth_block+=$'\n'"acl whitelist src ${WHITELIST_IPS}"
    fi

    case "$AUTH_CHOICE" in
        1) access_block=$'http_access allow whitelist\nhttp_access allow authenticated' ;;
        2) access_block='http_access allow authenticated' ;;
        3) access_block='http_access allow whitelist' ;;
    esac

    if [[ -n "${SERVER_IP:-}" && "$SERVER_IP" != "unknown" ]]; then
        self_acl="acl to_self dst ${SERVER_IP}"
        self_deny="http_access deny to_self"
    fi

    if [[ "$INSTALL_UNBOUND" == true ]]; then
        dns_block="dns_nameservers 127.0.0.1"
    fi

    port_block="http_port ${SQUID_PORT}"
    if [[ "$IPV6_ENABLED" == true ]]; then
        port_block+=$'\n'"http_port [::]:${SQUID_PORT}"
    fi

    cat > "$SQUID_CONF" <<EOF
# Generated by proxy-installer ${SCRIPT_VERSION}
# localhost, to_localhost, to_linklocal and CONNECT are built into Squid.
logfile_rotate 0
httpd_suppress_version_string on
coredump_dir /var/spool/squid
cache_effective_user ${PROXY_USER}
cache_effective_group ${PROXY_USER}

acl SSL_ports port 443
acl Safe_ports port 80
acl Safe_ports port 21
acl Safe_ports port 443
acl Safe_ports port 70
acl Safe_ports port 210
acl Safe_ports port 1025-65535
acl Safe_ports port 280
acl Safe_ports port 488
acl Safe_ports port 591
acl Safe_ports port 777

${auth_block}
${self_acl}

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow localhost
http_access deny to_localhost
http_access deny to_linklocal
${self_deny}
${access_block}
http_access deny all

${port_block}
via off
forwarded_for delete
request_header_access From deny all
request_header_access Server deny all
request_header_access Link deny all

logformat proxyinstaller %{%Y-%m-%dT%H:%M:%S}tl %>a %Ss/%03>Hs %rm %ru %un
access_log stdio:/var/log/squid/access.log proxyinstaller

refresh_pattern ^ftp:           1440    20%     10080
refresh_pattern ^gopher:        1440    0%      1440
refresh_pattern -i (/cgi-bin/|\?) 0     0%      0
refresh_pattern .               0       20%     4320

shutdown_lifetime 5 seconds
${dns_block}
EOF
}

configure_squid() {
    backup_file "$SQUID_CONF"
    detect_proxy_user
    detect_external_net || true
    if [[ "$AUTH_CHOICE" == "1" || "$AUTH_CHOICE" == "2" ]]; then
        detect_squid_helper || die "Не найден helper basic_ncsa_auth. Пакет squid установлен неполностью."
    fi
    write_squid_conf

    if [[ -f "$SQUID_PASSWD" ]]; then
        chown "root:${PROXY_USER}" "$SQUID_PASSWD"
        chmod 640 "$SQUID_PASSWD"
    fi

    mkdir -p /var/spool/squid /var/log/squid
    touch /var/log/squid/access.log
    chown -R "${PROXY_USER}:${PROXY_USER}" /var/spool/squid /var/log/squid 2>/dev/null || true
    chmod 755 /var/log/squid 2>/dev/null || true

    local parse_out=""
    if ! parse_out="$(squid -k parse -f "$SQUID_CONF" 2>&1)"; then
        if grep -q 'to_linklocal' <<<"$parse_out"; then
            sed -i '/to_linklocal/d' "$SQUID_CONF"
            parse_out="$(squid -k parse -f "$SQUID_CONF" 2>&1)" || {
                printf '%s\n' "$parse_out" >&2
                die "squid -k parse не принял ${SQUID_CONF}."
            }
        else
            printf '%s\n' "$parse_out" >&2
            die "squid -k parse не принял ${SQUID_CONF}."
        fi
    fi
    if [[ ! -d /var/spool/squid/00 ]]; then
        squid -z --foreground >/dev/null 2>&1 || squid -z >/dev/null 2>&1 || true
    fi
    log_ok "Squid: конфиг проверен (safe ports, свой журнал для Fail2ban)."
}

dante_pass_block() {
    local from="$1" to="$2" method="$3"
    printf 'socks pass {\n    from: %s to: %s\n    socksmethod: %s\n    command: connect udpassociate\n    log: error\n}\n' "$from" "$to" "$method"
}

dante_client_block() {
    local from="$1" to="$2"
    printf 'client pass {\n    from: %s to: %s\n    log: error\n}\n' "$from" "$to"
}

write_dante_conf() {
    local external_line="external: ${EXTERNAL_INTERFACE:-eth0}"
    if [[ -n "${EXTERNAL_IPV4:-}" ]]; then
        external_line="external: ${EXTERNAL_IPV4}"
    fi

    local internal_block="internal: 0.0.0.0 port = ${DANTE_PORT}"
    local v6_clients="" v6_socks_user=""
    if [[ "$IPV6_ENABLED" == true ]]; then
        internal_block+=$'\n'"internal: :: port = ${DANTE_PORT}"
        v6_clients="$(dante_client_block "::/0" "::/0")"
        v6_socks_user="$(dante_pass_block "::/0" "::/0" "username")"
    fi

    local socks_method="" client_rules="" socks_rules="" ip from to warned_v6=false
    case "$AUTH_CHOICE" in
        1)
            socks_method="socksmethod: username none"
            client_rules="$(dante_client_block "0.0.0.0/0" "0.0.0.0/0")"$'\n'
            [[ "$IPV6_ENABLED" == true ]] && client_rules+="${v6_clients}"$'\n'
            socks_rules=""
            for ip in $WHITELIST_IPS; do
                from="$(cidr_for "$ip")"
                if is_ipv6 "$ip"; then
                    if [[ "$IPV6_ENABLED" != true ]]; then
                        warned_v6=true
                        continue
                    fi
                    to="::/0"
                else
                    to="0.0.0.0/0"
                fi
                socks_rules+="$(dante_pass_block "$from" "$to" "none")"$'\n'
            done
            socks_rules+="$(dante_pass_block "0.0.0.0/0" "0.0.0.0/0" "username")"$'\n'
            [[ "$IPV6_ENABLED" == true ]] && socks_rules+="${v6_socks_user}"$'\n'
            ;;
        2)
            socks_method="socksmethod: username"
            client_rules="$(dante_client_block "0.0.0.0/0" "0.0.0.0/0")"$'\n'
            [[ "$IPV6_ENABLED" == true ]] && client_rules+="${v6_clients}"$'\n'
            socks_rules="$(dante_pass_block "0.0.0.0/0" "0.0.0.0/0" "username")"$'\n'
            [[ "$IPV6_ENABLED" == true ]] && socks_rules+="${v6_socks_user}"$'\n'
            ;;
        3)
            socks_method="socksmethod: none"
            client_rules=""
            socks_rules=""
            for ip in $WHITELIST_IPS; do
                from="$(cidr_for "$ip")"
                if is_ipv6 "$ip"; then
                    if [[ "$IPV6_ENABLED" != true ]]; then
                        warned_v6=true
                        continue
                    fi
                    to="::/0"
                else
                    to="0.0.0.0/0"
                fi
                client_rules+="$(dante_client_block "$from" "$to")"$'\n'
                socks_rules+="$(dante_pass_block "$from" "$to" "none")"$'\n'
            done
            ;;
    esac
    if [[ "$warned_v6" == true ]]; then
        log_warn "IPv6 на сервере выключен. IPv6-адреса белого списка записаны только в Squid."
    fi

    if [[ "$AUTH_CHOICE" == "3" && -z "${socks_rules//[[:space:]]/}" ]]; then
        log_err "Dante не получил ни одного применимого адреса белого списка."
        return 1
    fi

    local nopriv="${DANTE_NOPRIV_USER:-nobody}"
    cat > "$DANTE_CONF" <<EOF
# Generated by proxy-installer ${SCRIPT_VERSION}
# Username auth is socksmethod (SOCKS RFC 1929), not a client-rule method.
logoutput: ${DANTE_LOG}
${internal_block}
${external_line}
user.privileged: root
user.unprivileged: ${nopriv}
clientmethod: none
${socks_method}

${client_rules}
client block {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect error
}

${socks_rules}
socks block {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect error
}
EOF
}

configure_dante() {
    backup_file "$DANTE_CONF"
    detect_external_net
    detect_dante_unprivileged
    ensure_dante_log
    write_dante_conf || die "Конфигурация Dante не собрана."

    if ! danted -f "$DANTE_CONF" -V >/dev/null 2>&1; then
        sed -i 's/^user\.unprivileged:/user.notprivileged:/' "$DANTE_CONF"
        if ! danted -f "$DANTE_CONF" -V >/dev/null 2>&1; then
            log_err "danted -V не принял ${DANTE_CONF}. Последние строки ${DANTE_LOG}:"
            tail -n 40 "$DANTE_LOG" >&2 || true
            die "Проверьте внешний адрес и правила Dante."
        fi
    fi

    mkdir -p /etc/systemd/system/danted.service.d
    cat > "$DANTE_DROPIN" <<EOF
[Service]
# The packaged unit makes /var read-only. Allow the Dante log file.
ReadWritePaths=${DANTE_LOG}
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true

    cat > "$LOGROTATE_FILE" <<EOF
${DANTE_LOG} {
    weekly
    rotate 8
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF

    log_ok "Dante: интерфейс ${EXTERNAL_INTERFACE}, адрес ${EXTERNAL_IPV4:-auto}, порт ${DANTE_PORT}."
}

write_fail2ban_filters() {
    cat > "$FAIL2BAN_FILTER" <<'EOF'
[Definition]
# Dante 1.4.3 file log:
# Oct 23 22:06:46 (epoch) danted[pid]: info: block(1): tcp/accept ]: 203.0.113.5.54321 ...
failregex = info: block\(\d+\): tcp/accept \]: <HOST>\.\d+
ignoreregex =
EOF

    cat > "$FAIL2BAN_SQUID_FILTER" <<'EOF'
[Definition]
# logformat proxyinstaller %{%Y-%m-%dT%H:%M:%S}tl %>a %Ss/%03>Hs %rm %ru %un
# Example: 2026-10-25T17:34:01 203.0.113.9 TCP_DENIED/407 CONNECT example.com:443 -
# The timestamp is optional in the regex because Fail2ban removes a recognized
# date before matching, and required when that removal does not happen.
failregex = ^(?:\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\s+)?\s*<HOST> [A-Z_]+_DENIED/\d+
datepattern = {^LN-BEG}ExYear-Month-DayT24hour:Minute:Second
ignoreregex =
EOF
}

configure_fail2ban() {
    backup_file "$FAIL2BAN_JAIL"
    backup_file "$FAIL2BAN_FILTER"

    local ignore="127.0.0.1/8 ::1"
    local ssh_ports="ssh"
    if ((${#SSH_PORTS[@]} > 0)); then
        ssh_ports="$(IFS=,; echo "${SSH_PORTS[*]}")"
    fi
    if [[ -n "$WHITELIST_IPS" ]]; then
        ignore="${ignore} ${WHITELIST_IPS}"
    fi

    mkdir -p /etc/fail2ban/jail.d /etc/fail2ban/filter.d
    write_fail2ban_filters
    cat > "$FAIL2BAN_JAIL" <<EOF
# Do not set backend or journalmatch here. Debian matches ssh.service,
# Ubuntu matches sshd via the journal. Overriding either one breaks the other.
[sshd]
enabled = true
port = ${ssh_ports}
maxretry = 5
findtime = 10m
bantime = 1h

[squid-proxy-installer]
enabled = true
filter = squid-proxy-installer
port = ${SQUID_PORT}
logpath = /var/log/squid/access.log
backend = polling
bantime = 2h
findtime = 10m
maxretry = 8
ignoreip = ${ignore}

[dante-proxy-installer]
enabled = true
filter = dante-proxy-installer
port = ${DANTE_PORT}
protocol = tcp
logpath = ${DANTE_LOG}
backend = polling
bantime = 2h
findtime = 10m
maxretry = 8
ignoreip = ${ignore}
EOF

    log_ok "Fail2ban: отдельный jail.d drop-in (существующий jail.local не перезаписывается)."
}

# ====================================================================
# Firewall
# ====================================================================

ufw_output_allows_port() {
    local text="$1" port="$2" proto="${3:-tcp}"
    grep -Eq "(^|[[:space:]])allow[[:space:]]+${port}/${proto}([[:space:]]|$)" <<<"$text" && return 0
    grep -Eq -- "--dport ${port}([^0-9]|$)" <<<"$text"
}

setup_firewall() {
    echo -e "\n${C_YELLOW}--- Настройка firewall ---${C_RESET}"
    detect_ssh_port

    local prev_squid prev_dante ssh_port
    prev_squid="$(state_get SQUID_PORT)"
    prev_dante="$(state_get DANTE_PORT)"

    if systemctl is-active firewalld >/dev/null 2>&1 && command_exists firewall-cmd; then
        log_info "Обнаружен firewalld — правила будут добавлены в него (UFW не включается)."
        if [[ -n "$prev_squid" && "$prev_squid" != "$SQUID_PORT" ]]; then
            remove_firewalld_port "$prev_squid"
        fi
        if [[ -n "$prev_dante" && "$prev_dante" != "$DANTE_PORT" ]]; then
            remove_firewalld_port "$prev_dante"
        fi
        firewall-cmd --permanent --add-port="${SQUID_PORT}/tcp" >/dev/null
        firewall-cmd --permanent --add-port="${DANTE_PORT}/tcp" >/dev/null
        firewall-cmd --permanent --add-port="${DANTE_PORT}/udp" >/dev/null
        for ssh_port in "${SSH_PORTS[@]}"; do
            firewall-cmd --permanent --add-port="${ssh_port}/tcp" >/dev/null || true
        done
        firewall-cmd --reload >/dev/null
        save_runtime_state
        log_ok "firewalld: открыты ${SQUID_PORT}/tcp, ${DANTE_PORT}/tcp+udp, SSH ${SSH_PORTS[*]}."
        return 0
    fi

    if ! dpkg -s ufw >/dev/null 2>&1; then
        apt-get install -y -qq ufw >/dev/null || { log_warn "Не удалось установить ufw. Откройте порты вручную."; save_runtime_state; return 0; }
    fi

    local ufw_was_active=false
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw_was_active=true
    fi

    mkdir -p /etc/ufw
    ufw status numbered > /etc/ufw/ufw.rules.backup 2>/dev/null || true

    if [[ -n "$prev_squid" && "$prev_squid" != "$SQUID_PORT" ]]; then
        remove_ufw_port "$prev_squid"
    fi
    if [[ -n "$prev_dante" && "$prev_dante" != "$DANTE_PORT" ]]; then
        remove_ufw_port "$prev_dante"
    fi

    for ssh_port in "${SSH_PORTS[@]}"; do
        ufw allow "${ssh_port}/tcp" comment "SSH (proxy-installer)" >/dev/null
    done
    ufw allow "${SQUID_PORT}/tcp" comment "Squid HTTP proxy" >/dev/null
    ufw allow "${DANTE_PORT}/tcp" comment "Dante SOCKS5" >/dev/null
    ufw allow "${DANTE_PORT}/udp" comment "Dante UDP ASSOCIATE" >/dev/null

    if [[ "$ufw_was_active" == true ]]; then
        ufw reload >/dev/null
        save_runtime_state
        log_ok "UFW был активен: добавлены порты прокси, SSH (${SSH_PORTS[*]}) сохранён."
        return 0
    fi

    if [[ "$ENABLE_UFW" == true ]]; then
        local status_text
        # While UFW is inactive, "ufw status" prints only "Status: inactive"
        # and hides the rules that "ufw allow" already stored.
        status_text="$(ufw show added 2>/dev/null || true)"
        status_text+=$'\n'"$(cat /etc/ufw/user.rules /etc/ufw/user6.rules 2>/dev/null || true)"
        for ssh_port in "${SSH_PORTS[@]}"; do
            if ! ufw_output_allows_port "$status_text" "$ssh_port" tcp; then
                die "Правило SSH ${ssh_port}/tcp не появилось в UFW. Включение firewall отменено, чтобы не потерять доступ."
            fi
        done
        ufw --force enable >/dev/null
        log_ok "UFW включён. Перед этим явно разрешён SSH (${SSH_PORTS[*]})."
    else
        log_warn "UFW не был активен и не включался. Правила добавлены, но фильтр выключен."
        log_warn "Включите его позже: ufw enable (SSH ${SSH_PORTS[*]} уже разрешён)."
    fi
    save_runtime_state
}

save_runtime_state() {
    state_set SQUID_PORT "$SQUID_PORT"
    state_set DANTE_PORT "$DANTE_PORT"
    state_set AUTH_CHOICE "$AUTH_CHOICE"
    state_set WHITELIST_IPS "$WHITELIST_IPS"
}

# ====================================================================
# Users / services
# ====================================================================

read_password_twice() {
    local user="$1" first="" second=""
    while true; do
        read -r -s -p "   Пароль для '$user' (и Squid, и Dante, минимум 8 символов): " first || return 1
        printf '\n' >&2
        read -r -s -p "   Повтор пароля: " second || return 1
        printf '\n' >&2
        if [[ "$first" != "$second" ]]; then
            log_err "Пароли не совпали."
            continue
        fi
        if ((${#first} < 8)); then
            log_err "Пароль короче 8 символов."
            continue
        fi
        if [[ "$first" == "$user" ]]; then
            log_err "Пароль не должен совпадать с именем пользователя."
            continue
        fi
        if [[ "$first" == *$'\n'* ]]; then
            log_err "Пароль не должен содержать перевод строки."
            continue
        fi
        printf '%s' "$first"
        return 0
    done
}

retire_stale_proxy_users() {
    local old="" keep current
    local existing=()
    mapfile -t existing < <(read_tracked_users)
    for old in "${existing[@]}"; do
        [[ -n "$old" ]] || continue
        keep=false
        for current in "${USERS[@]}"; do
            if [[ "$current" == "$old" ]]; then
                keep=true
                break
            fi
        done
        if [[ "$keep" == false ]]; then
            log_info "Удаляю учётную запись '$old': её нет в новом списке."
            safe_delete_user "$old" || true
            if [[ -f "$USERS_FILE" ]]; then
                grep -vxF "$old" "$USERS_FILE" > "${USERS_FILE}.tmp" || true
                mv "${USERS_FILE}.tmp" "$USERS_FILE"
            fi
        fi
    done
}

add_squid_case_alias() {
    # Squid lowercases Basic usernames before the helper. Keep the original
    # htpasswd entry (and the system account used by Dante) and add a
    # lowercase alias with the same hash, e.g. RuProxySitc and ruproxysitc.
    local user="$1" lower="${1,,}" hash tmp
    [[ "$lower" == "$user" ]] && return 0
    [[ -f "$SQUID_PASSWD" ]] || return 1
    hash="$(awk -F: -v u="$user" '$1 == u { sub(/^[^:]*:/, ""); print; exit }' "$SQUID_PASSWD")"
    [[ -n "$hash" ]] || return 1
    tmp="$(mktemp)"
    awk -F: -v u="$lower" '$1 != u' "$SQUID_PASSWD" > "$tmp"
    printf '%s:%s\n' "$lower" "$hash" >> "$tmp"
    mv "$tmp" "$SQUID_PASSWD"
    log_info "Squid получит логин '$lower'. Исходное имя '$user' и его пароль сохранены."
}

create_or_update_users() {
    retire_stale_proxy_users
    if [[ "$AUTH_CHOICE" == "3" ]]; then
        rm -f "$SQUID_PASSWD"
    fi
    ((${#USERS[@]} > 0)) || return 0
    echo -e "\n${C_YELLOW}--- Шаг 3: Пользователи и пароли ---${C_RESET}"
    detect_nologin
    mkdir -p /etc/squid
    rm -f "$SQUID_PASSWD"

    local user password first_htpasswd=true
    for user in "${USERS[@]}"; do
        echo "-> Пользователь '$user'"
        if id "$user" >/dev/null 2>&1; then
            if grep -qxF "$user" "$USERS_FILE" 2>/dev/null; then
                log_info "Учётная запись уже создана этим установщиком. Обновляем пароль."
            else
                die "Пользователь '$user' уже существует и не был создан этим скриптом."
            fi
        else
            useradd --system --no-create-home --shell "$NOLOGIN_SHELL" --comment "proxy-installer" "$user" \
                || die "Не удалось создать пользователя '$user'."
            remember_user "$user"
            log_ok "Создан пользователь прокси '$user'."
        fi

        chage -m 0 -M 99999 -I -1 -E -1 "$user" >/dev/null 2>&1 || true
        password="$(read_password_twice "$user")" || die "Не удалось прочитать пароль для '$user'."
        printf '%s:%s\n' "$user" "$password" | chpasswd || die "Не удалось задать системный пароль для '$user'."
        if [[ "$first_htpasswd" == true ]]; then
            printf '%s\n' "$password" | htpasswd -i -c "$SQUID_PASSWD" "$user" \
                || die "Не удалось создать ${SQUID_PASSWD}."
            first_htpasswd=false
        else
            printf '%s\n' "$password" | htpasswd -i "$SQUID_PASSWD" "$user" \
                || die "Не удалось добавить '$user' в ${SQUID_PASSWD}."
        fi
        add_squid_case_alias "$user" || die "Не удалось добавить строчный алиас Squid для '$user'."
        log_ok "Пароль пользователя прокси '$user' записан для Dante и Squid."
        password=""
    done

    detect_proxy_user
    chown "root:${PROXY_USER}" "$SQUID_PASSWD"
    chmod 640 "$SQUID_PASSWD"
}

assert_ports_still_free() {
    if port_held_by_foreign_service "$SQUID_PORT"; then
        die "Порт Squid $SQUID_PORT заняла другая служба. Выберите другой порт."
    fi
    if port_held_by_foreign_service "$DANTE_PORT"; then
        die "Порт Dante $DANTE_PORT заняла другая служба. Выберите другой порт."
    fi
}

restart_one() {
    local unit="$1" required="${2:-1}"
    if ! systemctl restart "$unit"; then
        log_err "Не удалось запустить $unit. Последние логи:"
        journalctl -u "$unit" -n 40 --no-pager || true
        [[ "$required" == "1" ]] && exit 1
        return 1
    fi
    systemctl enable "$unit" >/dev/null 2>&1 || true
    sleep 1
    if ! systemctl is-active --quiet "$unit"; then
        log_err "Служба $unit не активна после запуска. Логи:"
        journalctl -u "$unit" -n 40 --no-pager || true
        [[ "$required" == "1" ]] && exit 1
        return 1
    fi
    log_ok "$unit запущен и добавлен в автозагрузку."
}

restart_services() {
    echo -e "\n${C_YELLOW}--- Шаг 5: Запуск служб ---${C_RESET}"
    if [[ "$INSTALL_UNBOUND" == true ]]; then
        if ! ensure_unbound_root_key; then
            log_warn "Нет /var/lib/unbound/root.key. Unbound не запускаю, Squid останется на системном DNS."
            sed -i '/^dns_nameservers /d' "$SQUID_CONF"
            INSTALL_UNBOUND=false
        fi
    fi
    if [[ "$INSTALL_UNBOUND" == true ]]; then
        systemctl reset-failed unbound >/dev/null 2>&1 || true
        if restart_one unbound 0; then
            log_ok "Unbound слушает 127.0.0.1:53."
        else
            log_warn "Unbound не запустился. Убираю dns_nameservers из Squid и продолжаю."
            sed -i '/^dns_nameservers /d' "$SQUID_CONF"
            INSTALL_UNBOUND=false
        fi
    fi
    restart_one squid 1
    restart_one danted 1
    restart_one fail2ban 0 || log_warn "Fail2ban не обязателен для работы прокси. Проверьте ${FAIL2BAN_JAIL}."
    setup_firewall
}

show_public_ip() {
    local pub=""
    if command_exists curl; then
        pub="$(curl -4 -fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)"
        [[ -z "$pub" ]] && pub="$(curl -4 -fsS --max-time 4 https://ifconfig.me 2>/dev/null || true)"
    fi
    if [[ -n "$pub" && "$pub" != "$SERVER_IP" ]]; then
        echo -e "  ${C_BLUE}Публичный IPv4:${C_RESET}     ${pub}"
    fi
}

# ====================================================================
# Interactive collection
# ====================================================================

maybe_cleanup_previous() {
    return 0
}

installer_present() {
    dpkg -s squid >/dev/null 2>&1 && return 0
    dpkg -s dante-server >/dev/null 2>&1 && return 0
    [[ -f "$STATE_FILE" || -f "$UNBOUND_DROPIN" || -f "$FAIL2BAN_JAIL" ]]
}

squid_port_from_conf() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    awk '/^http_port[[:space:]]+[0-9]/ {gsub(/[^0-9].*/, "", $2); if ($2+0 > 0) {print $2; exit}}' "$file"
}

dante_port_from_conf() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    awk '/^internal:[[:space:]]/ && /port[[:space:]]*=/ {
        for (i=1; i<=NF; i++) if ($i=="=") {gsub(/[^0-9]/, "", $(i+1)); print $(i+1); exit}
    }' "$file"
}

load_runtime_settings() {
    SQUID_PORT="$(state_get SQUID_PORT)"
    DANTE_PORT="$(state_get DANTE_PORT)"
    AUTH_CHOICE="$(state_get AUTH_CHOICE)"
    WHITELIST_IPS="$(state_get WHITELIST_IPS)"
    if [[ -z "$SQUID_PORT" ]]; then
        SQUID_PORT="$(squid_port_from_conf "$SQUID_CONF" 2>/dev/null || true)"
    fi
    if [[ -z "$DANTE_PORT" ]]; then
        DANTE_PORT="$(dante_port_from_conf "$DANTE_CONF" 2>/dev/null || true)"
    fi
}

require_proxy_ports() {
    load_runtime_settings
    if [[ -z "$SQUID_PORT" ]]; then
        local value=""
        while true; do
            read -r -e -i 3128 -p "Порт Squid [1-65535]: " value
            validate_port "$value" || continue
            SQUID_PORT="$(normalize_port "$value")"
            break
        done
    fi
    if [[ -z "$DANTE_PORT" ]]; then
        local value=""
        while true; do
            read -r -e -i 1080 -p "Порт Dante [1-65535]: " value
            validate_port "$value" || continue
            DANTE_PORT="$(normalize_port "$value")"
            break
        done
    fi
    save_runtime_state
}

point_squid_at_unbound() {
    [[ -f "$SQUID_CONF" ]] || return 0
    if grep -q '^dns_nameservers ' "$SQUID_CONF"; then
        sed -i 's/^dns_nameservers .*/dns_nameservers 127.0.0.1/' "$SQUID_CONF"
    else
        printf '\ndns_nameservers 127.0.0.1\n' >> "$SQUID_CONF"
    fi
    if systemctl is-active squid >/dev/null 2>&1; then
        systemctl try-restart squid >/dev/null 2>&1 || log_warn "Squid не перезапустился после смены DNS."
    fi
}

repair_unbound() {
    echo -e "\n${C_YELLOW}--- Unbound: установка и настройка ---${C_RESET}"
    local existed=0
    dpkg -s unbound >/dev/null 2>&1 && existed=1
    INSTALL_UNBOUND=true
    apt_install unbound dns-root-data
    state_set INSTALLED_UNBOUND 1
    if [[ "$(state_get UNBOUND_PREEXISTED)" != "1" ]]; then
        state_set UNBOUND_PREEXISTED "$existed"
    fi
    configure_unbound
    if [[ "$INSTALL_UNBOUND" != true ]]; then
        return 1
    fi
    systemctl reset-failed unbound >/dev/null 2>&1 || true
    if ! restart_one unbound 0; then
        return 1
    fi
    point_squid_at_unbound
    log_ok "Unbound слушает 127.0.0.1:53 и подключён к Squid, если конфиг Squid уже есть."
}

remove_unbound() {
    echo -e "\n${C_YELLOW}--- Unbound: удаление ---${C_RESET}"
    systemctl stop unbound >/dev/null 2>&1 || true
    systemctl disable unbound >/dev/null 2>&1 || true
    rm -f "$UNBOUND_DROPIN"
    if [[ -f "$SQUID_CONF" ]]; then
        sed -i '/^dns_nameservers /d' "$SQUID_CONF"
        systemctl try-restart squid >/dev/null 2>&1 || true
    fi
    if dpkg -s unbound >/dev/null 2>&1; then
        if ask_yes_no "Удалить пакеты unbound и dns-root-data" "y"; then
            apt-get purge -y unbound dns-root-data || log_warn "Не удалось полностью удалить пакеты Unbound."
        fi
    fi
    state_set INSTALLED_UNBOUND 0
    log_ok "Настройка Unbound от этого установщика снята."
}

repair_ufw() {
    echo -e "\n${C_YELLOW}--- UFW: правила прокси и включение ---${C_RESET}"
    require_proxy_ports
    ENABLE_UFW=true
    setup_firewall
}

remove_ufw_rules() {
    echo -e "\n${C_YELLOW}--- UFW: снятие правил прокси ---${C_RESET}"
    load_runtime_settings
    if [[ -n "$SQUID_PORT" ]]; then
        remove_ufw_port "$SQUID_PORT"
    fi
    if [[ -n "$DANTE_PORT" ]]; then
        remove_ufw_port "$DANTE_PORT"
    fi
    if command_exists ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
        if ask_yes_no "Выключить UFW целиком" "n"; then
            ufw disable || log_warn "Не удалось выключить UFW."
        fi
    fi
    log_ok "Правила портов прокси убраны из UFW."
}

repair_fail2ban() {
    echo -e "\n${C_YELLOW}--- Fail2ban: перенастройка ---${C_RESET}"
    require_proxy_ports
    local existed=0
    dpkg -s fail2ban >/dev/null 2>&1 && existed=1
    apt_install fail2ban
    state_set INSTALLED_FAIL2BAN 1
    if [[ "$(state_get FAIL2BAN_PREEXISTED)" != "1" ]]; then
        state_set FAIL2BAN_PREEXISTED "$existed"
    fi
    configure_fail2ban
    systemctl reset-failed fail2ban >/dev/null 2>&1 || true
    restart_one fail2ban 0 || return 1
}

remove_fail2ban_rules() {
    echo -e "\n${C_YELLOW}--- Fail2ban: снятие правил установщика ---${C_RESET}"
    rm -f "$FAIL2BAN_JAIL" "$FAIL2BAN_FILTER" "$FAIL2BAN_SQUID_FILTER"
    if systemctl is-active fail2ban >/dev/null 2>&1; then
        systemctl reload fail2ban >/dev/null 2>&1 || systemctl restart fail2ban >/dev/null 2>&1 || true
    fi
    if dpkg -s fail2ban >/dev/null 2>&1 && ask_yes_no "Удалить пакет fail2ban" "n"; then
        systemctl stop fail2ban >/dev/null 2>&1 || true
        apt-get purge -y fail2ban || log_warn "Не удалось удалить fail2ban."
        state_set INSTALLED_FAIL2BAN 0
    fi
    log_ok "Правила Fail2ban этого установщика сняты."
}

restart_proxy_services() {
    echo -e "\n${C_YELLOW}--- Перезапуск Squid и Dante ---${C_RESET}"
    dpkg -s squid >/dev/null 2>&1 || { log_err "Пакет squid не установлен."; return 1; }
    dpkg -s dante-server >/dev/null 2>&1 || { log_err "Пакет dante-server не установлен."; return 1; }
    restart_one squid 1
    restart_one danted 1
}

run_full_install() {
    log_info "Начата полная установка или переустановка."
    if installer_present; then
        echo
        echo "Уже есть установка Squid, Dante или файлы этого скрипта."
        if ask_yes_no "Удалить её и поставить заново с новыми настройками" "y"; then
            local tracked_preview=""
            tracked_preview="$(read_tracked_users | tr '\n' ' ')"
            if [[ -n "$tracked_preview" ]]; then
                log_info "Будут удалены учётные записи: ${tracked_preview}"
            fi
            cleanup
        else
            log_info "Пакеты сохраняются. Конфигурация будет записана заново."
        fi
    fi
    mkdir -p "$STATE_DIR"
    collect_settings
    echo
    log_ok "Параметры собраны, начинаем установку."
    sleep 1
    install_packages
    assert_ports_still_free
    apply_sysctl
    create_or_update_users
    configure_unbound
    configure_squid
    configure_dante
    configure_fail2ban
    restart_services
    print_summary
}

component_menu() {
    while true; do
        load_runtime_settings
        echo
        echo -e "${C_YELLOW}Отдельные компоненты${C_RESET}"
        echo "  Squid: ${SQUID_PORT:-не задан}    Dante: ${DANTE_PORT:-не задан}"
        echo "  1) Unbound — установить или перенастроить"
        echo "  2) Unbound — удалить"
        echo "  3) UFW — открыть порты прокси и включить"
        echo "  4) UFW — убрать правила прокси"
        echo "  5) Fail2ban — перенастроить"
        echo "  6) Fail2ban — убрать правила установщика"
        echo "  7) Перезапустить Squid и Dante"
        echo "  8) Назад"
        local choice=""
        read -r -p "Ваш выбор [1-8]: " choice
        case "$choice" in
            1) repair_unbound || true ;;
            2) remove_unbound ;;
            3) repair_ufw ;;
            4) remove_ufw_rules ;;
            5) repair_fail2ban ;;
            6) remove_fail2ban_rules ;;
            7) restart_proxy_services ;;
            8) return 0 ;;
            *) log_err "Введите число от 1 до 8." ;;
        esac
    done
}

main_menu() {
    while true; do
        echo
        echo -e "${C_YELLOW}Главное меню${C_RESET}"
        echo "  1) Установить или переустановить всё"
        echo "  2) Отдельный компонент: установить, перенастроить или удалить"
        echo "  3) Полностью удалить то, что поставил этот скрипт"
        echo "  4) Выход"
        local choice=""
        read -r -p "Ваш выбор [1-4]: " choice
        case "$choice" in
            1) run_full_install; return 0 ;;
            2) component_menu ;;
            3)
                if ! installer_present; then
                    log_info "Установка скрипта не обнаружена."
                    continue
                fi
                if ask_yes_no "Удалить Squid, Dante, настройки Unbound, Fail2ban и UFW этого скрипта" "n"; then
                    cleanup
                    log_ok "Удаление завершено."
                    return 0
                fi
                ;;
            4) exit 0 ;;
            *) log_err "Введите число от 1 до 4." ;;
        esac
    done
}

collect_settings() {
    echo -e "\n${C_YELLOW}--- Шаг 1: Параметры установки ---${C_RESET}"
    echo "Режим доступа к прокси:"
    local PS3=$'\n'"Ваш выбор (цифра): "
    select AUTH_MODE_TEXT in "Гибридный (пароль ИЛИ белый список IP)" "Только пароль" "Только белый список IP"; do
        AUTH_CHOICE="${REPLY}"
        case "$AUTH_CHOICE" in
            1|2|3) break ;;
            *) log_err "Неверный выбор." ;;
        esac
    done
    [[ "$AUTH_CHOICE" =~ ^[123]$ ]] || die "Режим доступа не выбран."

    WHITELIST_IPS=""
    if [[ "$AUTH_CHOICE" == "1" || "$AUTH_CHOICE" == "3" ]]; then
        while true; do
            echo
            echo "IP или CIDR для белого списка через пробел."
            echo "Примеры: 203.0.113.10  198.51.100.0/24  2001:db8::1"
            read -r -e -p "> " WHITELIST_IPS
            WHITELIST_IPS="$(normalize_ip_list "$WHITELIST_IPS")"
            if [[ "$AUTH_CHOICE" == "3" && -z "$WHITELIST_IPS" ]]; then
                log_err "Для режима «только белый список» нужен хотя бы один адрес."
                continue
            fi
            if [[ -n "$WHITELIST_IPS" ]] && ! validate_ips "$WHITELIST_IPS"; then
                continue
            fi
            break
        done
    fi

    USERS=()
    if [[ "$AUTH_CHOICE" == "1" || "$AUTH_CHOICE" == "2" ]]; then
        echo
        echo "Добавьте пользователей. Пустое имя — конец списка."
        while true; do
            local username=""
            read -r -p "Имя пользователя: " username
            if [[ -z "$username" ]]; then
                if ((${#USERS[@]} == 0)); then
                    log_err "Нужен хотя бы один пользователь."
                    continue
                fi
                break
            fi
            validate_username "$username" || continue
            local dup
            for dup in "${USERS[@]}"; do
                if [[ "${dup,,}" == "${username,,}" ]]; then
                    log_err "Имя '$username' совпадает с '$dup' без учёта регистра. Squid ищет логин в нижнем регистре."
                    continue 2
                fi
            done
            if [[ "$username" != "${username,,}" ]]; then
                log_info "Для Squid будет добавлен алиас '${username,,}'. Для Dante останется '$username'."
            fi
            USERS+=("$username")
        done
    fi

    echo
    echo "Порты прокси. Не используйте порт SSH (${SSH_PORTS[*]})."
    while true; do
        read -r -e -i 3128 -p "Порт Squid (HTTP CONNECT) [1-65535]: " SQUID_PORT
        validate_port "$SQUID_PORT" || continue
        SQUID_PORT="$(normalize_port "$SQUID_PORT")"
        if is_ssh_port "$SQUID_PORT"; then
            log_err "Порт $SQUID_PORT занят SSH."
            continue
        fi
        if port_held_by_foreign_service "$SQUID_PORT"; then
            log_err "Порт $SQUID_PORT уже слушается другой службой."
            continue
        fi
        if ((SQUID_PORT < 1024)); then
            log_warn "Порт $SQUID_PORT меньше 1024 и может пересечься с системной службой."
        fi
        break
    done
    while true; do
        read -r -e -i 1080 -p "Порт Dante (SOCKS5) [1-65535]: " DANTE_PORT
        validate_port "$DANTE_PORT" || continue
        DANTE_PORT="$(normalize_port "$DANTE_PORT")"
        if [[ "$DANTE_PORT" == "$SQUID_PORT" ]]; then
            log_err "Порты Squid и Dante должны различаться."
            continue
        fi
        if is_ssh_port "$DANTE_PORT"; then
            log_err "Порт $DANTE_PORT занят SSH."
            continue
        fi
        if port_held_by_foreign_service "$DANTE_PORT"; then
            log_err "Порт $DANTE_PORT уже слушается другой службой."
            continue
        fi
        if ((DANTE_PORT < 1024)); then
            log_warn "Порт $DANTE_PORT меньше 1024 и может пересечься с системной службой."
        fi
        break
    done

    echo
    if ask_yes_no "Установить Unbound как локальный DNS только для Squid?" "n"; then
        INSTALL_UNBOUND=true
    else
        INSTALL_UNBOUND=false
    fi

    echo
    if ask_yes_no "Применить сетевые оптимизации (BBR, если ядро позволяет)?" "y"; then
        APPLY_OPTIMIZATIONS=true
    else
        APPLY_OPTIMIZATIONS=false
    fi

    echo
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        ENABLE_UFW=false
        log_info "UFW уже активен — будут добавлены правила для прокси и SSH."
    else
        if systemctl is-active firewalld >/dev/null 2>&1; then
            ENABLE_UFW=false
        else
            local ufw_default="n"
            if command_exists ss && ss -lntupH 2>/dev/null | grep -q sshd; then
                ufw_default="y"
            else
                log_warn "Не видно слушающего sshd. По умолчанию UFW не включается, чтобы не отрезать доступ."
            fi
            if ask_yes_no "Включить UFW? SSH (${SSH_PORTS[*]}) будет разрешён заранее." "$ufw_default"; then
                ENABLE_UFW=true
            else
                ENABLE_UFW=false
            fi
        fi
    fi
}

print_summary() {
    detect_external_net
    if [[ -t 1 ]]; then
        clear || true
    fi
    echo -e "${C_GREEN}=======================================================${C_RESET}"
    echo -e "${C_GREEN}Установка завершена.${C_RESET}"
    echo -e "${C_GREEN}=======================================================${C_RESET}"
    echo
    echo "Данные для подключения:"
    echo -e "  ${C_BLUE}IP сервера:${C_RESET}          ${SERVER_IP}"
    show_public_ip
    echo -e "  ${C_BLUE}Интерфейс:${C_RESET}           ${EXTERNAL_INTERFACE}"
    echo
    echo -e "  ${C_YELLOW}HTTP/HTTPS (Squid):${C_RESET}  ${SERVER_IP}:${SQUID_PORT}"
    echo -e "  ${C_YELLOW}SOCKS5 (Dante):${C_RESET}      ${SERVER_IP}:${DANTE_PORT}"
    echo
    echo -e "  ${C_YELLOW}Метод доступа:${C_RESET}       ${AUTH_MODE_TEXT}"
    if ((${#USERS[@]} > 0)); then
        echo -e "  ${C_YELLOW}Пользователи:${C_RESET}        ${USERS[*]}"
    fi
    if [[ -n "$WHITELIST_IPS" ]]; then
        echo -e "  ${C_YELLOW}Белый список:${C_RESET}        ${WHITELIST_IPS}"
    fi
    if [[ "$INSTALL_UNBOUND" == true ]]; then
        echo -e "  ${C_YELLOW}Unbound DNS:${C_RESET}         127.0.0.1:53 (только для Squid)"
    fi
    echo
    echo "Логи прокси: /var/log/squid/access.log , ${DANTE_LOG} , /var/log/fail2ban.log"
    echo "Журнал установщика (только root): ${INSTALL_LOG}"
    echo "Состояние установщика: ${STATE_FILE}"
    echo
    echo "Проверка Squid:  curl -x http://USER:PASS@${SERVER_IP}:${SQUID_PORT} https://example.com"
    echo "Проверка Dante:  curl -x socks5h://USER:PASS@${SERVER_IP}:${DANTE_PORT} https://example.com"
    echo -e "${C_GREEN}=======================================================${C_RESET}"
}

selftest() {
    local rc=0
    echo "Running installer self-tests..."

    expect_ok() {
        if ! "$@" 2>/dev/null; then
            echo "expected success: $*"
            rc=1
        fi
    }
    expect_fail() {
        if "$@" 2>/dev/null; then
            echo "expected failure: $*"
            rc=1
        fi
    }

    expect_ok validate_port 3128
    expect_ok validate_port 1
    expect_ok validate_port 65535
    expect_fail validate_port 0
    expect_fail validate_port 65536
    expect_fail validate_port abc

    expect_ok validate_username alice
    expect_ok validate_username user_1
    expect_ok validate_username Alice
    expect_fail validate_username root
    expect_fail validate_username 'a b'
    expect_fail validate_username 1abc

    expect_ok validate_ip_or_cidr 8.8.8.8
    expect_ok validate_ip_or_cidr 192.168.1.0/24
    expect_fail validate_ip_or_cidr 999.999.999.999
    expect_fail validate_ip_or_cidr 1.2.3.4:8080
    expect_fail validate_ip_or_cidr 08.1.1.1

    [[ "$(cidr_for 1.2.3.4)" == "1.2.3.4/32" ]] || { echo "cidr_for v4 failed"; rc=1; }
    [[ "$(cidr_for 10.0.0.0/8)" == "10.0.0.0/8" ]] || { echo "cidr_for keep failed"; rc=1; }

    if command_exists python3; then
        expect_ok validate_ip_or_cidr 2001:db8::1
        expect_ok validate_ip_or_cidr 2001:db8::/32
    fi

    local port_sample
    port_sample="$(mktemp)"
    cat > "$port_sample" <<'EOF'
http_port 3128
internal: 0.0.0.0 port = 1080
EOF
    [[ "$(normalize_port 03128)" == "3128" ]] || { echo "normalize_port failed"; rc=1; }
    local log_sample previous_ready previous_path
    log_sample="$(mktemp)"
    previous_ready="$INSTALL_LOG_READY"
    previous_path="$INSTALL_LOG"
    INSTALL_LOG="$log_sample"
    INSTALL_LOG_READY=1
    log_write SESSION "======== новая установка: запуск test ========"
    log_write OK "Пользователь прокси 'alice' записан"
    log_write ERROR "пример ошибки"
    log_write SESSION "======== новая установка: запуск test-2 ========"
    [[ "$(grep -c 'новая установка' "$log_sample")" -eq 2 ]] || { echo "install log must append sessions"; rc=1; }
    grep -q "\[OK\] Пользователь прокси 'alice' записан" "$log_sample" || { echo "install log missed user"; rc=1; }
    grep -q "\[ERROR\] пример ошибки" "$log_sample" || { echo "install log missed error"; rc=1; }
    INSTALL_LOG_READY="$previous_ready"
    INSTALL_LOG="$previous_path"
    rm -f "$log_sample"
    [[ "$(squid_port_from_conf "$port_sample")" == "3128" ]] || { echo "squid port parse failed"; rc=1; }
    [[ "$(dante_port_from_conf "$port_sample")" == "1080" ]] || { echo "dante port parse failed"; rc=1; }
    rm -f "$port_sample"
    inactive=$'Status: inactive\n'
    added=$'Added user rules:\nufw allow 22/tcp comment SSH\n'
    rules='-A ufw-user-input -p tcp --dport 22 -j ACCEPT'
    if ufw_output_allows_port "$inactive" 22 tcp; then
        echo "inactive ufw status must not count as an SSH rule"
        rc=1
    fi
    if ! ufw_output_allows_port "$added" 22 tcp; then
        echo "ufw show added should allow 22/tcp"
        rc=1
    fi
    if ! ufw_output_allows_port "$rules" 22 tcp; then
        echo "ufw user.rules should allow 22/tcp"
        rc=1
    fi
    if ufw_output_allows_port "$added" 2222 tcp; then
        echo "port 2222 must not match a 22 rule"
        rc=1
    fi
    [[ "$(dante_candidate_action debian 12 1.4.2+dfsg-7)" == "refuse" ]] || { echo "debian 12 must refuse dante 1.4.2"; rc=1; }
    [[ "$(dante_candidate_action debian 11 1.4.2+dfsg-7+b2)" == "refuse" ]] || { echo "debian 11 must refuse dante 1.4.2"; rc=1; }
    [[ "$(dante_candidate_action debian 13 1.4.2+dfsg-7)" == "replace" ]] || { echo "debian 13 must replace dante 1.4.2"; rc=1; }
    [[ "$(dante_candidate_action debian 13 1.4.4+dfsg2-1+b1)" == "accept" ]] || { echo "debian 13 must accept dante 1.4.4"; rc=1; }
    [[ "$(dante_candidate_action ubuntu 20.04 1.4.2+dfsg-7)" == "refuse" ]] || { echo "ubuntu 20.04 must refuse dante 1.4.2"; rc=1; }
    [[ "$(dante_candidate_action ubuntu 22.04 1.4.3+dfsg-1)" == "refuse" ]] || { echo "ubuntu 22.04 must refuse dante 1.4.3"; rc=1; }
    [[ "$(dante_candidate_action ubuntu 24.04 1.4.3+dfsg-1)" == "replace" ]] || { echo "ubuntu 24.04 must replace dante 1.4.3"; rc=1; }
    [[ "$(dante_candidate_action ubuntu 24.04 1.4.3+dfsg-1 2.39)" == "replace" ]] || { echo "ubuntu 24.04 glibc 2.39 must replace"; rc=1; }
    [[ "$(dante_candidate_action ubuntu 22.04 1.4.3+dfsg-1 2.35)" == "refuse" ]] || { echo "ubuntu 22.04 glibc 2.35 must refuse"; rc=1; }
    [[ "$(dante_candidate_action ubuntu 20.04 1.4.2+dfsg-7 2.31)" == "refuse" ]] || { echo "ubuntu 20.04 glibc 2.31 must refuse"; rc=1; }
    [[ "$(dante_candidate_action linuxmint 22 1.4.3+dfsg-1 2.39)" == "replace" ]] || { echo "mint 22 on noble glibc must replace"; rc=1; }
    [[ "$(dante_fallback_suite riscv64)" == "forky" ]] || { echo "dante suite riscv64 failed"; rc=1; }
    if dante_fallback_suite armhf >/dev/null; then
        echo "dante suite armhf should fail"
        rc=1
    fi
    [[ "$(normalize_ip_list '203.0.113.1, 198.51.100.0/24;')" == "203.0.113.1 198.51.100.0/24" ]] \
        || { echo "normalize_ip_list failed: [$(normalize_ip_list '203.0.113.1, 198.51.100.0/24;')]"; rc=1; }

    local old_passwd passwd_file
    old_passwd="$SQUID_PASSWD"
    passwd_file="$(mktemp)"
    SQUID_PASSWD="$passwd_file"
    printf '%s\n' 'RuProxySitc:apr1-salt-hash' > "$SQUID_PASSWD"
    add_squid_case_alias RuProxySitc || { echo "case alias failed"; rc=1; }
    grep -qxF 'RuProxySitc:apr1-salt-hash' "$SQUID_PASSWD" || { echo "original htpasswd entry missing"; rc=1; }
    grep -qxF 'ruproxysitc:apr1-salt-hash' "$SQUID_PASSWD" || { echo "lowercase htpasswd alias missing"; rc=1; }
    printf '%s\n' 'alice:apr1-x' > "$SQUID_PASSWD"
    add_squid_case_alias alice || { echo "lowercase alias no-op failed"; rc=1; }
    [[ "$(grep -c . "$SQUID_PASSWD")" -eq 1 ]] || { echo "lowercase user should not gain an alias"; rc=1; }
    SQUID_PASSWD="$old_passwd"
    rm -f "$passwd_file"

    local render_dir old_squid old_dante old_log
    render_dir="$(mktemp -d)"
    old_squid="$SQUID_CONF"
    old_dante="$DANTE_CONF"
    old_log="$DANTE_LOG"
    SQUID_CONF="${render_dir}/squid.conf"
    DANTE_CONF="${render_dir}/danted.conf"
    DANTE_LOG="${render_dir}/danted.log"
    AUTH_CHOICE=1
    AUTH_MODE_TEXT="hybrid"
    WHITELIST_IPS="203.0.113.10 2001:db8::5"
    SQUID_PORT=3128
    DANTE_PORT=1080
    EXTERNAL_IPV4="127.0.0.1"
    EXTERNAL_INTERFACE="lo"
    SERVER_IP="203.0.113.2"
    SQUID_HELPER="/usr/lib/squid/basic_ncsa_auth"
    DANTE_NOPRIV_USER="nobody"
    IPV6_ENABLED=true
    INSTALL_UNBOUND=false
    write_squid_conf
    write_dante_conf || { echo "write_dante_conf failed"; rc=1; }
    grep -q 'user.unprivileged: nobody' "$DANTE_CONF" || { echo "dante user keyword missing"; rc=1; }
    grep -q 'socksmethod: username' "$DANTE_CONF" || { echo "dante socksmethod missing"; rc=1; }
    grep -q 'from: 2001:db8::5/128 to: ::/0' "$DANTE_CONF" || { echo "dante ipv6 rule missing"; rc=1; }
    grep -q 'http_port \[::\]:3128' "$SQUID_CONF" || { echo "squid ipv6 port missing"; rc=1; }
    grep -q 'acl to_self dst 203.0.113.2' "$SQUID_CONF" || { echo "squid to_self missing"; rc=1; }
    grep -q 'logformat proxyinstaller %{%Y-%m-%dT%H:%M:%S}tl' "$SQUID_CONF" || { echo "squid logformat missing"; rc=1; }
    if grep -q 'acl localhost' "$SQUID_CONF"; then
        echo "squid redefined built-in localhost ACL"
        rc=1
    fi
    if grep -q '^resolve ' "$DANTE_CONF"; then
        echo "dante still has invalid resolve block"
        rc=1
    fi
    if command_exists squid; then
        squid -k parse -f "$SQUID_CONF" >/dev/null 2>&1 || { echo "squid -k parse failed"; squid -k parse -f "$SQUID_CONF" || true; rc=1; }
    fi
    if command_exists danted; then
        danted -f "$DANTE_CONF" -V >/dev/null 2>&1 || { echo "danted -V failed"; danted -f "$DANTE_CONF" -V || true; rc=1; }
    fi
    if command_exists fail2ban-regex; then
        local old_dante_filter old_squid_filter dante_line squid_line
        old_dante_filter="$FAIL2BAN_FILTER"
        old_squid_filter="$FAIL2BAN_SQUID_FILTER"
        FAIL2BAN_FILTER="${render_dir}/dante-proxy-installer.conf"
        FAIL2BAN_SQUID_FILTER="${render_dir}/squid-proxy-installer.conf"
        write_fail2ban_filters
        dante_line='Oct 23 22:06:46 (1792793206.163861) danted[1]: info: block(1): tcp/accept ]: 203.0.113.50.47538 203.0.113.2.11080: error after reading 4 bytes'
        fail2ban-regex "$dante_line" "$FAIL2BAN_FILTER" 2>/dev/null | grep -q '1 matched' || { echo "dante fail2ban regex missed"; rc=1; }
        # Same line Squid writes for logformat %{%Y-%m-%dT%H:%M:%S}tl %>a %Ss/%03>Hs
        squid_line='2026-10-25T17:34:01 203.0.113.9 TCP_DENIED/407 CONNECT example.com:443 -'
        fail2ban-regex "$squid_line" "$FAIL2BAN_SQUID_FILTER" 2>/dev/null | grep -q '1 matched' || { echo "squid fail2ban regex missed"; rc=1; }
        squid_line='2026-10-25T17:34:01 198.51.100.8 TCP_TUNNEL/200 CONNECT example.com:443 alice'
        if fail2ban-regex "$squid_line" "$FAIL2BAN_SQUID_FILTER" 2>/dev/null | grep -q '1 matched'; then
            echo "squid fail2ban regex matched a successful request"
            rc=1
        fi
        FAIL2BAN_FILTER="$old_dante_filter"
        FAIL2BAN_SQUID_FILTER="$old_squid_filter"
    fi
    SQUID_CONF="$old_squid"
    DANTE_CONF="$old_dante"
    DANTE_LOG="$old_log"
    rm -rf "$render_dir"

    if ((rc == 0)); then
        echo "All self-tests passed."
    else
        echo "Self-tests FAILED."
    fi
    return "$rc"
}

usage() {
    cat <<'EOF'
Usage: sudo ./proxy-installer.sh
       sudo ./proxy-installer.sh --selftest
       sudo ./proxy-installer.sh --help

Interactive installer for Squid (HTTP CONNECT) and Dante (SOCKS5)
on Debian 13+ / Ubuntu 24.04+ and derivatives.

Do not pipe this script into bash: menus need a TTY.
EOF
}

# ====================================================================
# Main
# ====================================================================

main() {
    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
        --selftest) selftest; exit $? ;;
    esac

    if [[ -t 1 ]]; then
        clear || true
    fi
    print_banner

    is_root || die "Запустите скрипт с правами root (sudo)."
    init_install_log
    is_tty || die "Нужен интерактивный терминал. Скачайте скрипт и запустите: sudo ./proxy-installer.sh"

    detect_os
    detect_nologin
    check_internet
    check_disk
    ensure_iproute
    detect_ssh_port
    if ipv6_is_enabled; then
        IPV6_ENABLED=true
        log_info "IPv6 включён: Squid и Dante будут слушать его тоже."
    else
        IPV6_ENABLED=false
    fi

    maybe_cleanup_previous
    main_menu
}

main "$@"
