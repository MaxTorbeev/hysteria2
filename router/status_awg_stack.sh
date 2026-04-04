#!/usr/bin/env bash
set -euo pipefail

STACK_WORK_DIR="${STACK_WORK_DIR:-/opt/hp2-awg-stack}"
STACK_STATE_ENV_FILE="${STACK_STATE_ENV_FILE:-${STACK_WORK_DIR}/stack.env}"
WIRESOCK_REPO_DIR="${WIRESOCK_REPO_DIR:-${STACK_WORK_DIR}/amneziawg-install}"
SERVER_AWG_NIC="${SERVER_AWG_NIC:-awg0}"
AWG_WEB_LISTEN="${AWG_WEB_LISTEN:-127.0.0.1:8080}"

if [[ -f "${STACK_STATE_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${STACK_STATE_ENV_FILE}"
fi

echo "== awg interface =="
ip -br link show dev "${SERVER_AWG_NIC}" || true
ip -br addr show dev "${SERVER_AWG_NIC}" || true
echo

echo "== awg service =="
systemctl status "awg-quick@${SERVER_AWG_NIC}.service" --no-pager || true
echo

echo "== panel status =="
if [[ -x "${WIRESOCK_REPO_DIR}/amneziawg-web.sh" ]]; then
  (
    cd "${WIRESOCK_REPO_DIR}"
    ./amneziawg-web.sh status
  ) || true
else
  echo "Missing: ${WIRESOCK_REPO_DIR}/amneziawg-web.sh"
fi
echo

echo "== listening sockets =="
ss -ltnup | grep -E "(:8080|:${SERVER_AWG_NIC}|:51820)" || true
echo

echo "== panel listen hint =="
echo "${AWG_WEB_LISTEN}"
echo

echo "== last awg logs =="
journalctl -u "awg-quick@${SERVER_AWG_NIC}.service" -n 50 --no-pager || true
