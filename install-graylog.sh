#!/usr/bin/env bash
set -euo pipefail

# ==================================================
# Global configuration
# ==================================================
LOGFILE="/var/log/graylog-installer.log"

REQUIRED_TZ="Europe/Berlin"
DEFAULT_NTP_SERVERS="0.de.pool.ntp.org 1.de.pool.ntp.org 2.de.pool.ntp.org 3.de.pool.ntp.org"
REQUIRED_MAX_MAP_COUNT=262144
JAVA_PACKAGE="openjdk-21-jre-headless"

# ==================================================
# State variables (read-only phase)
# ==================================================
ROLE=""
AVX_SUPPORTED="no"
MONGODB_PRESENT="no"
GRAYLOG_PRESENT="no"
JAVA_PRESENT="no"
JAVA_VERSION="n/a"

CURRENT_TZ=""
NTP_SYNC=""
CURRENT_MAX_MAP_COUNT=""

# ==================================================
# Helpers
# ==================================================
log() {
    echo "[INFO] $1" | tee -a "$LOGFILE"
}

fatal() {
    echo "[ERROR] $1" | tee -a "$LOGFILE"
    exit 1
}

confirm() {
    read -r -p "$1 [yes/no]: " reply
    [[ "$reply" == "yes" ]]
}

# ==================================================
# Phase 1 – Read-only preflight
# ==================================================
check_root() {
    [[ "$EUID" -eq 0 ]] || fatal "This script must be run as root"
}

check_os() {
    source /etc/os-release
    [[ "$ID" == "ubuntu" ]] || fatal "Unsupported OS: $ID"
    [[ "$VERSION_ID" == "22.04" || "$VERSION_ID" == "24.04" ]] \
        || fatal "Unsupported Ubuntu version: $VERSION_ID"
    [[ "$(uname -m)" == "x86_64" ]] || fatal "Unsupported architecture"
}

check_systemd() {
    command -v systemctl >/dev/null || fatal "systemd not found"
}

check_apt() {
    fuser /var/lib/dpkg/lock >/dev/null 2>&1 && fatal "apt is locked"
}

select_role() {
    echo
    echo "Select host role:"
    echo "[1] Graylog Server (includes MongoDB)"
    echo "[2] Graylog Data Node"
    read -r -p "Selection: " choice

    case "$choice" in
        1) ROLE="server" ;;
        2) ROLE="datanode" ;;
        *) fatal "Invalid role selection" ;;
    esac

    log "Role selected: $ROLE"
}

inspect_time() {
    CURRENT_TZ=$(timedatectl show --property=Timezone --value)
    NTP_SYNC=$(timedatectl show --property=NTPSynchronized --value)
}

inspect_kernel() {
    CURRENT_MAX_MAP_COUNT=$(cat /proc/sys/vm/max_map_count)
}

inspect_java() {
    if command -v java >/dev/null; then
        JAVA_PRESENT="yes"
        JAVA_VERSION=$(java -version 2>&1 | head -n1)
    fi
}

inspect_avx() {
    [[ "$ROLE" != "server" ]] && AVX_SUPPORTED="n/a" && return
    grep -q avx /proc/cpuinfo || fatal "CPU lacks AVX support (required for MongoDB 8.x)"
    AVX_SUPPORTED="yes"
}

inspect_existing_software() {
    command -v mongod >/dev/null && fatal "MongoDB already installed (clean install required)"
    dpkg -l | grep -q graylog && fatal "Graylog packages already installed"
    systemctl list-unit-files | grep -q graylog && fatal "Graylog services already present"
}

preflight_summary() {
    echo
    echo "================================================="
    echo " Graylog Open 7 – Preflight Summary"
    echo "================================================="
    echo "OS                   : Ubuntu $(lsb_release -rs)"
    echo "Role                 : $ROLE"
    echo "CPU AVX support      : $AVX_SUPPORTED"
    echo "Timezone             : $CURRENT_TZ"
    echo "NTP synchronized     : $NTP_SYNC"
    echo "vm.max_map_count     : $CURRENT_MAX_MAP_COUNT"
    echo "Java present         : $JAVA_PRESENT"
    echo "Java version         : $JAVA_VERSION"
    echo "MongoDB installed    : NO"
    echo "Graylog installed    : NO"
    echo "-------------------------------------------------"
    echo "The following changes WILL be applied:"
    echo "- Timezone → $REQUIRED_TZ"
    echo "- NTP configuration"
    echo "- vm.max_map_count → $REQUIRED_MAX_MAP_COUNT"
    echo "- Install Java 21"
    [[ "$ROLE" == "server" ]] && echo "- Install MongoDB 8.x (next phase)"
    echo "================================================="
    echo
}

# ==================================================
# Phase 2 – Explicit confirmation
# ==================================================
confirm_proceed() {
    confirm "Proceed with installation and system configuration?" || {
        log "Installation aborted by user"
        exit 0
    }
}

# ==================================================
# Phase 3 – Prerequisite correction (WRITE)
# ==================================================
apply_timezone() {
    log "Setting timezone to $REQUIRED_TZ"
    timedatectl set-timezone "$REQUIRED_TZ"
}

configure_ntp() {
    echo
    echo "Configure NTP:"
    echo "[1] Default German pool (recommended)"
    echo "[2] Custom NTP servers"
    read -r -p "Selection: " choice

    if [[ "$choice" == "2" ]]; then
        read -r -p "Enter space-separated NTP servers: " ntp
        [[ -n "$ntp" ]] || fatal "No NTP servers provided"
    else
        ntp="$DEFAULT_NTP_SERVERS"
    fi

    cat >/etc/systemd/timesyncd.conf <<EOF
[Time]
NTP=$ntp
EOF

    systemctl restart systemd-timesyncd
}

apply_vm_max_map_count() {
    log "Applying vm.max_map_count"
    echo "vm.max_map_count=$REQUIRED_MAX_MAP_COUNT" \
        >/etc/sysctl.d/99-graylog-datanode.conf
    sysctl --system >/dev/null
}

install_java_21() {
    log "Installing Java 21"
    apt update
    apt install -y "$JAVA_PACKAGE"
}

verify_prerequisites() {
    [[ "$(timedatectl show --property=Timezone --value)" == "$REQUIRED_TZ" ]] \
        || fatal "Timezone not applied"
    [[ "$(cat /proc/sys/vm/max_map_count)" -ge "$REQUIRED_MAX_MAP_COUNT" ]] \
        || fatal "vm.max_map_count not applied"
    java -version >/dev/null 2>&1 || fatal "Java verification failed"
}

# ==================================================
# Main
# ==================================================
main() {
    touch "$LOGFILE"
    log "Starting Graylog installer (combined v3)"

    check_root
    check_os
    check_systemd
    check_apt

    select_role

    inspect_time
    inspect_kernel
    inspect_java
    inspect_avx
    inspect_existing_software

    preflight_summary
    confirm_proceed

    log "Applying prerequisites"
    apply_timezone
    configure_ntp
    apply_vm_max_map_count
    install_java_21
    verify_prerequisites

    log "Prerequisites successfully applied"
    echo
    echo "System is ready for MongoDB and Graylog installation."
}

main