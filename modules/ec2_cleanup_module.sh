#!/usr/bin/env bash
set -euo pipefail

# EC2 console billable resources cleanup
# Validation status: PENDING_SECONDARY_VERIFICATION
# Scope: instances, ASG, ELB/ALB/NLB, EIP, EBS volumes, AMIs, snapshots
# NAT Gateway is billed under EC2-Other, included here.

RECORD_DIR="${RECORD_DIR:-./verification}"
REGISTRY_FILE="${REGISTRY_FILE:-${RECORD_DIR}/module_validation_registry.json}"
RUN_LOG="${RECORD_DIR}/ec2_cleanup_runs.log"

log() {
  local msg="[$(date '+%F %T')] $*"
  echo "${msg}"
  [[ -n "${RUN_LOG:-}" && -f "${RUN_LOG}" ]] && echo "${msg}" >> "${RUN_LOG}"
}

quiet() { "$@" >/dev/null 2>&1 || true; }

init_records() {
  mkdir -p "${RECORD_DIR}"
  : > "${RUN_LOG}"
}

update_registry() {
  local result="$1"
  local now
  now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  command -v jq >/dev/null 2>&1 || return 0
  [[ -f "${REGISTRY_FILE}" ]] || return 0
  tmp="$(mktemp)"
  jq --arg now "${now}" --arg result "${result}" '
    .modules.ec2_cleanup_module.last_run_at=$now
    | .modules.ec2_cleanup_module.last_result=$result
    | .modules.ec2_cleanup_module.status="PENDING_SECONDARY_VERIFICATION"
  ' "${REGISTRY_FILE}" > "${tmp}" && mv "${tmp}" "${REGISTRY_FILE}"
}

aws_r() {
  local region="$1"
  shift
  aws --region "${region}" "$@"
}

lines() { tr '\t' '\n' | sed '/^$/d'; }

cleanup_region() {
  local region="$1"
  log "=== Region ${region} ==="

  log "  Auto Scaling groups"
  aws_r "${region}" autoscaling describe-auto-scaling-groups \
    --query 'AutoScalingGroups[].AutoScalingGroupName' --output text | lines | while read -r name; do
      log "    delete ASG ${name}"
      quiet aws_r "${region}" autoscaling delete-auto-scaling-group --auto-scaling-group-name "${name}" --force-delete
    done

  log "  Classic load balancers"
  aws_r "${region}" elb describe-load-balancers \
    --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text | lines | while read -r name; do
      log "    delete CLB ${name}"
      quiet aws_r "${region}" elb delete-load-balancer --load-balancer-name "${name}"
    done

  log "  ALB/NLB"
  aws_r "${region}" elbv2 describe-load-balancers \
    --query 'LoadBalancers[].LoadBalancerArn' --output text | lines | while read -r arn; do
      log "    delete LB ${arn}"
      quiet aws_r "${region}" elbv2 delete-load-balancer --load-balancer-arn "${arn}"
    done
  aws_r "${region}" elbv2 describe-target-groups \
    --query 'TargetGroups[].TargetGroupArn' --output text | lines | while read -r arn; do
      log "    delete target group ${arn}"
      quiet aws_r "${region}" elbv2 delete-target-group --target-group-arn "${arn}"
    done

  log "  NAT gateways"
  aws_r "${region}" ec2 describe-nat-gateways \
    --filter Name=state,Values=pending,available,deleting \
    --query 'NatGateways[].NatGatewayId' --output text | lines | while read -r nid; do
      log "    delete NAT ${nid}"
      quiet aws_r "${region}" ec2 delete-nat-gateway --nat-gateway-id "${nid}"
    done

  log "  EC2 instances"
  ids="$(aws_r "${region}" ec2 describe-instances \
    --filters Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[].Instances[].InstanceId' --output text | lines | tr '\n' ' ')"
  if [[ -n "${ids// }" ]]; then
    log "    terminate ${ids}"
    quiet aws_r "${region}" ec2 terminate-instances --instance-ids ${ids}
    quiet aws_r "${region}" ec2 wait instance-terminated --instance-ids ${ids}
  fi

  log "  Elastic IPs"
  aws_r "${region}" ec2 describe-addresses --output json | jq -c '.Addresses[]?' | while read -r addr; do
    assoc="$(echo "${addr}" | jq -r '.AssociationId // empty')"
    alloc="$(echo "${addr}" | jq -r '.AllocationId // empty')"
    [[ -n "${assoc}" ]] && quiet aws_r "${region}" ec2 disassociate-address --association-id "${assoc}"
    if [[ -n "${alloc}" ]]; then
      log "    release ${alloc}"
      quiet aws_r "${region}" ec2 release-address --allocation-id "${alloc}"
    fi
  done

  log "  EBS volumes"
  aws_r "${region}" ec2 describe-volumes --filters Name=status,Values=in-use \
    --query 'Volumes[].VolumeId' --output text | lines | while read -r vid; do
      quiet aws_r "${region}" ec2 detach-volume --volume-id "${vid}" --force
    done
  aws_r "${region}" ec2 describe-volumes --filters Name=status,Values=available \
    --query 'Volumes[].VolumeId' --output text | lines | while read -r vid; do
      log "    delete volume ${vid}"
      quiet aws_r "${region}" ec2 delete-volume --volume-id "${vid}"
    done

  log "  AMIs"
  aws_r "${region}" ec2 describe-images --owners self --output json | jq -c '.Images[]?' | while read -r img; do
    ami="$(echo "${img}" | jq -r '.ImageId')"
    log "    deregister ${ami}"
    quiet aws_r "${region}" ec2 deregister-image --image-id "${ami}"
    echo "${img}" | jq -r '.BlockDeviceMappings[]?.Ebs.SnapshotId // empty' | while read -r sid; do
      [[ -z "${sid}" ]] && continue
      quiet aws_r "${region}" ec2 delete-snapshot --snapshot-id "${sid}"
    done
  done

  log "  Snapshots"
  aws_r "${region}" ec2 describe-snapshots --owner-ids self \
    --query 'Snapshots[].SnapshotId' --output text | lines | while read -r sid; do
      log "    delete snapshot ${sid}"
      quiet aws_r "${region}" ec2 delete-snapshot --snapshot-id "${sid}"
    done
}

main() {
  init_records
  log "Starting EC2 cleanup module"

  local regions
  regions="$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text | lines)"
  log "Regions: $(echo "${regions}" | wc -l | tr -d ' ')"

  while read -r region; do
    [[ -z "${region}" ]] && continue
    cleanup_region "${region}"
  done <<< "${regions}"

  log "EC2 cleanup finished"
  update_registry "SUCCESS"
}

main "$@"
