#!/usr/bin/env bash
set -euo pipefail

HYSTERIA_DIR="${HYSTERIA_DIR:-/etc/hysteria}"
CONFIG_FILE="${CONFIG_FILE:-${HYSTERIA_DIR}/config.yaml}"
USERS_FILE="${USERS_FILE:-${HYSTERIA_DIR}/users.db}"
AUTH_FILE="${AUTH_FILE:-${HYSTERIA_DIR}/auth.txt}"
OBFS_FILE="${OBFS_FILE:-${HYSTERIA_DIR}/obfs.txt}"
OUT_DIR="${OUT_DIR:-./hy2_clients_$(date +%Y%m%d_%H%M%S)}"

log() {
  echo "[+] $*"
}

die() {
  echo "[x] $*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root: sudo bash $0 [--out-dir DIR]"
  fi
}

require_tools() {
  command -v awk >/dev/null 2>&1 || die "awk is required"
  command -v sed >/dev/null 2>&1 || die "sed is required"
  command -v qrencode >/dev/null 2>&1 || die "qrencode is required"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out-dir)
        [[ $# -ge 2 ]] || die "Missing value for --out-dir"
        OUT_DIR="$2"
        shift 2
        ;;
      -h|--help)
        cat <<EOF
Usage: sudo bash $0 [--out-dir DIR]

Options:
  --out-dir DIR   Output directory for PNG and HTML files
EOF
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

ensure_files() {
  [[ -f "${CONFIG_FILE}" ]] || die "Config not found: ${CONFIG_FILE}"
}

extract_domain() {
  local cert_line cert_path domain
  cert_line="$(sed -n 's/^[[:space:]]*cert:[[:space:]]*//p' "${CONFIG_FILE}" | head -n1 || true)"
  cert_path="${cert_line}"
  domain="$(echo "${cert_path}" | sed -E 's|.*/live/([^/]+)/.*|\1|' || true)"
  [[ -n "${domain}" ]] || die "Could not detect domain from ${CONFIG_FILE}"
  echo "${domain}"
}

extract_port() {
  local listen_line port
  listen_line="$(sed -n 's/^[[:space:]]*listen:[[:space:]]*//p' "${CONFIG_FILE}" | head -n1 || true)"
  port="$(echo "${listen_line}" | sed -E 's|.*:([0-9]+).*|\1|' || true)"
  [[ "${port}" =~ ^[0-9]+$ ]] || port="443"
  echo "${port}"
}

extract_auth_type() {
  awk '
    BEGIN {in_auth=0}
    {
      if ($0 ~ /^auth:[[:space:]]*$/) { in_auth=1; next }
      if (in_auth && $0 ~ /^[^[:space:]].*:/) { in_auth=0 }
      if (in_auth && $0 ~ /^[[:space:]]+type:[[:space:]]*/) {
        sub(/^[[:space:]]+type:[[:space:]]*/, "", $0)
        print $0
        exit
      }
    }
  ' "${CONFIG_FILE}"
}

extract_config_password() {
  awk '
    BEGIN {in_auth=0}
    {
      if ($0 ~ /^auth:[[:space:]]*$/) { in_auth=1; next }
      if (in_auth && $0 ~ /^[^[:space:]].*:/) { in_auth=0 }
      if (in_auth && $0 ~ /^[[:space:]]+password:[[:space:]]*/) {
        sub(/^[[:space:]]+password:[[:space:]]*/, "", $0)
        print $0
        exit
      }
    }
  ' "${CONFIG_FILE}"
}

extract_obfs_password() {
  if ! grep -Eq '^[[:space:]]*obfs:[[:space:]]*$' "${CONFIG_FILE}"; then
    echo ""
    return
  fi

  if [[ -f "${OBFS_FILE}" ]]; then
    tr -d '[:space:]' < "${OBFS_FILE}"
    return
  fi

  awk '
    BEGIN {in_obfs=0}
    {
      if ($0 ~ /^obfs:[[:space:]]*$/) { in_obfs=1; next }
      if (in_obfs && $0 ~ /^[^[:space:]].*:/) { in_obfs=0 }
      if (in_obfs && $0 ~ /^[[:space:]]+password:[[:space:]]*/) {
        sub(/^[[:space:]]+password:[[:space:]]*/, "", $0)
        print $0
        exit
      }
    }
  ' "${CONFIG_FILE}"
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

html_escape() {
  printf '%s' "$1" | sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&#39;/g"
}

sanitize_name() {
  local input="$1"
  local sanitized
  sanitized="$(printf '%s' "${input}" | tr -c 'A-Za-z0-9._-' '_')"
  [[ -n "${sanitized}" ]] || sanitized="user"
  echo "${sanitized}"
}

collect_users() {
  local auth_type="$1"
  local tmp_users="$2"

  case "${auth_type}" in
    password)
      local pass
      if [[ -f "${AUTH_FILE}" ]]; then
        pass="$(tr -d '[:space:]' < "${AUTH_FILE}")"
      else
        pass="$(extract_config_password)"
      fi
      [[ -n "${pass}" ]] || die "Password auth is enabled, but password is empty"
      printf 'password-auth\t%s\n' "${pass}" > "${tmp_users}"
      ;;
    userpass)
      if [[ -s "${USERS_FILE}" ]]; then
        awk -F':' 'NF>=2 && $1!="" {print $1 "\t" $2}' "${USERS_FILE}" > "${tmp_users}"
      else
        awk '
          BEGIN {in_auth=0; in_userpass=0}
          {
            if ($0 ~ /^auth:[[:space:]]*$/) { in_auth=1; next }
            if (in_auth && $0 ~ /^[^[:space:]].*:/) { in_auth=0; in_userpass=0 }
            if (in_auth && $0 ~ /^[[:space:]]+userpass:[[:space:]]*$/) { in_userpass=1; next }
            if (in_userpass && $0 ~ /^[[:space:]]{4}[A-Za-z0-9._-]+:[[:space:]]*/) {
              line=$0
              sub(/^[[:space:]]+/, "", line)
              split(line, a, /:[[:space:]]*/)
              print a[1] "\t" a[2]
            }
          }
        ' "${CONFIG_FILE}" > "${tmp_users}"
      fi
      ;;
    *)
      die "Unsupported auth type in ${CONFIG_FILE}: ${auth_type}"
      ;;
  esac

  [[ -s "${tmp_users}" ]] || die "No users found for auth type '${auth_type}'"
}

build_links_and_qr() {
  local auth_type="$1"
  local domain="$2"
  local port="$3"
  local obfs="$4"
  local tmp_users="$5"
  local manifest="$6"

  : > "${manifest}"
  while IFS=$'\t' read -r username password; do
    local enc_user enc_pass uri_hy2 uri_hysteria2 tag base_name qr_file
    enc_user="$(url_encode "${username}")"
    enc_pass="$(url_encode "${password}")"
    tag="$(url_encode "HP2-${username}")"

    if [[ "${auth_type}" == "password" ]]; then
      uri_hy2="hy2://${enc_pass}@${domain}:${port}/?sni=${domain}"
      uri_hysteria2="hysteria2://${enc_pass}@${domain}:${port}/?sni=${domain}"
    else
      uri_hy2="hy2://${enc_user}:${enc_pass}@${domain}:${port}/?sni=${domain}"
      uri_hysteria2="hysteria2://${enc_user}:${enc_pass}@${domain}:${port}/?sni=${domain}"
    fi

    if [[ -n "${obfs}" ]]; then
      uri_hy2="${uri_hy2}&obfs=salamander&obfs-password=${obfs}"
      uri_hysteria2="${uri_hysteria2}&obfs=salamander&obfs-password=${obfs}"
    fi
    uri_hy2="${uri_hy2}#${tag}"
    uri_hysteria2="${uri_hysteria2}#${tag}"

    base_name="$(sanitize_name "${username}")"
    qr_file="qr_${base_name}.png"
    qrencode -o "${OUT_DIR}/${qr_file}" "${uri_hy2}"
    printf '%s\t%s\t%s\t%s\n' "${username}" "${qr_file}" "${uri_hy2}" "${uri_hysteria2}" >> "${manifest}"
  done < "${tmp_users}"
}

write_html() {
  local domain="$1"
  local port="$2"
  local manifest="$3"
  local html_file="${OUT_DIR}/index.html"

  cat > "${html_file}" <<EOF
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Hysteria2 Users</title>
  <style>
    :root {
      --bg: #f6f8fb;
      --card: #ffffff;
      --text: #10203a;
      --muted: #5b6473;
      --border: #d9e0ea;
      --accent: #1f4aa2;
    }
    body {
      margin: 0;
      font-family: "Segoe UI", "Noto Sans", sans-serif;
      background: var(--bg);
      color: var(--text);
    }
    .wrap {
      max-width: 1300px;
      margin: 0 auto;
      padding: 24px;
    }
    .head {
      margin-bottom: 18px;
    }
    .head h1 {
      margin: 0 0 4px 0;
      font-size: 28px;
    }
    .head p {
      margin: 0;
      color: var(--muted);
    }
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
      gap: 14px;
    }
    .card {
      background: var(--card);
      border: 1px solid var(--border);
      border-radius: 12px;
      padding: 14px;
      box-shadow: 0 4px 20px rgba(20, 33, 55, 0.05);
    }
    .title {
      margin: 0 0 10px 0;
      font-size: 18px;
      color: var(--accent);
      overflow-wrap: anywhere;
    }
    .qr {
      width: 220px;
      height: 220px;
      object-fit: contain;
      display: block;
      margin: 0 auto 10px auto;
      border: 1px solid var(--border);
      border-radius: 8px;
      background: #fff;
    }
    .block {
      margin-top: 8px;
    }
    .label {
      font-size: 12px;
      color: var(--muted);
      margin-bottom: 4px;
    }
    .link {
      font-family: ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace;
      font-size: 12px;
      line-height: 1.45;
      overflow-wrap: anywhere;
      word-break: break-word;
      text-decoration: none;
      color: var(--text);
    }
    .link:hover {
      color: var(--accent);
    }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="head">
      <h1>Hysteria2 Users</h1>
      <p>Server: ${domain}:${port}/udp</p>
    </div>
    <div class="grid">
EOF

  while IFS=$'\t' read -r username qr_file uri_hy2 uri_hysteria2; do
    local esc_user esc_hy2 esc_hyst
    esc_user="$(html_escape "${username}")"
    esc_hy2="$(html_escape "${uri_hy2}")"
    esc_hyst="$(html_escape "${uri_hysteria2}")"
    cat >> "${html_file}" <<EOF
      <article class="card">
        <h2 class="title">${esc_user}</h2>
        <img class="qr" src="./${qr_file}" alt="QR ${esc_user}">
        <div class="block">
          <div class="label">hy2://</div>
          <a class="link" href="${esc_hy2}">${esc_hy2}</a>
        </div>
        <div class="block">
          <div class="label">hysteria2://</div>
          <a class="link" href="${esc_hyst}">${esc_hyst}</a>
        </div>
      </article>
EOF
  done < "${manifest}"

  cat >> "${html_file}" <<'EOF'
    </div>
  </div>
</body>
</html>
EOF
}

print_summary() {
  local manifest="$1"

  echo
  log "Generated links and QR for users:"
  while IFS=$'\t' read -r username qr_file uri_hy2 _; do
    echo " - ${username}: ${uri_hy2}"
    echo "   QR: ${OUT_DIR}/${qr_file}"
  done < "${manifest}"
  echo
  echo "HTML grid: ${OUT_DIR}/index.html"
}

main() {
  parse_args "$@"
  require_root
  require_tools
  ensure_files

  local domain port auth_type obfs tmp_users manifest
  domain="$(extract_domain)"
  port="$(extract_port)"
  auth_type="$(extract_auth_type)"
  obfs="$(extract_obfs_password)"

  mkdir -p "${OUT_DIR}"
  tmp_users="$(mktemp)"
  manifest="$(mktemp)"
  trap 'rm -f "${tmp_users}" "${manifest}"' EXIT

  collect_users "${auth_type}" "${tmp_users}"
  build_links_and_qr "${auth_type}" "${domain}" "${port}" "${obfs}" "${tmp_users}" "${manifest}"
  write_html "${domain}" "${port}" "${manifest}"
  print_summary "${manifest}"
}

main "$@"
