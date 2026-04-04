#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_INPUT_ENV_FILE="${SCRIPT_DIR}/.env"

WORK_DIR="${WORK_DIR:-/opt/hp2-routing}"
CONFIG_DIR="${CONFIG_DIR:-${WORK_DIR}/config}"
CONFIG_FILE="${CONFIG_FILE:-${CONFIG_DIR}/config.json}"
STATE_ENV_FILE="${STATE_ENV_FILE:-${WORK_DIR}/routing.env}"
DNS_FILTER_CONFIG_FILE="${DNS_FILTER_CONFIG_FILE:-${WORK_DIR}/dnsmasq.conf}"

INPUT_ENV_FILE="${INPUT_ENV_FILE:-}"
POSITIONAL_HY2_URI=""

AWG_IFACE="${AWG_IFACE:-}"
DEFAULT_AWG_IFACE="${DEFAULT_AWG_IFACE:-awg0}"
TUN_IFACE="${TUN_IFACE:-sbhp2}"
TUN_ADDRESS="${TUN_ADDRESS:-172.19.0.1/30}"
TUN_MTU="${TUN_MTU:-1400}"
IPROUTE2_TABLE_INDEX="${IPROUTE2_TABLE_INDEX:-2022}"
IPROUTE2_RULE_INDEX="${IPROUTE2_RULE_INDEX:-9000}"
AUTO_REDIRECT_INPUT_MARK="${AUTO_REDIRECT_INPUT_MARK:-0x2023}"
AUTO_REDIRECT_OUTPUT_MARK="${AUTO_REDIRECT_OUTPUT_MARK:-0x2024}"
AUTO_REDIRECT_RESET_MARK="${AUTO_REDIRECT_RESET_MARK:-0x2025}"
AUTO_REDIRECT_FALLBACK_RULE_INDEX="${AUTO_REDIRECT_FALLBACK_RULE_INDEX:-32768}"
LOG_LEVEL="${LOG_LEVEL:-debug}"
DNS_SERVER="${DNS_SERVER:-77.88.8.8}"
DNS_SERVER_PORT="${DNS_SERVER_PORT:-53}"
DNS_STRATEGY="${DNS_STRATEGY:-ipv4_only}"
DNS_FILTER_ENABLED="${DNS_FILTER_ENABLED:-1}"
DNS_FILTER_LISTEN="${DNS_FILTER_LISTEN:-127.0.0.1}"
DNS_FILTER_PORT="${DNS_FILTER_PORT:-5353}"
DNS_FILTER_RR_TYPES="${DNS_FILTER_RR_TYPES:-HTTPS,SVCB}"
DEBUG_SOCKS_LISTEN="${DEBUG_SOCKS_LISTEN:-127.0.0.1}"
DEBUG_SOCKS_PORT="${DEBUG_SOCKS_PORT:-1080}"
REJECT_UDP_443="${REJECT_UDP_443:-0}"
DIRECT_SUFFIXES="${DIRECT_SUFFIXES:-ru,xn--p1ai}"
VPN_DOMAINS="${VPN_DOMAINS:-youtubei.googleapis.com,www.youtube.com,m.youtube.com,music.youtube.com}"
VPN_SUFFIXES="${VPN_SUFFIXES:-youtube.com,youtu.be,googlevideo.com,ytimg.com}"
ROUTE_FINAL="${ROUTE_FINAL:-direct}"
IPLIST_DOMAINS_URL="${IPLIST_DOMAINS_URL:-}"
IPLIST_WILDCARD_DOMAINS_URL="${IPLIST_WILDCARD_DOMAINS_URL:-https://iplist.opencck.org/?format=text&data=domains&group=youtube&wildcard=1}"
IPLIST_CONNECT_TIMEOUT="${IPLIST_CONNECT_TIMEOUT:-5}"
IPLIST_FETCH_TIMEOUT="${IPLIST_FETCH_TIMEOUT:-20}"
IPLIST_RETRIES="${IPLIST_RETRIES:-2}"
IPLIST_STRICT="${IPLIST_STRICT:-0}"
EXTRA_DIRECT_DOMAINS="${EXTRA_DIRECT_DOMAINS:-}"
EXTRA_DIRECT_SUFFIXES="${EXTRA_DIRECT_SUFFIXES:-}"
DOMAINS_CONFIG_DIR="${DOMAINS_CONFIG_DIR:-${SCRIPT_DIR}/config/domains}"
MANUAL_BLOCKED_DOMAINS_FILE="${MANUAL_BLOCKED_DOMAINS_FILE:-${DOMAINS_CONFIG_DIR}/blocked_domains.txt}"
MANUAL_BLOCKED_SUFFIXES_FILE="${MANUAL_BLOCKED_SUFFIXES_FILE:-${DOMAINS_CONFIG_DIR}/blocked_suffixes.txt}"
GENERATED_BLOCKED_DOMAINS_FILE="${GENERATED_BLOCKED_DOMAINS_FILE:-${WORK_DIR}/blocked_domains.generated.txt}"
GENERATED_BLOCKED_SUFFIXES_FILE="${GENERATED_BLOCKED_SUFFIXES_FILE:-${WORK_DIR}/blocked_suffixes.generated.txt}"
HY2_URI="${HY2_URI:-}"

HYSTERIA_SERVER=""
HYSTERIA_PORT=""
HYSTERIA_PASSWORD=""
HYSTERIA_SNI=""
HYSTERIA_OBFS_TYPE=""
HYSTERIA_OBFS_PASSWORD=""

log() {
  echo "[render] $*"
}

warn() {
  echo "[render:warn] $*" >&2
}

die() {
  echo "[render:error] $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  bash render_awg_routing_config.sh
  STATE_ENV_FILE=/opt/hp2-routing/routing.env bash render_awg_routing_config.sh
  bash render_awg_routing_config.sh --env-file /root/vpn/router/.env
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
      --state-file)
        [[ $# -ge 2 ]] || die "--state-file requires a path"
        STATE_ENV_FILE="$2"
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

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

load_state_env() {
  if [[ -f "${STATE_ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_ENV_FILE}"
  fi
}

load_input_env() {
  local env_file="${INPUT_ENV_FILE}"
  if [[ -z "${env_file}" && -f "${DEFAULT_INPUT_ENV_FILE}" ]]; then
    env_file="${DEFAULT_INPUT_ENV_FILE}"
  fi
  if [[ -z "${env_file}" ]]; then
    return
  fi
  [[ -f "${env_file}" ]] || die "Env file not found: ${env_file}"
  [[ -r "${env_file}" ]] || die "Env file is not readable: ${env_file}"
  INPUT_ENV_FILE="${env_file}"
  set -a
  # shellcheck disable=SC1090
  source "${env_file}"
  set +a
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

append_lines_to_csv() {
  local current="$1"
  local input="$2"
  local cleaned
  cleaned="$(printf '%s\n' "${input}" | awk 'NF {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0); if ($0 !~ /^#/) print $0}' | paste -sd, -)"
  if [[ -z "${cleaned}" ]]; then
    printf '%s' "${current}"
  elif [[ -z "${current}" ]]; then
    printf '%s' "${cleaned}"
  else
    printf '%s,%s' "${current}" "${cleaned}"
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
      awg*) iface="${dev}"; break ;;
    esac
  done
  if [[ -z "${iface}" ]]; then
    for dev in /sys/class/net/*; do
      dev="${dev##*/}"
      case "${dev}" in
        wg*) iface="${dev}"; break ;;
      esac
    done
  fi

  if [[ -n "${iface}" ]]; then
    AWG_IFACE="${iface}"
  else
    AWG_IFACE="${DEFAULT_AWG_IFACE}"
    warn "Could not auto-detect AWG/WG interface. Falling back to ${AWG_IFACE}"
  fi
}

fetch_url_lines() {
  local url="$1"
  [[ -n "${url}" ]] || return 0
  curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --connect-timeout "${IPLIST_CONNECT_TIMEOUT}" \
    --max-time "${IPLIST_FETCH_TIMEOUT}" \
    --retry "${IPLIST_RETRIES}" \
    --retry-delay 1 \
    "${url}" | tr -d '\r'
}

merge_remote_domain_lists() {
  local exact_lines wildcard_lines wildcard_suffixes="" exact_count wildcard_count

  if [[ -n "${IPLIST_DOMAINS_URL}" ]]; then
    log "Fetching exact domains from ${IPLIST_DOMAINS_URL}"
    if exact_lines="$(fetch_url_lines "${IPLIST_DOMAINS_URL}")"; then
      exact_count="$(printf '%s\n' "${exact_lines}" | awk 'NF {count++} END {print count+0}')"
      log "Fetched ${exact_count} exact domains"
      VPN_DOMAINS="$(append_lines_to_csv "${VPN_DOMAINS}" "${exact_lines}")"
    elif [[ "${IPLIST_STRICT}" == "1" ]]; then
      die "Failed to fetch exact domains from iplist"
    else
      warn "Failed to fetch exact domains from iplist, continuing with built-in VPN_DOMAINS"
    fi
  fi

  if [[ -n "${IPLIST_WILDCARD_DOMAINS_URL}" ]]; then
    log "Fetching wildcard domains from ${IPLIST_WILDCARD_DOMAINS_URL}"
    if wildcard_lines="$(fetch_url_lines "${IPLIST_WILDCARD_DOMAINS_URL}")"; then
      wildcard_count="$(printf '%s\n' "${wildcard_lines}" | awk 'NF {count++} END {print count+0}')"
      log "Fetched ${wildcard_count} wildcard domains"
      while IFS= read -r line; do
        line="$(trim "${line}")"
        [[ -n "${line}" ]] || continue
        case "${line}" in
          \*.*) line="${line#*.}" ;;
          .*) line="${line#.}" ;;
        esac
        wildcard_suffixes="$(add_csv_item "${wildcard_suffixes}" "${line}")"
      done <<< "${wildcard_lines}"
      VPN_SUFFIXES="$(add_csv_item "${VPN_SUFFIXES}" "${wildcard_suffixes}")"
    elif [[ "${IPLIST_STRICT}" == "1" ]]; then
      die "Failed to fetch wildcard domains from iplist"
    else
      warn "Failed to fetch wildcard domains from iplist, continuing with built-in VPN_SUFFIXES"
    fi
  fi
}

merge_blocked_files() {
  local blocked_lines=""
  local blocked_suffix_lines=""

  for file in "${MANUAL_BLOCKED_DOMAINS_FILE}" "${GENERATED_BLOCKED_DOMAINS_FILE}"; do
    if [[ -f "${file}" ]]; then
      blocked_lines="$(printf '%s\n%s' "${blocked_lines}" "$(cat "${file}")")"
    fi
  done
  VPN_DOMAINS="$(append_lines_to_csv "${VPN_DOMAINS}" "${blocked_lines}")"

  for file in "${MANUAL_BLOCKED_SUFFIXES_FILE}" "${GENERATED_BLOCKED_SUFFIXES_FILE}"; do
    if [[ -f "${file}" ]]; then
      blocked_suffix_lines="$(printf '%s\n%s' "${blocked_suffix_lines}" "$(cat "${file}")")"
    fi
  done
  VPN_SUFFIXES="$(append_lines_to_csv "${VPN_SUFFIXES}" "${blocked_suffix_lines}")"
}

write_dns_filter_config() {
  mkdir -p "${WORK_DIR}" "${CONFIG_DIR}"
  if [[ "${DNS_FILTER_ENABLED}" != "1" ]]; then
    rm -f "${DNS_FILTER_CONFIG_FILE}"
    return 0
  fi

  cat > "${DNS_FILTER_CONFIG_FILE}" <<EOF
no-daemon
bind-interfaces
listen-address=${DNS_FILTER_LISTEN}
port=${DNS_FILTER_PORT}
no-resolv
no-hosts
cache-size=1000
user=root
server=${DNS_SERVER}#${DNS_SERVER_PORT}
filter-rr=${DNS_FILTER_RR_TYPES}
EOF
  chmod 0600 "${DNS_FILTER_CONFIG_FILE}"
}

render_config() {
  local direct_domains=""
  local domain_rule=""
  local suffix_rule=""
  local vpn_domain_rule=""
  local vpn_suffix_rule=""
  local reject_rule=""
  local reject_udp_443_rule=""
  local obfs_block=""
  local debug_socks_inbound=""
  local route_final=""
  local dns_resolver_tag="dns-direct"

  case "${ROUTE_FINAL}" in
    direct|hy2-out)
      route_final="${ROUTE_FINAL}"
      ;;
    *)
      die "Unsupported ROUTE_FINAL: ${ROUTE_FINAL} (expected: direct or hy2-out)"
      ;;
  esac

  case "${DNS_FILTER_ENABLED}" in
    0)
      ;;
    1)
      dns_resolver_tag="dns-local"
      ;;
    *)
      die "Unsupported DNS_FILTER_ENABLED: ${DNS_FILTER_ENABLED} (expected: 0 or 1)"
      ;;
  esac

  direct_domains="$(add_csv_item "${direct_domains}" "${HYSTERIA_SNI}")"
  if ! is_ip_literal "${HYSTERIA_SERVER}"; then
    direct_domains="$(add_csv_item "${direct_domains}" "${HYSTERIA_SERVER}")"
  fi
  direct_domains="$(add_csv_item "${direct_domains}" "${EXTRA_DIRECT_DOMAINS}")"

  if [[ "${REJECT_UDP_443}" == "1" ]]; then
    reject_udp_443_rule=$(cat <<'EOF'
          ,
          {
            "network": "udp",
            "port": 443
          }
EOF
)
  elif [[ "${REJECT_UDP_443}" != "0" ]]; then
    die "Unsupported REJECT_UDP_443: ${REJECT_UDP_443} (expected: 0 or 1)"
  fi

  reject_rule=$(cat <<'EOF'
      {
        "type": "logical",
        "mode": "or",
        "rules": [
          {
            "port": 853
          },
          {
            "protocol": "stun"
          }REJECT_UDP_443_RULE
        ],
        "action": "reject"
      },
EOF
)
  reject_rule="${reject_rule/REJECT_UDP_443_RULE/${reject_udp_443_rule}}"

  if [[ -n "${VPN_DOMAINS//,/}" ]]; then
    vpn_domain_rule=$(cat <<EOF
      {
        "domain": $(csv_to_json_array "${VPN_DOMAINS}"),
        "action": "route",
        "outbound": "hy2-out"
      },
EOF
)
  fi

  if [[ -n "${VPN_SUFFIXES//,/}" ]]; then
    vpn_suffix_rule=$(cat <<EOF
      {
        "domain_suffix": $(csv_to_json_array "${VPN_SUFFIXES}"),
        "action": "route",
        "outbound": "hy2-out"
      },
EOF
)
  fi

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

  if [[ -n "${DEBUG_SOCKS_PORT}" ]]; then
    debug_socks_inbound=$(cat <<EOF
    ,
    {
      "type": "socks",
      "tag": "debug-socks",
      "listen": $(json_quote "${DEBUG_SOCKS_LISTEN}"),
      "listen_port": ${DEBUG_SOCKS_PORT}
    }
EOF
)
  fi

  mkdir -p "${CONFIG_DIR}"
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
      }$(if [[ "${DNS_FILTER_ENABLED}" == "1" ]]; then cat <<EOF2
,
      {
        "type": "udp",
        "tag": "dns-local",
        "server": $(json_quote "${DNS_FILTER_LISTEN}"),
        "server_port": ${DNS_FILTER_PORT}
      }
EOF2
fi)
    ],
    "final": $(json_quote "${dns_resolver_tag}"),
    "strategy": $(json_quote "${DNS_STRATEGY}")
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": $(json_quote "${TUN_IFACE}"),
      "address": [
        $(json_quote "${TUN_ADDRESS}")
      ],
      "mtu": ${TUN_MTU},
      "auto_route": true,
      "iproute2_table_index": ${IPROUTE2_TABLE_INDEX},
      "iproute2_rule_index": ${IPROUTE2_RULE_INDEX},
      "auto_redirect": true,
      "auto_redirect_input_mark": $(json_quote "${AUTO_REDIRECT_INPUT_MARK}"),
      "auto_redirect_output_mark": $(json_quote "${AUTO_REDIRECT_OUTPUT_MARK}"),
      "auto_redirect_reset_mark": $(json_quote "${AUTO_REDIRECT_RESET_MARK}"),
      "auto_redirect_iproute2_fallback_rule_index": ${AUTO_REDIRECT_FALLBACK_RULE_INDEX},
      "strict_route": true,
      "exclude_mptcp": true,
      "stack": "system",
      "include_interface": [
        $(json_quote "${AWG_IFACE}")
      ]
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
      },
      "domain_resolver": {
        "server": $(json_quote "${dns_resolver_tag}"),
        "strategy": $(json_quote "${DNS_STRATEGY}")
      }${obfs_block}
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "default_domain_resolver": {
      "server": $(json_quote "${dns_resolver_tag}"),
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
${reject_rule}${vpn_domain_rule}${vpn_suffix_rule}${domain_rule}${suffix_rule}      {
        "ip_is_private": true,
        "action": "route",
        "outbound": "direct"
      }
    ],
    "final": $(json_quote "${route_final}")
  }
}
EOF
  chmod 0600 "${CONFIG_FILE}"
}

main() {
  parse_args "$@"
  load_state_env
  load_input_env
  HY2_URI="${HY2_URI:-${POSITIONAL_HY2_URI}}"
  [[ -n "${HY2_URI}" ]] || die "HY2_URI is required"
  require_cmd sing-box
  require_cmd curl
  parse_hy2_uri "${HY2_URI}"
  [[ -n "${AWG_IFACE}" ]] || detect_awg_iface
  merge_remote_domain_lists
  merge_blocked_files
  write_dns_filter_config
  render_config
  sing-box check -c "${CONFIG_FILE}"
  log "Rendered ${CONFIG_FILE}"
}

main "$@"
