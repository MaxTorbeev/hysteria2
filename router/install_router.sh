#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_INPUT_ENV_FILE="${SCRIPT_DIR}/.env"

INPUT_ENV_FILE="${INPUT_ENV_FILE:-}"
POSITIONAL_HY2_URI=""

WORK_DIR=""
CONFIG_DIR=""
CONFIG_FILE=""
STATE_ENV_FILE=""

IMAGE_NAME=""
CONTAINER_NAME=""
AMNEZIA_CONTAINER=""
AWG_IFACE=""

TPROXY_PORT=""
ROUTER_TABLE=""
ROUTER_MARK=""
NFT_TABLE=""
WAIT_TIMEOUT=""
LOG_LEVEL=""

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
  HY2_URI              Hysteria2 URI. Optional if present in env file.
  INPUT_ENV_FILE       Env file to source before applying defaults.
  AMNEZIA_CONTAINER   Docker container with AmneziaWG (auto-detected if empty)
  CONTAINER_NAME      Router sidecar container name (default: hp2-router)
  IMAGE_NAME          Docker image tag (default: hp2-router:latest)
  WORK_DIR            Where config/env files are stored (default: /opt/hp2-router)
  AWG_IFACE           WireGuard interface inside the Amnezia container (auto-detected if empty)
  DIRECT_SUFFIXES     Domain suffixes routed directly, comma-separated (default: ru,xn--p1ai)
  EXTRA_DIRECT_DOMAINS   Exact domains routed directly, comma-separated
  EXTRA_DIRECT_SUFFIXES  Extra domain suffixes routed directly, comma-separated
  SAVE_STATE_ENV      Set to 1 to save effective settings to WORK_DIR/router.env
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

apply_defaults() {
  WORK_DIR="${WORK_DIR:-/opt/hp2-router}"
  CONFIG_DIR="${WORK_DIR}/config"
  CONFIG_FILE="${CONFIG_DIR}/config.json"
  STATE_ENV_FILE="${STATE_ENV_FILE:-${WORK_DIR}/router.env}"

  IMAGE_NAME="${IMAGE_NAME:-hp2-router:latest}"
  CONTAINER_NAME="${CONTAINER_NAME:-hp2-router}"
  AMNEZIA_CONTAINER="${AMNEZIA_CONTAINER:-}"
  AWG_IFACE="${AWG_IFACE:-}"

  TPROXY_PORT="${TPROXY_PORT:-60080}"
  ROUTER_TABLE="${ROUTER_TABLE:-100}"
  ROUTER_MARK="${ROUTER_MARK:-0x1}"
  NFT_TABLE="${NFT_TABLE:-hp2router}"
  WAIT_TIMEOUT="${WAIT_TIMEOUT:-30}"
  LOG_LEVEL="${LOG_LEVEL:-info}"

  DIRECT_SUFFIXES="${DIRECT_SUFFIXES:-ru,xn--p1ai}"
  EXTRA_DIRECT_DOMAINS="${EXTRA_DIRECT_DOMAINS:-}"
  EXTRA_DIRECT_SUFFIXES="${EXTRA_DIRECT_SUFFIXES:-}"
  SAVE_STATE_ENV="${SAVE_STATE_ENV:-0}"
  HY2_URI="${HY2_URI:-${POSITIONAL_HY2_URI}}"
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

container_has_vpn_iface() {
  local container="$1"
  docker exec "${container}" sh -lc '
    for dev in /sys/class/net/*; do
      dev="${dev##*/}"
      case "${dev}" in
        awg*|wg*)
          exit 0
          ;;
      esac
    done
    exit 1
  ' >/dev/null 2>&1
}

detect_amnezia_container() {
  local name image lower_info
  local -a candidates=()
  local -a preferred=()

  while IFS=$'\t' read -r name image; do
    [[ -n "${name}" ]] || continue
    if container_has_vpn_iface "${name}"; then
      candidates+=("${name}")
      lower_info="${name,,} ${image,,}"
      if [[ "${lower_info}" =~ amnezia|awg|wireguard ]]; then
        preferred+=("${name}")
      fi
    fi
  done < <(docker ps --format '{{.Names}}	{{.Image}}')

  if (( ${#preferred[@]} == 1 )); then
    AMNEZIA_CONTAINER="${preferred[0]}"
    return 0
  fi

  if (( ${#candidates[@]} == 1 )); then
    AMNEZIA_CONTAINER="${candidates[0]}"
    return 0
  fi

  if (( ${#preferred[@]} > 1 )); then
    die "Multiple Amnezia-like containers detected: ${preferred[*]}. Set AMNEZIA_CONTAINER explicitly."
  fi

  if (( ${#candidates[@]} > 1 )); then
    die "Multiple containers with awg/wg interfaces detected: ${candidates[*]}. Set AMNEZIA_CONTAINER explicitly."
  fi

  die "Could not auto-detect an AmneziaWG container. Set AMNEZIA_CONTAINER explicitly."
}

resolve_amnezia_container() {
  if [[ -z "${AMNEZIA_CONTAINER}" ]]; then
    detect_amnezia_container
    log "Detected Amnezia container: ${AMNEZIA_CONTAINER}"
  fi

  docker inspect "${AMNEZIA_CONTAINER}" >/dev/null 2>&1 || die "Container not found: ${AMNEZIA_CONTAINER}"
  [[ "$(docker inspect -f '{{.State.Running}}' "${AMNEZIA_CONTAINER}")" == "true" ]] || die "Container is not running: ${AMNEZIA_CONTAINER}"
}

detect_awg_iface() {
  local iface
  iface="$(docker exec "${AMNEZIA_CONTAINER}" sh -lc '
    for dev in /sys/class/net/*; do
      dev="${dev##*/}"
      case "${dev}" in
        awg*)
          echo "${dev}"
          exit 0
          ;;
      esac
    done
    for dev in /sys/class/net/*; do
      dev="${dev##*/}"
      case "${dev}" in
        wg*)
          echo "${dev}"
          exit 0
          ;;
      esac
    done
    exit 1
  ' 2>/dev/null || true)"

  [[ -n "${iface}" ]] || die "Could not auto-detect awg/wg interface inside ${AMNEZIA_CONTAINER}. Set AWG_IFACE explicitly."
  AWG_IFACE="${iface}"
}

resolve_awg_iface() {
  if [[ -z "${AWG_IFACE}" ]]; then
    detect_awg_iface
    log "Detected WireGuard interface: ${AWG_IFACE}"
    return 0
  fi

  docker exec "${AMNEZIA_CONTAINER}" sh -lc '
    target="$1"
    for dev in /sys/class/net/*; do
      dev="${dev##*/}"
      if [ "${dev}" = "${target}" ]; then
        exit 0
      fi
    done
    exit 1
  ' sh "${AWG_IFACE}" >/dev/null 2>&1 || die "Interface ${AWG_IFACE} not found inside ${AMNEZIA_CONTAINER}"
}

ensure_amnezia_container() {
  resolve_amnezia_container
  resolve_awg_iface
}

render_config() {
  local direct_domains=""
  local domain_rule=""
  local suffix_rule=""
  local obfs_block=""
  local domain_resolver_block=""

  direct_domains="$(add_csv_item "${direct_domains}" "${HYSTERIA_SNI}")"
  direct_domains="$(add_csv_item "${direct_domains}" "${HYSTERIA_SERVER}")"
  direct_domains="$(add_csv_item "${direct_domains}" "${EXTRA_DIRECT_DOMAINS}")"

  if [[ -n "${direct_domains//,/}" ]]; then
    domain_rule=$(cat <<EOF
      {
        "inbound": ["tproxy-in"],
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
        "inbound": ["tproxy-in"],
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
        "server": "local-dns",
        "strategy": "prefer_ipv4"
      }
EOF
)

  mkdir -p "${CONFIG_DIR}"
  chmod 0700 "${WORK_DIR}" "${CONFIG_DIR}"

  cat > "${CONFIG_FILE}" <<EOF
{
  "log": {
    "level": $(json_quote "${LOG_LEVEL}"),
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "type": "local",
        "tag": "local-dns"
      }
    ],
    "final": "local-dns",
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {
      "type": "tproxy",
      "tag": "tproxy-in",
      "listen": "0.0.0.0",
      "listen_port": ${TPROXY_PORT}
    }
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
      "server": "local-dns",
      "strategy": "prefer_ipv4"
    },
    "rules": [
      {
        "inbound": ["tproxy-in"],
        "action": "sniff",
        "timeout": "1s"
      },
      {
        "inbound": ["tproxy-in"],
        "type": "logical",
        "mode": "or",
        "rules": [
          {
            "protocol": "dns"
          },
          {
            "port": 53
          }
        ],
        "action": "hijack-dns"
      },
${domain_rule}${suffix_rule}      {
        "inbound": ["tproxy-in"],
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

write_env_file() {
  cat > "${STATE_ENV_FILE}" <<EOF
HY2_URI=$(printf '%q' "${HY2_URI}")
AMNEZIA_CONTAINER=$(printf '%q' "${AMNEZIA_CONTAINER}")
CONTAINER_NAME=$(printf '%q' "${CONTAINER_NAME}")
IMAGE_NAME=$(printf '%q' "${IMAGE_NAME}")
WORK_DIR=$(printf '%q' "${WORK_DIR}")
AWG_IFACE=$(printf '%q' "${AWG_IFACE}")
TPROXY_PORT=$(printf '%q' "${TPROXY_PORT}")
ROUTER_TABLE=$(printf '%q' "${ROUTER_TABLE}")
ROUTER_MARK=$(printf '%q' "${ROUTER_MARK}")
NFT_TABLE=$(printf '%q' "${NFT_TABLE}")
WAIT_TIMEOUT=$(printf '%q' "${WAIT_TIMEOUT}")
DIRECT_SUFFIXES=$(printf '%q' "${DIRECT_SUFFIXES}")
EXTRA_DIRECT_DOMAINS=$(printf '%q' "${EXTRA_DIRECT_DOMAINS}")
EXTRA_DIRECT_SUFFIXES=$(printf '%q' "${EXTRA_DIRECT_SUFFIXES}")
EOF
  chmod 0600 "${STATE_ENV_FILE}"
}

build_image() {
  log "Building image ${IMAGE_NAME}"
  docker build -t "${IMAGE_NAME}" "${SCRIPT_DIR}"
}

prepare_namespace_sysctls() {
  local pid

  require_cmd nsenter
  require_cmd sysctl

  pid="$(docker inspect -f '{{.State.Pid}}' "${AMNEZIA_CONTAINER}")"
  [[ "${pid}" =~ ^[0-9]+$ ]] || die "Could not determine PID for ${AMNEZIA_CONTAINER}"
  (( pid > 1 )) || die "Unexpected PID for ${AMNEZIA_CONTAINER}: ${pid}"

  log "Preparing network namespace sysctls for ${AMNEZIA_CONTAINER} (pid ${pid})"

  nsenter -t "${pid}" -n sysctl -w net.ipv4.ip_forward=1 >/dev/null
  nsenter -t "${pid}" -n sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
  nsenter -t "${pid}" -n sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null
  nsenter -t "${pid}" -n sysctl -w net.ipv4.conf.all.src_valid_mark=1 >/dev/null
  nsenter -t "${pid}" -n sysctl -w "net.ipv4.conf.${AWG_IFACE}.rp_filter=0" >/dev/null
}

remove_existing_container() {
  if docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    log "Removing existing container ${CONTAINER_NAME}"
    docker rm -f "${CONTAINER_NAME}" >/dev/null
  fi
}

run_router() {
  log "Starting router sidecar ${CONTAINER_NAME}"
  docker run -d \
    --name "${CONTAINER_NAME}" \
    --restart unless-stopped \
    --network "container:${AMNEZIA_CONTAINER}" \
    --cap-add NET_ADMIN \
    --cap-add NET_RAW \
    -e AWG_IFACE="${AWG_IFACE}" \
    -e CONFIG_FILE=/etc/sing-box/config.json \
    -e TPROXY_PORT="${TPROXY_PORT}" \
    -e ROUTER_TABLE="${ROUTER_TABLE}" \
    -e ROUTER_MARK="${ROUTER_MARK}" \
    -e NFT_TABLE="${NFT_TABLE}" \
    -e WAIT_TIMEOUT="${WAIT_TIMEOUT}" \
    -v "${CONFIG_FILE}:/etc/sing-box/config.json:ro" \
    "${IMAGE_NAME}" >/dev/null
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

Router sidecar is running.

Container:
  ${CONTAINER_NAME}

Config:
  ${CONFIG_FILE}

${state_env_note}Main commands:
  docker logs -f ${CONTAINER_NAME}
  docker exec ${CONTAINER_NAME} sing-box check -c /etc/sing-box/config.json
  bash ${SCRIPT_DIR}/status_router.sh

Notes:
  - Direct routing is currently based on domain suffixes: ${DIRECT_SUFFIXES}
  - Everything else falls back to Hysteria 2.
  - If Amnezia recreates ${AMNEZIA_CONTAINER}, rerun this installer.
EOF
}

main() {
  parse_args "$@"
  require_root
  require_cmd docker
  load_env_file
  apply_defaults

  if [[ -z "${HY2_URI}" ]]; then
    usage
    exit 1
  fi

  parse_hy2_uri "${HY2_URI}"
  ensure_amnezia_container
  render_config
  if [[ "${SAVE_STATE_ENV}" == "1" ]]; then
    write_env_file
  fi
  build_image
  prepare_namespace_sysctls
  remove_existing_container
  run_router
  print_summary
}

main "$@"
