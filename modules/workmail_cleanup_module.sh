#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="workmail"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

cleanup_org() {
  local region="$1"
  local org="$2"
  local id domain

  aws_r "${region}" workmail list-users --organization-id "${org}" \
    --query 'Users[?UserRole!=`SYSTEM_USER`].Id' --output text 2>/dev/null | lines | while read -r id; do
    quiet aws_r "${region}" workmail deregister-from-work-mail --organization-id "${org}" --entity-id "${id}"
    log "  delete user ${id}"
    quiet aws_r "${region}" workmail delete-user --organization-id "${org}" --user-id "${id}"
  done

  aws_r "${region}" workmail list-groups --organization-id "${org}" --query 'Groups[].Id' --output text 2>/dev/null | lines | while read -r id; do
    quiet aws_r "${region}" workmail deregister-from-work-mail --organization-id "${org}" --entity-id "${id}"
    log "  delete group ${id}"
    quiet aws_r "${region}" workmail delete-group --organization-id "${org}" --group-id "${id}"
  done

  aws_r "${region}" workmail list-resources --organization-id "${org}" --query 'Resources[].Id' --output text 2>/dev/null | lines | while read -r id; do
    quiet aws_r "${region}" workmail deregister-from-work-mail --organization-id "${org}" --entity-id "${id}"
    log "  delete resource ${id}"
    quiet aws_r "${region}" workmail delete-resource --organization-id "${org}" --resource-id "${id}"
  done

  aws_r "${region}" workmail list-mail-domains --organization-id "${org}" --query 'MailDomains[].DomainName' --output text 2>/dev/null | lines | while read -r domain; do
    log "  deregister domain ${domain}"
    quiet aws_r "${region}" workmail deregister-mail-domain --organization-id "${org}" --domain-name "${domain}"
  done

  log "  delete organization ${org}"
  quiet aws_r "${region}" workmail delete-organization --organization-id "${org}" --force-delete --no-delete-directory
}

cleanup_region() {
  local region="$1"
  local org
  aws_r "${region}" workmail list-organizations --query 'OrganizationSummaries[].OrganizationId' --output text 2>/dev/null | lines | while read -r org; do
    cleanup_org "${region}" "${org}"
  done
}

init_records
while read -r region; do
  [[ -z "${region}" ]] && continue
  cleanup_region "${region}"
done < <(each_region)
update_registry "SUCCESS"
