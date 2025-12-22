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
# Debug/robust error reporting
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
# Global configuration
# ==================================================
REQUIRED_TZ="Europe/Berlin"
DEFAULT_NTP_SERVERS="0.de.pool.ntp.org 1.de.pool.ntp.org 2.de.pool.ntp.org 3.de.pool.ntp.org"
REQUIRED_MAX_MAP_COUNT=262144
JAVA_PACKAGE="openjdk-21-jre-headless"

APT_LOCK_WAIT_SECONDS=120
APT_LOCK_SLEEP_SECONDS=5

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

# ==================================================
# Helpers
# ==================================================
init_log() {
  # Ensure log exists now that we are root
  mkdir -p "$(dirname "$LOGFILE")"
  touch "$LOGFILE"
}

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

# ==================================================
# Preflight checks
# ==================================================
check_os() {
  # /etc/os-release should exist on Ubuntu
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || fatal "Unsupported OS: ${ID:-unknown}"
  [[ "${VERSION_ID:-}" == "22.04" || "${VERSION_ID:-}" == "24.04" ]] || fatal "Unsupported Ubuntu version: ${VERSION_ID:-unknown}"
  [[ "$(uname -m)" == "x86_64" ]] || fatal "Unsupported architecture: $(uname -m)"

  # lsb_release may not exist; do not fail preflight for this
  if command -v lsb_release >/dev/null 2>&1; then
    UBUNTU_VERSION="$(lsb_release -rs 2>/dev/null || echo "$VERSION_ID")"
  else
    UBUNTU_VERSION="${VERSION_ID:-unknown}"
  fi
}

check_systemd() {
  command -v systemctl >/dev/null 2>&1 || fatal "systemd not found (systemctl missing)"
}

# Apt lock handling: detect and (optionally) wait
apt_lock_holders() {
  local lockfile="$1"
  # fuser returns non-zero when no holders; do not let set -e kill script here
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
    warn "apt/dpkg appears locked. This is often caused by apt-daily or unattended-upgrades."
    for lf in /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock; do
      [[ -e "$lf" ]] || continue
      if fuser "$lf" >/dev/null 2>&1; then
        warn "Lock holders for $lf:"
        apt_lock_holders "$lf" | tee -a "$LOGFILE"
      fi
    done
  fi

  while apt_is_locked; do
    if (( waited >= APT_LOCK_WAIT_SECONDS )); then
      fatal "apt is locked by another process (waited ${APT_LOCK_WAIT_SECONDS}s). Please wait for apt-daily/unattended-upgrades to finish and retry."
    fi
    warn "Waiting for apt lock to clear... (${waited}s/${APT_LOCK_WAIT_SECONDS}s)"
    sleep "$APT_LOCK_SLEEP_SECONDS"
    waited=$(( waited + APT_LOCK_SLEEP_SECONDS ))
  done
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

# ==================================================
# Read-only inspections (MUST NOT EXIT)
# ==================================================
inspect_time() {
  if command -v timedatectl >/dev/null 2>&1; then
    CURRENT_TZ="$(timedatectl show --property=Timezone --value 2>/dev/null || echo "unknown")"
    NTP_SYNC="$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "unknown")"
  else
    CURRENT_TZ="unknown"
    NTP_SYNC="unknown"
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
    fatal "CPU lacks AVX support (required for MongoDB 8.x)."
  fi
}

inspect_existing_software() {
  if command -v mongod >/dev/null 2>&1; then
    fatal "MongoDB already installed (clean install required)."
  fi
  if dpkg -l 2>/dev/null | grep -q graylog; then
    fatal "Graylog packages already installed (clean install required)."
  fi
  if systemctl list-unit-files 2>/dev/null | grep -q graylog; then
    fatal "Graylog services already present (clean install required)."
  fi
}

preflight_summary() {
  echo
  echo "================================================="
  echo " Graylog Open 7 – Preflight Summary (Read-only)"
  echo "================================================="
  echo "OS                   : Ubuntu $UBUNTU_VERSION"
  echo "Role                 : $ROLE"
  echo "CPU AVX support      : $AVX_SUPPORTED"
  echo "Timezone             : $CURRENT_TZ"
  echo "NTP synchronized     : $NTP_SYNC"
  echo "vm.max_map_count     : $CURRENT_MAX_MAP_COUNT"
  echo "Java present         : $JAVA_PRESENT"
  echo "Java version         : $JAVA_VERSION"
  echo "-------------------------------------------------"
  echo "The following actions WILL be performed if you proceed:"
  echo "- Set timezone → $REQUIRED_TZ"
  echo "- Configure NTP (default: German pool or custom input)"
  echo "- Set vm.max_map_count → $REQUIRED_MAX_MAP_COUNT"
  echo "- Install Java 21 ($JAVA_PACKAGE)"
  echo "================================================="
  echo
}

confirm_proceed() {
  confirm "Proceed with installation and system configuration?" || {
    log "Installation aborted by user"
    exit 0
  }
}

# ==================================================
# Phase 3 – prerequisite correction (WRITE) – placeholder for next phases
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

  check_os
  check_systemd
  check_apt_with_wait

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
  echo "Prerequisites are now corrected. Next phases will install MongoDB/Graylog/Data Node."
}

main