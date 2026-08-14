#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="cloudwatch"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

# Logs/subscriptions can keep writing to S3/Lambda. Delete before S3.

cleanup_region() {
  local region="$1"
  aws_r "${region}" logs describe-log-groups --query 'logGroups[].logGroupName' --output text | lines | while read -r name; do
    aws_r "${region}" logs describe-subscription-filters --log-group-name "${name}" --query 'subscriptionFilters[].filterName' --output text 2>/dev/null | lines | while read -r f; do
      quiet aws_r "${region}" logs delete-subscription-filter --log-group-name "${name}" --filter-name "${f}"
    done
    log "  delete log group ${name}"
    quiet aws_r "${region}" logs delete-log-group --log-group-name "${name}"
  done
  alarms="$(aws_r "${region}" cloudwatch describe-alarms --query 'MetricAlarms[].AlarmName' --output text | lines | tr '\n' ' ')"
  if [[ -n "${alarms// }" ]]; then
    # shellcheck disable=SC2086
    quiet aws_r "${region}" cloudwatch delete-alarms --alarm-names ${alarms}
  fi
}

init_records
while read -r region; do
  [[ -z "${region}" ]] && continue
  cleanup_region "${region}"
done < <(each_region)
update_registry "SUCCESS"
