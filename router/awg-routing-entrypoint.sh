#!/usr/bin/env bash
set -euo pipefail

AWG_IFACE="${AWG_IFACE:-awg0}"
TUN_IFACE="${TUN_IFACE:-sbhp2}"
CONFIG_FILE="${CONFIG_FILE:-/etc/sing-box/config.json}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-30}"
IPROUTE2_TABLE_INDEX="${IPROUTE2_TABLE_INDEX:-2022}"
IPROUTE2_RULE_INDEX="${IPROUTE2_RULE_INDEX:-9000}"
AUTO_REDIRECT_INPUT_MARK="${AUTO_REDIRECT_INPUT_MARK:-0x2023}"
AUTO_REDIRECT_OUTPUT_MARK="${AUTO_REDIRECT_OUTPUT_MARK:-0x2024}"
AUTO_REDIRECT_RESET_MARK="${AUTO_REDIRECT_RESET_MARK:-0x2025}"
AUTO_REDIRECT_FALLBACK_RULE_INDEX="${AUTO_REDIRECT_FALLBACK_RULE_INDEX:-32768}"
DNS_FILTER_ENABLED="${DNS_FILTER_ENABLED:-0}"
DNS_FILTER_CONFIG_FILE="${DNS_FILTER_CONFIG_FILE:-/etc/dnsmasq.conf}"
DNS_FILTER_LISTEN="${DNS_FILTER_LISTEN:-127.0.0.1}"
DNS_FILTER_PORT="${DNS_FILTER_PORT:-5353}"

log() {
  echo "[routing] $*"
}

warn() {
  echo "[routing:warn] $*" >&2
}

die() {
  echo "[routing:error] $*" >&2
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
  sysctl -w net.ipv4.ip_forward=1 >/dev/null || warn "Could not set net.ipv4.ip_forward"
  sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null || warn "Could not set net.ipv4.conf.all.rp_filter"
  sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null || warn "Could not set net.ipv4.conf.default.rp_filter"
  sysctl -w net.ipv4.conf.all.src_valid_mark=1 >/dev/null || warn "Could not set net.ipv4.conf.all.src_valid_mark"
  sysctl -w "net.ipv4.conf.${AWG_IFACE}.rp_filter=0" >/dev/null || warn "Could not set net.ipv4.conf.${AWG_IFACE}.rp_filter"
}

log_runtime_state() {
  log "AWG interface state"
  ip -br addr show dev "${AWG_IFACE}" 2>&1 | sed 's/^/[routing] /'
  log "sing-box tun interface state"
  ip -br addr show dev "${TUN_IFACE}" 2>&1 | sed 's/^/[routing] /' || true
  if [[ "${DNS_FILTER_ENABLED}" == "1" ]]; then
    log "dns filter socket"
    ss -lunp 2>&1 | grep -E "${DNS_FILTER_LISTEN//./\\.}:${DNS_FILTER_PORT}" | sed 's/^/[routing] /' || true
  fi
  log "Policy rules"
  ip rule show 2>&1 | sed 's/^/[routing] /'
  log "Policy table ${IPROUTE2_TABLE_INDEX}"
  ip route show table "${IPROUTE2_TABLE_INDEX}" 2>&1 | sed 's/^/[routing] /' || true
  log "nft ruleset (filtered)"
  nft list ruleset 2>/dev/null | grep -E -C 3 "sing-box|${TUN_IFACE}|${AUTO_REDIRECT_INPUT_MARK}|${AUTO_REDIRECT_OUTPUT_MARK}|${AUTO_REDIRECT_RESET_MARK}|${IPROUTE2_TABLE_INDEX}|${AUTO_REDIRECT_FALLBACK_RULE_INDEX}" | sed 's/^/[routing] /' || true
}

main() {
  require_cmd ip
  require_cmd nft
  require_cmd sing-box
  local dnsmasq_pid=""
  [[ -f "${CONFIG_FILE}" ]] || die "Config file not found: ${CONFIG_FILE}"

  log "Waiting for ${AWG_IFACE}"
  wait_for_interface

  log "Applying kernel settings"
  setup_sysctls

  if [[ "${DNS_FILTER_ENABLED}" == "1" ]]; then
    require_cmd dnsmasq
    [[ -f "${DNS_FILTER_CONFIG_FILE}" ]] || die "DNS filter config not found: ${DNS_FILTER_CONFIG_FILE}"
    log "Validating dns filter config"
    dnsmasq --test --conf-file="${DNS_FILTER_CONFIG_FILE}"
    log "Starting dns filter on ${DNS_FILTER_LISTEN}:${DNS_FILTER_PORT}"
    dnsmasq --keep-in-foreground --conf-file="${DNS_FILTER_CONFIG_FILE}" &
    dnsmasq_pid=$!
    sleep 1
    kill -0 "${dnsmasq_pid}" >/dev/null 2>&1 || die "dns filter failed to start"
  fi

  log "Validating sing-box config"
  sing-box check -c "${CONFIG_FILE}"

  log "Starting sing-box"
  sing-box run -c "${CONFIG_FILE}" &
  SINGBOX_PID=$!

  trap 'kill "${SINGBOX_PID}" >/dev/null 2>&1 || true; if [[ -n "${dnsmasq_pid}" ]]; then kill "${dnsmasq_pid}" >/dev/null 2>&1 || true; fi' INT TERM

  sleep 1
  log_runtime_state

  wait "${SINGBOX_PID}"
  if [[ -n "${dnsmasq_pid}" ]]; then
    kill "${dnsmasq_pid}" >/dev/null 2>&1 || true
  fi
}

main "$@"
