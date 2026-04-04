#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_INPUT_ENV_FILE="${SCRIPT_DIR}/.env"

INPUT_ENV_FILE="${INPUT_ENV_FILE:-}"

STACK_WORK_DIR="${STACK_WORK_DIR:-/opt/hp2-awg-stack}"
STACK_LOG_DIR="${STACK_LOG_DIR:-${STACK_WORK_DIR}/logs}"
STACK_INSTALL_LOG="${STACK_INSTALL_LOG:-${STACK_LOG_DIR}/install.log}"
STACK_STATE_ENV_FILE="${STACK_STATE_ENV_FILE:-${STACK_WORK_DIR}/stack.env}"
WIRESOCK_REPO_URL="${WIRESOCK_REPO_URL:-https://github.com/wiresock/amneziawg-install.git}"
WIRESOCK_REPO_DIR="${WIRESOCK_REPO_DIR:-${STACK_WORK_DIR}/amneziawg-install}"
WIRESOCK_REF="${WIRESOCK_REF:-main}"

INSTALL_DEPENDENCIES="${INSTALL_DEPENDENCIES:-1}"
INSTALL_WEB_PANEL="${INSTALL_WEB_PANEL:-1}"
INSTALL_WEB_RUST="${INSTALL_WEB_RUST:-0}"
SAVE_STATE_ENV="${SAVE_STATE_ENV:-1}"

AUTO_INSTALL="${AUTO_INSTALL:-y}"
SERVER_PUB_IP="${SERVER_PUB_IP:-}"
SERVER_PUB_NIC="${SERVER_PUB_NIC:-}"
SERVER_AWG_NIC="${SERVER_AWG_NIC:-awg0}"
SERVER_AWG_IPV4="${SERVER_AWG_IPV4:-}"
SERVER_AWG_IPV6="${SERVER_AWG_IPV6:-}"
SERVER_PORT="${SERVER_PORT:-}"
CLIENT_DNS_1="${CLIENT_DNS_1:-1.1.1.1}"
CLIENT_DNS_2="${CLIENT_DNS_2:-1.0.0.1}"
ALLOWED_IPS="${ALLOWED_IPS:-0.0.0.0/0,::/0}"

AWG_WEB_LISTEN="${AWG_WEB_LISTEN:-127.0.0.1:8080}"
AWG_WEB_PUBLIC_BASE_URL="${AWG_WEB_PUBLIC_BASE_URL:-}"

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
  sudo bash install_awg_stack.sh
  sudo bash install_awg_stack.sh --env-file /root/hp2-awg-stack.env

This installer bootstraps a clean server using wiresock/amneziawg-install:
  1. Clones/updates the repository.
  2. Runs amneziawg-install.sh in interactive or AUTO_INSTALL mode.
  3. Installs the optional web panel via amneziawg-web.sh install.
  4. Saves a small state file and writes an install log.

Optional variables:
  INPUT_ENV_FILE          Env file to source before applying defaults.
  STACK_WORK_DIR          Working directory for checkout/logs/state.
  WIRESOCK_REPO_URL       Repository URL.
  WIRESOCK_REF            Branch or tag to checkout.
  INSTALL_DEPENDENCIES    Set to 1 to install git/curl/ca-certificates.
  INSTALL_WEB_PANEL       Set to 0 to skip the panel.
  INSTALL_WEB_RUST        Set to 1 to pass --install-rust to amneziawg-web.sh.
  SAVE_STATE_ENV          Set to 1 to persist effective variables.

  AUTO_INSTALL            Passed to amneziawg-install.sh (default: y).
  SERVER_PUB_IP           Optional explicit public IP.
  SERVER_PUB_NIC          Optional explicit public NIC.
  SERVER_AWG_NIC          AWG interface name (default: awg0).
  SERVER_AWG_IPV4         Optional VPN IPv4 address.
  SERVER_AWG_IPV6         Optional VPN IPv6 address.
  SERVER_PORT             Optional server UDP port.
  CLIENT_DNS_1            Client DNS #1 (default: 1.1.1.1).
  CLIENT_DNS_2            Client DNS #2 (default: 1.0.0.1).
  ALLOWED_IPS             Client allowed IPs (default: 0.0.0.0/0,::/0).

  AWG_WEB_LISTEN          Panel listen address (default: 127.0.0.1:8080).
  AWG_WEB_PUBLIC_BASE_URL Optional panel public base URL.
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
        die "Unexpected argument: $1"
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

  set -a
  # shellcheck disable=SC1090
  source "${env_file}"
  set +a
}

setup_logging() {
  mkdir -p "${STACK_WORK_DIR}" "${STACK_LOG_DIR}"
  chmod 0700 "${STACK_WORK_DIR}" "${STACK_LOG_DIR}"
  exec > >(tee -a "${STACK_INSTALL_LOG}") 2>&1
  log "Install log: ${STACK_INSTALL_LOG}"
}

install_dependencies() {
  [[ "${INSTALL_DEPENDENCIES}" == "1" ]] || return 0
  require_cmd apt-get
  log "Installing bootstrap dependencies"
  apt-get update
  apt-get install -y ca-certificates curl git
}

checkout_repo() {
  if [[ -d "${WIRESOCK_REPO_DIR}/.git" ]]; then
    log "Updating ${WIRESOCK_REPO_DIR}"
    if ! git -C "${WIRESOCK_REPO_DIR}" rev-parse --git-dir >/dev/null 2>&1 ||
       ! git -C "${WIRESOCK_REPO_DIR}" fetch --tags origin; then
      warn "Existing checkout is broken, recreating ${WIRESOCK_REPO_DIR}"
      rm -rf "${WIRESOCK_REPO_DIR}"
    fi
  fi

  if [[ ! -d "${WIRESOCK_REPO_DIR}/.git" ]]; then
    log "Cloning ${WIRESOCK_REPO_URL} -> ${WIRESOCK_REPO_DIR}"
    git clone "${WIRESOCK_REPO_URL}" "${WIRESOCK_REPO_DIR}"
  fi

  log "Checking out ${WIRESOCK_REF}"
  git -C "${WIRESOCK_REPO_DIR}" checkout "${WIRESOCK_REF}"
  if ! git -C "${WIRESOCK_REPO_DIR}" pull --ff-only origin "${WIRESOCK_REF}"; then
    warn "Checkout update failed, recreating ${WIRESOCK_REPO_DIR}"
    rm -rf "${WIRESOCK_REPO_DIR}"
    git clone "${WIRESOCK_REPO_URL}" "${WIRESOCK_REPO_DIR}"
    git -C "${WIRESOCK_REPO_DIR}" checkout "${WIRESOCK_REF}"
  fi
}

run_awg_install() {
  local -a env_cmd

  log "Running amneziawg-install.sh"
  env_cmd=(
    env
    "AUTO_INSTALL=${AUTO_INSTALL}"
    "CLIENT_DNS_1=${CLIENT_DNS_1}"
    "CLIENT_DNS_2=${CLIENT_DNS_2}"
    "ALLOWED_IPS=${ALLOWED_IPS}"
    "SERVER_AWG_NIC=${SERVER_AWG_NIC}"
  )

  [[ -n "${SERVER_PUB_IP}" ]] && env_cmd+=("SERVER_PUB_IP=${SERVER_PUB_IP}")
  [[ -n "${SERVER_PUB_NIC}" ]] && env_cmd+=("SERVER_PUB_NIC=${SERVER_PUB_NIC}")
  [[ -n "${SERVER_AWG_IPV4}" ]] && env_cmd+=("SERVER_AWG_IPV4=${SERVER_AWG_IPV4}")
  [[ -n "${SERVER_AWG_IPV6}" ]] && env_cmd+=("SERVER_AWG_IPV6=${SERVER_AWG_IPV6}")
  [[ -n "${SERVER_PORT}" ]] && env_cmd+=("SERVER_PORT=${SERVER_PORT}")

  (
    cd "${WIRESOCK_REPO_DIR}"
    "${env_cmd[@]}" bash ./amneziawg-install.sh
  )
}

run_web_install() {
  local -a web_args

  [[ "${INSTALL_WEB_PANEL}" == "1" ]] || return 0

  log "Running amneziawg-web.sh install"
  web_args=(install)
  [[ "${INSTALL_WEB_RUST}" == "1" ]] && web_args+=(--install-rust)

  (
    cd "${WIRESOCK_REPO_DIR}"
    env \
      "AWG_WEB_LISTEN=${AWG_WEB_LISTEN}" \
      "AWG_WEB_PUBLIC_BASE_URL=${AWG_WEB_PUBLIC_BASE_URL}" \
      bash ./amneziawg-web.sh "${web_args[@]}"
  )
}

write_state_env_file() {
  [[ "${SAVE_STATE_ENV}" == "1" ]] || return 0

  cat > "${STACK_STATE_ENV_FILE}" <<EOF
STACK_WORK_DIR=$(printf '%q' "${STACK_WORK_DIR}")
STACK_LOG_DIR=$(printf '%q' "${STACK_LOG_DIR}")
STACK_INSTALL_LOG=$(printf '%q' "${STACK_INSTALL_LOG}")
WIRESOCK_REPO_URL=$(printf '%q' "${WIRESOCK_REPO_URL}")
WIRESOCK_REPO_DIR=$(printf '%q' "${WIRESOCK_REPO_DIR}")
WIRESOCK_REF=$(printf '%q' "${WIRESOCK_REF}")
INSTALL_DEPENDENCIES=$(printf '%q' "${INSTALL_DEPENDENCIES}")
INSTALL_WEB_PANEL=$(printf '%q' "${INSTALL_WEB_PANEL}")
INSTALL_WEB_RUST=$(printf '%q' "${INSTALL_WEB_RUST}")
AUTO_INSTALL=$(printf '%q' "${AUTO_INSTALL}")
SERVER_PUB_IP=$(printf '%q' "${SERVER_PUB_IP}")
SERVER_PUB_NIC=$(printf '%q' "${SERVER_PUB_NIC}")
SERVER_AWG_NIC=$(printf '%q' "${SERVER_AWG_NIC}")
SERVER_AWG_IPV4=$(printf '%q' "${SERVER_AWG_IPV4}")
SERVER_AWG_IPV6=$(printf '%q' "${SERVER_AWG_IPV6}")
SERVER_PORT=$(printf '%q' "${SERVER_PORT}")
CLIENT_DNS_1=$(printf '%q' "${CLIENT_DNS_1}")
CLIENT_DNS_2=$(printf '%q' "${CLIENT_DNS_2}")
ALLOWED_IPS=$(printf '%q' "${ALLOWED_IPS}")
AWG_WEB_LISTEN=$(printf '%q' "${AWG_WEB_LISTEN}")
AWG_WEB_PUBLIC_BASE_URL=$(printf '%q' "${AWG_WEB_PUBLIC_BASE_URL}")
EOF
  chmod 0600 "${STACK_STATE_ENV_FILE}"
}

print_summary() {
  cat <<EOF

AmneziaWG stack install finished.

Checkout:
  ${WIRESOCK_REPO_DIR}

Install log:
  ${STACK_INSTALL_LOG}

State file:
  ${STACK_STATE_ENV_FILE}

Useful commands:
  bash ${SCRIPT_DIR}/status_awg_stack.sh
  journalctl -u awg-quick@${SERVER_AWG_NIC}.service -f
  cd ${WIRESOCK_REPO_DIR} && ./amneziawg-web.sh status
  ss -ltnp | grep 8080 || true

Notes:
  - The panel install was ${INSTALL_WEB_PANEL}.
  - AWG panel listen address: ${AWG_WEB_LISTEN}
  - The wiresock checkout is kept on disk for upgrades and client management.
EOF
}

main() {
  parse_args "$@"
  require_root
  load_env_file
  setup_logging
  install_dependencies
  require_cmd git
  checkout_repo
  run_awg_install
  run_web_install
  write_state_env_file
  print_summary
}

main "$@"
