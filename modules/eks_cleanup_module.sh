#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="eks"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

cleanup_region() {
  local region="$1"
  log "=== EKS ${region} ==="
  aws_r "${region}" eks list-clusters --query 'clusters[]' --output text | lines | while read -r n; do
    log "  delete ${n}"
    quiet aws_r "${region}" eks delete-cluster --name "${n}"
  done
}

init_records
log "Starting EKS module"
while read -r region; do
  [[ -z "${region}" ]] && continue
  cleanup_region "${region}"
done < <(each_region)
log "EKS finished"
update_registry "SUCCESS"
