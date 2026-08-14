#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="rds"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

cleanup_region() {
  local region="$1"
  log "=== RDS ${region} ==="
  aws_r "${region}" rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output text | lines | while read -r id; do
    log "  delete instance ${id}"
    quiet aws_r "${region}" rds delete-db-instance --db-instance-identifier "${id}" --skip-final-snapshot --delete-automated-backups
  done
  aws_r "${region}" rds describe-db-clusters --query 'DBClusters[].DBClusterIdentifier' --output text | lines | while read -r id; do
    log "  delete cluster ${id}"
    quiet aws_r "${region}" rds delete-db-cluster --db-cluster-identifier "${id}" --skip-final-snapshot
  done
}

init_records
log "Starting RDS module"
while read -r region; do
  [[ -z "${region}" ]] && continue
  cleanup_region "${region}"
done < <(each_region)
log "RDS finished"
update_registry "SUCCESS"
