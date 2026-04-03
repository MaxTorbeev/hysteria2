#!/usr/bin/env bash
set -euo pipefail

AWG_IFACE="${AWG_IFACE:-awg0}"
CONFIG_FILE="${CONFIG_FILE:-/etc/sing-box/config.json}"
TPROXY_PORT="${TPROXY_PORT:-60080}"
ROUTER_TABLE="${ROUTER_TABLE:-100}"
ROUTER_MARK="${ROUTER_MARK:-0x1}"
NFT_TABLE="${NFT_TABLE:-hp2router}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-30}"

log() {
  echo "[router] $*"
}

warn() {
  echo "[router:warn] $*" >&2
}

die() {
  echo "[router:x] $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

wait_for_interface() {
  local i
  for ((i = 0; i < WAIT_TIMEOUT; i++)); do
    if ip link show dev "${AWG_IFACE}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  die "Interface ${AWG_IFACE} not found after ${WAIT_TIMEOUT}s"
}

setup_sysctls() {
  if ! sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
    warn "Could not set net.ipv4.ip_forward inside container; assuming it was prepared on the host"
  fi
  if ! sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1; then
    warn "Could not set net.ipv4.conf.all.rp_filter inside container; assuming it was prepared on the host"
  fi
  if ! sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1; then
    warn "Could not set net.ipv4.conf.default.rp_filter inside container; assuming it was prepared on the host"
  fi
  if ! sysctl -w net.ipv4.conf.all.src_valid_mark=1 >/dev/null 2>&1; then
    warn "Could not set net.ipv4.conf.all.src_valid_mark inside container; assuming it was prepared on the host"
  fi
  if ! sysctl -w "net.ipv4.conf.${AWG_IFACE}.rp_filter=0" >/dev/null 2>&1; then
    warn "Could not set net.ipv4.conf.${AWG_IFACE}.rp_filter inside container; assuming it was prepared on the host"
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

setup_rules() {
  cleanup_rules

  ip rule add fwmark "${ROUTER_MARK}" table "${ROUTER_TABLE}"
  ip route replace local 0.0.0.0/0 dev lo table "${ROUTER_TABLE}"

  nft add table ip "${NFT_TABLE}"
  nft "add chain ip ${NFT_TABLE} prerouting { type filter hook prerouting priority mangle; policy accept; }"
  nft add rule ip "${NFT_TABLE}" prerouting iifname "${AWG_IFACE}" ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } return
  nft add rule ip "${NFT_TABLE}" prerouting iifname "${AWG_IFACE}" meta l4proto { tcp, udp } tproxy to :"${TPROXY_PORT}" meta mark set "${ROUTER_MARK}" accept
}

main() {
  require_cmd ip
  require_cmd nft
  require_cmd sing-box
  [[ -f "${CONFIG_FILE}" ]] || die "Config file not found: ${CONFIG_FILE}"

  log "Waiting for ${AWG_IFACE}"
  wait_for_interface

  log "Applying kernel settings"
  setup_sysctls

  log "Applying TPROXY rules"
  setup_rules

  log "Validating sing-box config"
  sing-box check -c "${CONFIG_FILE}"

  log "Starting sing-box"
  sing-box run -c "${CONFIG_FILE}" &
  SINGBOX_PID=$!

  trap 'kill "${SINGBOX_PID}" >/dev/null 2>&1 || true' INT TERM
  wait "${SINGBOX_PID}"
}

trap cleanup_rules EXIT

main "$@"
