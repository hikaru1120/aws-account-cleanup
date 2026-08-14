#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="s3"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

# Bill: Amazon S3

empty_bucket() {
  local b="$1"
  quiet aws s3 rm "s3://${b}" --recursive
  aws s3api list-object-versions --bucket "${b}" --output json 2>/dev/null \
    | jq -c '.Versions[]?, .DeleteMarkers[]?' | while read -r obj; do
      [[ -z "${obj}" ]] && continue
      key="$(echo "${obj}" | jq -r '.Key')"
      vid="$(echo "${obj}" | jq -r '.VersionId')"
      quiet aws s3api delete-object --bucket "${b}" --key "${key}" --version-id "${vid}"
    done
}

init_records
log "Starting S3 module"
aws s3api list-buckets --query 'Buckets[].Name' --output text | lines | while read -r b; do
  log "  empty+delete ${b}"
  empty_bucket "${b}"
  quiet aws s3api delete-bucket --bucket "${b}"
done
log "S3 finished"
update_registry "SUCCESS"
