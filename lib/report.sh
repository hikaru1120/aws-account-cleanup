#!/usr/bin/env bash
# Send leftover report so the operator does not paste Cloud Shell logs.
# Default: GitHub issue with COUNTS ONLY (no account/resource IDs) on the public repo.

send_report() {
  local report="${RECORD_DIR:-./verification}/latest_report.json"
  [[ -f "${report}" ]] || return 0

  local status leftovers
  status="$(jq -r '.status' "${report}")"
  leftovers="$(jq -r '.leftovers | to_entries[] | "- \(.key): \(.value)"' "${report}")"
  local title="cleanup-report ${status} $(date -u +%Y%m%dT%H%M%SZ)"
  local body
  body="$(cat <<EOF
Automated leftover check (counts only, no account IDs).

Status: **${status}**

${leftovers}

Cost Explorer 7d is historical and may still show deleted services.
EOF
)"

  if [[ -n "${REPORT_WEBHOOK:-}" ]]; then
    curl -fsSL -X POST -H 'Content-Type: application/json' \
      -d @"${report}" "${REPORT_WEBHOOK}" >/dev/null 2>&1 || true
    echo "Report posted to REPORT_WEBHOOK"
    return 0
  fi

  if [[ -n "${REPORT_S3:-}" ]]; then
    aws s3 cp "${report}" "${REPORT_S3}" >/dev/null 2>&1 || true
    echo "Report uploaded to ${REPORT_S3}"
  fi

  local token="${CLEANUP_GITHUB_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"
  local repo="${CLEANUP_GITHUB_REPO:-hikaru1120/aws-account-cleanup}"
  if [[ -n "${token}" ]]; then
    curl -fsSL -X POST \
      -H "Authorization: Bearer ${token}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${repo}/issues" \
      -d "$(jq -n --arg t "${title}" --arg b "${body}" '{title:$t,body:$b,labels:["cleanup-report"]}')" \
      >/dev/null
    echo "Report issue created on ${repo}"
    return 0
  fi

  echo "No CLEANUP_GITHUB_TOKEN / REPORT_WEBHOOK / REPORT_S3 set; report kept at ${report}"
}
