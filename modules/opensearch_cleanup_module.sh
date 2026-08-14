#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="opensearch"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

cleanup_region() {
  local region="$1"
  aws_r "${region}" opensearch list-domain-names --query 'DomainNames[].DomainName' --output text 2>/dev/null | lines | while read -r d; do
    log "  delete ${d}"
    quiet aws_r "${region}" opensearch delete-domain --domain-name "${d}"
  done
}

init_records
while read -r region; do
  [[ -z "${region}" ]] && continue
  cleanup_region "${region}"
done < <(each_region)
update_registry "SUCCESS"
