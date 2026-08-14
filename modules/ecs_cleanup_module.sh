#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="ecs"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

cleanup_region() {
  local region="$1"
  log "=== ECS ${region} ==="
  aws_r "${region}" ecs list-clusters --query 'clusterArns[]' --output text | lines | while read -r c; do
    aws_r "${region}" ecs list-services --cluster "${c}" --query 'serviceArns[]' --output text | lines | while read -r s; do
      quiet aws_r "${region}" ecs delete-service --cluster "${c}" --service "${s}" --force
    done
    log "  delete cluster ${c}"
    quiet aws_r "${region}" ecs delete-cluster --cluster "${c}"
  done
}

init_records
log "Starting ECS module"
while read -r region; do
  [[ -z "${region}" ]] && continue
  cleanup_region "${region}"
done < <(each_region)
log "ECS finished"
update_registry "SUCCESS"
