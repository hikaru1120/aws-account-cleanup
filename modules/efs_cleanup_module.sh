#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="efs"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

cleanup_region() {
  local region="$1"
  aws_r "${region}" efs describe-file-systems --query 'FileSystems[].FileSystemId' --output text | lines | while read -r fs; do
    aws_r "${region}" efs describe-mount-targets --file-system-id "${fs}" --query 'MountTargets[].MountTargetId' --output text | lines | while read -r mt; do
      quiet aws_r "${region}" efs delete-mount-target --mount-target-id "${mt}"
    done
    log "  delete ${fs}"
    quiet aws_r "${region}" efs delete-file-system --file-system-id "${fs}"
  done
}

init_records
while read -r region; do
  [[ -z "${region}" ]] && continue
  cleanup_region "${region}"
done < <(each_region)
update_registry "SUCCESS"
