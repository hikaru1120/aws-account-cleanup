#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="backup"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

empty_vault() {
  local region="$1"
  local vault="$2"
  local arn
  quiet aws_r "${region}" backup delete-backup-vault-lock-configuration --backup-vault-name "${vault}"
  aws_r "${region}" backup list-recovery-points-by-backup-vault --backup-vault-name "${vault}" \
    --query 'RecoveryPoints[].RecoveryPointArn' --output text | lines | while read -r arn; do
    log "  delete recovery point ${arn}"
    quiet aws_r "${region}" backup disassociate-recovery-point --backup-vault-name "${vault}" --recovery-point-arn "${arn}"
    quiet aws_r "${region}" backup delete-recovery-point --backup-vault-name "${vault}" --recovery-point-arn "${arn}"
  done
}

cleanup_region() {
  local region="$1"
  local id name vault

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
    empty_vault "${region}" "${vault}"
    empty_vault "${region}" "${vault}"
    log "  delete vault ${vault}"
    quiet aws_r "${region}" backup delete-backup-vault --backup-vault-name "${vault}"
  done
}

init_records
while read -r region; do
  [[ -z "${region}" ]] && continue
  cleanup_region "${region}"
done < <(each_region)
update_registry "SUCCESS"
