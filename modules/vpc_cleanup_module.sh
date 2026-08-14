#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="vpc"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

# Bill: VPC / EC2-Other network: EIP, NAT, VPC endpoints

cleanup_region() {
  local region="$1"

  aws_r "${region}" ec2 describe-nat-gateways \
    --filter Name=state,Values=pending,available,deleting \
    --query 'NatGateways[].NatGatewayId' --output text | lines | while read -r nid; do
      log "    delete NAT ${nid}"
      quiet aws_r "${region}" ec2 delete-nat-gateway --nat-gateway-id "${nid}"
    done

  aws_r "${region}" ec2 describe-addresses --output json | jq -c '.Addresses[]?' | while read -r addr; do
    assoc="$(echo "${addr}" | jq -r '.AssociationId // empty')"
    alloc="$(echo "${addr}" | jq -r '.AllocationId // empty')"
    [[ -n "${assoc}" ]] && quiet aws_r "${region}" ec2 disassociate-address --association-id "${assoc}"
    if [[ -n "${alloc}" ]]; then
      log "    release ${alloc}"
      quiet aws_r "${region}" ec2 release-address --allocation-id "${alloc}"
    fi
  done

  aws_r "${region}" ec2 describe-vpc-endpoints --query 'VpcEndpoints[].VpcEndpointId' --output text | lines | while read -r e; do
    log "    delete endpoint ${e}"
    quiet aws_r "${region}" ec2 delete-vpc-endpoints --vpc-endpoint-ids "${e}"
  done
}

init_records
while read -r region; do
  [[ -z "${region}" ]] && continue
  cleanup_region "${region}"
done < <(each_region)
update_registry "SUCCESS"
