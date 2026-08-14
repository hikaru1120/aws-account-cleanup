#!/usr/bin/env bash
# Global inventory of resources that cleanup will try to delete.
# Prints only services with count > 0.

MODULE_NAME="${MODULE_NAME:-plan}"
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

PLAN_FILE="${RECORD_DIR}/delete_plan.txt"
MAX_NAMES=8

emit() {
  local kind="$1"
  local names="$2"
  local arr n show extra
  names="$(echo "${names}" | tr '\t' '\n' | sed '/^$/d')"
  [[ -z "${names}" ]] && return 0
  n="$(echo "${names}" | wc -l | tr -d ' ')"
  show="$(echo "${names}" | head -n "${MAX_NAMES}" | tr '\n' ' ')"
  extra=""
  [[ "${n}" -gt "${MAX_NAMES}" ]] && extra=" ..."
  printf '%s (%s): %s%s\n' "${kind}" "${n}" "${show}" "${extra}"
  printf '%s\t%s\n' "${kind}" "${n}" >> "${PLAN_FILE}.counts"
}

scan_global() {
  mkdir -p "${RECORD_DIR}"
  : > "${PLAN_FILE}.counts"
  echo "==== SCAN (what will be deleted) ===="

  local caller
  caller="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo unknown)"
  echo "caller: ${caller}"

  emit "iam.users" "$(aws iam list-users --query 'Users[].UserName' --output text 2>/dev/null || true)"
  emit "s3.buckets" "$(aws s3api list-buckets --query 'Buckets[].Name' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^aws-cleanup-report-' || true)"
  emit "cloudfront.distributions" "$(aws cloudfront list-distributions --query 'DistributionList.Items[].Id' --output text 2>/dev/null || true)"
  emit "route53.zones" "$(aws route53 list-hosted-zones --query 'HostedZones[].Name' --output text 2>/dev/null || true)"

  local region inst vol snap ami eip nat vpce alb clb rds
  while read -r region; do
    [[ -z "${region}" ]] && continue
    printf '%s\n' "[$(date '+%F %T')] scanning ${region}..."
    inst="$(aws_r "${region}" ec2 describe-instances --filters Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)"
    emit "ec2.instances.${region}" "${inst}"
    vol="$(aws_r "${region}" ec2 describe-volumes --query 'Volumes[].VolumeId' --output text 2>/dev/null || true)"
    emit "ec2.volumes.${region}" "${vol}"
    snap="$(aws_r "${region}" ec2 describe-snapshots --owner-ids self --query 'Snapshots[].SnapshotId' --output text 2>/dev/null || true)"
    emit "ec2.snapshots.${region}" "${snap}"
    ami="$(aws_r "${region}" ec2 describe-images --owners self --query 'Images[].ImageId' --output text 2>/dev/null || true)"
    emit "ec2.amis.${region}" "${ami}"
    eip="$(aws_r "${region}" ec2 describe-addresses --query 'Addresses[].AllocationId' --output text 2>/dev/null || true)"
    emit "vpc.eips.${region}" "${eip}"
    nat="$(aws_r "${region}" ec2 describe-nat-gateways --filter Name=state,Values=pending,available --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null || true)"
    emit "vpc.nats.${region}" "${nat}"
    vpce="$(aws_r "${region}" ec2 describe-vpc-endpoints --query 'VpcEndpoints[].VpcEndpointId' --output text 2>/dev/null || true)"
    emit "vpc.endpoints.${region}" "${vpce}"
    alb="$(aws_r "${region}" elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output text 2>/dev/null || true)"
    emit "elb.${region}" "${alb}"
    clb="$(aws_r "${region}" elb describe-load-balancers --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text 2>/dev/null || true)"
    emit "elb.classic.${region}" "${clb}"
    rds="$(aws_r "${region}" rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output text 2>/dev/null || true)"
    emit "rds.instances.${region}" "${rds}"
    emit "rds.clusters.${region}" "$(aws_r "${region}" rds describe-db-clusters --query 'DBClusters[].DBClusterIdentifier' --output text 2>/dev/null || true)"
    emit "eks.${region}" "$(aws_r "${region}" eks list-clusters --query 'clusters[]' --output text 2>/dev/null || true)"
    emit "lambda.${region}" "$(aws_r "${region}" lambda list-functions --query 'Functions[].FunctionName' --output text 2>/dev/null || true)"
  done < <(each_region)

  local hits total
  hits="$(wc -l < "${PLAN_FILE}.counts" | tr -d ' ')"
  total="$(awk '{s+=$2} END {print s+0}' "${PLAN_FILE}.counts")"
  echo "----"
  echo "scan done: ${hits} resource groups, ${total} items"
  echo "==== SCAN END ===="
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  init_records
  scan_global
fi
