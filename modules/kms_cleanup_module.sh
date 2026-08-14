#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="kms"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

# Bill: AWS Key Management Service
# Customer keys cannot be deleted immediately; schedule 7-day deletion.

cleanup_region() {
  local region="$1"
  aws_r "${region}" kms list-keys --query 'Keys[].KeyId' --output text | lines | while read -r kid; do
    mgr="$(aws_r "${region}" kms describe-key --key-id "${kid}" --query 'KeyMetadata.KeyManager' --output text 2>/dev/null || true)"
    state="$(aws_r "${region}" kms describe-key --key-id "${kid}" --query 'KeyMetadata.KeyState' --output text 2>/dev/null || true)"
    [[ "${mgr}" != "CUSTOMER" ]] && continue
    [[ "${state}" == "PendingDeletion" ]] && continue
    log "  schedule delete ${kid}"
    quiet aws_r "${region}" kms disable-key --key-id "${kid}"
    quiet aws_r "${region}" kms schedule-key-deletion --key-id "${kid}" --pending-window-in-days 7
  done
}

init_records
while read -r region; do
  [[ -z "${region}" ]] && continue
  cleanup_region "${region}"
done < <(each_region)
update_registry "SUCCESS"
