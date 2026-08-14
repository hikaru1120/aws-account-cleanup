#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE="${1:-all}"
export RECORD_DIR="${RECORD_DIR:-${ROOT}/verification}"
export ERR_FILE="${RECORD_DIR}/errors.log"
mkdir -p "${RECORD_DIR}"
: > "${ERR_FILE}"

# Order matches billing services and delete dependencies.
ALL_MODULES=(
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
  ec2
  vpc
  cloudfront
  s3
  kms
  route53
  iam
)

run_one() {
  local name="$1"
  echo "==== ${name} ===="
  bash "${ROOT}/modules/${name}_cleanup_module.sh" || true
}

run_all() {
  local i=1
  local total="${#ALL_MODULES[@]}"
  for name in "${ALL_MODULES[@]}"; do
    echo "==== ${i}/${total} ${name} ===="
    bash "${ROOT}/modules/${name}_cleanup_module.sh" || true
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
  finish
fi

if [[ "${MODULE}" == "verify" ]]; then
  finish
fi

if [[ -f "${ROOT}/modules/${MODULE}_cleanup_module.sh" ]]; then
  run_one "${MODULE}"
  finish
fi

echo "Usage: bash run.sh [all|verify|elb|ec2|vpc|s3|cloudfront|kms|...]"
exit 1
