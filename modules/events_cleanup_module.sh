#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="events"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

# EventBridge can recreate/start workloads. Remove rules before compute.

cleanup_region() {
  local region="$1"
  log "=== EventBridge ${region} ==="
  aws_r "${region}" events list-rules --query 'Rules[].Name' --output text | lines | while read -r name; do
    ids="$(aws_r "${region}" events list-targets-by-rule --rule "${name}" --query 'Targets[].Id' --output text 2>/dev/null || true)"
    if [[ -n "${ids}" ]]; then
      # shellcheck disable=SC2086
      quiet aws_r "${region}" events remove-targets --rule "${name}" --ids ${ids} --force
    fi
    log "  delete rule ${name}"
    quiet aws_r "${region}" events delete-rule --name "${name}" --force
  done
}

init_records
log "Starting EventBridge module"
while read -r region; do
  [[ -z "${region}" ]] && continue
  cleanup_region "${region}"
done < <(each_region)
log "EventBridge finished"
update_registry "SUCCESS"
