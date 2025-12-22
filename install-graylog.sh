#!/usr/bin/env bash
set -euo pipefail

# ==============================
# Global variables
# ==============================
LOGFILE="/var/log/graylog-installer.log"
DEFAULT_TZ="Europe/Berlin"
DEFAULT_NTP_SERVERS="0.de.pool.ntp.org 1.de.pool.ntp.org 2.de.pool.ntp.org 3.de.pool.ntp.org"
MIN_MAX_MAP_COUNT=262144

# ==============================
# Helpers
# ==============================
log() {
    echo "[INFO] $1" | tee -a "$LOGFILE"
}

warn() {
    echo "[WARN] $1" | tee -a "$LOGFILE"
}

fatal() {
    echo "[ERROR] $1" | tee -a "$LOGFILE"
    exit 1
}

confirm() {
    read -r -p "$1 [yes/no]: " reply
    [[ "$reply" == "yes" ]]
}

# ==============================
# Preflight checks
# ==============================
check_root() {
    [[ "$EUID" -eq 0 ]] || fatal "This script must be run as root"
}

check_os() {
    source /etc/os-release

    [[ "$ID" == "ubuntu" ]] || fatal "Unsupported OS: $ID"
    [[ "$VERSION_ID" == "22.04" || "$VERSION_ID" == "24.04" ]] || fatal "Unsupported Ubuntu version: $VERSION_ID"
    [[ "$(uname -m)" == "x86_64" ]] || fatal "Unsupported architecture"
}

check_systemd() {
    command -v systemctl >/dev/null || fatal "systemd not found"
}

check_apt() {
    if fuser /var/lib/dpkg/lock >/dev/null 2>&1; then
        fatal "apt is locked"
    fi
}

# ==============================
# Time & NTP
# ==============================
configure_timezone() {
    current_tz=$(timedatectl show --property=Timezone --value)
    if [[ "$current_tz" != "$DEFAULT_TZ" ]]; then
        log "Setting timezone to $DEFAULT_TZ"
        timedatectl set-timezone "$DEFAULT_TZ"
    else
        log "Timezone already set to $DEFAULT_TZ"
    fi
}

configure_ntp() {
    log "Configuring NTP"

    echo "Use default NTP servers?"
    echo "  $DEFAULT_NTP_SERVERS"
    echo "[1] Yes (recommended)"
    echo "[2] No, specify custom NTP servers"
    read -r -p "Selection: " ntp_choice

    if [[ "$ntp_choice" == "2" ]]; then
        read -r -p "Enter space-separated NTP servers: " ntp_servers
        [[ -n "$ntp_servers" ]] || fatal "No NTP servers provided"
    else
        ntp_servers="$DEFAULT_NTP_SERVERS"
    fi

    cat >/etc/systemd/timesyncd.conf <<EOF
[Time]
NTP=$ntp_servers
EOF

    systemctl restart systemd-timesyncd
    sleep 2

    synced=$(timedatectl show --property=NTPSynchronized --value)
    if [[ "$synced" != "yes" ]]; then
        warn "NTP not synchronized yet"
    else
        log "NTP synchronized"
    fi
}

# ==============================
# Role selection
# ==============================
select_role() {
    echo
    echo "Select host role:"
    echo "[1] Graylog Server (includes MongoDB)"
    echo "[2] Graylog Data Node"
    read -r -p "Selection: " role_choice

    case "$role_choice" in
        1) ROLE="server" ;;
        2) ROLE="datanode" ;;
        *) fatal "Invalid role selection" ;;
    esac

    log "Selected role: $ROLE"
}

# ==============================
# Kernel tuning
# ==============================
check_vm_max_map_count() {
    current=$(cat /proc/sys/vm/max_map_count)
    log "Current vm.max_map_count = $current"

    if (( current < MIN_MAX_MAP_COUNT )); then
        log "Setting vm.max_map_count to $MIN_MAX_MAP_COUNT"
        echo "vm.max_map_count=$MIN_MAX_MAP_COUNT" >/etc/sysctl.d/99-graylog-datanode.conf
        sysctl --system >/dev/null
    fi

    current=$(cat /proc/sys/vm/max_map_count)
    [[ "$current" -ge "$MIN_MAX_MAP_COUNT" ]] || fatal "vm.max_map_count could not be set"
}

# ==============================
# Java
# ==============================
check_java() {
    if command -v java >/dev/null; then
        version=$(java -version 2>&1 | awk -F\" '/version/ {print $2}')
        major=${version%%.*}
        if (( major >= 17 )); then
            log "Java $version detected"
            return
        fi
        warn "Java version too old: $version"
    fi

    log "Installing OpenJDK 17"
    apt update
    apt install -y openjdk-17-jre-headless
}

# ==============================
# Main
# ==============================
main() {
    touch "$LOGFILE"

    log "Starting Graylog installer v1"

    check_root
    check_os
    check_systemd
    check_apt

    configure_timezone
    configure_ntp

    select_role

    check_vm_max_map_count
    check_java

    log "Preflight completed successfully"
    log "Next steps: package installation and configuration (v2)"

    echo
    echo "Preflight checks completed successfully."
    echo "Role: $ROLE"
    echo "Timezone: $DEFAULT_TZ"
}

main