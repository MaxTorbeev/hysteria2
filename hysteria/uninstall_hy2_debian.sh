#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-hysteria-server}"
HYSTERIA_BIN="${HYSTERIA_BIN:-/usr/local/bin/hysteria}"
HYSTERIA_DIR="${HYSTERIA_DIR:-/etc/hysteria}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
RENEW_HOOK="/etc/letsencrypt/renewal-hooks/deploy/hysteria-restart.sh"

DOMAIN="${DOMAIN:-}"
PURGE_CERT=0
AUTO_YES=0

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

usage() {
  cat <<'EOF'
Usage:
  sudo bash uninstall_hy2_debian.sh [options]

Options:
  --domain <name>  Domain for cert cleanup (example.com)
  --purge-cert     Also remove Let's Encrypt cert for --domain
  --yes            Non-interactive mode (skip confirmation)
  -h, --help       Show this help

Examples:
  sudo bash uninstall_hy2_debian.sh
  sudo bash uninstall_hy2_debian.sh --domain example.com --purge-cert
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root: sudo bash $0"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)
        [[ $# -ge 2 ]] || die "Missing value for --domain"
        DOMAIN="$2"
        shift 2
        ;;
      --purge-cert)
        PURGE_CERT=1
        shift
        ;;
      --yes)
        AUTO_YES=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

confirm() {
  if [[ "${AUTO_YES}" -eq 1 ]]; then
    return
  fi

  echo "This will remove Hysteria2 service, config and binary from this server."
  read -r -p "Continue? [y/N]: " answer
  case "${answer}" in
    y|Y|yes|YES) ;;
    *) die "Aborted by user" ;;
  esac
}

stop_and_remove_service() {
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files | awk '{print $1}' | grep -qx "${SERVICE_NAME}.service"; then
      log "Stopping and disabling ${SERVICE_NAME}"
      systemctl disable --now "${SERVICE_NAME}" || true
    fi
  fi

  if [[ -f "${SERVICE_FILE}" ]]; then
    log "Removing ${SERVICE_FILE}"
    rm -f "${SERVICE_FILE}"
    if command -v systemctl >/dev/null 2>&1; then
      systemctl daemon-reload
      systemctl reset-failed || true
    fi
  fi
}

remove_runtime_files() {
  if [[ -f "${HYSTERIA_BIN}" ]]; then
    log "Removing ${HYSTERIA_BIN}"
    rm -f "${HYSTERIA_BIN}"
  fi

  if [[ -d "${HYSTERIA_DIR}" ]]; then
    log "Removing ${HYSTERIA_DIR}"
    rm -rf "${HYSTERIA_DIR}"
  fi

  if [[ -f "${RENEW_HOOK}" ]]; then
    log "Removing ${RENEW_HOOK}"
    rm -f "${RENEW_HOOK}"
  fi
}

remove_qr_file() {
  if [[ -n "${DOMAIN}" ]]; then
    local qr_png="/root/hy2-${DOMAIN}.png"
    if [[ -f "${qr_png}" ]]; then
      log "Removing ${qr_png}"
      rm -f "${qr_png}"
    fi
  fi
}

purge_certificate() {
  if [[ "${PURGE_CERT}" -ne 1 ]]; then
    return
  fi

  [[ -n "${DOMAIN}" ]] || die "--purge-cert requires --domain <name>"

  if ! command -v certbot >/dev/null 2>&1; then
    warn "certbot not found, skipping cert cleanup for ${DOMAIN}"
    return
  fi

  if certbot certificates --cert-name "${DOMAIN}" >/dev/null 2>&1; then
    log "Removing Let's Encrypt certificate: ${DOMAIN}"
    certbot delete --non-interactive --cert-name "${DOMAIN}" || warn "Failed to remove cert ${DOMAIN}"
  else
    warn "Certificate '${DOMAIN}' not found in certbot"
  fi
}

main() {
  parse_args "$@"
  require_root
  confirm
  stop_and_remove_service
  remove_runtime_files
  remove_qr_file
  purge_certificate
  log "Hysteria2 uninstall completed"
}

main "$@"
