#!/usr/bin/env bash
set -euo pipefail

# Cloud Shell one-liner (cleans all billable modules):
# curl -fsSL https://raw.githubusercontent.com/hikaru1120/aws-account-cleanup/main/bootstrap.sh | bash

REPO_URL="${REPO_URL:-https://github.com/hikaru1120/aws-account-cleanup.git}"
WORKDIR="${WORKDIR:-/tmp/aws-account-cleanup}"
MODULE="${1:-all}"

rm -rf "${WORKDIR}"
git clone --depth 1 "${REPO_URL}" "${WORKDIR}"
bash "${WORKDIR}/run.sh" "${MODULE}"
