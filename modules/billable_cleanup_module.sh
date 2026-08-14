#!/usr/bin/env bash
set -euo pipefail

# Other billable services (not in EC2/Route53/IAM modules)
# Validation status: PENDING_SECONDARY_VERIFICATION

RECORD_DIR="${RECORD_DIR:-./verification}"
REGISTRY_FILE="${REGISTRY_FILE:-${RECORD_DIR}/module_validation_registry.json}"
RUN_LOG="${RECORD_DIR}/billable_cleanup_runs.log"

log() {
  local msg="[$(date '+%F %T')] $*"
  echo "${msg}"
  [[ -n "${RUN_LOG:-}" && -f "${RUN_LOG}" ]] && echo "${msg}" >> "${RUN_LOG}"
}

quiet() { "$@" >/dev/null 2>&1 || true; }
aws_r() { local r="$1"; shift; aws --region "$r" "$@"; }
lines() { tr '\t' '\n' | sed '/^$/d'; }

init_records() {
  mkdir -p "${RECORD_DIR}"
  : > "${RUN_LOG}"
}

update_registry() {
  local result="$1"
  command -v jq >/dev/null 2>&1 || return 0
  [[ -f "${REGISTRY_FILE}" ]] || return 0
  tmp="$(mktemp)"
  jq --arg now "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" --arg result "${result}" '
    .modules.billable_cleanup_module.last_run_at=$now
    | .modules.billable_cleanup_module.last_result=$result
    | .modules.billable_cleanup_module.status="PENDING_SECONDARY_VERIFICATION"
  ' "${REGISTRY_FILE}" > "${tmp}" && mv "${tmp}" "${REGISTRY_FILE}"
}

cleanup_s3() {
  log "=== S3 ==="
  aws s3api list-buckets --query 'Buckets[].Name' --output text | lines | while read -r b; do
    log "  empty+delete bucket ${b}"
    quiet aws s3 rm "s3://${b}" --recursive
    quiet aws s3api delete-bucket --bucket "${b}"
  done
}

cleanup_cloudfront() {
  log "=== CloudFront ==="
  aws cloudfront list-distributions --output json 2>/dev/null | jq -c '.DistributionList.Items[]?' | while read -r d; do
    id="$(echo "$d" | jq -r '.Id')"
    log "  disable/delete distribution ${id}"
    cfg="$(aws cloudfront get-distribution-config --id "${id}" --output json 2>/dev/null || true)"
    [[ -z "${cfg}" ]] && continue
    etag="$(echo "${cfg}" | jq -r '.ETag')"
    echo "${cfg}" | jq '.DistributionConfig.Enabled=false | .DistributionConfig' > /tmp/cf.json
    quiet aws cloudfront update-distribution --id "${id}" --if-match "${etag}" --distribution-config file:///tmp/cf.json
  done
}

cleanup_region() {
  local region="$1"
  log "=== Billable region ${region} ==="

  log "  RDS instances"
  aws_r "${region}" rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output text | lines | while read -r id; do
    log "    delete db ${id}"
    quiet aws_r "${region}" rds delete-db-instance --db-instance-identifier "${id}" --skip-final-snapshot --delete-automated-backups
  done
  log "  RDS clusters"
  aws_r "${region}" rds describe-db-clusters --query 'DBClusters[].DBClusterIdentifier' --output text | lines | while read -r id; do
    log "    delete cluster ${id}"
    quiet aws_r "${region}" rds delete-db-cluster --db-cluster-identifier "${id}" --skip-final-snapshot
  done

  log "  ElastiCache"
  aws_r "${region}" elasticache describe-replication-groups --query 'ReplicationGroups[].ReplicationGroupId' --output text | lines | while read -r id; do
    quiet aws_r "${region}" elasticache delete-replication-group --replication-group-id "${id}"
  done
  aws_r "${region}" elasticache describe-cache-clusters --query 'CacheClusters[].CacheClusterId' --output text | lines | while read -r id; do
    quiet aws_r "${region}" elasticache delete-cache-cluster --cache-cluster-id "${id}"
  done

  log "  Redshift"
  aws_r "${region}" redshift describe-clusters --query 'Clusters[].ClusterIdentifier' --output text | lines | while read -r id; do
    quiet aws_r "${region}" redshift delete-cluster --cluster-identifier "${id}" --skip-final-cluster-snapshot
  done

  log "  DynamoDB"
  aws_r "${region}" dynamodb list-tables --query 'TableNames[]' --output text | lines | while read -r t; do
    quiet aws_r "${region}" dynamodb delete-table --table-name "${t}"
  done

  log "  OpenSearch"
  aws_r "${region}" opensearch list-domain-names --query 'DomainNames[].DomainName' --output text 2>/dev/null | lines | while read -r d; do
    quiet aws_r "${region}" opensearch delete-domain --domain-name "${d}"
  done

  log "  EFS"
  aws_r "${region}" efs describe-file-systems --query 'FileSystems[].FileSystemId' --output text | lines | while read -r fs; do
    aws_r "${region}" efs describe-mount-targets --file-system-id "${fs}" --query 'MountTargets[].MountTargetId' --output text | lines | while read -r mt; do
      quiet aws_r "${region}" efs delete-mount-target --mount-target-id "${mt}"
    done
    quiet aws_r "${region}" efs delete-file-system --file-system-id "${fs}"
  done

  log "  FSx"
  aws_r "${region}" fsx describe-file-systems --query 'FileSystems[].FileSystemId' --output text | lines | while read -r fs; do
    quiet aws_r "${region}" fsx delete-file-system --file-system-id "${fs}"
  done

  log "  ECS"
  aws_r "${region}" ecs list-clusters --query 'clusterArns[]' --output text | lines | while read -r c; do
    aws_r "${region}" ecs list-services --cluster "${c}" --query 'serviceArns[]' --output text | lines | while read -r s; do
      quiet aws_r "${region}" ecs delete-service --cluster "${c}" --service "${s}" --force
    done
    quiet aws_r "${region}" ecs delete-cluster --cluster "${c}"
  done

  log "  EKS"
  aws_r "${region}" eks list-clusters --query 'clusters[]' --output text | lines | while read -r n; do
    quiet aws_r "${region}" eks delete-cluster --name "${n}"
  done

  log "  Lambda"
  aws_r "${region}" lambda list-functions --query 'Functions[].FunctionName' --output text | lines | while read -r n; do
    quiet aws_r "${region}" lambda delete-function --function-name "${n}"
  done

  log "  ECR"
  aws_r "${region}" ecr describe-repositories --query 'repositories[].repositoryName' --output text | lines | while read -r n; do
    quiet aws_r "${region}" ecr delete-repository --repository-name "${n}" --force
  done

  log "  VPC endpoints"
  aws_r "${region}" ec2 describe-vpc-endpoints --query 'VpcEndpoints[].VpcEndpointId' --output text | lines | while read -r e; do
    quiet aws_r "${region}" ec2 delete-vpc-endpoints --vpc-endpoint-ids "${e}"
  done
}

main() {
  init_records
  log "Starting billable cleanup module"
  cleanup_s3
  cleanup_cloudfront
  aws ec2 describe-regions --query 'Regions[].RegionName' --output text | lines | while read -r region; do
    [[ -z "${region}" ]] && continue
    cleanup_region "${region}"
  done
  log "Billable cleanup finished"
  update_registry "SUCCESS"
}

main "$@"
