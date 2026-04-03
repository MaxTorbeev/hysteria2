#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_INPUT_ENV_FILE="${SCRIPT_DIR}/.env"

INPUT_ENV_FILE="${INPUT_ENV_FILE:-}"
POSITIONAL_HY2_URI=""

WORK_DIR=""
CONFIG_DIR=""
CONFIG_FILE=""
BIN_DIR=""
ENTRYPOINT_FILE=""
SERVICE_ENV_FILE=""
STATE_ENV_FILE=""
LOG_DIR=""
INSTALL_LOG_FILE=""

SERVICE_NAME=""
UNIT_NAME=""
SYSTEMD_UNIT_FILE=""
AWG_IFACE=""
DEFAULT_AWG_IFACE=""

TPROXY_PORT=""
ROUTER_TABLE=""
ROUTER_MARK=""
NFT_TABLE=""
WAIT_TIMEOUT=""
LOG_LEVEL=""
DNS_SERVER=""
DNS_SERVER_PORT=""
DNS_STRATEGY=""
DEBUG_SOCKS_PORT=""
INSTALL_PACKAGES=""

DIRECT_SUFFIXES=""
EXTRA_DIRECT_DOMAINS=""
EXTRA_DIRECT_SUFFIXES=""
SAVE_STATE_ENV=""
HY2_URI=""

HYSTERIA_SERVER=""
HYSTERIA_PORT=""
HYSTERIA_PASSWORD=""
HYSTERIA_SNI=""
HYSTERIA_OBFS_TYPE=""
HYSTERIA_OBFS_PASSWORD=""

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
  sudo bash install_router.sh
  sudo bash install_router.sh --env-file /root/hp2-router.env
  sudo HY2_URI='hy2://password@host:443/?sni=host&obfs=salamander&obfs-password=secret' bash install_router.sh

If present, router/.env is loaded automatically.

Optional variables:
  HY2_URI                Hysteria2 URI. Optional if present in env file.
  INPUT_ENV_FILE         Env file to source before applying defaults.
  SERVICE_NAME           systemd service name (default: hp2-router)
  WORK_DIR               Where config/runtime files are stored (default: /opt/hp2-router)
  AWG_IFACE              Host awg/wg interface (auto-detected if empty)
  DIRECT_SUFFIXES        Domain suffixes routed directly, comma-separated (default: ru,xn--p1ai)
  EXTRA_DIRECT_DOMAINS   Exact domains routed directly, comma-separated
  EXTRA_DIRECT_SUFFIXES  Extra domain suffixes routed directly, comma-separated
  DNS_SERVER             Upstream DNS server for sing-box (default: 77.88.8.8)
  DNS_SERVER_PORT        Upstream DNS port (default: 53)
  DNS_STRATEGY           DNS strategy (default: prefer_ipv4)
  DEFAULT_AWG_IFACE      Fallback interface name when host awg/wg is not up yet (default: awg0)
  DEBUG_SOCKS_PORT       Optional SOCKS inbound for debugging hy2-out directly
  INSTALL_PACKAGES       Set to 1 to install sing-box and nftables via apt
  SAVE_STATE_ENV         Set to 1 to save effective settings to WORK_DIR/router.env
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env-file)
        [[ $# -ge 2 ]] || die "--env-file requires a path"
        INPUT_ENV_FILE="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        if [[ -z "${POSITIONAL_HY2_URI}" ]]; then
          POSITIONAL_HY2_URI="$1"
          shift
        else
          die "Unexpected argument: $1"
        fi
        ;;
    esac
  done
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root: sudo bash $0"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

load_env_file() {
  local env_file="${INPUT_ENV_FILE}"
  if [[ -z "${env_file}" && -f "${DEFAULT_INPUT_ENV_FILE}" ]]; then
    env_file="${DEFAULT_INPUT_ENV_FILE}"
  fi
  if [[ -z "${env_file}" ]]; then
    return
  fi
  [[ -f "${env_file}" ]] || die "Env file not found: ${env_file}"
  [[ -r "${env_file}" ]] || die "Env file is not readable: ${env_file}"

  log "Loading env file ${env_file}"
  set -a
  # shellcheck disable=SC1090
  source "${env_file}"
  set +a
}

normalize_service_name() {
  local raw_name="${SERVICE_NAME:-hp2-router}"
  UNIT_NAME="${raw_name%.service}.service"
  SERVICE_NAME="${UNIT_NAME%.service}"
  SYSTEMD_UNIT_FILE="${SYSTEMD_UNIT_FILE:-/etc/systemd/system/${UNIT_NAME}}"
}

apply_defaults() {
  WORK_DIR="${WORK_DIR:-/opt/hp2-router}"
  CONFIG_DIR="${WORK_DIR}/config"
  CONFIG_FILE="${CONFIG_FILE:-${CONFIG_DIR}/config.json}"
  BIN_DIR="${BIN_DIR:-${WORK_DIR}/bin}"
  ENTRYPOINT_FILE="${ENTRYPOINT_FILE:-${BIN_DIR}/router-entrypoint.sh}"
  SERVICE_ENV_FILE="${SERVICE_ENV_FILE:-${WORK_DIR}/service.env}"
  STATE_ENV_FILE="${STATE_ENV_FILE:-${WORK_DIR}/router.env}"
  LOG_DIR="${LOG_DIR:-${WORK_DIR}/logs}"
  INSTALL_LOG_FILE="${INSTALL_LOG_FILE:-${LOG_DIR}/install.log}"

  SERVICE_NAME="${SERVICE_NAME:-hp2-router}"
  normalize_service_name
  AWG_IFACE="${AWG_IFACE:-}"
  DEFAULT_AWG_IFACE="${DEFAULT_AWG_IFACE:-awg0}"

  TPROXY_PORT="${TPROXY_PORT:-60080}"
  ROUTER_TABLE="${ROUTER_TABLE:-100}"
  ROUTER_MARK="${ROUTER_MARK:-0x1}"
  NFT_TABLE="${NFT_TABLE:-hp2router}"
  WAIT_TIMEOUT="${WAIT_TIMEOUT:-30}"
  LOG_LEVEL="${LOG_LEVEL:-info}"
  DNS_SERVER="${DNS_SERVER:-77.88.8.8}"
  DNS_SERVER_PORT="${DNS_SERVER_PORT:-53}"
  DNS_STRATEGY="${DNS_STRATEGY:-prefer_ipv4}"
  DEBUG_SOCKS_PORT="${DEBUG_SOCKS_PORT:-}"
  INSTALL_PACKAGES="${INSTALL_PACKAGES:-0}"

  DIRECT_SUFFIXES="${DIRECT_SUFFIXES:-ru,xn--p1ai}"
  EXTRA_DIRECT_DOMAINS="${EXTRA_DIRECT_DOMAINS:-}"
  EXTRA_DIRECT_SUFFIXES="${EXTRA_DIRECT_SUFFIXES:-}"
  SAVE_STATE_ENV="${SAVE_STATE_ENV:-0}"
  HY2_URI="${HY2_URI:-${POSITIONAL_HY2_URI}}"
}

setup_install_logging() {
  [[ "${INSTALL_LOGGING_READY:-0}" == "1" ]] && return 0
  mkdir -p "${WORK_DIR}" "${LOG_DIR}"
  chmod 0700 "${WORK_DIR}" "${LOG_DIR}"
  exec > >(tee -a "${INSTALL_LOG_FILE}") 2>&1
  INSTALL_LOGGING_READY=1
  export INSTALL_LOGGING_READY
  log "Install log: ${INSTALL_LOG_FILE}"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

json_quote() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

csv_to_json_array() {
  local csv="$1"
  local -a items
  local out=""
  IFS=',' read -r -a items <<< "$csv"
  for item in "${items[@]}"; do
    item="$(trim "$item")"
    [[ -n "${item}" ]] || continue
    out+="${out:+, }$(json_quote "$item")"
  done
  printf '[%s]' "$out"
}

add_csv_item() {
  local current="$1"
  local item="$2"
  item="$(trim "$item")"
  if [[ -z "${item}" ]]; then
    printf '%s' "$current"
    return
  fi
  if [[ -z "${current}" ]]; then
    printf '%s' "$item"
  else
    printf '%s,%s' "$current" "$item"
  fi
}

url_decode() {
  local data="${1//+/ }"
  printf '%b' "${data//%/\\x}"
}

parse_query_param() {
  local query="$1"
  local key="$2"
  local pair raw_key raw_value
  IFS='&' read -r -a pairs <<< "$query"
  for pair in "${pairs[@]}"; do
    raw_key="${pair%%=*}"
    raw_value="${pair#*=}"
    if [[ "${raw_key}" == "${key}" ]]; then
      url_decode "${raw_value}"
      return 0
    fi
  done
  return 1
}

parse_host_port() {
  local host_port="$1"
  if [[ "${host_port}" =~ ^\[([0-9A-Fa-f:]+)\]:([0-9]+)$ ]]; then
    HYSTERIA_SERVER="${BASH_REMATCH[1]}"
    HYSTERIA_PORT="${BASH_REMATCH[2]}"
    return
  fi
  HYSTERIA_SERVER="${host_port%:*}"
  HYSTERIA_PORT="${host_port##*:}"
}

parse_hy2_uri() {
  local uri="$1"
  local rest without_fragment host_port_and_path host_port query

  [[ -n "${uri}" ]] || die "HY2_URI is empty"
  [[ "${uri}" == hy2://* || "${uri}" == hysteria2://* ]] || die "HY2_URI must start with hy2:// or hysteria2://"

  rest="${uri#*://}"
  without_fragment="${rest%%#*}"

  HYSTERIA_PASSWORD="${without_fragment%@*}"
  host_port_and_path="${without_fragment#*@}"
  host_port="${host_port_and_path%%\?*}"
  host_port="${host_port%%/*}"
  query=""

  if [[ "${host_port_and_path}" == *\?* ]]; then
    query="${host_port_and_path#*\?}"
  fi

  parse_host_port "${host_port}"
  HYSTERIA_SNI="$(parse_query_param "${query}" "sni" || true)"
  HYSTERIA_OBFS_TYPE="$(parse_query_param "${query}" "obfs" || true)"
  HYSTERIA_OBFS_PASSWORD="$(parse_query_param "${query}" "obfs-password" || true)"

  [[ -n "${HYSTERIA_SERVER}" ]] || die "Could not parse server from HY2_URI"
  [[ "${HYSTERIA_PORT}" =~ ^[0-9]+$ ]] || die "Could not parse port from HY2_URI"
  [[ -n "${HYSTERIA_PASSWORD}" ]] || die "Could not parse password from HY2_URI"
  [[ -n "${HYSTERIA_SNI}" ]] || HYSTERIA_SNI="${HYSTERIA_SERVER}"
}

is_ip_literal() {
  local value="$1"
  [[ "${value}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "${value}" == *:* ]]
}

detect_awg_iface() {
  local dev iface=""
  for dev in /sys/class/net/*; do
    dev="${dev##*/}"
    case "${dev}" in
      awg*)
        iface="${dev}"
        break
        ;;
    esac
  done
  if [[ -z "${iface}" ]]; then
    shopt -s nullglob
    for dev in /sys/class/net/*; do
      dev="${dev##*/}"
      case "${dev}" in
        wg*)
          iface="${dev}"
          break
          ;;
      esac
    done
    shopt -u nullglob
  fi
  if [[ -n "${iface}" ]]; then
    AWG_IFACE="${iface}"
    return 0
  fi

  if [[ -n "${DEFAULT_AWG_IFACE}" ]]; then
    AWG_IFACE="${DEFAULT_AWG_IFACE}"
    warn "Could not auto-detect a host awg/wg interface. Falling back to ${AWG_IFACE}; the service will wait for it."
    return 0
  fi

  die "Could not auto-detect a host awg/wg interface. Start host-level AmneziaWG first or set AWG_IFACE explicitly."
}

resolve_awg_iface() {
  if [[ -z "${AWG_IFACE}" ]]; then
    detect_awg_iface
    log "Detected WireGuard interface: ${AWG_IFACE}"
    return 0
  fi

  if ip link show dev "${AWG_IFACE}" >/dev/null 2>&1; then
    log "Using WireGuard interface: ${AWG_IFACE}"
  else
    warn "Interface ${AWG_IFACE} is not present yet; the service will wait up to ${WAIT_TIMEOUT}s on start"
  fi
}

install_host_packages() {
  [[ "${INSTALL_PACKAGES}" == "1" ]] || return 0

  require_cmd apt-get
  require_cmd curl

  log "Installing host packages"
  apt-get update
  apt-get install -y ca-certificates curl iproute2 nftables

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
  chmod a+r /etc/apt/keyrings/sagernet.asc
  cat > /etc/apt/sources.list.d/sagernet.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
  apt-get update
  apt-get install -y sing-box
}

render_config() {
  local direct_domains=""
  local domain_rule=""
  local suffix_rule=""
  local obfs_block=""
  local domain_resolver_block=""
  local debug_socks_inbound=""

  direct_domains="$(add_csv_item "${direct_domains}" "${HYSTERIA_SNI}")"
  if ! is_ip_literal "${HYSTERIA_SERVER}"; then
    direct_domains="$(add_csv_item "${direct_domains}" "${HYSTERIA_SERVER}")"
  fi
  direct_domains="$(add_csv_item "${direct_domains}" "${EXTRA_DIRECT_DOMAINS}")"

  if [[ -n "${direct_domains//,/}" ]]; then
    domain_rule=$(cat <<EOF
      {
        "domain": $(csv_to_json_array "${direct_domains}"),
        "action": "route",
        "outbound": "direct"
      },
EOF
)
  fi

  if [[ -n "${DIRECT_SUFFIXES//,/}" || -n "${EXTRA_DIRECT_SUFFIXES//,/}" ]]; then
    local all_suffixes="${DIRECT_SUFFIXES}"
    if [[ -n "${EXTRA_DIRECT_SUFFIXES}" ]]; then
      all_suffixes="$(add_csv_item "${all_suffixes}" "${EXTRA_DIRECT_SUFFIXES}")"
    fi
    suffix_rule=$(cat <<EOF
      {
        "domain_suffix": $(csv_to_json_array "${all_suffixes}"),
        "action": "route",
        "outbound": "direct"
      },
EOF
)
  fi

  if [[ -n "${HYSTERIA_OBFS_TYPE}" ]]; then
    [[ "${HYSTERIA_OBFS_TYPE}" == "salamander" ]] || die "Unsupported obfs type: ${HYSTERIA_OBFS_TYPE}"
    [[ -n "${HYSTERIA_OBFS_PASSWORD}" ]] || die "HY2 URI contains obfs without obfs-password"
    obfs_block=$(cat <<EOF
      ,
      "obfs": {
        "type": "salamander",
        "password": $(json_quote "${HYSTERIA_OBFS_PASSWORD}")
      }
EOF
)
  fi

  domain_resolver_block=$(cat <<'EOF'
      ,
      "domain_resolver": {
        "server": "dns-direct",
        "strategy": "__DNS_STRATEGY__"
      }
EOF
)
  domain_resolver_block="${domain_resolver_block//__DNS_STRATEGY__/$(printf '%s' "${DNS_STRATEGY}")}"

  if [[ -n "${DEBUG_SOCKS_PORT}" ]]; then
    [[ "${DEBUG_SOCKS_PORT}" =~ ^[0-9]+$ ]] || die "DEBUG_SOCKS_PORT must be numeric"
    debug_socks_inbound=$(cat <<EOF
    ,
    {
      "type": "socks",
      "tag": "debug-socks",
      "listen": "0.0.0.0",
      "listen_port": ${DEBUG_SOCKS_PORT}
    }
EOF
)
  fi

  mkdir -p "${WORK_DIR}" "${CONFIG_DIR}" "${BIN_DIR}"
  chmod 0700 "${WORK_DIR}" "${CONFIG_DIR}" "${BIN_DIR}"

  cat > "${CONFIG_FILE}" <<EOF
{
  "log": {
    "level": $(json_quote "${LOG_LEVEL}"),
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "dns-direct",
        "server": $(json_quote "${DNS_SERVER}"),
        "server_port": ${DNS_SERVER_PORT}
      }
    ],
    "final": "dns-direct",
    "strategy": $(json_quote "${DNS_STRATEGY}")
  },
  "inbounds": [
    {
      "type": "tproxy",
      "tag": "tproxy-in",
      "listen": "0.0.0.0",
      "listen_port": ${TPROXY_PORT}
    }${debug_socks_inbound}
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    },
    {
      "type": "hysteria2",
      "tag": "hy2-out",
      "server": $(json_quote "${HYSTERIA_SERVER}"),
      "server_port": ${HYSTERIA_PORT},
      "password": $(json_quote "${HYSTERIA_PASSWORD}"),
      "tls": {
        "enabled": true,
        "server_name": $(json_quote "${HYSTERIA_SNI}")
      }${domain_resolver_block}${obfs_block}
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "default_domain_resolver": {
      "server": "dns-direct",
      "strategy": $(json_quote "${DNS_STRATEGY}")
    },
    "rules": [
      {
        "action": "sniff",
        "timeout": "1s"
      },
      {
        "protocol": "dns",
        "action": "hijack-dns"
      },
      {
        "port": 53,
        "action": "hijack-dns"
      },
${domain_rule}${suffix_rule}      {
        "ip_is_private": true,
        "action": "route",
        "outbound": "direct"
      }
    ],
    "final": "hy2-out"
  }
}
EOF
  chmod 0600 "${CONFIG_FILE}"
}

write_service_env_file() {
  cat > "${SERVICE_ENV_FILE}" <<EOF
AWG_IFACE=$(printf '%q' "${AWG_IFACE}")
CONFIG_FILE=$(printf '%q' "${CONFIG_FILE}")
TPROXY_PORT=$(printf '%q' "${TPROXY_PORT}")
ROUTER_TABLE=$(printf '%q' "${ROUTER_TABLE}")
ROUTER_MARK=$(printf '%q' "${ROUTER_MARK}")
NFT_TABLE=$(printf '%q' "${NFT_TABLE}")
WAIT_TIMEOUT=$(printf '%q' "${WAIT_TIMEOUT}")
EOF
  chmod 0600 "${SERVICE_ENV_FILE}"
}

write_state_env_file() {
  cat > "${STATE_ENV_FILE}" <<EOF
HY2_URI=$(printf '%q' "${HY2_URI}")
SERVICE_NAME=$(printf '%q' "${SERVICE_NAME}")
UNIT_NAME=$(printf '%q' "${UNIT_NAME}")
SYSTEMD_UNIT_FILE=$(printf '%q' "${SYSTEMD_UNIT_FILE}")
WORK_DIR=$(printf '%q' "${WORK_DIR}")
CONFIG_FILE=$(printf '%q' "${CONFIG_FILE}")
SERVICE_ENV_FILE=$(printf '%q' "${SERVICE_ENV_FILE}")
LOG_DIR=$(printf '%q' "${LOG_DIR}")
INSTALL_LOG_FILE=$(printf '%q' "${INSTALL_LOG_FILE}")
AWG_IFACE=$(printf '%q' "${AWG_IFACE}")
DEFAULT_AWG_IFACE=$(printf '%q' "${DEFAULT_AWG_IFACE}")
TPROXY_PORT=$(printf '%q' "${TPROXY_PORT}")
ROUTER_TABLE=$(printf '%q' "${ROUTER_TABLE}")
ROUTER_MARK=$(printf '%q' "${ROUTER_MARK}")
NFT_TABLE=$(printf '%q' "${NFT_TABLE}")
WAIT_TIMEOUT=$(printf '%q' "${WAIT_TIMEOUT}")
LOG_LEVEL=$(printf '%q' "${LOG_LEVEL}")
DNS_SERVER=$(printf '%q' "${DNS_SERVER}")
DNS_SERVER_PORT=$(printf '%q' "${DNS_SERVER_PORT}")
DNS_STRATEGY=$(printf '%q' "${DNS_STRATEGY}")
DEBUG_SOCKS_PORT=$(printf '%q' "${DEBUG_SOCKS_PORT}")
DIRECT_SUFFIXES=$(printf '%q' "${DIRECT_SUFFIXES}")
EXTRA_DIRECT_DOMAINS=$(printf '%q' "${EXTRA_DIRECT_DOMAINS}")
EXTRA_DIRECT_SUFFIXES=$(printf '%q' "${EXTRA_DIRECT_SUFFIXES}")
EOF
  chmod 0600 "${STATE_ENV_FILE}"
}

install_entrypoint() {
  install -m 0755 "${SCRIPT_DIR}/entrypoint.sh" "${ENTRYPOINT_FILE}"
}

install_systemd_unit() {
  cat > "${SYSTEMD_UNIT_FILE}" <<EOF
[Unit]
Description=HP2 transparent router for host-level AmneziaWG
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${SERVICE_ENV_FILE}
ExecStart=${ENTRYPOINT_FILE}
Restart=on-failure
RestartSec=3
User=root
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "${SYSTEMD_UNIT_FILE}"
}

validate_dependencies() {
  require_cmd ip
  require_cmd nft
  require_cmd systemctl
  require_cmd sing-box
}

reload_and_restart_service() {
  log "Installing systemd unit ${UNIT_NAME}"
  systemctl daemon-reload
  systemctl enable "${UNIT_NAME}" >/dev/null
  systemctl restart "${UNIT_NAME}"
}

print_summary() {
  local state_env_note=""
  if [[ "${SAVE_STATE_ENV}" == "1" ]]; then
    state_env_note=$(cat <<EOF
State env:
  ${STATE_ENV_FILE}

EOF
)
  fi

  cat <<EOF

Host router service is running.

Service:
  ${UNIT_NAME}

Interface:
  ${AWG_IFACE}

Config:
  ${CONFIG_FILE}

Runtime env:
  ${SERVICE_ENV_FILE}

${state_env_note}Main commands:
  systemctl status ${UNIT_NAME} --no-pager
  journalctl -u ${UNIT_NAME} -f
  bash ${SCRIPT_DIR}/debug_router.sh
  bash ${SCRIPT_DIR}/status_router.sh

Notes:
  - Direct routing is currently based on domain suffixes: ${DIRECT_SUFFIXES}
  - Everything else falls back to Hysteria 2.
  - This installer assumes host-level AmneziaWG is already configured or will appear on ${AWG_IFACE}.
EOF
}

main() {
  parse_args "$@"
  require_root
  load_env_file
  apply_defaults
  setup_install_logging

  if [[ -z "${HY2_URI}" ]]; then
    usage
    exit 1
  fi

  install_host_packages
  validate_dependencies
  parse_hy2_uri "${HY2_URI}"
  resolve_awg_iface
  render_config
  write_service_env_file
  if [[ "${SAVE_STATE_ENV}" == "1" ]]; then
    write_state_env_file
  fi
  install_entrypoint
  install_systemd_unit
  sing-box check -c "${CONFIG_FILE}"
  reload_and_restart_service
  print_summary
}

main "$@"
