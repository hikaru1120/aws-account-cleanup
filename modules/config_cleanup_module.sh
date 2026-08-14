#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="config"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

# Config delivery channel writes to S3/SNS. Stop before S3.

cleanup_region() {
  local region="$1"
  log "=== Config ${region} ==="
  aws_r "${region}" configservice describe-configuration-recorders --query 'ConfigurationRecorders[].name' --output text | lines | while read -r name; do
    log "  stop recorder ${name}"
    quiet aws_r "${region}" configservice stop-configuration-recorder --configuration-recorder-name "${name}"
    quiet aws_r "${region}" configservice delete-configuration-recorder --configuration-recorder-name "${name}"
  done
  aws_r "${region}" configservice describe-delivery-channels --query 'DeliveryChannels[].name' --output text | lines | while read -r name; do
    log "  delete channel ${name}"
    quiet aws_r "${region}" configservice delete-delivery-channel --delivery-channel-name "${name}"
  done
}

init_records
log "Starting Config module"
while read -r region; do
  [[ -z "${region}" ]] && continue
  cleanup_region "${region}"
done < <(each_region)
log "Config finished"
update_registry "SUCCESS"
