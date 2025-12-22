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
# State variables (preflight)
# ==================================================
ROLE=""
AVX_SUPPORTED="no"
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
    echo "-------------------------------------------------"
    echo "The following actions WILL be performed:"
    echo "- Set timezone → $REQUIRED_TZ"
    echo "- Configure NTP"
    echo "- Set vm.max_map_count → $REQUIRED_MAX_MAP_COUNT"
    echo "- Install Java 21"
    [[ "$ROLE" == "server" ]] && echo "- Install MongoDB 8.x + replica set"
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
# Phase 3 – Prerequisite correction
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
        [[ -z "$ntp" ]] && fatal "No NTP servers provided"
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
# Phase 4 – MongoDB 8.x installation (server only)
# ==================================================
install_mongodb_prereqs() {
    log "Installing MongoDB prerequisites"
    apt install -y gnupg curl
}

add_mongodb_repo() {
    log "Adding MongoDB 8.0 repository"

    curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | \
        gpg --dearmor -o /usr/share/keyrings/mongodb-server-8.0.gpg

    echo "deb [ arch=amd64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] \
https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.0 multiverse" \
        >/etc/apt/sources.list.d/mongodb-org-8.0.list

    apt update
}

install_mongodb() {
    log "Installing MongoDB 8.x"
    apt install -y mongodb-org
    apt-mark hold mongodb-org
}

configure_mongodb() {
    log "Configuring MongoDB"
    cp /etc/mongod.conf /etc/mongod.conf.graylog.bak

    cat >/etc/mongod.conf <<EOF
storage:
  dbPath: /var/lib/mongodb

systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log

net:
  port: 27017
  bindIpAll: true

replication:
  replSetName: "rs0"

processManagement:
  timeZoneInfo: /usr/share/zoneinfo
EOF
}

start_mongodb() {
    log "Starting MongoDB"
    systemctl daemon-reload
    systemctl enable mongod
    systemctl start mongod
    systemctl is-active --quiet mongod || fatal "MongoDB failed to start"
}

init_replica_set() {
    echo
    read -r -p "Is this node the MongoDB replica set initiator? [yes/no]: " reply
    [[ "$reply" != "yes" ]] && return

    read -r -p "Enter replica set members (host:port), comma-separated: " members
    [[ -z "$members" ]] && fatal "No replica set members provided"

    log "Initializing MongoDB replica set"

    mongosh --quiet --eval "
rs.initiate({
  _id: \"rs0\",
  members: [
    $(echo "$members" | awk -F, '{
      for (i=1;i<=NF;i++)
        printf("{ _id: %d, host: \"%s\" }%s", i-1, $i, (i<NF?",":""))
    }')
  ]
})
"
}

# ==================================================
# Main
# ==================================================
main() {
    touch "$LOGFILE"
    log "Starting Graylog installer (combined, MongoDB-ready)"

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

    if [[ "$ROLE" == "server" ]]; then
        install_mongodb_prereqs
        add_mongodb_repo
        install_mongodb
        configure_mongodb
        start_mongodb
        init_replica_set
    fi

    log "Installation phase completed successfully"
    echo
    echo "System is now ready for Graylog Data Node and Graylog Server installation."
}

main