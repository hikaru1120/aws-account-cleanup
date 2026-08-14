#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="cloudfront"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

# Bill: Amazon CloudFront

init_records
log "Starting CloudFront module"
aws cloudfront list-distributions --output json 2>/dev/null | jq -c '.DistributionList.Items[]?' | while read -r d; do
  id="$(echo "$d" | jq -r '.Id')"
  log "  disable ${id}"
  cfg="$(aws cloudfront get-distribution-config --id "${id}" --output json 2>/dev/null || true)"
  [[ -z "${cfg}" ]] && continue
  etag="$(echo "${cfg}" | jq -r '.ETag')"
  echo "${cfg}" | jq '.DistributionConfig.Enabled=false | .DistributionConfig' > /tmp/cf-${id}.json
  quiet aws cloudfront update-distribution --id "${id}" --if-match "${etag}" --distribution-config "file:///tmp/cf-${id}.json"
done
log "CloudFront finished (disabled; delete may need a later retry after deploy)"
update_registry "SUCCESS"
