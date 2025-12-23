#!/usr/bin/env bash

# ==================================================
# Self-elevation (must be first)
# ==================================================
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[INFO] Not running as root, re-executing with sudo..."
  exec sudo -E bash "$0" "$@"
fi

set -euo pipefail

# ==================================================
# Script metadata
# ==================================================
SCRIPT_NAME="Graylog Open Installer"
SCRIPT_VERSION="v0.7"
SCRIPT_SCOPE="Preflight + prerequisites + MongoDB 8.0 (server) + Graylog Server (server) + Graylog Data Node (datanode)"
SUPPORTED_OS="Ubuntu Server 22.04 (jammy) and 24.04 (noble)"
GRAYLOG_TARGET="Graylog Open 7.x (latest)"
MONGODB_TARGET="MongoDB 8.0.x (server role only; AVX required)"
JAVA_TARGET="OpenJDK 21 (headless)"

# ==================================================
# Error reporting
# ==================================================
LOGFILE="/var/log/graylog-installer.log"

on_error() {
  local exit_code=$?
  local line_no=${1:-"?"}
  echo "[ERROR] Script failed (exit=$exit_code) at line $line_no" | tee -a "$LOGFILE"
  echo "[ERROR] Check log: $LOGFILE" | tee -a "$LOGFILE"
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

# ==================================================
# ANSI colors (auto-disable when not a TTY)
# ==================================================
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
else
  C_RESET="" ; C_BOLD="" ; C_DIM=""
  C_RED="" ; C_GREEN="" ; C_YELLOW="" ; C_CYAN=""
fi

# ==================================================
# Global configuration
# ==================================================
REQUIRED_TZ="Europe/Berlin"
DEFAULT_NTP_SERVERS="0.de.pool.ntp.org 1.de.pool.ntp.org 2.de.pool.ntp.org 3.de.pool.ntp.org"
REQUIRED_MAX_MAP_COUNT=262144
JAVA_PACKAGE="openjdk-21-jre-headless"

APT_LOCK_WAIT_SECONDS=120
APT_LOCK_SLEEP_SECONDS=5

# Preflight thresholds (conservative defaults)
MIN_ROOT_FREE_GB_FAIL=10
MIN_ROOT_FREE_GB_WARN=20
MIN_CPU_SERVER_WARN=4
MIN_RAM_SERVER_GB_WARN=8
MIN_CPU_DATANODE_WARN=8
MIN_RAM_DATANODE_GB_WARN=16

# MongoDB
MONGO_RS_NAME="rs0"
MONGO_PORT="27017"
MONGO_KEYRING="/usr/share/keyrings/mongodb-server-8.0.gpg"
MONGO_LIST="/etc/apt/sources.list.d/mongodb-org-8.0.list"
MONGO_PGP_URL="https://www.mongodb.org/static/pgp/server-8.0.asc"
MONGO_REPO_BASE="https://repo.mongodb.org/apt/ubuntu"

# Graylog repo + packages
GRAYLOG_REPO_DEB_URL="https://packages.graylog2.org/repo/packages/graylog-7.0-repository_latest.deb"
GRAYLOG_REPO_DEB_LOCAL="/tmp/graylog-7.0-repository_latest.deb"
DATANODE_PKG="graylog-datanode"
SERVER_PKG="graylog-server"

# Config locations
DATANODE_CONF="/etc/graylog/datanode/datanode.conf"
SERVER_CONF="/etc/graylog/server/server.conf"
SERVER_DEFAULTS="/etc/default/graylog-server"

# Secret store (optional convenience)
SECRET_STORE_DIR="/etc/graylog-installer"
SECRET_STORE_FILE="${SECRET_STORE_DIR}/password_secret"

# ==================================================
# State variables (preflight)
# ==================================================
ROLE=""

UBUNTU_VERSION="unknown"
UBUNTU_CODENAME="unknown"

AVX_SUPPORTED="unknown"
JAVA_PRESENT="unknown"
JAVA_VERSION="n/a"

CURRENT_TZ="unknown"
NTP_SYNC="unknown"
CURRENT_MAX_MAP_COUNT="unknown"

CPU_CORES="unknown"
RAM_GB="unknown"
SWAP_GB="unknown"

ROOT_FREE_GB="unknown"
EXTRA_DISKS_FOUND="unknown"

DEFAULT_GW="unknown"
IFACE_SUMMARY="unknown"
DHCP_DETECTED="unknown"

DNS_OK="unknown"
HTTP_ARCHIVE_OK="unknown"

# Data Node config inputs
PASSWORD_SECRET=""
OPENSEARCH_HEAP=""
MONGODB_URI=""

# Server config inputs
ROOT_PASSWORD_SHA2=""
HTTP_BIND_ADDRESS="0.0.0.0:9000"
HTTP_EXTERNAL_URI=""
JOURNAL_MAX_AGE="72h"
JOURNAL_MAX_SIZE=""
IS_LEADER="true"
GRAYLOG_HEAP_OPTS=""

# Findings
FAILS=()
WARNS=()
INFOS=()

# ==================================================
# Helpers
# ==================================================
init_log() {
  mkdir -p "$(dirname "$LOGFILE")"
  touch "$LOGFILE"
}

log()   { echo "[INFO] $1" | tee -a "$LOGFILE"; }
fatal() { echo "[ERROR] $1" | tee -a "$LOGFILE"; exit 1; }

add_fail() { FAILS+=("$1"); }
add_warn() { WARNS+=("$1"); }
add_info() { INFOS+=("$1"); }

confirm() {
  read -r -p "$1 [yes/no]: " reply
  [[ "$reply" == "yes" ]]
}

is_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

print_intro() {
  echo
  echo "${C_BOLD}${SCRIPT_NAME}${C_RESET} ${C_DIM}${SCRIPT_VERSION}${C_RESET}"
  echo "${C_DIM}${SCRIPT_SCOPE}${C_RESET}"
  echo
  echo "${C_BOLD}Targets${C_RESET}"
  echo "  - ${GRAYLOG_TARGET}"
  echo "  - ${MONGODB_TARGET}"
  echo "  - ${JAVA_TARGET}"
  echo
  echo "${C_BOLD}Supported OS${C_RESET}"
  echo "  - ${SUPPORTED_OS}"
  echo
  echo "${C_BOLD}Safety${C_RESET}"
  echo "  - No system changes occur before you confirm."
  echo "  - Intended for clean, first-time installs (existing Graylog/MongoDB causes a hard stop)."
  echo
}

backup_file_if_exists() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
  fi
}

set_conf_kv() {
  # Ensures "key = value" exists; replaces existing, otherwise appends.
  local file="$1"
  local key="$2"
  local value="$3"

  mkdir -p "$(dirname "$file")"
  touch "$file"

  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$file"; then
    local tmp
    tmp="$(mktemp)"
    awk -v k="$key" -v v="$value" '
      BEGIN{done=0}
      {
        if (!done && $0 ~ "^[[:space:]]*"k"[[:space:]]*=") {
          print k" = "v
          done=1
        } else {
          print $0
        }
      }
    ' "$file" >"$tmp"
    mv "$tmp" "$file"
  else
    echo "${key} = ${value}" >>"$file"
  fi
}

uncomment_and_set_server_kv() {
  # Graylog server.conf often has commented defaults. This function:
  # - replaces an uncommented key if present
  # - otherwise replaces a commented key "#key = ..." if present
  # - otherwise appends
  local file="$1"
  local key="$2"
  local value="$3"

  mkdir -p "$(dirname "$file")"
  touch "$file"

  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$file"; then
    set_conf_kv "$file" "$key" "$value"
    return
  fi

  if grep -qE "^[[:space:]]*#\s*${key}[[:space:]]*=" "$file"; then
    local tmp
    tmp="$(mktemp)"
    awk -v k="$key" -v v="$value" '
      BEGIN{done=0}
      {
        if (!done && $0 ~ "^[[:space:]]*#\\s*"k"[[:space:]]*=") {
          print k" = "v
          done=1
        } else {
          print $0
        }
      }
    ' "$file" >"$tmp"
    mv "$tmp" "$file"
    return
  fi

  echo "${key} = ${value}" >>"$file"
}

# ==================================================
# Apt lock check (bounded wait)
# ==================================================
apt_is_locked() {
  local lf
  for lf in /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock; do
    if [[ -e "$lf" ]]; then
      if fuser "$lf" >/dev/null 2>&1; then
        return 0
      fi
    fi
  done
  return 1
}

check_apt_with_wait() {
  local waited=0

  while apt_is_locked; do
    if (( waited >= APT_LOCK_WAIT_SECONDS )); then
      add_fail "apt is locked by another process (waited ${APT_LOCK_WAIT_SECONDS}s). Retry after background apt jobs complete."
      return
    fi
    sleep "$APT_LOCK_SLEEP_SECONDS"
    waited=$(( waited + APT_LOCK_SLEEP_SECONDS ))
  done
}

# ==================================================
# Preflight checks (read-only)
# ==================================================
check_os() {
  if [[ ! -r /etc/os-release ]]; then
    add_fail "/etc/os-release not found; cannot determine OS."
    return
  fi

  # shellcheck disable=SC1091
  source /etc/os-release

  if [[ "${ID:-}" != "ubuntu" ]]; then
    add_fail "Unsupported OS: ${ID:-unknown} (supported: Ubuntu 22.04/24.04)"
  fi

  if [[ "${VERSION_ID:-}" != "22.04" && "${VERSION_ID:-}" != "24.04" ]]; then
    add_fail "Unsupported Ubuntu version: ${VERSION_ID:-unknown} (supported: 22.04/24.04)"
  fi

  if [[ "$(uname -m)" != "x86_64" ]]; then
    add_fail "Unsupported architecture: $(uname -m) (supported: x86_64)"
  fi

  UBUNTU_CODENAME="${VERSION_CODENAME:-unknown}"
  UBUNTU_VERSION="${VERSION_ID:-unknown}"

  if [[ "$UBUNTU_CODENAME" != "jammy" && "$UBUNTU_CODENAME" != "noble" ]]; then
    add_fail "Unsupported Ubuntu codename: $UBUNTU_CODENAME (expected jammy or noble)."
  fi
}

check_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    add_fail "systemd not found (systemctl missing)."
  fi
}

select_role() {
  echo
  echo "${C_BOLD}Select host role:${C_RESET}"
  echo "[1] Graylog Server (includes MongoDB + Graylog Server)"
  echo "[2] Graylog Data Node"
  read -r -p "Selection: " choice

  case "$choice" in
    1) ROLE="server" ;;
    2) ROLE="datanode" ;;
    *) add_fail "Invalid role selection." ;;
  esac
  add_info "Role selected: $ROLE"
}

inspect_existing_software() {
  if command -v mongod >/dev/null 2>&1; then
    add_fail "MongoDB already installed (clean install required)."
  fi

  if dpkg -l 2>/dev/null | grep -qE '^(ii|hi)\s+graylog'; then
    add_fail "Graylog packages already installed (clean install required)."
  fi

  if systemctl list-unit-files 2>/dev/null | grep -q 'graylog'; then
    add_fail "Graylog-related services already present (clean install required)."
  fi
}

inspect_time() {
  if command -v timedatectl >/dev/null 2>&1; then
    CURRENT_TZ="$(timedatectl show --property=Timezone --value 2>/dev/null || echo "unknown")"
    NTP_SYNC="$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "unknown")"
  fi
}

inspect_kernel() {
  CURRENT_MAX_MAP_COUNT="$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo "unknown")"
}

inspect_java() {
  if command -v java >/dev/null 2>&1; then
    JAVA_PRESENT="yes"
    JAVA_VERSION="$(java -version 2>&1 | head -n1 || echo "unknown")"
  else
    JAVA_PRESENT="no"
    JAVA_VERSION="n/a"
  fi
}

inspect_avx() {
  if [[ "$ROLE" != "server" ]]; then
    AVX_SUPPORTED="n/a"
    return
  fi

  if grep -q avx /proc/cpuinfo 2>/dev/null; then
    AVX_SUPPORTED="yes"
  else
    AVX_SUPPORTED="no"
    add_fail "CPU lacks AVX support (required for MongoDB 8.x)."
  fi
}

inspect_hardware() {
  CPU_CORES="$(nproc 2>/dev/null || echo "unknown")"
  if [[ -r /proc/meminfo ]]; then
    local mem_kb swap_kb
    mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    swap_kb="$(awk '/SwapTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    RAM_GB="$(( (mem_kb + 1024*1024 - 1) / (1024*1024) ))"
    SWAP_GB="$(( (swap_kb + 1024*1024 - 1) / (1024*1024) ))"
  fi
}

inspect_disk() {
  ROOT_FREE_GB="$(df -BG / 2>/dev/null | awk 'NR==2 {gsub("G","",$4); print $4}' || echo "unknown")"

  local root_src root_base
  root_src="$(findmnt -n -o SOURCE / 2>/dev/null || echo "")"
  root_base="$(lsblk -no PKNAME "$root_src" 2>/dev/null || true)"

  local disks count d
  disks="$(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}' || true)"
  if [[ -z "$disks" ]]; then
    EXTRA_DISKS_FOUND="no"
    return
  fi

  count=0
  for d in $disks; do
    if [[ -n "$root_base" && "$d" == "$root_base" ]]; then
      continue
    fi
    count=$((count+1))
  done
  EXTRA_DISKS_FOUND=$([[ $count -gt 0 ]] && echo "yes" || echo "no")
}

evaluate_hardware_requirements() {
  if is_uint "$ROOT_FREE_GB"; then
    if (( ROOT_FREE_GB < MIN_ROOT_FREE_GB_FAIL )); then
      add_fail "Low free space on / (${ROOT_FREE_GB}G). Require at least ${MIN_ROOT_FREE_GB_FAIL}G free."
    elif (( ROOT_FREE_GB < MIN_ROOT_FREE_GB_WARN )); then
      add_warn "Free space on / is ${ROOT_FREE_GB}G (recommended >= ${MIN_ROOT_FREE_GB_WARN}G)."
    fi
  else
    add_warn "Could not determine free space on /."
  fi

  if [[ "$ROLE" == "server" ]]; then
    if is_uint "$CPU_CORES" && (( CPU_CORES < MIN_CPU_SERVER_WARN )); then
      add_warn "CPU cores: ${CPU_CORES} (recommended >= ${MIN_CPU_SERVER_WARN} for server)."
    fi
    if is_uint "$RAM_GB" && (( RAM_GB < MIN_RAM_SERVER_GB_WARN )); then
      add_warn "RAM: ${RAM_GB}G (recommended >= ${MIN_RAM_SERVER_GB_WARN}G for server)."
    fi
  else
    if is_uint "$CPU_CORES" && (( CPU_CORES < MIN_CPU_DATANODE_WARN )); then
      add_warn "CPU cores: ${CPU_CORES} (recommended >= ${MIN_CPU_DATANODE_WARN} for data node)."
    fi
    if is_uint "$RAM_GB" && (( RAM_GB < MIN_RAM_DATANODE_GB_WARN )); then
      add_warn "RAM: ${RAM_GB}G (recommended >= ${MIN_RAM_DATANODE_GB_WARN}G for data node)."
    fi
    if [[ "$EXTRA_DISKS_FOUND" == "no" ]]; then
      add_warn "No additional disk detected (data nodes should have a dedicated data disk)."
    fi
  fi
}

inspect_network() {
  if ! command -v ip >/dev/null 2>&1; then
    add_fail "'ip' command not available; cannot validate network configuration."
    return
  fi

  IFACE_SUMMARY="$(ip -br addr 2>/dev/null | awk '$1!="lo"{print}' | sed 's/[[:space:]]\+/ /g' || true)"
  DEFAULT_GW="$(ip route show default 2>/dev/null | awk 'NR==1{print $3}' || echo "none")"
  if [[ "$DEFAULT_GW" == "none" || -z "$DEFAULT_GW" ]]; then
    add_fail "No default gateway configured (no default route)."
  fi

  if ls /etc/netplan/*.yaml >/dev/null 2>&1; then
    if grep -R "dhcp4:\s*true" /etc/netplan/*.yaml >/dev/null 2>&1; then
      DHCP_DETECTED="yes"
      add_warn "DHCP appears enabled in netplan (not ideal for server deployments)."
    else
      DHCP_DETECTED="no"
    fi
  else
    DHCP_DETECTED="unknown"
  fi
}

check_dns_archive() {
  if getent hosts archive.ubuntu.com >/dev/null 2>&1; then
    DNS_OK="yes"
  else
    DNS_OK="no"
    add_fail "DNS resolution failed for archive.ubuntu.com (required for apt)."
  fi
}

check_connectivity_archive() {
  if command -v curl >/dev/null 2>&1; then
    if curl -fsSLI --max-time 8 http://archive.ubuntu.com/ubuntu/ >/dev/null 2>&1; then
      HTTP_ARCHIVE_OK="yes"
    else
      HTTP_ARCHIVE_OK="no"
      add_warn "HTTP connectivity to archive.ubuntu.com/ubuntu failed (proxy/firewall?)."
    fi
  else
    HTTP_ARCHIVE_OK="unknown"
    add_warn "curl not installed; HTTP connectivity test skipped."
  fi
}

print_preflight_report() {
  echo
  echo "${C_BOLD}=================================================${C_RESET}"
  echo "${C_BOLD} Preflight Report (Read-only)${C_RESET}"
  echo "${C_BOLD}=================================================${C_RESET}"
  echo "  OS:               Ubuntu ${UBUNTU_VERSION} (${UBUNTU_CODENAME})"
  echo "  Role:             ${ROLE}"
  echo "  CPU cores:        ${CPU_CORES}"
  echo "  RAM:              ${RAM_GB}G"
  echo "  Free space on /:  ${ROOT_FREE_GB}G"
  echo "  Extra disks:      ${EXTRA_DISKS_FOUND}"
  echo "  AVX support:      ${AVX_SUPPORTED}"
  echo "  Gateway:          ${DEFAULT_GW}"
  echo "  DHCP detected:    ${DHCP_DETECTED}"
  echo "  DNS archive:      ${DNS_OK}"
  echo "  HTTP archive:     ${HTTP_ARCHIVE_OK}"
  echo "  Timezone:         ${CURRENT_TZ}"
  echo "  NTP synced:       ${NTP_SYNC}"
  echo "  vm.max_map_count: ${CURRENT_MAX_MAP_COUNT}"
  echo "  Java present:     ${JAVA_PRESENT}"
  echo "  Java version:     ${JAVA_VERSION}"
  echo

  if ((${#FAILS[@]} > 0)); then
    echo "${C_RED}${C_BOLD}FAILURES (${#FAILS[@]})${C_RESET}"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    echo
  else
    echo "${C_GREEN}${C_BOLD}No failures detected.${C_RESET}"
    echo
  fi

  if ((${#WARNS[@]} > 0)); then
    echo "${C_YELLOW}${C_BOLD}WARNINGS (${#WARNS[@]})${C_RESET}"
    for w in "${WARNS[@]}"; do echo "  - $w"; done
    echo
  fi

  echo "${C_BOLD}Planned changes if you proceed${C_RESET}"
  echo "  - Set timezone → $REQUIRED_TZ"
  echo "  - Configure NTP (default German pool or custom)"
  echo "  - Set vm.max_map_count → $REQUIRED_MAX_MAP_COUNT"
  echo "  - Install Java 21 ($JAVA_PACKAGE)"
  if [[ "$ROLE" == "server" ]]; then
    echo "  - Install MongoDB 8.0 + Graylog Server"
  else
    echo "  - Install Graylog Data Node"
  fi
  echo "${C_BOLD}=================================================${C_RESET}"
  echo
}

abort_if_failures() {
  if ((${#FAILS[@]} > 0)); then
    fatal "Preflight failed. Resolve failures and retry."
  fi
}

# ==================================================
# Phase 3 – prerequisite correction (WRITE)
# ==================================================
apply_timezone() {
  log "Setting timezone to $REQUIRED_TZ"
  timedatectl set-timezone "$REQUIRED_TZ"
}

configure_ntp() {
  echo
  echo "${C_BOLD}Configure NTP:${C_RESET}"
  echo "[1] Default German pool (recommended)"
  echo "[2] Custom NTP servers"
  read -r -p "Selection: " choice

  local ntp=""
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
  echo "vm.max_map_count=$REQUIRED_MAX_MAP_COUNT" >/etc/sysctl.d/99-graylog-datanode.conf
  sysctl --system >/dev/null
}

install_java_21() {
  log "Installing Java 21"
  check_apt_with_wait
  apt update
  apt install -y "$JAVA_PACKAGE"
}

# ==================================================
# Graylog repository (shared)
# ==================================================
install_graylog_repo_deb() {
  log "Installing Graylog repository package"
  check_apt_with_wait
  apt install -y wget ca-certificates

  rm -f "$GRAYLOG_REPO_DEB_LOCAL" || true
  wget -qO "$GRAYLOG_REPO_DEB_LOCAL" "$GRAYLOG_REPO_DEB_URL"
  dpkg -i "$GRAYLOG_REPO_DEB_LOCAL"
  check_apt_with_wait
  apt-get update
}

# ==================================================
# Phase 4 – MongoDB 8.0 (server only)
# ==================================================
install_mongodb_prereqs() {
  log "Installing MongoDB prerequisites (gnupg, curl)"
  check_apt_with_wait
  apt install -y gnupg curl
}

import_mongodb_key() {
  log "Importing MongoDB 8.0 public key"
  mkdir -p "$(dirname "$MONGO_KEYRING")"
  curl -fsSL "$MONGO_PGP_URL" | gpg --dearmor -o "$MONGO_KEYRING"
}

add_mongodb_repo() {
  log "Adding MongoDB 8.0 repository for Ubuntu ${UBUNTU_CODENAME}"
  echo "deb [ arch=amd64 signed-by=${MONGO_KEYRING} ] ${MONGO_REPO_BASE} ${UBUNTU_CODENAME}/mongodb-org/8.0 multiverse" >"$MONGO_LIST"
  check_apt_with_wait
  apt update
}

install_mongodb() {
  log "Installing MongoDB (mongodb-org)"
  check_apt_with_wait
  apt install -y mongodb-org
  apt-mark hold mongodb-org
}

configure_mongodb() {
  log "Configuring MongoDB (bindIpAll + replica set: ${MONGO_RS_NAME})"
  backup_file_if_exists /etc/mongod.conf
  cat >/etc/mongod.conf <<EOF
storage:
  dbPath: /var/lib/mongodb

systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log

net:
  port: ${MONGO_PORT}
  bindIpAll: true

replication:
  replSetName: "${MONGO_RS_NAME}"
EOF
}

start_mongodb() {
  log "Enabling and starting mongod"
  systemctl daemon-reload
  systemctl enable mongod.service
  systemctl start mongod.service
  systemctl is-active --quiet mongod.service || fatal "MongoDB failed to start."
}

build_rs_members_js() {
  local raw="$1"
  local cleaned="${raw// /}"
  local IFS=','
  # shellcheck disable=SC2206
  local parts=($cleaned)
  (( ${#parts[@]} > 0 )) || { echo ""; return 1; }

  local js="" idx=0 hostport=""
  for hostport in "${parts[@]}"; do
    [[ -z "$hostport" ]] && continue
    [[ "$hostport" == *:* ]] || hostport="${hostport}:${MONGO_PORT}"
    [[ -n "$js" ]] && js+=", "
    js+="{ _id: ${idx}, host: \"${hostport}\" }"
    idx=$((idx+1))
  done
  echo "$js"
}

init_replica_set() {
  echo
  read -r -p "Is this node the MongoDB replica set initiator? [yes/no]: " reply
  [[ "$reply" == "yes" ]] || { log "Skipping replica set initiation on this node."; return; }

  echo
  read -r -p "Members (comma-separated host[:port]): " members
  [[ -z "$members" ]] && fatal "No replica set members provided."

  local members_js
  members_js="$(build_rs_members_js "$members")"
  [[ -z "$members_js" ]] && fatal "Failed to parse replica set members."

  log "Initiating replica set ${MONGO_RS_NAME}"
  mongosh --quiet --eval "rs.initiate({ _id: \"${MONGO_RS_NAME}\", members: [ ${members_js} ] })" \
    || fatal "Replica set initiation failed. Verify connectivity and DNS."
}

# ==================================================
# Secrets / sizing helpers
# ==================================================
calc_half_ram_cap_g() {
  # half RAM, cap param, min 1
  local cap="$1"
  if ! is_uint "$RAM_GB"; then
    echo "2g"
    return
  fi
  local half=$((RAM_GB / 2))
  (( half < 1 )) && half=1
  (( half > cap )) && half=cap
  echo "${half}g"
}

read_or_generate_password_secret() {
  echo
  echo "${C_BOLD}password_secret${C_RESET}"
  echo "Must be identical on all Data Nodes AND on Graylog Server."
  echo

  if [[ -f "$SECRET_STORE_FILE" ]]; then
    read -r -p "Stored password_secret found at $SECRET_STORE_FILE. Reuse it? [yes/no]: " reuse
    if [[ "$reuse" == "yes" ]]; then
      PASSWORD_SECRET="$(cat "$SECRET_STORE_FILE")"
      [[ -z "$PASSWORD_SECRET" ]] && fatal "Stored password_secret is empty."
      return
    fi
  fi

  echo "[1] Generate new secret (recommended)"
  echo "[2] Enter existing secret"
  read -r -p "Selection: " choice

  if [[ "$choice" == "1" ]]; then
    check_apt_with_wait
    apt-get install -y openssl >/dev/null
    PASSWORD_SECRET="$(openssl rand -hex 32)"
  else
    read -r -p "Enter password_secret: " PASSWORD_SECRET
  fi

  [[ -z "$PASSWORD_SECRET" ]] && fatal "password_secret cannot be empty."

  read -r -p "Store this secret locally for reuse? [yes/no]: " store
  if [[ "$store" == "yes" ]]; then
    mkdir -p "$SECRET_STORE_DIR"
    umask 077
    echo -n "$PASSWORD_SECRET" >"$SECRET_STORE_FILE"
    chmod 600 "$SECRET_STORE_FILE"
  fi
}

prompt_mongodb_uri() {
  echo
  echo "${C_BOLD}MongoDB URI${C_RESET}"
  echo "Example: mongodb://graylog01:27017,graylog02:27017,graylog03:27017/graylog?replicaSet=${MONGO_RS_NAME}"
  read -r -p "Enter mongodb_uri: " MONGODB_URI
  [[ -z "$MONGODB_URI" ]] && fatal "mongodb_uri cannot be empty."
}

# ==================================================
# Phase 5 – Data Node install/config (datanode role)
# ==================================================
install_datanode() {
  log "Installing Graylog Data Node"
  install_graylog_repo_deb
  check_apt_with_wait
  apt-get install -y "$DATANODE_PKG"

  read_or_generate_password_secret
  prompt_mongodb_uri

  # Heap for OpenSearch (half RAM, cap 31g)
  local rec_heap
  rec_heap="$(calc_half_ram_cap_g 31)"
  read -r -p "Use opensearch_heap=${rec_heap}? [yes/no]: " use_rec
  if [[ "$use_rec" == "yes" ]]; then
    OPENSEARCH_HEAP="$rec_heap"
  else
    read -r -p "Enter opensearch_heap (e.g., 8g): " OPENSEARCH_HEAP
  fi
  [[ -z "$OPENSEARCH_HEAP" ]] && fatal "opensearch_heap cannot be empty."

  backup_file_if_exists "$DATANODE_CONF"
  set_conf_kv "$DATANODE_CONF" "password_secret" "$PASSWORD_SECRET"
  set_conf_kv "$DATANODE_CONF" "opensearch_heap" "$OPENSEARCH_HEAP"
  set_conf_kv "$DATANODE_CONF" "mongodb_uri" "$MONGODB_URI"

  systemctl daemon-reload
  systemctl enable graylog-datanode.service
  systemctl start graylog-datanode.service
  systemctl is-active --quiet graylog-datanode.service || fatal "graylog-datanode failed to start."

  echo
  echo "${C_GREEN}${C_BOLD}Data Node installed and started.${C_RESET}"
  echo "${C_YELLOW}Important:${C_RESET} Use the same password_secret on all Data Nodes and Graylog Server."
}

# ==================================================
# Phase 6 – Graylog Server install/config (server role)
# ==================================================
prompt_root_password_sha2() {
  echo
  echo "${C_BOLD}Graylog root password${C_RESET}"
  echo "You will set root_password_sha2 in server.conf (SHA-256 hash of your desired admin password)."
  echo "${C_YELLOW}Warning:${C_RESET} Do NOT log in the first time using this password."
  echo "Complete preflight login with credentials shown in the Graylog server log after first start."
  echo

  # Read password without echo (no external dependencies)
  local pw1 pw2
  read -r -s -p "Enter desired Graylog admin password: " pw1
  echo
  read -r -s -p "Confirm password: " pw2
  echo
  [[ "$pw1" == "$pw2" ]] || fatal "Passwords do not match."

  # Hash to root_password_sha2
  ROOT_PASSWORD_SHA2="$(printf "%s" "$pw1" | sha256sum | awk '{print $1}')"
  [[ -z "$ROOT_PASSWORD_SHA2" ]] && fatal "Failed to generate root_password_sha2."
}

prompt_http_external_uri() {
  echo
  echo "${C_BOLD}http_external_uri${C_RESET}"
  echo "Example: http://graylog.example.com/  (must end with /)"
  read -r -p "Enter http_external_uri: " HTTP_EXTERNAL_URI
  [[ -z "$HTTP_EXTERNAL_URI" ]] && fatal "http_external_uri cannot be empty."
  [[ "$HTTP_EXTERNAL_URI" == */ ]] || add_warn "http_external_uri does not end with '/'. Graylog recommends a trailing slash."
}

prompt_journal_size() {
  echo
  echo "${C_BOLD}Journal sizing${C_RESET}"
  echo "Recommended: max age 72h and size = expected 72h volume / number of Graylog nodes."
  read -r -p "Enter message_journal_max_size (e.g., 30gb): " JOURNAL_MAX_SIZE
  [[ -z "$JOURNAL_MAX_SIZE" ]] && fatal "message_journal_max_size cannot be empty."
}

prompt_is_leader() {
  echo
  echo "${C_BOLD}Leader setting${C_RESET}"
  echo "[1] Leader node (is_leader = true)"
  echo "[2] Follower node (is_leader = false)"
  read -r -p "Selection: " choice
  case "$choice" in
    1) IS_LEADER="true" ;;
    2) IS_LEADER="false" ;;
    *) fatal "Invalid selection for leader setting." ;;
  esac
}

configure_graylog_server() {
  log "Configuring Graylog Server"

  # password_secret must match Data Node
  read_or_generate_password_secret

  prompt_root_password_sha2
  prompt_mongodb_uri

  # http_bind_address
  echo
  echo "${C_BOLD}http_bind_address${C_RESET}"
  read -r -p "Bind address [default ${HTTP_BIND_ADDRESS}]: " hb
  [[ -n "$hb" ]] && HTTP_BIND_ADDRESS="$hb"

  prompt_http_external_uri
  prompt_journal_size
  prompt_is_leader

  # Heap sizing half RAM, cap 16g
  local rec_heap
  rec_heap="$(calc_half_ram_cap_g 16)"
  echo
  echo "${C_BOLD}Graylog server heap${C_RESET}"
  read -r -p "Use heap -Xms${rec_heap} -Xmx${rec_heap}? [yes/no]: " useh
  if [[ "$useh" == "yes" ]]; then
    GRAYLOG_HEAP_OPTS="-Xms${rec_heap} -Xmx${rec_heap}"
  else
    read -r -p "Enter heap size (e.g., 2g): " hs
    [[ -z "$hs" ]] && fatal "Heap size cannot be empty."
    GRAYLOG_HEAP_OPTS="-Xms${hs} -Xmx${hs}"
  fi

  # Install graylog-server
  log "Installing Graylog Server package"
  install_graylog_repo_deb
  check_apt_with_wait
  apt-get install -y "$SERVER_PKG"

  # Configure server.conf
  backup_file_if_exists "$SERVER_CONF"
  uncomment_and_set_server_kv "$SERVER_CONF" "password_secret" "$PASSWORD_SECRET"
  uncomment_and_set_server_kv "$SERVER_CONF" "root_password_sha2" "$ROOT_PASSWORD_SHA2"
  uncomment_and_set_server_kv "$SERVER_CONF" "http_bind_address" "$HTTP_BIND_ADDRESS"
  uncomment_and_set_server_kv "$SERVER_CONF" "mongodb_uri" "$MONGODB_URI"
  uncomment_and_set_server_kv "$SERVER_CONF" "http_external_uri" "$HTTP_EXTERNAL_URI"
  uncomment_and_set_server_kv "$SERVER_CONF" "message_journal_max_age" "$JOURNAL_MAX_AGE"
  uncomment_and_set_server_kv "$SERVER_CONF" "message_journal_max_size" "$JOURNAL_MAX_SIZE"
  uncomment_and_set_server_kv "$SERVER_CONF" "is_leader" "$IS_LEADER"

  # Configure /etc/default/graylog-server heap
  backup_file_if_exists "$SERVER_DEFAULTS"
  if [[ ! -f "$SERVER_DEFAULTS" ]]; then
    touch "$SERVER_DEFAULTS"
  fi

  # Replace or append GRAYLOG_SERVER_JAVA_OPTS
  local opts="${GRAYLOG_HEAP_OPTS} -server -XX:+UseG1GC -XX:-OmitStackTraceInFastThrow"
  if grep -qE '^[[:space:]]*GRAYLOG_SERVER_JAVA_OPTS=' "$SERVER_DEFAULTS"; then
    local tmp
    tmp="$(mktemp)"
    awk -v v="$opts" '
      BEGIN{done=0}
      {
        if (!done && $0 ~ "^[[:space:]]*GRAYLOG_SERVER_JAVA_OPTS=") {
          print "GRAYLOG_SERVER_JAVA_OPTS=\""v"\""
          done=1
        } else {
          print $0
        }
      }
    ' "$SERVER_DEFAULTS" >"$tmp"
    mv "$tmp" "$SERVER_DEFAULTS"
  else
    echo "GRAYLOG_SERVER_JAVA_OPTS=\"${opts}\"" >>"$SERVER_DEFAULTS"
  fi

  # Start service
  log "Enabling and starting graylog-server"
  systemctl daemon-reload
  systemctl enable graylog-server.service
  systemctl start graylog-server.service

  if ! systemctl is-active --quiet graylog-server.service; then
    systemctl status graylog-server.service --no-pager || true
    fatal "graylog-server failed to start."
  fi

  echo
  echo "${C_GREEN}${C_BOLD}Graylog Server installed and started.${C_RESET}"
  echo "${C_YELLOW}${C_BOLD}First-time login warning:${C_RESET}"
  echo "  - Do NOT log in with your chosen admin password yet."
  echo "  - Use the preflight credentials shown in the Graylog server log."
  echo "  - Check logs with: journalctl -u graylog-server -n 200 --no-pager"
}

# ==================================================
# Main
# ==================================================
main() {
  init_log
  log "Starting Graylog installer (${SCRIPT_VERSION})"
  print_intro

  echo "${C_CYAN}${C_BOLD}Preflight checks are running. Please be patient...${C_RESET}"
  echo

  check_os
  check_systemd
  check_apt_with_wait
  select_role

  inspect_time
  inspect_kernel
  inspect_java
  inspect_avx
  inspect_existing_software
  inspect_hardware
  inspect_disk
  evaluate_hardware_requirements
  inspect_network
  check_dns_archive
  check_connectivity_archive

  print_preflight_report
  abort_if_failures

  confirm "Proceed with installation and system configuration?" || {
    log "Installation aborted by user"
    exit 0
  }

  log "Applying prerequisites"
  apply_timezone
  configure_ntp
  apply_vm_max_map_count
  install_java_21

  if [[ "$ROLE" == "server" ]]; then
    log "Installing MongoDB 8.0"
    install_mongodb_prereqs
    import_mongodb_key
    add_mongodb_repo
    install_mongodb
    configure_mongodb
    start_mongodb
    init_replica_set

    log "Installing and configuring Graylog Server"
    configure_graylog_server
  else
    install_datanode
  fi

  echo
  echo "${C_GREEN}${C_BOLD}Installation phase completed.${C_RESET}"
}

main