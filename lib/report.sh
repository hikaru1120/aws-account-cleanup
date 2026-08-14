#!/usr/bin/env bash
# Optional S3 leftover report. Default is off.
# Enable with --report-s3 (public-read object).
# PASS always tries to delete the report bucket so it does not keep billing.

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

ensure_public_report_bucket() {
  local bucket="$1"
  if ! aws s3api head-bucket --bucket "${bucket}" >/dev/null 2>&1; then
    aws s3api create-bucket --bucket "${bucket}" >/dev/null
  fi
  aws s3api put-public-access-block --bucket "${bucket}" \
    --public-access-block-configuration \
    BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false \
    >/dev/null 2>&1 || true
  aws s3api put-bucket-ownership-controls --bucket "${bucket}" \
    --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerPreferred}]' >/dev/null 2>&1 || true
  local policy
  policy="$(jq -n --arg b "${bucket}" '{
    Version:"2012-10-17",
    Statement:[{
      Sid:"PublicReadReport",
      Effect:"Allow",
      Principal:"*",
      Action:"s3:GetObject",
      Resource:("arn:aws:s3:::" + $b + "/*")
    }]
  }')"
  aws s3api put-bucket-policy --bucket "${bucket}" --policy "${policy}" >/dev/null 2>&1 || true
}

send_report() {
  local report="${RECORD_DIR:-./verification}/latest_report.json"
  [[ -f "${report}" ]] || return 0

  local status bucket
  status="$(jq -r '.status' "${report}")"
  bucket="$(report_bucket_name)"

  if [[ "${status}" == "PASS" ]]; then
    delete_report_bucket "${bucket}"
    echo "VERIFY PASS; report bucket cleaned if it existed"
    return 0
  fi

  if [[ "${WRITE_REPORT_S3:-0}" != "1" ]]; then
    echo "VERIFY FAIL; S3 report skipped (pass --report-s3 to publish)"
    echo "Local report: ${report}"
    return 0
  fi

  ensure_public_report_bucket "${bucket}"
  aws s3 cp "${report}" "s3://${bucket}/latest_report.json" --acl public-read >/dev/null 2>&1 \
    || aws s3 cp "${report}" "s3://${bucket}/latest_report.json" >/dev/null
  echo "VERIFY FAIL; public report: https://${bucket}.s3.amazonaws.com/latest_report.json"
}
