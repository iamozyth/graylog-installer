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

# ==================================================
# State variables (preflight)
# ==================================================
ROLE=""

UBUNTU_VERSION="unknown"
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
PRIMARY_IFACES="unknown"
DHCP_DETECTED="unknown"

DNS_OK="unknown"
HTTP_ARCHIVE_OK="unknown"
ICMP_ARCHIVE_OK="unknown"

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

ui_step() {
  echo "${C_CYAN}${C_BOLD}>>${C_RESET} $1"
  log "PRECHECK: $1"
}

ui_ok()   { echo "   ${C_GREEN}OK${C_RESET}   $1"; }
ui_warn() { echo "   ${C_YELLOW}WARN${C_RESET} $1"; }
ui_fail() { echo "   ${C_RED}FAIL${C_RESET} $1"; }

# ==================================================
# Preflight: base checks (read-only)
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

  if command -v lsb_release >/dev/null 2>&1; then
    UBUNTU_VERSION="$(lsb_release -rs 2>/dev/null || echo "${VERSION_ID:-unknown}")"
  else
    UBUNTU_VERSION="${VERSION_ID:-unknown}"
  fi
}

check_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    add_fail "systemd not found (systemctl missing)."
  fi
}

# --------------------------------------------------
# Apt lock check (bounded wait)
# --------------------------------------------------
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

  if apt_is_locked; then
    add_warn "apt/dpkg appears locked (apt-daily/unattended-upgrades). Will wait up to ${APT_LOCK_WAIT_SECONDS}s."
  fi

  while apt_is_locked; do
    if (( waited >= APT_LOCK_WAIT_SECONDS )); then
      add_fail "apt is locked by another process (waited ${APT_LOCK_WAIT_SECONDS}s). Retry after background apt jobs complete."
      return
    fi
    sleep "$APT_LOCK_SLEEP_SECONDS"
    waited=$(( waited + APT_LOCK_SLEEP_SECONDS ))
  done
}

# --------------------------------------------------
# Role selection
# --------------------------------------------------
select_role() {
  echo
  echo "${C_BOLD}Select host role:${C_RESET}"
  echo "[1] Graylog Server (includes MongoDB)"
  echo "[2] Graylog Data Node"
  read -r -p "Selection: " choice

  case "$choice" in
    1) ROLE="server" ;;
    2) ROLE="datanode" ;;
    *) add_fail "Invalid role selection." ;;
  esac

  if [[ -n "$ROLE" ]]; then
    add_info "Role selected: $ROLE"
  fi
}

# --------------------------------------------------
# Clean-install enforcement
# --------------------------------------------------
inspect_existing_software() {
  if command -v mongod >/dev/null 2>&1; then
    add_fail "MongoDB already installed (clean install required)."
  fi

  # dpkg grep must be inside if; no pipefail surprises
  if dpkg -l 2>/dev/null | grep -qE '^(ii|hi)\s+graylog'; then
    add_fail "Graylog packages already installed (clean install required)."
  fi

  if systemctl list-unit-files 2>/dev/null | grep -q 'graylog'; then
    add_fail "Graylog services already present (clean install required)."
  fi
}

# ==================================================
# Preflight: inspections (read-only, resilient)
# ==================================================
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

  # Extra disk heuristic: any disk device excluding root’s parent disk
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

  if (( count > 0 )); then
    EXTRA_DISKS_FOUND="yes"
  else
    EXTRA_DISKS_FOUND="no"
  fi
}

evaluate_hardware_requirements() {
  # Root free
  if is_uint "$ROOT_FREE_GB"; then
    if (( ROOT_FREE_GB < MIN_ROOT_FREE_GB_FAIL )); then
      add_fail "Low free space on / (${ROOT_FREE_GB}G). Require at least ${MIN_ROOT_FREE_GB_FAIL}G free."
    elif (( ROOT_FREE_GB < MIN_ROOT_FREE_GB_WARN )); then
      add_warn "Free space on / is ${ROOT_FREE_GB}G (recommended >= ${MIN_ROOT_FREE_GB_WARN}G)."
    fi
  else
    add_warn "Could not determine free space on /."
  fi

  # CPU/RAM warnings per role
  if [[ "$ROLE" == "server" ]]; then
    if is_uint "$CPU_CORES" && (( CPU_CORES < MIN_CPU_SERVER_WARN )); then
      add_warn "CPU cores: ${CPU_CORES} (recommended >= ${MIN_CPU_SERVER_WARN} for server)."
    fi
    if is_uint "$RAM_GB" && (( RAM_GB < MIN_RAM_SERVER_GB_WARN )); then
      add_warn "RAM: ${RAM_GB}G (recommended >= ${MIN_RAM_SERVER_GB_WARN}G for server)."
    fi
  elif [[ "$ROLE" == "datanode" ]]; then
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

  if is_uint "$SWAP_GB" && (( SWAP_GB == 0 )); then
    add_warn "Swap is 0G (not always required, but can help stability under memory pressure)."
  fi
}

# ==================================================
# Network checks (minimal but critical)
# ==================================================
inspect_network() {
  if command -v ip >/dev/null 2>&1; then
    IFACE_SUMMARY="$(ip -br addr 2>/dev/null | awk '$1!="lo"{print}' | sed 's/[[:space:]]\+/ /g' || true)"
    PRIMARY_IFACES="$(ip -br link 2>/dev/null | awk '$1!="lo" && $2=="UP"{print $1}' || true)"
    DEFAULT_GW="$(ip route show default 2>/dev/null | awk 'NR==1{print $3}' || echo "none")"
  fi

  # DHCP detection (netplan signal)
  if ls /etc/netplan/*.yaml >/dev/null 2>&1; then
    if grep -R "dhcp4:\s*true" /etc/netplan/*.yaml >/dev/null 2>&1; then
      DHCP_DETECTED="yes"
    else
      DHCP_DETECTED="no"
    fi
  else
    DHCP_DETECTED="unknown"
  fi

  # Basic IP and gateway
  if command -v ip >/dev/null 2>&1; then
    local ipv4_count
    ipv4_count="$(ip -4 -br addr 2>/dev/null | awk '$1!="lo" && $3!=""{c++} END{print c+0}' || echo 0)"
    if ! is_uint "$ipv4_count" || (( ipv4_count == 0 )); then
      add_fail "No IPv4 address configured on non-loopback interfaces."
    fi
  else
    add_fail "'ip' command not available; cannot validate network configuration."
  fi

  if [[ "$DEFAULT_GW" == "none" || -z "$DEFAULT_GW" || "$DEFAULT_GW" == "unknown" ]]; then
    add_fail "No default gateway configured (no default route)."
  fi

  if [[ "$DHCP_DETECTED" == "yes" ]]; then
    add_warn "DHCP appears enabled in netplan (not ideal for server deployments)."
  fi

  if [[ -z "${PRIMARY_IFACES:-}" || "${PRIMARY_IFACES:-}" == "unknown" ]]; then
    add_warn "No UP ethernet interfaces detected (excluding lo)."
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
  # Primary indicator: HTTP HEAD (ICMP may be blocked)
  if command -v curl >/dev/null 2>&1; then
    if curl -fsSLI --max-time 8 http://archive.ubuntu.com/ubuntu/ >/dev/null 2>&1; then
      HTTP_ARCHIVE_OK="yes"
    else
      HTTP_ARCHIVE_OK="no"
      add_warn "HTTP connectivity to archive.ubuntu.com/ubuntu failed (proxy/firewall?)."
    fi
  else
    HTTP_ARCHIVE_OK="unknown"
    add_warn "curl not installed; HTTP connectivity test skipped in preflight."
  fi

  # ICMP informational only
  if command -v ping >/dev/null 2>&1; then
    if ping -c 1 -W 1 archive.ubuntu.com >/dev/null 2>&1; then
      ICMP_ARCHIVE_OK="yes"
      add_info "ICMP ping to archive.ubuntu.com succeeded."
    else
      ICMP_ARCHIVE_OK="no"
      add_info "ICMP ping to archive.ubuntu.com failed (may be blocked; not a failure)."
    fi
  else
    ICMP_ARCHIVE_OK="unknown"
  fi
}

# ==================================================
# Report & gate
# ==================================================
print_preflight_report() {
  echo
  echo "${C_BOLD}=================================================${C_RESET}"
  echo "${C_BOLD} Graylog Open 7 – Preflight Report (Read-only)${C_RESET}"
  echo "${C_BOLD}=================================================${C_RESET}"

  echo "${C_BOLD}System${C_RESET}"
  echo "  OS:                Ubuntu ${UBUNTU_VERSION}"
  echo "  Role:              ${ROLE}"
  echo "  CPU cores:         ${CPU_CORES}"
  echo "  RAM:               ${RAM_GB}G"
  echo "  Swap:              ${SWAP_GB}G"
  echo "  Free space on /:   ${ROOT_FREE_GB}G"
  echo "  Extra disks:       ${EXTRA_DISKS_FOUND}"
  echo "  AVX support:       ${AVX_SUPPORTED}"
  echo
  echo "${C_BOLD}Network${C_RESET}"
  echo "  Default gateway:   ${DEFAULT_GW}"
  echo "  DHCP detected:     ${DHCP_DETECTED}"
  echo "  DNS archive:       ${DNS_OK}"
  echo "  HTTP archive:      ${HTTP_ARCHIVE_OK}"
  echo "  ICMP archive:      ${ICMP_ARCHIVE_OK}"
  echo "  Interfaces:"
  echo "${IFACE_SUMMARY:-unknown}" | sed 's/^/    /'
  echo
  echo "${C_BOLD}Runtime${C_RESET}"
  echo "  Timezone:          ${CURRENT_TZ}"
  echo "  NTP synchronized:  ${NTP_SYNC}"
  echo "  vm.max_map_count:  ${CURRENT_MAX_MAP_COUNT}"
  echo "  Java present:      ${JAVA_PRESENT}"
  echo "  Java version:      ${JAVA_VERSION}"
  echo

  if ((${#FAILS[@]} > 0)); then
    echo "${C_RED}${C_BOLD}FAILURES (${#FAILS[@]})${C_RESET}"
    for f in "${FAILS[@]}"; do echo "  ${C_RED}-${C_RESET} $f"; done
    echo
  else
    echo "${C_GREEN}${C_BOLD}No failures detected.${C_RESET}"
    echo
  fi

  if ((${#WARNS[@]} > 0)); then
    echo "${C_YELLOW}${C_BOLD}WARNINGS (${#WARNS[@]})${C_RESET}"
    for w in "${WARNS[@]}"; do echo "  ${C_YELLOW}-${C_RESET} $w"; done
    echo
  fi

  if ((${#INFOS[@]} > 0)); then
    echo "${C_CYAN}${C_BOLD}INFO (${#INFOS[@]})${C_RESET}"
    for i in "${INFOS[@]}"; do echo "  ${C_CYAN}-${C_RESET} $i"; done
    echo
  fi

  echo "${C_BOLD}Planned changes if you proceed${C_RESET}"
  echo "  - Set timezone → $REQUIRED_TZ"
  echo "  - Configure NTP (default German pool or custom)"
  echo "  - Set vm.max_map_count → $REQUIRED_MAX_MAP_COUNT"
  echo "  - Install Java 21 ($JAVA_PACKAGE)"
  echo "${C_BOLD}=================================================${C_RESET}"
  echo
}

abort_if_failures() {
  if ((${#FAILS[@]} > 0)); then
    fatal "Preflight failed. Resolve the failures above and retry."
  fi
}

confirm_proceed() {
  confirm "Proceed with installation and system configuration?" || {
    log "Installation aborted by user"
    exit 0
  }
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
  # apt lock may appear between preflight and install; re-check here
  check_apt_with_wait
  apt update
  apt install -y "$JAVA_PACKAGE"
}

verify_prerequisites() {
  if command -v timedatectl >/dev/null 2>&1; then
    local tz_now
    tz_now="$(timedatectl show --property=Timezone --value 2>/dev/null || echo "")"
    [[ "$tz_now" == "$REQUIRED_TZ" ]] || fatal "Timezone not applied"
  fi

  local mmc
  mmc="$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)"
  is_uint "$mmc" && (( mmc >= REQUIRED_MAX_MAP_COUNT )) || fatal "vm.max_map_count not applied"

  java -version >/dev/null 2>&1 || fatal "Java verification failed"
}

# ==================================================
# Main
# ==================================================
main() {
  init_log
  log "Starting Graylog installer (preflight + prerequisites)"

  echo "${C_CYAN}${C_BOLD}Preflight checks are running. Please be patient...${C_RESET}"
  echo "${C_DIM}This may take a short time (apt lock checks, DNS/connectivity tests).${C_RESET}"
  echo

  ui_step "Validating OS and system prerequisites"
  check_os
  check_systemd
  check_apt_with_wait
  ui_ok "Base checks completed"

  select_role

  ui_step "Collecting system information"
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
  ui_ok "System information collected"

  print_preflight_report
  abort_if_failures
  confirm_proceed

  log "Applying prerequisites"
  apply_timezone
  configure_ntp
  apply_vm_max_map_count
  install_java_21
  verify_prerequisites

  log "Prerequisites successfully applied"
  echo
  echo "${C_GREEN}${C_BOLD}Prerequisites are now corrected.${C_RESET} Next phases will install MongoDB/Graylog/Data Node."
}

main