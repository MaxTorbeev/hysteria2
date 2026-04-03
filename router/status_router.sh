#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-hp2-router}"
CONFIG_FILE="${CONFIG_FILE:-/opt/hp2-router/config/config.json}"
ROUTER_TABLE="${ROUTER_TABLE:-100}"
NFT_TABLE="${NFT_TABLE:-hp2router}"
SERVICE_ENV_FILE="${SERVICE_ENV_FILE:-/opt/hp2-router/service.env}"
AWG_IFACE="${AWG_IFACE:-}"

UNIT_NAME="${SERVICE_NAME%.service}.service"
UNIT_FILE="/etc/systemd/system/${UNIT_NAME}"

if [[ -f "${SERVICE_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${SERVICE_ENV_FILE}"
fi

if [[ ! -f "${UNIT_FILE}" ]]; then
  echo "Service not found: ${UNIT_NAME}" >&2
  exit 1
fi

echo "== sing-box check =="
sing-box check -c "${CONFIG_FILE}" || true
echo
echo "== systemctl =="
systemctl status "${UNIT_NAME}" --no-pager || true
echo
echo "== config =="
if [[ -f "${CONFIG_FILE}" ]]; then
  echo "${CONFIG_FILE}"
else
  echo "Missing: ${CONFIG_FILE}"
fi
echo
if [[ -n "${AWG_IFACE}" ]]; then
  echo "== interface ${AWG_IFACE} =="
  ip -br link show dev "${AWG_IFACE}" || true
  ip -br addr show dev "${AWG_IFACE}" || true
  echo
  echo "== interface stats ${AWG_IFACE} =="
  ip -s link show dev "${AWG_IFACE}" || true
  echo
fi
echo "== ip rule =="
ip rule show
echo
echo "== table ${ROUTER_TABLE} =="
ip route show table "${ROUTER_TABLE}" || true
echo
echo "== nft =="
nft list table ip "${NFT_TABLE}" || true
echo
echo "== sockets =="
ss -ltnup | grep -E '(:60080|:1080|:443)' || true
ss -uanp | grep ':443' || true
echo
echo "== last logs =="
journalctl -u "${UNIT_NAME}" -n 50 --no-pager || true
