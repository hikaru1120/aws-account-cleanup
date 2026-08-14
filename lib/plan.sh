#!/usr/bin/env bash
# Inventory of resources cleanup will try to delete. Prints only count > 0.
# AWS CLI --output text prints "None" for empty lists; treat that as empty.

MODULE_NAME="${MODULE_NAME:-plan}"
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

PLAN_FILE="${RECORD_DIR}/delete_plan.txt"
MAX_NAMES=8
SCAN_JOBS="${SCAN_JOBS:-8}"

normalize_names() {
  echo "${1:-}" | tr '\t' '\n' | sed '/^$/d' | grep -v -x 'None' || true
}

emit() {
  local kind="$1"
  local names
  names="$(normalize_names "${2:-}")"
  [[ -z "${names}" ]] && return 0
  local n show extra=""
  n="$(echo "${names}" | wc -l | tr -d ' ')"
  show="$(echo "${names}" | head -n "${MAX_NAMES}" | tr '\n' ' ')"
  [[ "${n}" -gt "${MAX_NAMES}" ]] && extra=" ..."
  printf '%s (%s): %s%s\n' "${kind}" "${n}" "${show}" "${extra}"
  printf '%s\t%s\n' "${kind}" "${n}" >> "${PLAN_FILE}.counts"
}

plan_add() {
  local dest="$1"
  local kind="$2"
  local names n show extra=""
  names="$(normalize_names "${3:-}")"
  [[ -z "${names}" ]] && return 0
  n="$(echo "${names}" | wc -l | tr -d ' ')"
  show="$(echo "${names}" | head -n "${MAX_NAMES}" | tr '\n' ' ')"
  [[ "${n}" -gt "${MAX_NAMES}" ]] && extra=" ..."
  printf '%s (%s): %s%s\n' "${kind}" "${n}" "${show}" "${extra}" >> "${dest}"
  printf '%s\t%s\n' "${kind}" "${n}" >> "${dest}.counts"
}

scan_one_region() {
  local region="$1"
  local out="${PLAN_FILE}.${region}.txt"
  : > "${out}"
  : > "${out}.counts"
  plan_add "${out}" "ec2.instances.${region}" "$(aws_r "${region}" ec2 describe-instances --filters Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)"
  plan_add "${out}" "ec2.volumes.${region}" "$(aws_r "${region}" ec2 describe-volumes --query 'Volumes[].VolumeId' --output text 2>/dev/null || true)"
  plan_add "${out}" "ec2.snapshots.${region}" "$(aws_r "${region}" ec2 describe-snapshots --owner-ids self --query 'Snapshots[].SnapshotId' --output text 2>/dev/null || true)"
  plan_add "${out}" "ec2.amis.${region}" "$(aws_r "${region}" ec2 describe-images --owners self --query 'Images[].ImageId' --output text 2>/dev/null || true)"
  plan_add "${out}" "vpc.eips.${region}" "$(aws_r "${region}" ec2 describe-addresses --query 'Addresses[].AllocationId' --output text 2>/dev/null || true)"
  plan_add "${out}" "vpc.nats.${region}" "$(aws_r "${region}" ec2 describe-nat-gateways --filter Name=state,Values=pending,available --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null || true)"
  plan_add "${out}" "vpc.endpoints.${region}" "$(aws_r "${region}" ec2 describe-vpc-endpoints --query 'VpcEndpoints[].VpcEndpointId' --output text 2>/dev/null || true)"
  plan_add "${out}" "elb.${region}" "$(aws_r "${region}" elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output text 2>/dev/null || true)"
  plan_add "${out}" "elb.classic.${region}" "$(aws_r "${region}" elb describe-load-balancers --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text 2>/dev/null || true)"
  plan_add "${out}" "rds.instances.${region}" "$(aws_r "${region}" rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output text 2>/dev/null || true)"
  plan_add "${out}" "rds.clusters.${region}" "$(aws_r "${region}" rds describe-db-clusters --query 'DBClusters[].DBClusterIdentifier' --output text 2>/dev/null || true)"
  plan_add "${out}" "eks.${region}" "$(aws_r "${region}" eks list-clusters --query 'clusters[]' --output text 2>/dev/null || true)"
  plan_add "${out}" "lambda.${region}" "$(aws_r "${region}" lambda list-functions --query 'Functions[].FunctionName' --output text 2>/dev/null || true)"
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

  echo "scanning regions (parallel)..."
  local region running=0
  while read -r region; do
    [[ -z "${region}" ]] && continue
    scan_one_region "${region}" &
    running=$((running + 1))
    if [[ "${running}" -ge "${SCAN_JOBS}" ]]; then
      wait -n 2>/dev/null || wait
      running=$((running - 1))
    fi
  done < <(each_region)
  wait

  while read -r region; do
    [[ -z "${region}" ]] && continue
    [[ -s "${PLAN_FILE}.${region}.txt" ]] && cat "${PLAN_FILE}.${region}.txt"
    [[ -s "${PLAN_FILE}.${region}.txt.counts" ]] && cat "${PLAN_FILE}.${region}.txt.counts" >> "${PLAN_FILE}.counts"
    rm -f "${PLAN_FILE}.${region}.txt" "${PLAN_FILE}.${region}.txt.counts"
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
