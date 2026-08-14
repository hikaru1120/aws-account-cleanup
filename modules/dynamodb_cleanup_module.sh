#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="dynamodb"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

cleanup_region() {
  local region="$1"
  aws_r "${region}" dynamodb list-tables --query 'TableNames[]' --output text | lines | while read -r t; do
    log "  disable deletion protection ${t}"
    quiet aws_r "${region}" dynamodb update-table --table-name "${t}" --no-deletion-protection-enabled
    log "  delete ${t}"
    quiet aws_r "${region}" dynamodb delete-table --table-name "${t}"
  done
}

init_records
while read -r region; do
  [[ -z "${region}" ]] && continue
  cleanup_region "${region}"
done < <(each_region)
update_registry "SUCCESS"
