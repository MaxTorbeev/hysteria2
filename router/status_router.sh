#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-hp2-router}"
CONFIG_FILE="${CONFIG_FILE:-/opt/hp2-router/config/config.json}"

if ! docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
  echo "Container not found: ${CONTAINER_NAME}" >&2
  exit 1
fi

echo "== docker ps =="
docker ps --filter "name=^/${CONTAINER_NAME}$" --format 'table {{.Names}}\t{{.Status}}\t{{.RunningFor}}'
echo
echo "== config =="
if [[ -f "${CONFIG_FILE}" ]]; then
  echo "${CONFIG_FILE}"
else
  echo "Missing: ${CONFIG_FILE}"
fi
echo
echo "== last logs =="
docker logs --tail 50 "${CONTAINER_NAME}"
