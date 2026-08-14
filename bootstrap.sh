#!/usr/bin/env bash
set -euo pipefail

# Default (no S3 report):
#   curl -fsSL https://raw.githubusercontent.com/hikaru1120/aws-account-cleanup/main/bootstrap.sh | bash
# With public S3 report:
#   curl -fsSL https://raw.githubusercontent.com/hikaru1120/aws-account-cleanup/main/bootstrap.sh | bash -s -- --report-s3

REPO_URL="${REPO_URL:-https://github.com/hikaru1120/aws-account-cleanup.git}"
WORKDIR="${WORKDIR:-/tmp/aws-account-cleanup}"
MODULE="all"
export WRITE_REPORT_S3="${WRITE_REPORT_S3:-0}"

for arg in "$@"; do
  case "${arg}" in
    --report-s3) export WRITE_REPORT_S3=1 ;;
    all|verify|iam_users|iam_roles|iam|cloudtrail|config|events|cloudwatch|elb|eks|ecs|lambda|rds|elasticache|redshift|dynamodb|opensearch|efs|fsx|ecr|ec2|vpc|cloudfront|s3|kms|route53)
      MODULE="${arg}"
      ;;
    *)
      echo "Unknown arg: ${arg}"
      echo "Usage: bootstrap.sh [module] [--report-s3]"
      exit 1
      ;;
  esac
done

rm -rf "${WORKDIR}"
git clone --depth 1 "${REPO_URL}" "${WORKDIR}"
bash "${WORKDIR}/run.sh" "${MODULE}"
