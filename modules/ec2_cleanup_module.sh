#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="ec2"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/lib/common.sh"

# Bill: Amazon EC2 / EC2-Other (instance, ASG, EBS, AMI, snapshot)

cleanup_region() {
  local region="$1"
  log "=== EC2 ${region} ==="

  log "  Auto Scaling groups"
  aws_r "${region}" autoscaling describe-auto-scaling-groups \
    --query 'AutoScalingGroups[].AutoScalingGroupName' --output text | lines | while read -r name; do
      log "    delete ASG ${name}"
      quiet aws_r "${region}" autoscaling delete-auto-scaling-group --auto-scaling-group-name "${name}" --force-delete
    done

  log "  instances"
  ids="$(aws_r "${region}" ec2 describe-instances \
    --filters Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[].Instances[].InstanceId' --output text | lines | tr '\n' ' ')"
  if [[ -n "${ids// }" ]]; then
    log "    terminate ${ids}"
    quiet aws_r "${region}" ec2 terminate-instances --instance-ids ${ids}
    quiet aws_r "${region}" ec2 wait instance-terminated --instance-ids ${ids}
  fi

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

  log "  snapshots"
  aws_r "${region}" ec2 describe-snapshots --owner-ids self \
    --query 'Snapshots[].SnapshotId' --output text | lines | while read -r sid; do
      log "    delete snapshot ${sid}"
      quiet aws_r "${region}" ec2 delete-snapshot --snapshot-id "${sid}"
    done
}

init_records
log "Starting EC2 module"
while read -r region; do
  [[ -z "${region}" ]] && continue
  cleanup_region "${region}"
done < <(each_region)
log "EC2 finished"
update_registry "SUCCESS"
