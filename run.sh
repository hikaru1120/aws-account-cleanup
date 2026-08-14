#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE="${1:-all}"

run_all() {
  echo "==== 1/4 EC2 ===="
  bash "${ROOT}/modules/ec2_cleanup_module.sh"
  echo "==== 2/4 other billable ===="
  bash "${ROOT}/modules/billable_cleanup_module.sh"
  echo "==== 3/4 Route53 ===="
  bash "${ROOT}/modules/route53_cleanup_module.sh"
  echo "==== 4/4 IAM ===="
  bash "${ROOT}/modules/iam_cleanup_module.sh"
  echo "==== all modules finished ===="
}

case "${MODULE}" in
  all|"") run_all ;;
  iam) bash "${ROOT}/modules/iam_cleanup_module.sh" ;;
  ec2) bash "${ROOT}/modules/ec2_cleanup_module.sh" ;;
  billable) bash "${ROOT}/modules/billable_cleanup_module.sh" ;;
  route53) bash "${ROOT}/modules/route53_cleanup_module.sh" ;;
  *)
    echo "Usage: bash run.sh [all|iam|ec2|billable|route53]"
    exit 1
    ;;
esac
