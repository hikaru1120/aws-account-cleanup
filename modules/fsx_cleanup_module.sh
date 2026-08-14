#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="fsx"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

cleanup_region() {
  local region="$1"
  aws_r "${region}" fsx describe-file-systems --query 'FileSystems[].FileSystemId' --output text | lines | while read -r fs; do
    log "  delete ${fs}"
    quiet aws_r "${region}" fsx delete-file-system --file-system-id "${fs}"
  done
}

init_records
while read -r region; do
  [[ -z "${region}" ]] && continue
  cleanup_region "${region}"
done < <(each_region)
update_registry "SUCCESS"
