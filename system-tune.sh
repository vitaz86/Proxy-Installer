#!/bin/bash

# System Tuning Script for Proxy Server Optimization
# Applies comprehensive system settings, limits, and network tuning

echo "Applying system optimizations for proxy server performance..."

# Backup current sysctl.conf
cp /etc/sysctl.conf /etc/sysctl.conf.backup.$(date +%Y%m%d_%H%M%S)

# Add comprehensive sysctl parameters
cat >> /etc/sysctl.conf <<EOF

# Network Stack Tuning
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 65536
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 1024 65535
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 87380 16777216
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.core.rmem_default = 2097152
net.core.wmem_default = 2097152
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 4000

# Memory and System Limits
vm.swappiness = 10
kernel.pid_max = 65536

# Connection Tracking (if needed)
net.nf_conntrack_max = 262144
EOF

# Apply sysctl changes
sysctl -p

# Set ulimits
cat >> /etc/security/limits.conf <<EOF

# Proxy Server Ulimits
* soft nofile 65536
* hard nofile 65536
* soft nproc 10240
* hard nproc 10240
* soft stack 8192
* hard stack 8192
* soft core unlimited
* hard core unlimited
EOF

# Enable BBR if not already
if ! modprobe tcp_bbr 2>/dev/null; then
    echo "tcp_bbr" >> /etc/modules-load.d/bbr.conf
fi

# Optimize network interfaces (example for eth0, adjust as needed)
INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5}')
if [ -n "$INTERFACE" ]; then
    ethtool -G $INTERFACE rx 8192 2>/dev/null || true
    ip link set dev $INTERFACE txqueuelen 5000 2>/dev/null || true
fi

# Set CPU affinity example (adjust for your cores)
# taskset -pc 0-3 $(pgrep squid) 2>/dev/null || true

echo "System tuning completed. Reboot recommended for full effect."