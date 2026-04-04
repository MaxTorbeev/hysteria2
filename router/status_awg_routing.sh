#!/usr/bin/env bash
set -euo pipefail

WORK_DIR="${WORK_DIR:-/opt/hp2-routing}"
STATE_ENV_FILE="${STATE_ENV_FILE:-${WORK_DIR}/routing.env}"
CONFIG_FILE="${CONFIG_FILE:-${WORK_DIR}/config/config.json}"
SERVICE_NAME="${SERVICE_NAME:-hp2-routing}"
ROUTER_TABLE="${ROUTER_TABLE:-100}"
NFT_TABLE="${NFT_TABLE:-hp2router}"
AWG_IFACE="${AWG_IFACE:-awg0}"
DEBUG_SOCKS_PORT="${DEBUG_SOCKS_PORT:-1080}"

if [[ -f "${STATE_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${STATE_ENV_FILE}"
fi

UNIT_NAME="${SERVICE_NAME%.service}.service"

echo "== sing-box check =="
sing-box check -c "${CONFIG_FILE}" || true
echo

echo "== routing service =="
systemctl status "${UNIT_NAME}" --no-pager || true
echo

echo "== awg interface =="
ip -br link show dev "${AWG_IFACE}" || true
ip -br addr show dev "${AWG_IFACE}" || true
ip -s link show dev "${AWG_IFACE}" || true
echo

echo "== ip rule =="
ip rule show || true
echo

echo "== table ${ROUTER_TABLE} =="
ip route show table "${ROUTER_TABLE}" || true
echo

echo "== nft =="
nft list table ip "${NFT_TABLE}" || true
echo

echo "== sockets =="
ss -ltnup | grep -E "(:${TPROXY_PORT:-60080}|:${DEBUG_SOCKS_PORT}|:443)" || true
ss -uanp | grep ':443' || true
echo

echo "== last logs =="
journalctl -u "${UNIT_NAME}" -n 80 --no-pager || true
