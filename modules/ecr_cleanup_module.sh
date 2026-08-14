#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="ecr"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

cleanup_region() {
  local region="$1"
  log "=== ECR ${region} ==="
  aws_r "${region}" ecr describe-repositories --query 'repositories[].repositoryName' --output text | lines | while read -r n; do
    log "  delete ${n}"
    quiet aws_r "${region}" ecr delete-repository --repository-name "${n}" --force
  done
}

init_records
log "Starting ECR module"
while read -r region; do
  [[ -z "${region}" ]] && continue
  cleanup_region "${region}"
done < <(each_region)
log "ECR finished"
update_registry "SUCCESS"
