#!/usr/bin/env bash
set -euo pipefail

# Fixed Cloud Shell one-liner (after repo is public):
#   curl -fsSL https://raw.githubusercontent.com/hikaru1120/aws-account-cleanup/main/bootstrap.sh | bash -s -- iam
#   curl -fsSL https://raw.githubusercontent.com/hikaru1120/aws-account-cleanup/main/bootstrap.sh | bash -s -- ec2
#   curl -fsSL https://raw.githubusercontent.com/hikaru1120/aws-account-cleanup/main/bootstrap.sh | bash -s -- route53

REPO_URL="${REPO_URL:-https://github.com/hikaru1120/aws-account-cleanup.git}"
WORKDIR="${WORKDIR:-/tmp/aws-account-cleanup}"
MODULE="${1:-}"

if [[ -z "${MODULE}" ]]; then
  echo "Usage: bash bootstrap.sh <iam|ec2|route53>"
  exit 1
fi

rm -rf "${WORKDIR}"
git clone --depth 1 "${REPO_URL}" "${WORKDIR}"
bash "${WORKDIR}/run.sh" "${MODULE}"
