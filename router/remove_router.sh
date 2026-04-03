#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-hp2-router}"
IMAGE_NAME="${IMAGE_NAME:-hp2-router:latest}"
WORK_DIR="${WORK_DIR:-/opt/hp2-router}"
REMOVE_IMAGE="${REMOVE_IMAGE:-0}"
PURGE_CONFIG="${PURGE_CONFIG:-0}"

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

main() {
  require_root

  if docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    log "Removing container ${CONTAINER_NAME}"
    docker rm -f "${CONTAINER_NAME}" >/dev/null
  else
    warn "Container ${CONTAINER_NAME} does not exist"
  fi

  if [[ "${REMOVE_IMAGE}" == "1" ]]; then
    if docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
      log "Removing image ${IMAGE_NAME}"
      docker rmi "${IMAGE_NAME}" >/dev/null
    else
      warn "Image ${IMAGE_NAME} does not exist"
    fi
  fi

  if [[ "${PURGE_CONFIG}" == "1" ]]; then
    log "Removing config directory ${WORK_DIR}"
    rm -rf "${WORK_DIR}"
  fi

  log "Done"
}

main "$@"
