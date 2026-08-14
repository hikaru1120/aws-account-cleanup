#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="rds"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

# 1) turn off deletion protection  2) delete instances/clusters  3) delete snapshots

cleanup_region() {
  local region="$1"
  log "=== RDS ${region} ==="

  log "  disable deletion protection (clusters)"
  aws_r "${region}" rds describe-db-clusters --query 'DBClusters[].DBClusterIdentifier' --output text | lines | while read -r id; do
    log "    cluster ${id}"
    quiet aws_r "${region}" rds modify-db-cluster --db-cluster-identifier "${id}" --no-deletion-protection --apply-immediately
  done

  log "  disable deletion protection (instances)"
  aws_r "${region}" rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output text | lines | while read -r id; do
    log "    instance ${id}"
    quiet aws_r "${region}" rds modify-db-instance --db-instance-identifier "${id}" --no-deletion-protection --apply-immediately
  done

  log "  delete instances"
  aws_r "${region}" rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output text | lines | while read -r id; do
    log "    delete instance ${id}"
    quiet aws_r "${region}" rds delete-db-instance --db-instance-identifier "${id}" --skip-final-snapshot --delete-automated-backups
  done

  log "  delete clusters"
  aws_r "${region}" rds describe-db-clusters --query 'DBClusters[].DBClusterIdentifier' --output text | lines | while read -r id; do
    log "    delete cluster ${id}"
    quiet aws_r "${region}" rds delete-db-cluster --db-cluster-identifier "${id}" --skip-final-snapshot
  done

  log "  delete snapshots"
  aws_r "${region}" rds describe-db-snapshots --snapshot-type manual --query 'DBSnapshots[].DBSnapshotIdentifier' --output text | lines | while read -r sid; do
    log "    delete snapshot ${sid}"
    quiet aws_r "${region}" rds delete-db-snapshot --db-snapshot-identifier "${sid}"
  done
  aws_r "${region}" rds describe-db-cluster-snapshots --snapshot-type manual --query 'DBClusterSnapshots[].DBClusterSnapshotIdentifier' --output text | lines | while read -r sid; do
    log "    delete cluster snapshot ${sid}"
    quiet aws_r "${region}" rds delete-db-cluster-snapshot --db-cluster-snapshot-identifier "${sid}"
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
