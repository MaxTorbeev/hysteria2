#!/usr/bin/env bash
set -euo pipefail

DOMAIN="${DOMAIN:-hp2.maxtor.name}"
EMAIL="${EMAIL:-}"
PORT="${PORT:-443}"
SKIP_DOMAIN_IP_CHECK="${SKIP_DOMAIN_IP_CHECK:-0}"
SERVICE_NAME="hysteria-server"
HYSTERIA_BIN="/usr/local/bin/hysteria"
HYSTERIA_DIR="/etc/hysteria"
CONFIG_FILE="${HYSTERIA_DIR}/config.yaml"
AUTH_FILE="${HYSTERIA_DIR}/auth.txt"
MASQ_DIR="${HYSTERIA_DIR}/masquerade"
QR_PNG="/root/hy2-${DOMAIN}.png"

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

require_debian() {
  if [[ ! -f /etc/os-release ]]; then
    die "/etc/os-release not found"
  fi
  # shellcheck source=/dev/null
  source /etc/os-release
  if [[ "${ID:-}" != "debian" && "${ID_LIKE:-}" != *"debian"* ]]; then
    die "This script supports Debian-based systems only"
  fi
}

validate_input() {
  [[ -n "${DOMAIN}" ]] || die "DOMAIN is empty"
  [[ "${PORT}" =~ ^[0-9]+$ ]] || die "PORT must be a number"
  if (( PORT < 1 || PORT > 65535 )); then
    die "PORT must be between 1 and 65535"
  fi
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o DPkg::Lock::Timeout=300 update
  apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends "$@"
}

detect_arch() {
  local raw
  raw="$(uname -m)"
  case "${raw}" in
    x86_64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "arm" ;;
    *)
      die "Unsupported architecture: ${raw}"
      ;;
  esac
}

install_dependencies() {
  log "Installing dependencies"
  apt_install ca-certificates curl openssl qrencode certbot
}

download_hysteria() {
  local arch url
  arch="$(detect_arch)"
  url="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${arch}"
  log "Downloading Hysteria2 (${arch})"
  curl -fL "${url}" -o "${HYSTERIA_BIN}"
  chmod 0755 "${HYSTERIA_BIN}"
}

ensure_domain_points_here() {
  local matched matched_ip dip sip
  local -a server_ips domain_ips

  if [[ "${SKIP_DOMAIN_IP_CHECK}" == "1" ]]; then
    warn "Skipping domain/IP check because SKIP_DOMAIN_IP_CHECK=1"
    return
  fi

  mapfile -t server_ips < <(
    {
      ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d'/' -f1
      ip -o -6 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d'/' -f1
      curl -4fsS --max-time 6 https://api.ipify.org 2>/dev/null || true
      curl -6fsS --max-time 6 https://api64.ipify.org 2>/dev/null || true
    } | awk 'NF && !seen[$0]++'
  )
  mapfile -t domain_ips < <(
    {
      getent ahostsv4 "${DOMAIN}" 2>/dev/null | awk '{print $1}'
      getent ahostsv6 "${DOMAIN}" 2>/dev/null | awk '{print $1}'
    } | awk 'NF && !seen[$0]++'
  )

  if (( ${#domain_ips[@]} == 0 )); then
    die "Domain ${DOMAIN} does not resolve to any IP. Check DNS records first."
  fi

  if (( ${#server_ips[@]} == 0 )); then
    die "Could not detect server IP addresses. Set SKIP_DOMAIN_IP_CHECK=1 to bypass."
  fi

  matched=0
  matched_ip=""
  for dip in "${domain_ips[@]}"; do
    for sip in "${server_ips[@]}"; do
      if [[ "${dip}" == "${sip}" ]]; then
        matched=1
        matched_ip="${dip}"
        break 2
      fi
    done
  done

  if (( matched == 0 )); then
    warn "Domain ${DOMAIN} resolves to: ${domain_ips[*]}"
    warn "Server IP candidates: ${server_ips[*]}"
    die "Domain/IP mismatch. Point ${DOMAIN} to this server IP, then retry."
  fi

  log "Domain/IP check passed: ${DOMAIN} -> ${matched_ip}"
}

issue_certificate() {
  if [[ -z "${EMAIL}" ]]; then
    read -r -p "Enter email for Let's Encrypt (required): " EMAIL
  fi
  [[ -n "${EMAIL}" ]] || die "EMAIL is required for Let's Encrypt"

  log "Requesting TLS certificate for ${DOMAIN} via Let's Encrypt"
  certbot certonly \
    --standalone \
    --non-interactive \
    --agree-tos \
    --email "${EMAIL}" \
    -d "${DOMAIN}"
}

prepare_runtime_files() {
  mkdir -p "${HYSTERIA_DIR}"
  chmod 0700 "${HYSTERIA_DIR}"

  if [[ ! -f "${AUTH_FILE}" ]]; then
    openssl rand -hex 16 > "${AUTH_FILE}"
    chmod 0600 "${AUTH_FILE}"
  fi

  mkdir -p "${MASQ_DIR}"
  chmod 0755 "${MASQ_DIR}"
  cat > "${MASQ_DIR}/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${DOMAIN}</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 0; padding: 4rem 1.25rem; background: #f4f7fb; color: #0f172a; }
    main { max-width: 760px; margin: 0 auto; background: #fff; border-radius: 12px; padding: 2rem; box-shadow: 0 8px 24px rgba(15, 23, 42, 0.08); }
    h1 { margin-top: 0; font-size: 1.8rem; }
    p { line-height: 1.6; }
    code { background: #e2e8f0; padding: 0.15rem 0.35rem; border-radius: 6px; }
  </style>
</head>
<body>
  <main>
    <h1>${DOMAIN}</h1>
    <p>This host is online.</p>
    <p>If you are the administrator, Hysteria2 is configured with local masquerade content from <code>${MASQ_DIR}</code>.</p>
  </main>
</body>
</html>
EOF
  chmod 0644 "${MASQ_DIR}/index.html"
}

write_config() {
  local auth cert key
  auth="$(tr -d '[:space:]' < "${AUTH_FILE}")"
  cert="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
  key="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

  [[ -f "${cert}" ]] || die "Certificate not found: ${cert}"
  [[ -f "${key}" ]] || die "Private key not found: ${key}"

  cat > "${CONFIG_FILE}" <<EOF
listen: :${PORT}

tls:
  cert: ${cert}
  key: ${key}

auth:
  type: password
  password: ${auth}

masquerade:
  type: file
  file:
    dir: ${MASQ_DIR}
EOF
  chmod 0600 "${CONFIG_FILE}"
}

write_systemd_service() {
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Hysteria2 Server
After=network.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${HYSTERIA_BIN} server -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}"
}

configure_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    log "Opening ports in UFW"
    ufw allow "${PORT}/udp" || true
    ufw allow 80/tcp || true
  fi
}

configure_renew_hook() {
  local hook="/etc/letsencrypt/renewal-hooks/deploy/hysteria-restart.sh"
  mkdir -p "$(dirname "${hook}")"
  cat > "${hook}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
systemctl reload hysteria-server 2>/dev/null || systemctl restart hysteria-server
EOF
  chmod 0755 "${hook}"
}

print_client_info() {
  local auth uri_hy2 uri_hysteria2
  auth="$(tr -d '[:space:]' < "${AUTH_FILE}")"
  uri_hy2="hy2://${auth}@${DOMAIN}:${PORT}/?sni=${DOMAIN}#HP2-Hysteria2"
  uri_hysteria2="hysteria2://${auth}@${DOMAIN}:${PORT}/?sni=${DOMAIN}#HP2-Hysteria2"

  echo
  log "Hysteria2 is installed and running."
  echo "Server: ${DOMAIN}:${PORT}/udp"
  echo "Auth : ${auth}"
  echo
  echo "Client URI (hy2):"
  echo "${uri_hy2}"
  echo
  echo "Client URI (hysteria2):"
  echo "${uri_hysteria2}"
  echo

  log "QR for hy2:// URI"
  qrencode -t ANSIUTF8 "${uri_hy2}" || true
  qrencode -o "${QR_PNG}" "${uri_hy2}" || true
  echo
  echo "QR PNG saved to: ${QR_PNG}"
}

main() {
  require_root
  require_debian
  validate_input
  install_dependencies
  download_hysteria
  ensure_domain_points_here
  issue_certificate
  prepare_runtime_files
  write_config
  write_systemd_service
  configure_firewall
  configure_renew_hook
  print_client_info
}

main "$@"
