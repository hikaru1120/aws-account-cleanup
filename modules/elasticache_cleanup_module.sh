#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="elasticache"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

cleanup_region() {
  local region="$1"
  aws_r "${region}" elasticache describe-replication-groups --query 'ReplicationGroups[].ReplicationGroupId' --output text | lines | while read -r id; do
    log "  delete rg ${id}"
    quiet aws_r "${region}" elasticache delete-replication-group --replication-group-id "${id}"
  done
  aws_r "${region}" elasticache describe-cache-clusters --query 'CacheClusters[].CacheClusterId' --output text | lines | while read -r id; do
    log "  delete cluster ${id}"
    quiet aws_r "${region}" elasticache delete-cache-cluster --cache-cluster-id "${id}"
  done
}

init_records
while read -r region; do
  [[ -z "${region}" ]] && continue
  cleanup_region "${region}"
done < <(each_region)
update_registry "SUCCESS"
