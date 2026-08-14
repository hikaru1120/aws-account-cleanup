#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="redshift"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

cleanup_region() {
  local region="$1"
  log "=== Redshift ${region} ==="
  aws_r "${region}" redshift describe-clusters --query 'Clusters[].ClusterIdentifier' --output text | lines | while read -r id; do
    log "  delete ${id}"
    quiet aws_r "${region}" redshift delete-cluster --cluster-identifier "${id}" --skip-final-cluster-snapshot
  done
}

init_records
log "Starting Redshift module"
while read -r region; do
  [[ -z "${region}" ]] && continue
  cleanup_region "${region}"
done < <(each_region)
log "Redshift finished"
update_registry "SUCCESS"
