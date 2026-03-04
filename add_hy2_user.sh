#!/usr/bin/env bash
set -euo pipefail

HYSTERIA_DIR="${HYSTERIA_DIR:-/etc/hysteria}"
CONFIG_FILE="${CONFIG_FILE:-${HYSTERIA_DIR}/config.yaml}"
USERS_FILE="${USERS_FILE:-${HYSTERIA_DIR}/users.db}"
AUTH_FILE="${AUTH_FILE:-${HYSTERIA_DIR}/auth.txt}"
SERVICE_NAME="${SERVICE_NAME:-hysteria-server}"
QR_DIR="${QR_DIR:-/root}"

NEW_USER="${1:-}"
NEW_PASS="${2:-}"

log() {
  echo "[+] $*"
}

die() {
  echo "[x] $*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root: sudo bash $0 <username> [password]"
  fi
}

require_tools() {
  command -v awk >/dev/null 2>&1 || die "awk is required"
  command -v sed >/dev/null 2>&1 || die "sed is required"
  command -v systemctl >/dev/null 2>&1 || die "systemctl is required"
}

validate_username() {
  local user="$1"
  [[ -n "${user}" ]] || die "Username is required: sudo bash $0 <username> [password]"
  if [[ ! "${user}" =~ ^[A-Za-z0-9._-]{1,32}$ ]]; then
    die "Invalid username. Allowed: A-Z a-z 0-9 . _ - (max 32 chars)"
  fi
}

validate_password() {
  local pass="$1"
  [[ -n "${pass}" ]] || die "Password is empty"
  if [[ "${pass}" == *$'\n'* || "${pass}" == *$'\r'* ]]; then
    die "Password must be a single line"
  fi
  if [[ "${pass}" == *:* ]]; then
    die "Password must not contain ':'"
  fi
}

generate_password() {
  openssl rand -hex 12
}

ensure_files() {
  [[ -f "${CONFIG_FILE}" ]] || die "Config not found: ${CONFIG_FILE}"
  mkdir -p "${HYSTERIA_DIR}"
  touch "${USERS_FILE}"
  chmod 0600 "${USERS_FILE}" || true
}

extract_domain() {
  local cert_line cert_path domain
  cert_line="$(sed -n 's/^[[:space:]]*cert:[[:space:]]*//p' "${CONFIG_FILE}" | head -n1 || true)"
  cert_path="${cert_line}"
  domain="$(echo "${cert_path}" | sed -E 's|.*/live/([^/]+)/.*|\1|' || true)"
  echo "${domain}"
}

extract_port() {
  local listen_line port
  listen_line="$(sed -n 's/^[[:space:]]*listen:[[:space:]]*//p' "${CONFIG_FILE}" | head -n1 || true)"
  port="$(echo "${listen_line}" | sed -E 's|.*:([0-9]+).*|\1|' || true)"
  [[ "${port}" =~ ^[0-9]+$ ]] || port="443"
  echo "${port}"
}

extract_legacy_password() {
  sed -n 's/^[[:space:]]*password:[[:space:]]*//p' "${CONFIG_FILE}" | head -n1 || true
}

bootstrap_users_file() {
  if [[ -s "${USERS_FILE}" ]]; then
    return
  fi

  local legacy_pass
  legacy_pass="$(extract_legacy_password)"
  if [[ -z "${legacy_pass}" && -f "${AUTH_FILE}" ]]; then
    legacy_pass="$(tr -d '[:space:]' < "${AUTH_FILE}")"
  fi

  if [[ -n "${legacy_pass}" ]]; then
    echo "main:${legacy_pass}" > "${USERS_FILE}"
    chmod 0600 "${USERS_FILE}" || true
    log "Migrated existing password auth to user 'main'"
  fi
}

ensure_no_duplicate_user() {
  local user="$1"
  if awk -F':' -v u="${user}" '$1==u {found=1} END{exit found?0:1}' "${USERS_FILE}"; then
    die "User '${user}' already exists"
  fi
}

add_user_to_db() {
  local user="$1"
  local pass="$2"
  echo "${user}:${pass}" >> "${USERS_FILE}"
  chmod 0600 "${USERS_FILE}" || true
}

rewrite_auth_block() {
  local tmp_auth tmp_cfg
  tmp_auth="$(mktemp)"
  tmp_cfg="$(mktemp)"

  {
    echo "auth:"
    echo "  type: userpass"
    echo "  userpass:"
    awk -F':' 'NF>=2 && $1!="" {print "    " $1 ": " $2}' "${USERS_FILE}"
  } > "${tmp_auth}"

  awk -v auth_file="${tmp_auth}" '
    function print_auth() {
      while ((getline line < auth_file) > 0) print line
      close(auth_file)
    }
    BEGIN {in_auth=0; inserted=0}
    {
      if (!in_auth && $0 ~ /^auth:[[:space:]]*$/) {
        print_auth()
        in_auth=1
        inserted=1
        next
      }
      if (in_auth) {
        if ($0 ~ /^[^[:space:]].*:/) {
          in_auth=0
          print $0
        }
        next
      }
      print $0
    }
    END {
      if (!inserted) {
        print ""
        print_auth()
      }
    }
  ' "${CONFIG_FILE}" > "${tmp_cfg}"

  cp "${CONFIG_FILE}" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  mv "${tmp_cfg}" "${CONFIG_FILE}"
  rm -f "${tmp_auth}"
  chmod 0600 "${CONFIG_FILE}" || true
}

remove_obfs_block() {
  local tmp_cfg
  tmp_cfg="$(mktemp)"

  awk '
    BEGIN {in_obfs=0}
    {
      if (!in_obfs && $0 ~ /^obfs:[[:space:]]*$/) {
        in_obfs=1
        next
      }
      if (in_obfs) {
        if ($0 ~ /^[^[:space:]].*:/) {
          in_obfs=0
          print $0
        }
        next
      }
      print $0
    }
  ' "${CONFIG_FILE}" > "${tmp_cfg}"

  mv "${tmp_cfg}" "${CONFIG_FILE}"
  chmod 0600 "${CONFIG_FILE}" || true
}

restart_service() {
  systemctl restart "${SERVICE_NAME}"
  systemctl is-active --quiet "${SERVICE_NAME}" || die "Service '${SERVICE_NAME}' failed to start"
}

url_encode() {
  local s="$1"
  local out=""
  local i c hex
  for ((i=0; i<${#s}; i++)); do
    c="${s:$i:1}"
    case "${c}" in
      [a-zA-Z0-9.~_-]) out+="${c}" ;;
      *)
        printf -v hex '%%%02X' "'${c}"
        out+="${hex}"
        ;;
    esac
  done
  echo "${out}"
}

print_connection_info() {
  local user="$1"
  local pass="$2"
  local domain port uri_hy2 uri_hysteria2 png_file
  domain="$(extract_domain)"
  port="$(extract_port)"

  [[ -n "${domain}" ]] || die "Could not detect domain from ${CONFIG_FILE}"

  local enc_user enc_pass
  enc_user="$(url_encode "${user}")"
  enc_pass="$(url_encode "${pass}")"

  uri_hy2="hy2://${enc_user}:${enc_pass}@${domain}:${port}/?sni=${domain}"
  uri_hysteria2="hysteria2://${enc_user}:${enc_pass}@${domain}:${port}/?sni=${domain}"
  uri_hy2="${uri_hy2}#HP2-${user}"
  uri_hysteria2="${uri_hysteria2}#HP2-${user}"

  echo
  log "New Hysteria2 user created"
  echo "User   : ${user}"
  echo "Pass   : ${pass}"
  echo "Server : ${domain}:${port}/udp"
  echo
  echo "Client URI (hy2):"
  echo "${uri_hy2}"
  echo
  echo "Client URI (hysteria2):"
  echo "${uri_hysteria2}"
  echo

  if command -v qrencode >/dev/null 2>&1; then
    log "QR for hy2:// URI"
    qrencode -t ANSIUTF8 "${uri_hy2}" || true
    png_file="${QR_DIR}/hy2-${user}.png"
    qrencode -o "${png_file}" "${uri_hy2}" || true
    echo "QR PNG saved to: ${png_file}"
  else
    echo "qrencode not found, QR output skipped"
  fi
}

main() {
  require_root
  require_tools
  validate_username "${NEW_USER}"
  ensure_files
  bootstrap_users_file
  ensure_no_duplicate_user "${NEW_USER}"

  if [[ -z "${NEW_PASS}" ]]; then
    NEW_PASS="$(generate_password)"
  fi
  validate_password "${NEW_PASS}"

  add_user_to_db "${NEW_USER}" "${NEW_PASS}"
  rewrite_auth_block
  remove_obfs_block
  restart_service
  print_connection_info "${NEW_USER}" "${NEW_PASS}"
}

main "$@"
