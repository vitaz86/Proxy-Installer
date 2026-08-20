#!/usr/bin/env bash
# ====================================================================
#   Advanced Proxy Installer v8 by vitaz86
#   Interactive installer for Squid (HTTP/HTTPS forward proxy) and
#   Dante (SOCKS5) with optional IP whitelist, Fail2ban and Unbound.
#   Debian 11+ / Ubuntu 20.04+ and derivatives (Mint, Pop!_OS, etc.).
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

# --- State ---
STATE_DIR="/etc/proxy-installer"
STATE_FILE="${STATE_DIR}/state"
USERS_FILE="${STATE_DIR}/created-users"
SYSCTL_FILE="/etc/sysctl.d/99-proxy-installer.conf"
UNBOUND_DROPIN="/etc/unbound/unbound.conf.d/proxy-installer.conf"
FAIL2BAN_JAIL="/etc/fail2ban/jail.d/proxy-installer.local"
FAIL2BAN_FILTER="/etc/fail2ban/filter.d/dante-proxy-installer.conf"
LOGROTATE_FILE="/etc/logrotate.d/danted-proxy-installer"
SQUID_PASSWD="/etc/squid/passwd"
SQUID_CONF="/etc/squid/squid.conf"
DANTE_CONF="/etc/danted.conf"
DANTE_LOG="/var/log/danted.log"

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
SSH_PORT="22"
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

log_ok()   { echo -e "${C_GREEN}[+]${C_RESET} $*"; }
log_info() { echo -e "${C_BLUE}[*]${C_RESET} $*"; }
log_warn() { echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
log_err()  { echo -e "${C_RED}[x]${C_RESET} $*" >&2; }

die() {
    log_err "$*"
    exit 1
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

is_root() { [[ "${EUID}" -eq 0 ]]; }

is_tty() { [[ -t 0 && -t 1 ]]; }

print_banner() {
    echo -e "${C_BLUE}=======================================================${C_RESET}"
    echo -e "${C_BLUE}==   Advanced Proxy Installer v8 - vitaz86           ==${C_RESET}"
    echo -e "${C_BLUE}=======================================================${C_RESET}"
    echo
    echo "Установка Squid (HTTP/HTTPS CONNECT) и Dante (SOCKS5)"
    echo "с Fail2ban, опциональным Unbound и настройкой firewall."
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

validate_ip_or_cidr() {
    local input="$1" addr prefix

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
        ubuntu|linuxmint|pop|elementary|zorin|neon|kubuntu|xubuntu|lubuntu)
            local major="${OS_VERSION_ID%%.*}"
            if [[ "$major" =~ ^[0-9]+$ ]] && ((major < 20)); then
                die "Нужен Ubuntu 20.04 или новее (сейчас ${OS_VERSION_ID})."
            fi
            ;;
        debian|raspbian|devuan)
            local major="${OS_VERSION_ID%%.*}"
            if [[ "$major" =~ ^[0-9]+$ ]] && ((major < 11)); then
                die "Нужен Debian 11 или новее (сейчас ${OS_VERSION_ID})."
            fi
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
    local port=""
    if command_exists sshd; then
        port="$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')"
    fi
    if [[ -z "$port" && -f /etc/ssh/sshd_config ]]; then
        port="$(awk 'BEGIN{IGNORECASE=1} /^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config)"
    fi
    SSH_PORT="${port:-22}"
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
    local key="$1" value="$2"
    mkdir -p "$STATE_DIR"
    touch "$STATE_FILE"
    if grep -q "^${key}=" "$STATE_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$STATE_FILE"
    else
        echo "${key}=${value}" >> "$STATE_FILE"
    fi
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
    local port="$1"
    command_exists ufw || return 0
    ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
    ufw delete allow "${port}/udp" >/dev/null 2>&1 || true
}

cleanup() {
    echo -e "\n${C_YELLOW}--- Очистка предыдущей установки ---${C_RESET}"

    local old_squid old_dante
    old_squid="$(state_get SQUID_PORT)"
    old_dante="$(state_get DANTE_PORT)"
    [[ -n "$old_squid" ]] && remove_ufw_port "$old_squid"
    [[ -n "$old_dante" ]] && remove_ufw_port "$old_dante"

    systemctl stop squid danted 2>/dev/null || true
    systemctl disable squid danted 2>/dev/null || true
    log_info "Службы Squid и Dante остановлены."

    apt-get purge -y squid dante-server >/dev/null 2>&1 || true

    if [[ "$(state_get INSTALLED_UNBOUND)" == "1" ]]; then
        systemctl stop unbound 2>/dev/null || true
        apt-get purge -y unbound >/dev/null 2>&1 || true
    fi
    rm -f "$UNBOUND_DROPIN"

    rm -f "$FAIL2BAN_JAIL" "$FAIL2BAN_FILTER"
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
        if id "$user" >/dev/null 2>&1; then
            userdel -r "$user" >/dev/null 2>&1 || userdel "$user" >/dev/null 2>&1 || true
            log_info "Пользователь '$user' удалён."
        fi
    done

    rm -f "$SQUID_PASSWD" "$SYSCTL_FILE" "$LOGROTATE_FILE" "$DANTE_LOG"
    rm -rf "$STATE_DIR"
    log_ok "Очистка завершена."
    sleep 1
}

# ====================================================================
# Packages / sysctl / unbound
# ====================================================================

apt_install() {
    apt-get update -qq -o Acquire::Retries=3 || die "Не удалось обновить списки пакетов (apt-get update)."
    apt-get install -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" "$@" \
        || die "Не удалось установить пакеты: $*"
}

install_packages() {
    echo -e "\n${C_YELLOW}--- Шаг 2: Установка пакетов ---${C_RESET}"

    local pkgs=(squid dante-server apache2-utils fail2ban)
    command_exists curl || pkgs+=(curl)
    command_exists ip && command_exists ss || pkgs+=(iproute2)

    local fail2ban_existed=0
    dpkg -s fail2ban >/dev/null 2>&1 && fail2ban_existed=1

    apt_install "${pkgs[@]}"
    state_set INSTALLED_FAIL2BAN 1
    state_set FAIL2BAN_PREEXISTED "$fail2ban_existed"

    if [[ "$INSTALL_UNBOUND" == true ]]; then
        apt_install unbound
        state_set INSTALLED_UNBOUND 1
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

    if ! unbound-checkconf >/dev/null 2>&1; then
        log_warn "unbound-checkconf сообщил об ошибке. Проверьте $UNBOUND_DROPIN."
    fi
    log_ok "Unbound настроен на 127.0.0.1:53 (без публикации резолвера в интернет)."
}

# ====================================================================
# Service configs
# ====================================================================

configure_squid() {
    backup_file "$SQUID_CONF"
    detect_squid_helper || die "Не найден helper basic_ncsa_auth. Пакет squid установлен неполностью."
    detect_proxy_user

    local auth_block="" access_block="" dns_block=""
    if [[ "$AUTH_CHOICE" == "1" || "$AUTH_CHOICE" == "2" ]]; then
        auth_block=$(cat <<EOF
auth_param basic program ${SQUID_HELPER} ${SQUID_PASSWD}
auth_param basic realm Squid Proxy
auth_param basic credentialsttl 2 hours
auth_param basic children 5
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

    if [[ "$INSTALL_UNBOUND" == true ]]; then
        dns_block="dns_nameservers 127.0.0.1"
    fi

    cat > "$SQUID_CONF" <<EOF
# Generated by proxy-installer v8
visible_hostname proxy
httpd_suppress_version_string on
coredump_dir /var/spool/squid

acl localhost src 127.0.0.1/32 ::1
acl to_localhost dst 127.0.0.0/8 0.0.0.0/32 ::1
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
acl CONNECT method CONNECT

${auth_block}

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow localhost
http_access deny to_localhost
${access_block}
http_access deny all

http_port ${SQUID_PORT}
via off
forwarded_for delete
request_header_access From deny all
request_header_access Server deny all
request_header_access WWW-Authenticate deny all
request_header_access Link deny all

refresh_pattern ^ftp:           1440    20%     10080
refresh_pattern ^gopher:        1440    0%      1440
refresh_pattern -i (/cgi-bin/|\?) 0     0%      0
refresh_pattern .               0       20%     4320

shutdown_lifetime 5 seconds
${dns_block}
EOF

    if [[ -f "$SQUID_PASSWD" ]]; then
        chown "root:${PROXY_USER}" "$SQUID_PASSWD"
        chmod 640 "$SQUID_PASSWD"
    fi

    mkdir -p /var/spool/squid /var/log/squid
    chown -R "${PROXY_USER}:${PROXY_USER}" /var/spool/squid /var/log/squid 2>/dev/null || true
    if [[ ! -d /var/spool/squid/00 ]]; then
        squid -z --foreground >/dev/null 2>&1 || squid -z >/dev/null 2>&1 || true
    fi

    if ! squid -k parse >/dev/null 2>&1; then
        log_err "squid -k parse не принял конфигурацию. Фрагмент ошибки:"
        squid -k parse || true
        die "Исправьте ${SQUID_CONF} и повторите установку."
    fi
    log_ok "Squid: конфиг проверен (safe ports, скрытие заголовков, helper ${SQUID_HELPER})."
}

configure_dante() {
    backup_file "$DANTE_CONF"
    detect_external_net
    detect_dante_unprivileged
    ensure_dante_log

    local external_line="external: ${EXTERNAL_INTERFACE}"
    if [[ -n "$EXTERNAL_IPV4" ]]; then
        external_line="external: ${EXTERNAL_IPV4}"
    fi

    local socks_method client_rules socks_rules
    case "$AUTH_CHOICE" in
        1)
            socks_method="socksmethod: username none"
            client_rules="$(cat <<EOF
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}
EOF
)"
            socks_rules=""
            local ip
            for ip in $WHITELIST_IPS; do
                socks_rules+="socks pass {
    from: $(cidr_for "$ip") to: 0.0.0.0/0
    socksmethod: none
    command: connect udpassociate
    log: error
}
"
            done
            socks_rules+="$(cat <<EOF
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    socksmethod: username
    command: connect udpassociate
    log: error
}
EOF
)"
            ;;
        2)
            socks_method="socksmethod: username"
            client_rules="$(cat <<EOF
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}
EOF
)"
            socks_rules="$(cat <<EOF
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    socksmethod: username
    command: connect udpassociate
    log: error
}
EOF
)"
            ;;
        3)
            socks_method="socksmethod: none"
            client_rules=""
            socks_rules=""
            local ip
            for ip in $WHITELIST_IPS; do
                client_rules+="client pass {
    from: $(cidr_for "$ip") to: 0.0.0.0/0
    log: error
}
"
                socks_rules+="socks pass {
    from: $(cidr_for "$ip") to: 0.0.0.0/0
    socksmethod: none
    command: connect udpassociate
    log: error
}
"
            done
            ;;
    esac

    cat > "$DANTE_CONF" <<EOF
# Generated by proxy-installer v8
# Username auth is socksmethod (SOCKS RFC 1929), not clientmethod.
logoutput: syslog ${DANTE_LOG}
internal: 0.0.0.0 port = ${DANTE_PORT}
${external_line}
user.privileged: root
user.notprivileged: ${DANTE_NOPRIV_USER}
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

    cat > "$LOGROTATE_FILE" <<EOF
${DANTE_LOG} {
    weekly
    rotate 8
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        systemctl kill -s HUP danted.service >/dev/null 2>&1 || true
    endscript
}
EOF

    log_ok "Dante: интерфейс ${EXTERNAL_INTERFACE}, адрес ${EXTERNAL_IPV4:-auto}, порт ${DANTE_PORT}."
}

configure_fail2ban() {
    backup_file "$FAIL2BAN_JAIL"
    backup_file "$FAIL2BAN_FILTER"

    local ignore="127.0.0.1/8 ::1"
    if [[ -n "$WHITELIST_IPS" ]]; then
        ignore="${ignore} ${WHITELIST_IPS}"
    fi

    cat > "$FAIL2BAN_FILTER" <<'EOF'
[Definition]
# Dante 1.4 logs authentication/policy blocks with the client IP as a.b.c.d.port
failregex = ^\s*(?:\S+\s+\S+\s+)?(?:error|info): block\(\d+\): tcp/accept \[: <HOST>\.\d+\]:
            ^\s*(?:\S+\s+\S+\s+)?error: .*\[: <HOST>\.\d+\]:.*(?:authentication failed|password)
ignoreregex =
EOF

    cat > "$FAIL2BAN_JAIL" <<EOF
[squid]
enabled = true
port = ${SQUID_PORT}
logpath = /var/log/squid/access.log
backend = auto
bantime = 2h
findtime = 10m
maxretry = 8
ignoreip = ${ignore}

[dante-proxy-installer]
enabled = true
filter = dante-proxy-installer
port = ${DANTE_PORT}
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

setup_firewall() {
    echo -e "\n${C_YELLOW}--- Настройка firewall ---${C_RESET}"
    detect_ssh_port

    if systemctl is-active firewalld >/dev/null 2>&1 && command_exists firewall-cmd; then
        log_info "Обнаружен firewalld — правила будут добавлены в него (UFW не включается)."
        firewall-cmd --permanent --add-port="${SQUID_PORT}/tcp" >/dev/null
        firewall-cmd --permanent --add-port="${DANTE_PORT}/tcp" >/dev/null
        firewall-cmd --permanent --add-port="${DANTE_PORT}/udp" >/dev/null
        firewall-cmd --permanent --add-port="${SSH_PORT}/tcp" >/dev/null || true
        firewall-cmd --reload >/dev/null
        log_ok "firewalld: открыты ${SQUID_PORT}/tcp, ${DANTE_PORT}/tcp+udp, SSH ${SSH_PORT}/tcp."
        return 0
    fi

    if ! dpkg -s ufw >/dev/null 2>&1; then
        apt-get install -y -qq ufw >/dev/null || { log_warn "Не удалось установить ufw. Откройте порты вручную."; return 0; }
    fi

    local ufw_was_active=false
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw_was_active=true
    fi

    mkdir -p /etc/ufw
    ufw status numbered > /etc/ufw/ufw.rules.backup 2>/dev/null || true

    ufw allow "${SSH_PORT}/tcp" comment "SSH (proxy-installer)" >/dev/null
    ufw allow OpenSSH >/dev/null 2>&1 || true
    ufw allow "${SQUID_PORT}/tcp" comment "Squid HTTP proxy" >/dev/null
    ufw allow "${DANTE_PORT}/tcp" comment "Dante SOCKS5" >/dev/null
    ufw allow "${DANTE_PORT}/udp" comment "Dante UDP ASSOCIATE" >/dev/null

    if [[ "$ufw_was_active" == true ]]; then
        ufw reload >/dev/null
        log_ok "UFW был активен: добавлены порты прокси, SSH ${SSH_PORT}/tcp сохранён."
        return 0
    fi

    if [[ "$ENABLE_UFW" == true ]]; then
        ufw --force enable >/dev/null
        log_ok "UFW включён. Перед этим явно разрешён SSH (${SSH_PORT}/tcp), чтобы не потерять доступ."
    else
        log_warn "UFW не был активен и не включался. Правила добавлены, но фильтр выключен."
        log_warn "Включите его позже: ufw enable (SSH ${SSH_PORT} уже разрешён)."
    fi
}

# ====================================================================
# Users / services
# ====================================================================

create_or_update_users() {
    ((${#USERS[@]} > 0)) || return 0
    echo -e "\n${C_YELLOW}--- Шаг 3: Пользователи и пароли ---${C_RESET}"
    detect_nologin
    mkdir -p /etc/squid

    local user first_htpasswd=true
    [[ -s "$SQUID_PASSWD" ]] && first_htpasswd=false

    for user in "${USERS[@]}"; do
        echo "-> Пользователь '$user'"
        if id "$user" >/dev/null 2>&1; then
            if grep -qxF "$user" "$USERS_FILE" 2>/dev/null; then
                log_info "Учётная запись уже создана этим установщиком. Обновляем пароль."
            else
                die "Пользователь '$user' уже существует и не был создан этим скриптом."
            fi
        else
            useradd --no-create-home --shell "$NOLOGIN_SHELL" --comment "proxy-installer" "$user" \
                || die "Не удалось создать пользователя '$user'."
            remember_user "$user"
        fi

        chage -m 0 -M 99999 -I -1 -E -1 "$user" >/dev/null 2>&1 || true

        echo "   Пароль для Dante (SOCKS5, системный passwd):"
        passwd "$user" || die "Не удалось задать пароль для '$user'."

        echo "   Повторите пароль для Squid (файл ${SQUID_PASSWD}):"
        if [[ "$first_htpasswd" == true ]]; then
            htpasswd -c "$SQUID_PASSWD" "$user" || die "Не удалось создать ${SQUID_PASSWD}."
            first_htpasswd=false
        else
            htpasswd "$SQUID_PASSWD" "$user" || die "Не удалось добавить '$user' в ${SQUID_PASSWD}."
        fi
    done

    detect_proxy_user
    chown "root:${PROXY_USER}" "$SQUID_PASSWD"
    chmod 640 "$SQUID_PASSWD"
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
    if ! dpkg -s squid >/dev/null 2>&1 && ! dpkg -s dante-server >/dev/null 2>&1 && [[ ! -f "$STATE_FILE" ]]; then
        return 0
    fi

    echo -e "\n${C_YELLOW}Обнаружена предыдущая установка Squid/Dante или состояние установщика.${C_RESET}"
    echo "  1) Полная очистка и новая установка (рекомендуется)"
    echo "  2) Только перезаписать конфигурацию (пакеты сохранить)"
    echo "  3) Отмена"
    local choice
    while true; do
        read -r -p "Ваш выбор [1-3]: " choice
        case "$choice" in
            1)
                local tracked_preview
                tracked_preview="$(read_tracked_users | tr '\n' ' ')"
                if [[ -n "$tracked_preview" ]]; then
                    log_info "Будут удалены учётные записи: $tracked_preview"
                else
                    echo "Введите имена пользователей прошлой установки (через пробел), либо Enter."
                    local input=""
                    read -r -p "> " input
                    IFS=' ' read -r -a USERS_TO_DELETE <<< "$input"
                fi
                cleanup
                return 0
                ;;
            2)
                log_info "Пакеты сохраняются, конфигурация будет перезаписана."
                return 0
                ;;
            3)
                echo "Установка отменена."
                exit 0
                ;;
            *) log_err "Введите 1, 2 или 3." ;;
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
                if [[ "$dup" == "$username" ]]; then
                    log_err "Пользователь '$username' уже добавлен."
                    continue 2
                fi
            done
            USERS+=("$username")
        done
    fi

    echo
    echo "Порты прокси. Не используйте порт SSH (${SSH_PORT})."
    while true; do
        read -r -e -i 3128 -p "Порт Squid (HTTP CONNECT) [1-65535]: " SQUID_PORT
        validate_port "$SQUID_PORT" || continue
        if [[ "$SQUID_PORT" == "$SSH_PORT" ]]; then
            log_err "Порт $SQUID_PORT занят SSH."
            continue
        fi
        if port_held_by_foreign_service "$SQUID_PORT"; then
            log_err "Порт $SQUID_PORT уже слушается другой службой."
            continue
        fi
        break
    done
    while true; do
        read -r -e -i 1080 -p "Порт Dante (SOCKS5) [1-65535]: " DANTE_PORT
        validate_port "$DANTE_PORT" || continue
        if [[ "$DANTE_PORT" == "$SQUID_PORT" ]]; then
            log_err "Порты Squid и Dante должны различаться."
            continue
        fi
        if [[ "$DANTE_PORT" == "$SSH_PORT" ]]; then
            log_err "Порт $DANTE_PORT занят SSH."
            continue
        fi
        if port_held_by_foreign_service "$DANTE_PORT"; then
            log_err "Порт $DANTE_PORT уже слушается другой службой."
            continue
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
        elif ask_yes_no "Включить UFW? SSH-порт ${SSH_PORT} будет разрешён заранее." "y"; then
            ENABLE_UFW=true
        else
            ENABLE_UFW=false
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
    echo "Логи: /var/log/squid/access.log , ${DANTE_LOG} , /var/log/fail2ban.log"
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
on Debian 11+ / Ubuntu 20.04+ and derivatives.

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
    is_tty || die "Нужен интерактивный терминал. Скачайте скрипт и запустите: sudo ./proxy-installer.sh"

    detect_os
    detect_ssh_port
    check_internet
    check_disk
    detect_nologin

    maybe_cleanup_previous
    mkdir -p "$STATE_DIR"
    collect_settings

    echo
    log_ok "Параметры собраны, начинаем установку."
    sleep 1

    install_packages
    apply_sysctl
    create_or_update_users
    configure_unbound
    configure_squid
    configure_dante
    configure_fail2ban

    state_set SQUID_PORT "$SQUID_PORT"
    state_set DANTE_PORT "$DANTE_PORT"
    state_set AUTH_CHOICE "$AUTH_CHOICE"

    restart_services
    print_summary
}

main "$@"
