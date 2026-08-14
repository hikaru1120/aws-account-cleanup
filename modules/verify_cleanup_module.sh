#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="verify"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/lib/common.sh"

# Independent leftover check (EC2 Global View style: all-region describe).
# Also tries Resource Explorer and Cost Explorer when available.

REPORT_JSON="${RECORD_DIR}/latest_report.json"

n() { count_text "${1:-0}"; }

sum_regions() {
  local region_cmd="$1"
  local total=0
  local c
  while read -r region; do
    [[ -z "${region}" ]] && continue
    c="$(eval "${region_cmd}" 2>/dev/null || echo 0)"
    c="$(n "${c}")"
    total=$((total + c))
  done < <(each_region)
  echo "${total}"
}

init_records

account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo unknown)"
log "Account ${account}"

ec2_instances="$(sum_regions 'aws_r "${region}" ec2 describe-instances --filters Name=instance-state-name,Values=pending,running,stopping,stopped --query "length(Reservations[].Instances[])" --output text')"
ec2_volumes="$(sum_regions 'aws_r "${region}" ec2 describe-volumes --query "length(Volumes[])" --output text')"
ec2_snapshots="$(sum_regions 'aws_r "${region}" ec2 describe-snapshots --owner-ids self --query "length(Snapshots[])" --output text')"
ec2_amis="$(sum_regions 'aws_r "${region}" ec2 describe-images --owners self --query "length(Images[])" --output text')"
vpc_eips="$(sum_regions 'aws_r "${region}" ec2 describe-addresses --query "length(Addresses[])" --output text')"
vpc_nats="$(sum_regions 'aws_r "${region}" ec2 describe-nat-gateways --filter Name=state,Values=pending,available --query "length(NatGateways[])" --output text')"
vpc_endpoints="$(sum_regions 'aws_r "${region}" ec2 describe-vpc-endpoints --query "length(VpcEndpoints[])" --output text')"
elb_v2="$(sum_regions 'aws_r "${region}" elbv2 describe-load-balancers --query "length(LoadBalancers[])" --output text')"
elb_v1="$(sum_regions 'aws_r "${region}" elb describe-load-balancers --query "length(LoadBalancerDescriptions[])" --output text')"
rds="$(sum_regions 'aws_r "${region}" rds describe-db-instances --query "length(DBInstances[])" --output text')"
s3_raw="$(aws s3api list-buckets --query 'Buckets[].Name' --output text 2>/dev/null || true)"
s3="$(echo "${s3_raw}" | tr '\t' '\n' | sed '/^$/d' | grep -vc '^aws-cleanup-report-' || true)"
s3="$(n "${s3}")"
cf="$(n "$(aws cloudfront list-distributions --query "length(DistributionList.Items[])" --output text 2>/dev/null || echo 0)")"

explorer_ec2="unavailable"
if aws resource-explorer-2 list-indexes --output json >/dev/null 2>&1; then
  explorer_ec2="$(aws resource-explorer-2 search --query-string 'resourcetype:ec2:instance' --query 'length(Resources[])' --output text 2>/dev/null || echo unavailable)"
fi

ce_services="[]"
if aws ce get-cost-and-usage \
  --time-period Start="$(date -u -d '7 days ago' +%F 2>/dev/null || date -u -v-7d +%F)" \
  --time-period End="$(date -u +%F)" \
  --granularity DAILY --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --output json >/tmp/ce.json 2>/dev/null; then
  ce_services="$(jq '[.ResultsByTime[].Groups[] | {service: .Keys[0], amount: (.Metrics.UnblendedCost.Amount|tonumber)}] | group_by(.service) | map({service: .[0].service, amount: (map(.amount)|add)}) | map(select(.amount > 0))' /tmp/ce.json)"
fi

leftovers="$(jq -n \
  --argjson ec2_instances "${ec2_instances}" \
  --argjson ec2_volumes "${ec2_volumes}" \
  --argjson ec2_snapshots "${ec2_snapshots}" \
  --argjson ec2_amis "${ec2_amis}" \
  --argjson vpc_eips "${vpc_eips}" \
  --argjson vpc_nats "${vpc_nats}" \
  --argjson vpc_endpoints "${vpc_endpoints}" \
  --argjson elb "$((elb_v1 + elb_v2))" \
  --argjson rds "${rds}" \
  --argjson s3 "${s3}" \
  --argjson cloudfront "${cf}" \
  '{ec2_instances:$ec2_instances,ec2_volumes:$ec2_volumes,ec2_snapshots:$ec2_snapshots,ec2_amis:$ec2_amis,vpc_eips:$vpc_eips,vpc_nats:$vpc_nats,vpc_endpoints:$vpc_endpoints,elb:$elb,rds:$rds,s3:$s3,cloudfront:$cloudfront}')"

nonzero="$(echo "${leftovers}" | jq '[.[] | select(. > 0)] | length')"
status="PASS"
[[ "${nonzero}" -gt 0 ]] && status="FAIL"

errors_tail=""
[[ -f "${ERR_FILE}" ]] && errors_tail="$(tail -n 80 "${ERR_FILE}")"

jq -n \
  --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg status "${status}" \
  --arg explorer_ec2 "${explorer_ec2}" \
  --argjson leftovers "${leftovers}" \
  --argjson ce "${ce_services}" \
  --arg errors "${errors_tail}" \
  '{timestamp:$ts,status:$status,leftovers:$leftovers,resource_explorer_ec2_instances:$explorer_ec2,cost_explorer_7d:$ce,errors:$errors}' \
  > "${REPORT_JSON}"

log "VERIFY ${status}"
echo "${leftovers}" | jq -r 'to_entries[] | select(.value > 0) | "  leftover.\(.key)=\(.value)"' | while read -r line; do
  [[ -z "${line}" ]] && continue
  log "${line}"
done
log "Report: ${REPORT_JSON}"

[[ "${status}" == "PASS" ]] && update_registry "SUCCESS" || update_registry "LEFTOVERS"
[[ "${status}" == "PASS" ]]
