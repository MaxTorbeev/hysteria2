#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-hp2-router}"
CONFIG_FILE="${CONFIG_FILE:-/opt/hp2-router/config/config.json}"
ROUTER_TABLE="${ROUTER_TABLE:-100}"
NFT_TABLE="${NFT_TABLE:-hp2router}"

UNIT_NAME="${SERVICE_NAME%.service}.service"
UNIT_FILE="/etc/systemd/system/${UNIT_NAME}"

if [[ ! -f "${UNIT_FILE}" ]]; then
  echo "Service not found: ${UNIT_NAME}" >&2
  exit 1
fi

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
echo "== ip rule =="
ip rule show
echo
echo "== table ${ROUTER_TABLE} =="
ip route show table "${ROUTER_TABLE}" || true
echo
echo "== nft =="
nft list table ip "${NFT_TABLE}" || true
echo
echo "== last logs =="
journalctl -u "${UNIT_NAME}" -n 50 --no-pager || true
