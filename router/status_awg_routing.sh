#!/usr/bin/env bash
set -euo pipefail

WORK_DIR="${WORK_DIR:-/opt/hp2-routing}"
STATE_ENV_FILE="${STATE_ENV_FILE:-${WORK_DIR}/routing.env}"
CONFIG_FILE="${CONFIG_FILE:-${WORK_DIR}/config/config.json}"
SERVICE_NAME="${SERVICE_NAME:-hp2-routing}"
AWG_IFACE="${AWG_IFACE:-awg0}"
TUN_IFACE="${TUN_IFACE:-sbhp2}"
IPROUTE2_TABLE_INDEX="${IPROUTE2_TABLE_INDEX:-2022}"
IPROUTE2_RULE_INDEX="${IPROUTE2_RULE_INDEX:-9000}"
AUTO_REDIRECT_INPUT_MARK="${AUTO_REDIRECT_INPUT_MARK:-0x2023}"
AUTO_REDIRECT_OUTPUT_MARK="${AUTO_REDIRECT_OUTPUT_MARK:-0x2024}"
AUTO_REDIRECT_RESET_MARK="${AUTO_REDIRECT_RESET_MARK:-0x2025}"
AUTO_REDIRECT_FALLBACK_RULE_INDEX="${AUTO_REDIRECT_FALLBACK_RULE_INDEX:-32768}"
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

echo "== tun interface =="
ip -br link show dev "${TUN_IFACE}" || true
ip -br addr show dev "${TUN_IFACE}" || true
ip -s link show dev "${TUN_IFACE}" || true
echo

echo "== ip rule =="
ip rule show || true
echo

echo "== table ${IPROUTE2_TABLE_INDEX} =="
ip route show table "${IPROUTE2_TABLE_INDEX}" || true
echo

echo "== nft ruleset (filtered) =="
nft list ruleset 2>/dev/null | grep -E -C 3 "sing-box|${TUN_IFACE}|${AUTO_REDIRECT_INPUT_MARK}|${AUTO_REDIRECT_OUTPUT_MARK}|${AUTO_REDIRECT_RESET_MARK}|${IPROUTE2_TABLE_INDEX}|${AUTO_REDIRECT_FALLBACK_RULE_INDEX}" || true
echo

echo "== sockets =="
ss -ltnup | grep -E "(:${DEBUG_SOCKS_PORT}|:443)" || true
ss -uanp | grep ':443' || true
echo

echo "== last logs =="
journalctl -u "${UNIT_NAME}" -n 80 --no-pager || true
