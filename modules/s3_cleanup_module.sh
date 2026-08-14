#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="s3"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

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
  echo "${payload}" | jq '{Objects: map({Key,VersionId}), Quiet: true}' > /tmp/s3-del.json
  log "    calling DeleteObjects n=${n} ..."
  quiet aws s3api delete-objects --region "${region}" --bucket "${b}" --delete file:///tmp/s3-del.json
}

empty_bucket() {
  local b="$1"
  local idx="$2"
  local total="$3"
  local region
  region="$(bucket_region "${b}")"
  log "S3 [${idx}/${total}] empty ${b} region=${region}"

  quiet aws s3api --region "${region}" delete-bucket-policy --bucket "${b}"
  quiet aws s3api --region "${region}" put-bucket-versioning --bucket "${b}" \
    --versioning-configuration Status=Suspended

  log "    abort incomplete multipart uploads"
  aws s3api --region "${region}" list-multipart-uploads --bucket "${b}" --output json 2>/dev/null \
    | jq -c '.Uploads[]?' | while read -r u; do
      [[ -z "${u}" ]] && continue
      quiet aws s3api --region "${region}" abort-multipart-upload --bucket "${b}" \
        --key "$(echo "${u}" | jq -r '.Key')" --upload-id "$(echo "${u}" | jq -r '.UploadId')"
    done

  local start now elapsed batch=0 deleted=0 n
  start="$(date +%s)"
  start_heartbeat "S3 emptying ${b} (${idx}/${total})"
  while true; do
    now="$(date +%s)"
    elapsed=$((now - start))
    if [[ "${elapsed}" -ge "${S3_EMPTY_MAX_SECONDS}" ]]; then
      stop_heartbeat
      log "S3 [${idx}/${total}] TIMEOUT ${b} after ${elapsed}s deleted_approx=${deleted}"
      return 1
    fi

    log "    listing object versions (batch $((batch + 1)), elapsed ${elapsed}s, deleted_approx=${deleted})"
    local page payload
    page="$(aws s3api --region "${region}" list-object-versions --bucket "${b}" --max-items 1000 --output json 2>/dev/null || echo '{}')"
    payload="$(echo "${page}" | jq '[.Versions[]?, .DeleteMarkers[]? | {Key, VersionId}]')"
    n="$(echo "${payload}" | jq 'length')"
    if [[ "${n}" -eq 0 ]]; then
      page="$(aws s3api --region "${region}" list-objects-v2 --bucket "${b}" --max-items 1000 --output json 2>/dev/null || echo '{}')"
      payload="$(echo "${page}" | jq '[.Contents[]? | {Key, VersionId: "null"}]')"
      n="$(echo "${payload}" | jq 'length')"
    fi
    if [[ "${n}" -eq 0 ]]; then
      stop_heartbeat
      log "S3 [${idx}/${total}] EMPTY ${b} in ${elapsed}s deleted_approx=${deleted}"
      return 0
    fi
    batch=$((batch + 1))
    deleted=$((deleted + n))
    log "    deleting batch ${batch} size=${n} total_approx=${deleted} elapsed=${elapsed}s"
    delete_batch "${region}" "${b}" "${payload}"
  done
}

init_records
mapfile -t buckets < <(aws s3api list-buckets --query 'Buckets[].Name' --output text | lines)
total="${#buckets[@]}"
log "Starting S3 module buckets=${total} max_seconds_per_bucket=${S3_EMPTY_MAX_SECONDS}"
idx=0
for b in "${buckets[@]}"; do
  idx=$((idx + 1))
  if [[ "${b}" == aws-cleanup-report-* ]]; then
    log "S3 [${idx}/${total}] skip report bucket ${b}"
    continue
  fi
  if empty_bucket "${b}" "${idx}" "${total}"; then
    log "S3 [${idx}/${total}] delete bucket ${b}"
    quiet aws s3api delete-bucket --bucket "${b}"
    log "S3 [${idx}/${total}] bucket deleted ${b}"
  else
    log "S3 [${idx}/${total}] keep ${b} (not empty yet, re-run later)"
  fi
done
stop_heartbeat
log "S3 module finished"
update_registry "SUCCESS"
