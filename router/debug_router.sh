#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-hp2-router}"
WORK_DIR="${WORK_DIR:-/opt/hp2-router}"
CONFIG_FILE="${CONFIG_FILE:-${WORK_DIR}/config/config.json}"
SERVICE_ENV_FILE="${SERVICE_ENV_FILE:-${WORK_DIR}/service.env}"
LOG_DIR="${LOG_DIR:-${WORK_DIR}/logs}"
ROUTER_TABLE="${ROUTER_TABLE:-100}"
NFT_TABLE="${NFT_TABLE:-hp2router}"
AWG_IFACE="${AWG_IFACE:-}"

UNIT_NAME="${SERVICE_NAME%.service}.service"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BUNDLE_FILE="${LOG_DIR}/debug-${TIMESTAMP}.log"

if [[ -f "${SERVICE_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${SERVICE_ENV_FILE}"
fi

mkdir -p "${LOG_DIR}"

{
  echo "== meta =="
  date -Is
  echo "host=$(hostname -f 2>/dev/null || hostname)"
  uname -a
  echo

  echo "== sing-box check =="
  sing-box check -c "${CONFIG_FILE}" || true
  echo

  echo "== systemctl =="
  systemctl status "${UNIT_NAME}" --no-pager || true
  echo

  echo "== interface summary =="
  ip -br link || true
  echo
  ip -br addr || true
  echo

  if [[ -n "${AWG_IFACE}" ]]; then
    echo "== interface ${AWG_IFACE} =="
    ip -br link show dev "${AWG_IFACE}" || true
    ip -br addr show dev "${AWG_IFACE}" || true
    ip -s link show dev "${AWG_IFACE}" || true
    echo
  fi

  echo "== sysctls =="
  sysctl net.ipv4.ip_forward net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter net.ipv4.conf.all.src_valid_mark || true
  if [[ -n "${AWG_IFACE}" ]]; then
    sysctl "net.ipv4.conf.${AWG_IFACE}.rp_filter" || true
  fi
  echo

  echo "== ip rule =="
  ip rule show || true
  echo

  echo "== main route =="
  ip route show || true
  echo

  echo "== table ${ROUTER_TABLE} =="
  ip route show table "${ROUTER_TABLE}" || true
  echo

  echo "== nft =="
  nft list table ip "${NFT_TABLE}" || true
  echo

  echo "== sockets =="
  ss -ltnup || true
  echo
  ss -uanp || true
  echo

  echo "== journal =="
  journalctl -u "${UNIT_NAME}" -n 200 --no-pager || true
} | tee "${BUNDLE_FILE}"

echo
echo "Saved debug bundle: ${BUNDLE_FILE}"
