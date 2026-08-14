#!/usr/bin/env bash
set -euo pipefail

# Cloud Shell:
#   bash run.sh iam
#   bash run.sh ec2
#   bash run.sh route53

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE="${1:-}"

usage() {
  echo "Usage: bash run.sh <iam|ec2|route53>"
  exit 1
}

[[ -z "${MODULE}" ]] && usage

case "${MODULE}" in
  iam) bash "${ROOT}/modules/iam_cleanup_module.sh" ;;
  ec2) bash "${ROOT}/modules/ec2_cleanup_module.sh" ;;
  route53) bash "${ROOT}/modules/route53_cleanup_module.sh" ;;
  *) usage ;;
esac
