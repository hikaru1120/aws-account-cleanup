#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="lambda"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

cleanup_region() {
  local region="$1"
  log "=== Lambda ${region} ==="
  aws_r "${region}" lambda list-functions --query 'Functions[].FunctionName' --output text | lines | while read -r n; do
    log "  delete ${n}"
    quiet aws_r "${region}" lambda delete-function --function-name "${n}"
  done
}

init_records
log "Starting Lambda module"
while read -r region; do
  [[ -z "${region}" ]] && continue
  cleanup_region "${region}"
done < <(each_region)
log "Lambda finished"
update_registry "SUCCESS"
