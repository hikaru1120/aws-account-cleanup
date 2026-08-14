#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="elb"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

# Bill: Elastic Load Balancing

cleanup_region() {
  local region="$1"
  log "=== ELB ${region} ==="
  aws_r "${region}" elb describe-load-balancers \
    --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text | lines | while read -r name; do
      log "  delete CLB ${name}"
      quiet aws_r "${region}" elb delete-load-balancer --load-balancer-name "${name}"
    done
  aws_r "${region}" elbv2 describe-load-balancers \
    --query 'LoadBalancers[].LoadBalancerArn' --output text | lines | while read -r arn; do
      log "  delete ALB/NLB ${arn}"
      quiet aws_r "${region}" elbv2 delete-load-balancer --load-balancer-arn "${arn}"
    done
  aws_r "${region}" elbv2 describe-target-groups \
    --query 'TargetGroups[].TargetGroupArn' --output text | lines | while read -r arn; do
      quiet aws_r "${region}" elbv2 delete-target-group --target-group-arn "${arn}"
    done
}

init_records
log "Starting ELB module"
while read -r region; do
  [[ -z "${region}" ]] && continue
  cleanup_region "${region}"
done < <(each_region)
log "ELB finished"
update_registry "SUCCESS"
