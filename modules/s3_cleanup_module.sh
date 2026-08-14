#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="s3"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

# Bill: Amazon S3
# Large buckets: batch DeleteObjects (1000), high concurrency, progress logs.
# Do not delete one object at a time.

S3_EMPTY_MAX_SECONDS="${S3_EMPTY_MAX_SECONDS:-3600}"

bucket_region() {
  local b="$1"
  local loc
  loc="$(aws s3api get-bucket-location --bucket "${b}" --query LocationConstraint --output text 2>/dev/null || true)"
  if [[ -z "${loc}" || "${loc}" == "None" || "${loc}" == "null" ]]; then
    echo "us-east-1"
  else
    echo "${loc}"
  fi
}

delete_batch() {
  local region="$1"
  local b="$2"
  local payload="$3"
  local n
  n="$(echo "${payload}" | jq 'length')"
  [[ "${n}" -eq 0 ]] && return 0
  echo "${payload}" | jq '{Objects: ., Quiet: true}' > /tmp/s3-del.json
  quiet aws s3api delete-objects --region "${region}" --bucket "${b}" --delete file:///tmp/s3-del.json
  log "    deleted batch ${n}"
}

empty_bucket() {
  local b="$1"
  local region
  region="$(bucket_region "${b}")"
  log "  empty ${b} (${region})"

  quiet aws s3api --region "${region}" delete-bucket-policy --bucket "${b}"
  quiet aws s3api --region "${region}" put-bucket-versioning --bucket "${b}" \
    --versioning-configuration Status=Suspended

  # Current objects, parallel CLI copy/rm
  AWS_MAX_ATTEMPTS=10 aws s3 rm "s3://${b}" --region "${region}" --recursive --only-show-errors \
    --page-size 1000 >/dev/null 2>&1 || true

  # Abort leftover multipart uploads (otherwise bucket delete fails)
  aws s3api --region "${region}" list-multipart-uploads --bucket "${b}" --output json 2>/dev/null \
    | jq -c '.Uploads[]?' | while read -r u; do
      [[ -z "${u}" ]] && continue
      quiet aws s3api --region "${region}" abort-multipart-upload --bucket "${b}" \
        --key "$(echo "${u}" | jq -r '.Key')" --upload-id "$(echo "${u}" | jq -r '.UploadId')"
    done

  local start now elapsed
  start="$(date +%s)"
  while true; do
    now="$(date +%s)"
    elapsed=$((now - start))
    if [[ "${elapsed}" -ge "${S3_EMPTY_MAX_SECONDS}" ]]; then
      log "    timeout after ${elapsed}s, leave ${b} for a later run"
      return 1
    fi

    local page
    page="$(aws s3api --region "${region}" list-object-versions --bucket "${b}" --max-items 1000 --output json 2>/dev/null || echo '{}')"
    local payload
    payload="$(echo "${page}" | jq '[.Versions[]?, .DeleteMarkers[]? | {Key, VersionId}]')"
    local n
    n="$(echo "${payload}" | jq 'length')"
    if [[ "${n}" -eq 0 ]]; then
      log "    empty"
      return 0
    fi
    delete_batch "${region}" "${b}" "${payload}"
  done
}

init_records
log "Starting S3 module (batch delete, max ${S3_EMPTY_MAX_SECONDS}s per bucket)"
aws s3api list-buckets --query 'Buckets[].Name' --output text | lines | while read -r b; do
  if [[ "${b}" == aws-cleanup-report-* ]]; then
    log "  skip report bucket ${b}"
    continue
  fi
  if empty_bucket "${b}"; then
    log "  delete bucket ${b}"
    quiet aws s3api delete-bucket --bucket "${b}"
  else
    log "  keep ${b} (not empty yet)"
  fi
done
log "S3 finished"
update_registry "SUCCESS"
