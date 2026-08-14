#!/usr/bin/env bash
# Write leftover report to a private S3 bucket in the same account.
# PASS: delete that bucket so it does not keep billing.
# FAIL: keep the bucket for inspection in the console.

REPORT_BUCKET_PREFIX="aws-cleanup-report"

report_bucket_name() {
  local account
  account="$(aws sts get-caller-identity --query Account --output text)"
  echo "${REPORT_BUCKET_PREFIX}-${account}"
}

delete_report_bucket() {
  local bucket="$1"
  aws s3api head-bucket --bucket "${bucket}" >/dev/null 2>&1 || return 0
  aws s3 rm "s3://${bucket}" --recursive >/dev/null 2>&1 || true
  aws s3api delete-bucket --bucket "${bucket}" >/dev/null 2>&1 || true
  echo "Removed report bucket s3://${bucket}"
}

ensure_report_bucket() {
  local bucket="$1"
  if aws s3api head-bucket --bucket "${bucket}" >/dev/null 2>&1; then
    return 0
  fi
  aws s3api create-bucket --bucket "${bucket}" >/dev/null
  aws s3api put-public-access-block --bucket "${bucket}" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
    >/dev/null 2>&1 || true
}

send_report() {
  local report="${RECORD_DIR:-./verification}/latest_report.json"
  [[ -f "${report}" ]] || return 0

  local status bucket
  status="$(jq -r '.status' "${report}")"
  bucket="$(report_bucket_name)"

  if [[ "${status}" == "PASS" ]]; then
    delete_report_bucket "${bucket}"
    echo "VERIFY PASS; report bucket cleaned"
    return 0
  fi

  ensure_report_bucket "${bucket}"
  aws s3 cp "${report}" "s3://${bucket}/latest_report.json" >/dev/null
  echo "VERIFY FAIL; report kept at s3://${bucket}/latest_report.json"
}
