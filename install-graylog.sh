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
AVX_SUPPORTED="no"
JAVA_PRESENT="no"
JAVA_VERSION="n/a"

CURRENT_TZ="unknown"
NTP_SYNC="unknown"
CURRENT_MAX_MAP_COUNT="unknown"
UBUNTU_VERSION="unknown"

# Network snapshot
DEFAULT_GW="none"
PRIMARY_IFACES=""
IFACE_SUMMARY="n/a"
DHCP_DETECTED="unknown"
DNS_OK="no"
HTTP_ARCHIVE_OK="no"
ICMP_ARCHIVE_OK="unknown"

# Hardware snapshot
CPU_CORES="unknown"
RAM_GB="unknown"
SWAP_GB="unknown"
ROOT_FREE_GB="unknown"
EXTRA_DISKS_FOUND="unknown"

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

# Status line helpers (UI)
ui_step() {
  echo "${C_CYAN}${C_BOLD}>>${C_RESET} $1"
  log "PRECHECK: $1"
}

ui_ok()   { echo "   ${C_GREEN}OK${C_RESET}   $1"; }
ui_warn() { echo "   ${C_YELLOW}WARN${C_RESET} $1"; }
ui_fail() { echo "   ${C_RED}FAIL${C_RESET} $1"; }

# ==================================================
# Core preflight checks (hard gates)
# ==================================================
check_os() {
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || add_fail "Unsupported OS: ${ID:-unknown}"
  [[ "${VERSION_ID:-}" == "22.04" || "${VERSION_ID:-}" == "24.04" ]] || add_fail "Unsupported Ubuntu version: ${VERSION_ID:-unknown}"
  [[ "$(uname -m)" == "x86_64" ]] || add_fail "Unsupported architecture: $(uname -m)"

  if command -v lsb_release >/dev/null 2>&1; then
    UBUNTU_VERSION="$(lsb_release -rs 2>/dev/null || echo "${VERSION_ID:-unknown}")"
  else
    UBUNTU_VERSION="${VERSION_ID:-unknown}"
  fi
}

check_systemd() {
  command -v systemctl >/dev/null 2>&1 || add_fail "systemd not found (systemctl missing)"
}

apt_lock_holders() {
  local lockfile="$1"
  fuser -v "$lockfile" 2>/dev/null || true
}

apt_is_locked() {
  local locked="no"
  for lf in /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock; do
    if [[ -e "$lf" ]]; then
      if fuser "$lf" >/dev/null 2>&1; then
        locked="yes"
      fi
    fi
  done
  [[ "$locked" == "yes" ]]
}

check_apt_with_wait() {
  local waited=0

  if apt_is_locked; then
    add_warn "apt/dpkg appears locked (apt-daily/unattended-upgrades). Will wait up to ${APT_LOCK_WAIT_SECONDS}s."
    for lf in /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock; do
      [[ -e "$lf" ]] || continue
      if fuser "$lf" >/dev/null 2>&1; then
        add_info "Lock holders for $lf (see logfile)."
        apt_lock_holders "$lf" | tee -a "$LOGFILE" >/dev/null
      fi
    done
  fi

  while apt_is_locked; do
    if (( waited >= APT_LOCK_WAIT_SECONDS )); then
      add_fail "apt is locked by another process (waited ${APT_LOCK_WAIT_SECONDS}s). Retry after apt-daily/unattended-upgrades completes."
      return
    fi
    sleep "$APT_LOCK_SLEEP_SECONDS"
    waited=$(( waited + APT_LOCK_SLEEP_SECONDS ))
  done
}

select_role() {
  echo
  echo "${C_BOLD}Select host role:${C_RESET}"
  echo "[1] Graylog Server (includes MongoDB)"
  echo "[2] Graylog Data Node"
  read -r -p "Selection: " choice

  case "$choice" in
    1) ROLE="server" ;;
    2) ROLE="datanode" ;;
    *) add_fail "Invalid role selection" ;;
  esac

  [[ -n "$ROLE" ]] && add_info "Role selected: $ROLE"
}

inspect_existing_software() {
  command -v mongod >/dev/null 2>&1 && add_fail "MongoDB already installed (clean install required)."
  dpkg -l 2>/dev/null | grep -q graylog && add_fail "Graylog packages already installed (clean install required)."
  systemctl list-unit-files 2>/dev/null | grep -q graylog && add_fail "Graylog services already present (clean install required)."
}

# ==================================================
# Read-only inspections
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
    add_fail "CPU lacks AVX support (required for MongoDB 8.x)."
  fi
}

inspect_hardware() {
  CPU_CORES="$(nproc 2>/dev/null || echo "unknown")"

  if [[ -r /proc/meminfo ]]; then
    local mem_kb swap_kb
    mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    RAM_GB="$(( (mem_kb + 1024*1024 - 1) / (1024*1024) ))"
    swap_kb="$(awk '/SwapTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    SWAP_GB="$(( (swap_kb + 1024*1024 - 1) / (1024*1024) ))"
  fi
}

inspect_disk() {
  ROOT_FREE_GB="$(df -BG / 2>/dev/null | awk 'NR==2 {gsub("G","",$4); print $4}' || echo "unknown")"

  local root_src root_base
  root_src="$(findmnt -n -o SOURCE / 2>/dev/null || echo "")"
  root_base="$(lsblk -no PKNAME "$root_src" 2>/dev/null || true)"

  local disks
  disks="$(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}' || true)"
  if [[ -z "$disks" ]]; then
    EXTRA_DISKS_FOUND="no"
    return
  fi

  local count=0
  for d in $disks; do
    if [[ -n "$root_base" && "$d" == "$root_base" ]]; then
      continue
    fi
    count=$((count+1))
  done
  EXTRA_DISKS_FOUND=$([[ $count -gt 0 ]] && echo "yes" || echo "no")
}

evaluate_hardware_requirements() {
  if [[ "$ROOT_FREE_GB" != "unknown" ]]; then
    if (( ROOT_FREE_GB < MIN_ROOT_FREE_GB_FAIL )); then
      add_fail "Low free space on / (${ROOT_FREE_GB}G). Require at least ${MIN_ROOT_FREE_GB_FAIL}G free."
    elif (( ROOT_FREE_GB < MIN_ROOT_FREE_GB_WARN )); then
      add_warn "Free space on / is ${ROOT_FREE_GB}G (recommended >= ${MIN_ROOT_FREE_GB_WARN}G)."
    fi
  else
    add_warn "Could not determine free space on /."
  fi

  if [[ "$ROLE" == "server" ]]; then
    [[ "$CPU_CORES" != "unknown" && "$CPU_CORES" -lt "$MIN_CPU_SERVER_WARN" ]] && add_warn "CPU cores: ${CPU_CORES} (recommended >= ${MIN_CPU_SERVER_WARN} for server)."
    [[ "$RAM_GB" != "unknown" && "$RAM_GB" -lt "$MIN_RAM_SERVER_GB_WARN" ]] && add_warn "RAM: ${RAM_GB}G (recommended >= ${MIN_RAM_SERVER_GB_WARN}G for server)."
  elif [[ "$ROLE" == "datanode" ]]; then
    [[ "$CPU_CORES" != "unknown" && "$CPU_CORES" -lt "$MIN_CPU_DATANODE_WARN" ]] && add_warn "CPU cores: ${CPU_CORES} (recommended >= ${MIN_CPU_DATANODE_WARN} for data node)."
    [[ "$RAM_GB" != "unknown" && "$RAM_GB" -lt "$MIN_RAM_DATANODE_GB_WARN" ]] && add_warn "RAM: ${RAM_GB}G (recommended >= ${MIN_RAM_DATANODE_GB_WARN}G for data node)."
    [[ "$EXTRA_DISKS_FOUND" == "no" ]] && add_warn "No additional disk detected (data nodes should have a dedicated data disk)."
  fi

  if [[ "$SWAP_GB" != "unknown" && "$SWAP_GB" -eq 0 ]]; then
    add_warn "Swap is 0G (not always required, but can help stability under memory pressure)."
  fi
}

# Network checks (simple & critical)
inspect_network() {
  if command -v ip >/dev/null 2>&1; then
    IFACE_SUMMARY="$(ip -br addr 2>/dev/null | awk '$1!="lo"{print}' | sed 's/[[:space:]]\+/ /g' || true)"
    PRIMARY_IFACES="$(ip -br link 2>/dev/null | awk '$1!="lo" && $2=="UP"{print $1}' || true)"
    DEFAULT_GW="$(ip route show default 2>/dev/null | awk 'NR==1{print $3}' || echo "none")"
  fi

  if ls /etc/netplan/*.yaml >/dev/null 2>&1; then
    if grep -R "dhcp4:\s*true" /etc/netplan/*.yaml >/dev/null 2>&1; then
      DHCP_DETECTED="yes"
    else
      DHCP_DETECTED="no"
    fi
  else
    DHCP_DETECTED="unknown"
  fi

  local ipv4_count
  ipv4_count="$(ip -4 -br addr 2>/dev/null | awk '$1!="lo" && $3!=""{c++} END{print c+0}' || echo 0)"
  (( ipv4_count == 0 )) && add_fail "No IPv4 address configured on non-loopback interfaces."
  [[ "$DEFAULT_GW" == "none" || -z "$DEFAULT_GW" ]] && add_fail "No default gateway configured (no default route)."
  [[ "$DHCP_DETECTED" == "yes" ]] && add_warn "DHCP appears enabled in netplan (not ideal for server deployments)."
  [[ -z "${PRIMARY_IFACES:-}" ]] && add_warn "No UP ethernet interfaces detected (excluding lo)."
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
    add_warn "curl not installed; cannot test HTTP connectivity in preflight."
  fi

  if command -v ping >/dev/null 2>&1; then
    if ping -c 1 -W 1 archive.ubuntu.com >/dev/null 2>&1; then
      ICMP_ARCHIVE_OK="yes"
      add_info "ICMP ping to archive.ubuntu.com succeeded."
    else
      ICMP_ARCHIVE_OK="no"
      add_info "ICMP ping to archive.ubuntu.com failed (may be blocked; not a failure)."
    fi
  fi
}

# ==================================================
# Preflight report (color-coded, readable)
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
  echo "${IFACE_SUMMARY:-n/a}" | sed 's/^/    /'
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
  check_apt_with_wait
  apt update
  apt install -y "$JAVA_PACKAGE"
}

verify_prerequisites() {
  if command -v timedatectl >/dev/null 2>&1; then
    [[ "$(timedatectl show --property=Timezone --value 2>/dev/null || echo "")" == "$REQUIRED_TZ" ]] || fatal "Timezone not applied"
  fi
  [[ "$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)" -ge "$REQUIRED_MAX_MAP_COUNT" ]] || fatal "vm.max_map_count not applied"
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
  ui_ok "Base OS checks completed"

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