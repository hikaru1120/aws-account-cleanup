#!/usr/bin/env bash
set -euo pipefail

# Route53 cleanup module
# Validation status: PENDING_SECONDARY_VERIFICATION

MAX_FEATURE_WAIT=24
MAX_DELETE_RETRY=10
RECORD_DIR="${RECORD_DIR:-./verification}"
REGISTRY_FILE="${REGISTRY_FILE:-${RECORD_DIR}/module_validation_registry.json}"
RUN_LOG="${RECORD_DIR}/route53_cleanup_runs.log"
FAILED_ZONES=()

log() { echo "[$(date '+%F %T')] $*"; }

init_registry() {
  mkdir -p "${RECORD_DIR}"
  if [[ ! -f "${REGISTRY_FILE}" ]]; then
    cat > "${REGISTRY_FILE}" <<'JSON'
{
  "modules": {
    "route53_cleanup_module": {
      "status": "PENDING_SECONDARY_VERIFICATION",
      "last_run_at": null,
      "last_result": null,
      "verified_by_user": false,
      "notes": "Needs additional real-account validation."
    }
  }
}
JSON
  fi
}

update_registry() {
  local result="$1"
  local now
  now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  if command -v jq >/dev/null 2>&1; then
    tmp="$(mktemp)"
    jq --arg now "${now}" --arg result "${result}" \
      '.modules.route53_cleanup_module.last_run_at=$now
       | .modules.route53_cleanup_module.last_result=$result' \
      "${REGISTRY_FILE}" > "${tmp}" && mv "${tmp}" "${REGISTRY_FILE}"
  fi
}

delete_records_in_zone() {
  local zid="$1"
  local zname="$2"

  local records_json total del_changes del_count
  records_json="$(aws route53 list-resource-record-sets --hosted-zone-id "$zid" --output json)"
  total="$(echo "$records_json" | jq '.ResourceRecordSets | length')"
  del_changes="$(echo "$records_json" | jq --arg apex "$zname" '
    .ResourceRecordSets
    | map(select(( .Name == $apex and (.Type == "NS" or .Type == "SOA") ) | not))
    | map({Action:"DELETE", ResourceRecordSet:.})
  ')"
  del_count="$(echo "$del_changes" | jq 'length')"

  log "   total records: $total"
  log "   records to delete: $del_count"
  [[ "$del_count" -eq 0 ]] && return 0

  echo "$del_changes" | jq -c '[range(0; length; 100) as $i | {Changes: .[$i:($i+100)]}][]' | while read -r batch; do
    [[ -z "${batch}" ]] && continue
    aws route53 change-resource-record-sets \
      --hosted-zone-id "$zid" \
      --change-batch "$batch" >/dev/null
  done
}

disable_blocking_features() {
  local zid="$1"
  log "   disabling DNSSEC (if enabled)..."
  aws route53 disable-hosted-zone-dnssec --hosted-zone-id "$zid" >/dev/null 2>&1 || true

  log "   disabling Accelerated Recovery (if enabled)..."
  aws route53 update-hosted-zone-features \
    --hosted-zone-id "$zid" \
    --no-enable-accelerated-recovery >/dev/null 2>&1 || true

  local stable=0
  for ((i=1; i<=MAX_FEATURE_WAIT; i++)); do
    state="$(aws route53 get-hosted-zone --id "$zid" --output json | jq -r '.HostedZone.Features.AcceleratedRecoveryStatus // "UNKNOWN"')"
    log "   feature check $i/$MAX_FEATURE_WAIT: AcceleratedRecoveryStatus=$state"
    if [[ "$state" == "DISABLED" || "$state" == "UNKNOWN" ]]; then
      stable=$((stable + 1))
    else
      stable=0
    fi
    [[ "$stable" -ge 2 ]] && return 0
    sleep 5
  done
  return 1
}

try_delete_zone() {
  local zid="$1"
  local zname="$2"
  for ((i=1; i<=MAX_DELETE_RETRY; i++)); do
    log "   deleting hosted zone... (attempt $i/$MAX_DELETE_RETRY)"
    if aws route53 delete-hosted-zone --id "$zid" >/dev/null 2>&1; then
      log "   deleted"
      return 0
    fi
    delete_records_in_zone "$zid" "$zname" || true
    disable_blocking_features "$zid" || true
    sleep $(( i < 6 ? i * 2 : 12 ))
  done
  return 1
}

main() {
  init_registry
  : > "${RUN_LOG}"

  local zones
  zones="$(aws route53 list-hosted-zones --output json | jq -r '.HostedZones[] | "\(.Id|split("/")[-1])\t\(.Name)"')"

  if [[ -z "${zones}" ]]; then
    log "No hosted zones found" | tee -a "${RUN_LOG}"
    update_registry "NO_ZONES"
    exit 0
  fi

  while IFS=$'\t' read -r zid zname; do
    [[ -z "$zid" ]] && continue
    log "==> Zone: ${zname} (/hostedzone/${zid})" | tee -a "${RUN_LOG}"
    delete_records_in_zone "$zid" "$zname" | tee -a "${RUN_LOG}" || true
    disable_blocking_features "$zid" | tee -a "${RUN_LOG}" || true
    if ! try_delete_zone "$zid" "$zname" | tee -a "${RUN_LOG}"; then
      FAILED_ZONES+=("${zname} (${zid})")
    fi
  done <<< "${zones}"

  if [[ "${#FAILED_ZONES[@]}" -gt 0 ]]; then
    log "FAILED_ZONES=${#FAILED_ZONES[@]}" | tee -a "${RUN_LOG}"
    for z in "${FAILED_ZONES[@]}"; do echo " - $z" | tee -a "${RUN_LOG}"; done
    update_registry "PARTIAL_FAIL"
    exit 1
  fi

  log "All hosted zones processed successfully" | tee -a "${RUN_LOG}"
  update_registry "SUCCESS"
}

main "$@"
