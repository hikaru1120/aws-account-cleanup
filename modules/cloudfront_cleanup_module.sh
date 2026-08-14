#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="cloudfront"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

# Bill: Amazon CloudFront
# Must disable, wait until Status=Deployed, then delete.

CF_WAIT_SECONDS="${CF_WAIT_SECONDS:-900}"

wait_disabled_deployed() {
  local id="$1"
  local start now elapsed status enabled
  start="$(date +%s)"
  while true; do
    now="$(date +%s)"
    elapsed=$((now - start))
    if [[ "${elapsed}" -ge "${CF_WAIT_SECONDS}" ]]; then
      log "    ${id} still not Deployed after ${elapsed}s, skip delete this run"
      return 1
    fi
    status="$(aws cloudfront get-distribution --id "${id}" --query 'Distribution.Status' --output text 2>/dev/null || echo unknown)"
    enabled="$(aws cloudfront get-distribution --id "${id}" --query 'Distribution.DistributionConfig.Enabled' --output text 2>/dev/null || echo true)"
    log "    ${id} Status=${status} Enabled=${enabled} (${elapsed}s)"
    if [[ "${status}" == "Deployed" && "${enabled}" == "False" ]]; then
      return 0
    fi
    sleep 15
  done
}

disable_and_delete() {
  local id="$1"
  log "  disable ${id}"
  local cfg etag
  cfg="$(aws cloudfront get-distribution-config --id "${id}" --output json 2>/dev/null || true)"
  [[ -z "${cfg}" ]] && return 0
  etag="$(echo "${cfg}" | jq -r '.ETag')"
  if [[ "$(echo "${cfg}" | jq -r '.DistributionConfig.Enabled')" == "true" ]]; then
    echo "${cfg}" | jq '.DistributionConfig.Enabled=false | .DistributionConfig' > "/tmp/cf-${id}.json"
    quiet aws cloudfront update-distribution --id "${id}" --if-match "${etag}" --distribution-config "file:///tmp/cf-${id}.json"
  fi
  if ! wait_disabled_deployed "${id}"; then
    return 0
  fi
  etag="$(aws cloudfront get-distribution-config --id "${id}" --query ETag --output text 2>/dev/null || true)"
  [[ -z "${etag}" ]] && return 0
  log "  delete ${id}"
  quiet aws cloudfront delete-distribution --id "${id}" --if-match "${etag}"
}

init_records
log "Starting CloudFront module (disable -> wait Deployed -> delete)"
aws cloudfront list-distributions --output json 2>/dev/null | jq -c '.DistributionList.Items[]?' | while read -r d; do
  [[ -z "${d}" ]] && continue
  disable_and_delete "$(echo "${d}" | jq -r '.Id')"
done
log "CloudFront finished"
update_registry "SUCCESS"
