#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="backup"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

# Do not disassociate continuous backups: that keeps data until retention expires.
# Permanently delete recovery points, then vaults. EFS automatic vault cannot be deleted.

EFS_VAULT="aws/efs/automatic-backup-vault"

rp_arns() {
  local region="$1"
  local vault="$2"
  aws_r "${region}" backup list-recovery-points-by-backup-vault \
    --backup-vault-name "${vault}" \
    --query 'RecoveryPoints[].RecoveryPointArn' --output text 2>/dev/null | lines | grep -v -x 'None' || true
}

rp_count() {
  local region="$1"
  local vault="$2"
  local n
  n="$(aws_r "${region}" backup describe-backup-vault --backup-vault-name "${vault}" \
    --query 'NumberOfRecoveryPoints' --output text 2>/dev/null || echo 0)"
  count_text "${n}"
}

# Default aws/efs/automatic-backup-vault policy Denies DeleteRecoveryPoint AND
# DeleteBackupVaultAccessPolicy. delete-backup-vault-access-policy therefore fails.
# Put Allow first (PutBackupVaultAccessPolicy is not denied).
allow_vault_deletes() {
  local region="$1"
  local vault="$2"
  local account policy
  account="$(aws sts get-caller-identity --query Account --output text)"
  policy="$(jq -n --arg p "arn:aws:iam::${account}:root" '{
    Version:"2012-10-17",
    Statement:[{
      Effect:"Allow",
      Principal:{AWS:$p},
      Action:[
        "backup:DeleteBackupVault",
        "backup:DeleteBackupVaultAccessPolicy",
        "backup:DeleteRecoveryPoint",
        "backup:StartCopyJob",
        "backup:StartRestoreJob",
        "backup:UpdateRecoveryPointLifecycle"
      ],
      Resource:"*"
    }]
  }')"
  log "  allow deletes on vault ${vault}"
  quiet aws_r "${region}" backup put-backup-vault-access-policy --backup-vault-name "${vault}" --policy "${policy}"
  quiet aws_r "${region}" backup delete-backup-vault-access-policy --backup-vault-name "${vault}"
}

disable_efs_auto_backup() {
  local region="$1"
  local fs
  aws_r "${region}" efs describe-file-systems --query 'FileSystems[].FileSystemId' --output text 2>/dev/null | lines | while read -r fs; do
    log "  disable EFS automatic backup ${fs}"
    quiet aws_r "${region}" efs put-backup-policy --file-system-id "${fs}" --backup-policy Status=DISABLED
  done
}

empty_vault() {
  local region="$1"
  local vault="$2"
  local arn n i

  quiet aws_r "${region}" backup delete-backup-vault-lock-configuration --backup-vault-name "${vault}"
  allow_vault_deletes "${region}" "${vault}"
  quiet aws_r "${region}" backup delete-backup-vault-notifications --backup-vault-name "${vault}"

  for i in 1 2 3 4 5 6; do
    while read -r arn; do
      [[ -z "${arn}" ]] && continue
      log "  delete recovery point ${arn}"
      quiet aws_r "${region}" backup delete-recovery-point --backup-vault-name "${vault}" --recovery-point-arn "${arn}"
    done < <(rp_arns "${region}" "${vault}")
    n="$(rp_count "${region}" "${vault}")"
    [[ "${n}" -eq 0 ]] && return 0
    sleep 10
  done
}

stop_jobs() {
  local region="$1"
  local id
  aws_r "${region}" backup list-backup-jobs --by-state RUNNING --query 'BackupJobs[].BackupJobId' --output text 2>/dev/null | lines | while read -r id; do
    log "  stop backup job ${id}"
    quiet aws_r "${region}" backup stop-backup-job --backup-job-id "${id}"
  done
  aws_r "${region}" backup list-backup-jobs --by-state CREATED --query 'BackupJobs[].BackupJobId' --output text 2>/dev/null | lines | while read -r id; do
    quiet aws_r "${region}" backup stop-backup-job --backup-job-id "${id}"
  done
  aws_r "${region}" backup list-copy-jobs --by-state RUNNING --query 'CopyJobs[].CopyJobId' --output text 2>/dev/null | lines | while read -r id; do
    log "  stop copy job ${id}"
    quiet aws_r "${region}" backup stop-copy-job --copy-job-id "${id}"
  done
}

cleanup_region() {
  local region="$1"
  local id name vault n

  disable_efs_auto_backup "${region}"
  stop_jobs "${region}"

  aws_r "${region}" backup list-legal-holds --query 'LegalHolds[?Status==`ACTIVE`].LegalHoldId' --output text 2>/dev/null | lines | while read -r id; do
    log "  cancel legal hold ${id}"
    quiet aws_r "${region}" backup cancel-legal-hold --legal-hold-id "${id}" --cancel-description reclaim
  done

  aws_r "${region}" backup list-report-plans --query 'ReportPlans[].ReportPlanName' --output text 2>/dev/null | lines | while read -r name; do
    log "  delete report plan ${name}"
    quiet aws_r "${region}" backup delete-report-plan --report-plan-name "${name}"
  done

  aws_r "${region}" backup list-restore-testing-plans --query 'RestoreTestingPlans[].RestoreTestingPlanName' --output text 2>/dev/null | lines | while read -r name; do
    log "  delete restore testing plan ${name}"
    quiet aws_r "${region}" backup delete-restore-testing-plan --restore-testing-plan-name "${name}"
  done

  aws_r "${region}" backup list-frameworks --query 'Frameworks[].FrameworkName' --output text 2>/dev/null | lines | while read -r name; do
    log "  delete framework ${name}"
    quiet aws_r "${region}" backup delete-framework --framework-name "${name}"
  done

  aws_r "${region}" backup list-backup-plans --query 'BackupPlansList[].BackupPlanId' --output text 2>/dev/null | lines | while read -r id; do
    aws_r "${region}" backup list-backup-selections --backup-plan-id "${id}" --query 'BackupSelectionsList[].SelectionId' --output text | lines | while read -r sel; do
      quiet aws_r "${region}" backup delete-backup-selection --backup-plan-id "${id}" --selection-id "${sel}"
    done
    log "  delete backup plan ${id}"
    quiet aws_r "${region}" backup delete-backup-plan --backup-plan-id "${id}"
  done

  aws_r "${region}" backup list-backup-vaults --query 'BackupVaultList[].BackupVaultName' --output text 2>/dev/null | lines | while read -r vault; do
    [[ -z "${vault}" || "${vault}" == "None" ]] && continue
    empty_vault "${region}" "${vault}"
    n="$(rp_count "${region}" "${vault}")"
    if [[ "${n}" -gt 0 ]]; then
      log "  vault ${vault} still has ${n} recovery points"
      continue
    fi
    if [[ "${vault}" == "${EFS_VAULT}" ]]; then
      verbose "  skip undeletable ${vault}"
      continue
    fi
    log "  delete vault ${vault}"
    quiet aws_r "${region}" backup delete-backup-vault --backup-vault-name "${vault}"
    quiet aws_r "${region}" backup delete-logically-air-gapped-vault --backup-vault-name "${vault}"
  done
}

init_records
while read -r region; do
  [[ -z "${region}" ]] && continue
  cleanup_region "${region}"
done < <(each_region)
update_registry "SUCCESS"
