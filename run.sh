#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE="all"
export WRITE_REPORT_S3="${WRITE_REPORT_S3:-0}"
export SCAN_ONLY="${SCAN_ONLY:-0}"
export RECORD_DIR="${RECORD_DIR:-${ROOT}/verification}"
export ERR_FILE="${RECORD_DIR}/errors.log"

for arg in "$@"; do
  case "${arg}" in
    --report-s3) export WRITE_REPORT_S3=1 ;;
    --scan-only) export SCAN_ONLY=1 ;;
    all|verify|scan|iam_users|iam_roles|iam|cloudtrail|config|events|cloudwatch|backup|elb|eks|ecs|lambda|rds|elasticache|redshift|dynamodb|opensearch|efs|fsx|ecr|workmail|ec2|vpc|cloudfront|s3|kms|route53)
      MODULE="${arg}"
      ;;
    "")
      ;;
    *)
      echo "Unknown arg: ${arg}"
      echo "Usage: bash run.sh [all|verify|elb|...] [--report-s3]"
      exit 1
      ;;
  esac
done

mkdir -p "${RECORD_DIR}"
: > "${ERR_FILE}"

# 1 freeze IAM users  2 stop log/event producers  3 compute  4 data  5 network
# 6 CloudFront  7 S3  8 KMS  9 Route53  10 IAM roles
ALL_MODULES=(
  iam_users
  cloudtrail
  config
  events
  cloudwatch
  backup
  elb
  eks
  ecs
  lambda
  rds
  elasticache
  redshift
  dynamodb
  opensearch
  efs
  fsx
  ecr
  workmail
  ec2
  vpc
  cloudfront
  s3
  kms
  route53
  iam_roles
)

run_one() {
  local name="$1"
  echo "==== ${name} ===="
  case "${name}" in
    iam_users) IAM_SCOPE=users bash "${ROOT}/modules/iam_cleanup_module.sh" || true ;;
    iam_roles) IAM_SCOPE=roles bash "${ROOT}/modules/iam_cleanup_module.sh" || true ;;
    iam) IAM_SCOPE=all bash "${ROOT}/modules/iam_cleanup_module.sh" || true ;;
    *) bash "${ROOT}/modules/${name}_cleanup_module.sh" || true ;;
  esac
}

run_all() {
  if [[ "${SCAN_ONLY}" == "1" ]]; then
    echo "==== scan-only ===="
    # shellcheck source=lib/plan.sh
    source "${ROOT}/lib/plan.sh"
    init_records
    scan_global
    echo "scan-only: not deleting"
    return 0
  fi
  echo "==== delete ===="
  local i=1
  local total="${#ALL_MODULES[@]}"
  for name in "${ALL_MODULES[@]}"; do
    echo "==== module ${i}/${total}: ${name} ===="
    case "${name}" in
      iam_users) IAM_SCOPE=users bash "${ROOT}/modules/iam_cleanup_module.sh" || true ;;
      iam_roles) IAM_SCOPE=roles bash "${ROOT}/modules/iam_cleanup_module.sh" || true ;;
      *) bash "${ROOT}/modules/${name}_cleanup_module.sh" || true ;;
    esac
    i=$((i + 1))
  done
}

finish() {
  echo "==== verify leftovers ===="
  set +e
  bash "${ROOT}/modules/verify_cleanup_module.sh"
  local rc=$?
  set -e
  # shellcheck source=lib/report.sh
  source "${ROOT}/lib/report.sh"
  send_report
  echo "==== done ===="
  exit "${rc}"
}

if [[ "${MODULE}" == "all" || "${MODULE}" == "" ]]; then
  run_all
  if [[ "${SCAN_ONLY}" == "1" ]]; then
    echo "==== done (scan-only) ===="
    exit 0
  fi
  finish
fi

if [[ "${MODULE}" == "scan" ]]; then
  source "${ROOT}/lib/plan.sh"
  init_records
  scan_global
  exit 0
fi

if [[ "${MODULE}" == "verify" ]]; then
  finish
fi

if [[ "${MODULE}" == "iam_users" || "${MODULE}" == "iam_roles" || "${MODULE}" == "iam" ]]; then
  run_one "${MODULE}"
  finish
fi

if [[ -f "${ROOT}/modules/${MODULE}_cleanup_module.sh" ]]; then
  run_one "${MODULE}"
  finish
fi

echo "Usage: bash run.sh [all|verify|elb|ec2|vpc|s3|cloudfront|kms|...]"
exit 1
