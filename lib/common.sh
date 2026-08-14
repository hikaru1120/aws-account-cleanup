#!/usr/bin/env bash
# sourced by modules. Set MODULE_NAME first.

RECORD_DIR="${RECORD_DIR:-./verification}"
REGISTRY_FILE="${REGISTRY_FILE:-${RECORD_DIR}/module_validation_registry.json}"
RUN_LOG="${RECORD_DIR}/${MODULE_NAME}_runs.log"

log() {
  local msg="[$(date '+%F %T')] $*"
  echo "${msg}"
  [[ -n "${RUN_LOG:-}" && -f "${RUN_LOG}" ]] && echo "${msg}" >> "${RUN_LOG}"
}

quiet() { "$@" >/dev/null 2>&1 || true; }
aws_r() { local r="$1"; shift; aws --region "$r" "$@"; }
lines() { tr '\t' '\n' | sed '/^$/d'; }

init_records() {
  mkdir -p "${RECORD_DIR}"
  : > "${RUN_LOG}"
}

update_registry() {
  local result="$1"
  command -v jq >/dev/null 2>&1 || return 0
  [[ -f "${REGISTRY_FILE}" ]] || return 0
  local key="${MODULE_NAME}_cleanup_module"
  tmp="$(mktemp)"
  jq --arg now "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" --arg result "${result}" --arg key "${key}" '
    .modules[$key].last_run_at=$now
    | .modules[$key].last_result=$result
    | .modules[$key].status="PENDING_SECONDARY_VERIFICATION"
  ' "${REGISTRY_FILE}" > "${tmp}" && mv "${tmp}" "${REGISTRY_FILE}"
}

each_region() {
  aws ec2 describe-regions --query 'Regions[].RegionName' --output text | lines
}
