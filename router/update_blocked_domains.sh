#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_INPUT_ENV_FILE="${SCRIPT_DIR}/.env"

WORK_DIR="${WORK_DIR:-/opt/hp2-routing}"
STATE_ENV_FILE="${STATE_ENV_FILE:-${WORK_DIR}/routing.env}"
INPUT_ENV_FILE="${INPUT_ENV_FILE:-}"
DOMAINS_CONFIG_DIR="${DOMAINS_CONFIG_DIR:-${SCRIPT_DIR}/config/domains}"
BLOCKED_SERVICES_FILE="${BLOCKED_SERVICES_FILE:-${DOMAINS_CONFIG_DIR}/blocked_services.txt}"
IPLIST_GROUPS_FILE="${IPLIST_GROUPS_FILE:-${DOMAINS_CONFIG_DIR}/iplist_groups.tsv}"
GENERATED_BLOCKED_DOMAINS_FILE="${GENERATED_BLOCKED_DOMAINS_FILE:-${WORK_DIR}/blocked_domains.generated.txt}"
GENERATED_BLOCKED_SUFFIXES_FILE="${GENERATED_BLOCKED_SUFFIXES_FILE:-${WORK_DIR}/blocked_suffixes.generated.txt}"
BLOCKED_SERVICES_STATE_FILE="${BLOCKED_SERVICES_STATE_FILE:-${WORK_DIR}/blocked_services.state.tsv}"
RENDER_SCRIPT_FILE="${RENDER_SCRIPT_FILE:-${WORK_DIR}/bin/render_awg_routing_config.sh}"
SERVICE_NAME="${SERVICE_NAME:-hp2-routing}"
IPLIST_BASE_URL="${IPLIST_BASE_URL:-https://iplist.opencck.org/}"
IPLIST_CONNECT_TIMEOUT="${IPLIST_CONNECT_TIMEOUT:-5}"
IPLIST_FETCH_TIMEOUT="${IPLIST_FETCH_TIMEOUT:-20}"
IPLIST_RETRIES="${IPLIST_RETRIES:-2}"
IPLIST_STRICT="${IPLIST_STRICT:-0}"

log() {
  echo "[blocklist] $*"
}

warn() {
  echo "[blocklist:warn] $*" >&2
}

die() {
  echo "[blocklist:error] $*" >&2
  exit 1
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

fetch_url_lines() {
  local url="$1"
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

resolve_source() {
  local service="$1"
  local key mode value
  if [[ -f "${IPLIST_GROUPS_FILE}" ]]; then
    while IFS=$'\t' read -r key mode value; do
      key="$(trim "${key}")"
      mode="$(trim "${mode}")"
      value="$(trim "${value}")"
      [[ -n "${key}" ]] || continue
      [[ "${key}" == \#* ]] && continue
      if [[ "${key}" == "${service}" ]]; then
        printf '%s\t%s' "${mode:-group}" "${value:-${service}}"
        return 0
      fi
    done < "${IPLIST_GROUPS_FILE}"
  fi
  printf 'group\t%s' "${service}"
}

extract_site_domains() {
  python3 - <<'PY'
import json
import sys

try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(1)

if not isinstance(payload, dict):
    sys.exit(0)

for value in payload.values():
    if not isinstance(value, dict):
        continue
    domains = value.get("domains", [])
    if isinstance(domains, list):
        for domain in domains:
            if isinstance(domain, str):
                domain = domain.strip()
                if domain:
                    print(domain)
    break
PY
}

main() {
  local line service source_mode source_value
  local exact_tmp suffix_tmp state_tmp
  local exact_url suffix_url site_url exact_lines suffix_lines site_json
  local changed=0

  load_state_env
  load_input_env

  [[ -f "${BLOCKED_SERVICES_FILE}" ]] || die "Blocked services file not found: ${BLOCKED_SERVICES_FILE}"
  [[ -x "${RENDER_SCRIPT_FILE}" ]] || die "Render script not found or not executable: ${RENDER_SCRIPT_FILE}"

  mkdir -p "${WORK_DIR}"
  exact_tmp="$(mktemp)"
  suffix_tmp="$(mktemp)"
  state_tmp="$(mktemp)"

  while IFS= read -r line || [[ -n "${line}" ]]; do
    service="$(trim "${line}")"
    [[ -n "${service}" ]] || continue
    [[ "${service}" == \#* ]] && continue

    IFS=$'\t' read -r source_mode source_value <<< "$(resolve_source "${service}")"
    [[ -n "${source_mode}" ]] || die "Could not resolve source mode for service: ${service}"
    [[ -n "${source_value}" ]] || die "Could not resolve source value for service: ${service}"

    case "${source_mode}" in
      group)
        exact_url="${IPLIST_BASE_URL}?format=text&data=domains&group=${source_value}"
        suffix_url="${IPLIST_BASE_URL}?format=text&data=domains&group=${source_value}&wildcard=1"

        log "Fetching exact domains for ${service} (group=${source_value})"
        if exact_lines="$(fetch_url_lines "${exact_url}")"; then
          printf '%s\n' "${exact_lines}" | awk 'NF {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0); if (length($0)) print $0}' >> "${exact_tmp}"
        elif [[ "${IPLIST_STRICT}" == "1" ]]; then
          die "Failed to fetch exact domains for service ${service} (group=${source_value})"
        else
          warn "Failed to fetch exact domains for ${service}, continuing"
        fi

        log "Fetching wildcard domains for ${service} (group=${source_value})"
        if suffix_lines="$(fetch_url_lines "${suffix_url}")"; then
          while IFS= read -r line; do
            line="$(trim "${line}")"
            [[ -n "${line}" ]] || continue
            case "${line}" in
              \*.*) line="${line#*.}" ;;
              .*) line="${line#.}" ;;
            esac
            printf '%s\n' "${line}" >> "${suffix_tmp}"
          done <<< "${suffix_lines}"
        elif [[ "${IPLIST_STRICT}" == "1" ]]; then
          die "Failed to fetch wildcard domains for service ${service} (group=${source_value})"
        else
          warn "Failed to fetch wildcard domains for ${service}, continuing"
        fi
        ;;
      site)
        site_url="${IPLIST_BASE_URL}?format=json&site=${source_value}"

        log "Fetching exact domains for ${service} (site=${source_value})"
        if site_json="$(fetch_url_lines "${site_url}")"; then
          if ! printf '%s\n' "${site_json}" | extract_site_domains | awk 'NF {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0); if (length($0)) print $0}' >> "${exact_tmp}"; then
            if [[ "${IPLIST_STRICT}" == "1" ]]; then
              die "Failed to parse exact domains for service ${service} (site=${source_value})"
            else
              warn "Failed to parse exact domains for ${service}, continuing"
            fi
          fi
        elif [[ "${IPLIST_STRICT}" == "1" ]]; then
          die "Failed to fetch exact domains for service ${service} (site=${source_value})"
        else
          warn "Failed to fetch exact domains for ${service}, continuing"
        fi
        ;;
      *)
        die "Unsupported source mode ${source_mode} for service ${service}"
        ;;
    esac

    printf '%s\t%s\t%s\n' "${service}" "${source_mode}" "${source_value}" >> "${state_tmp}"
  done < "${BLOCKED_SERVICES_FILE}"

  sort -u "${exact_tmp}" -o "${exact_tmp}"
  sort -u "${suffix_tmp}" -o "${suffix_tmp}"
  sort -u "${state_tmp}" -o "${state_tmp}"

  if [[ ! -f "${GENERATED_BLOCKED_DOMAINS_FILE}" ]] || ! cmp -s "${exact_tmp}" "${GENERATED_BLOCKED_DOMAINS_FILE}"; then
    mv "${exact_tmp}" "${GENERATED_BLOCKED_DOMAINS_FILE}"
    changed=1
  else
    rm -f "${exact_tmp}"
  fi

  if [[ ! -f "${GENERATED_BLOCKED_SUFFIXES_FILE}" ]] || ! cmp -s "${suffix_tmp}" "${GENERATED_BLOCKED_SUFFIXES_FILE}"; then
    mv "${suffix_tmp}" "${GENERATED_BLOCKED_SUFFIXES_FILE}"
    changed=1
  else
    rm -f "${suffix_tmp}"
  fi

  if [[ ! -f "${BLOCKED_SERVICES_STATE_FILE}" ]] || ! cmp -s "${state_tmp}" "${BLOCKED_SERVICES_STATE_FILE}"; then
    mv "${state_tmp}" "${BLOCKED_SERVICES_STATE_FILE}"
  else
    rm -f "${state_tmp}"
  fi

  if [[ "${changed}" == "1" ]]; then
    log "Generated blocklists changed, re-rendering routing config"
    INPUT_ENV_FILE="${INPUT_ENV_FILE}" STATE_ENV_FILE="${STATE_ENV_FILE}" "${RENDER_SCRIPT_FILE}"
    systemctl restart "${SERVICE_NAME%.service}.service"
  else
    log "Generated blocklists unchanged"
  fi
}

main "$@"
