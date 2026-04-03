#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-hp2-router}"
WORK_DIR="${WORK_DIR:-/opt/hp2-router}"
PURGE_CONFIG="${PURGE_CONFIG:-0}"
ROUTER_TABLE="${ROUTER_TABLE:-100}"
ROUTER_MARK="${ROUTER_MARK:-0x1}"
NFT_TABLE="${NFT_TABLE:-hp2router}"

log() {
  echo "[+] $*"
}

warn() {
  echo "[!] $*" >&2
}

die() {
  echo "[x] $*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root: sudo bash $0"
  fi
}

cleanup_rules() {
  set +e
  while ip rule del fwmark "${ROUTER_MARK}" table "${ROUTER_TABLE}" >/dev/null 2>&1; do
    :
  done
  nft delete table ip "${NFT_TABLE}" >/dev/null 2>&1 || true
  set -e
}

main() {
  local unit_name="${SERVICE_NAME%.service}.service"
  local unit_file="/etc/systemd/system/${unit_name}"

  require_root

  if [[ -f "${unit_file}" ]]; then
    log "Stopping service ${unit_name}"
    systemctl disable --now "${unit_name}" >/dev/null 2>&1 || true
  else
    warn "Service ${unit_name} is not installed"
  fi

  if [[ -f "${unit_file}" ]]; then
    log "Removing unit file ${unit_file}"
    rm -f "${unit_file}"
    systemctl daemon-reload
  fi

  log "Cleaning routing rules"
  cleanup_rules

  if [[ "${PURGE_CONFIG}" == "1" ]]; then
    log "Removing config directory ${WORK_DIR}"
    rm -rf "${WORK_DIR}"
  fi

  log "Done"
}

main "$@"
