#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="cloudtrail"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

# Stop trails before S3 (trails write logs to buckets).

cleanup_region() {
  local region="$1"
  aws_r "${region}" cloudtrail list-trails --query 'Trails[].Name' --output text | lines | while read -r name; do
    log "  stop+delete trail ${name}"
    quiet aws_r "${region}" cloudtrail stop-logging --name "${name}"
    quiet aws_r "${region}" cloudtrail delete-trail --name "${name}"
  done
}

init_records
while read -r region; do
  [[ -z "${region}" ]] && continue
  cleanup_region "${region}"
done < <(each_region)
update_registry "SUCCESS"
