#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE="${1:-all}"

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
  bash "${ROOT}/modules/${name}_cleanup_module.sh"
}

run_all() {
  local i=1
  local total="${#ALL_MODULES[@]}"
  for name in "${ALL_MODULES[@]}"; do
    echo "==== ${i}/${total} ${name} ===="
    bash "${ROOT}/modules/${name}_cleanup_module.sh"
    i=$((i + 1))
  done
  echo "==== all modules finished ===="
}

if [[ "${MODULE}" == "all" || "${MODULE}" == "" ]]; then
  run_all
  exit 0
fi

if [[ -f "${ROOT}/modules/${MODULE}_cleanup_module.sh" ]]; then
  run_one "${MODULE}"
  exit 0
fi

echo "Usage: bash run.sh [all|elb|ec2|vpc|s3|cloudfront|kms|...]"
exit 1
