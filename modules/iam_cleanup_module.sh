#!/usr/bin/env bash
set -euo pipefail

# IAM user/role cleanup module
# Validation status: PENDING_SECONDARY_VERIFICATION
# Run in Cloud Shell: bash ./modules/iam_cleanup_module.sh

RECORD_DIR="${RECORD_DIR:-./verification}"
REGISTRY_FILE="${REGISTRY_FILE:-${RECORD_DIR}/module_validation_registry.json}"
RUN_LOG="${RECORD_DIR}/iam_cleanup_runs.log"
FAILED=()
CURRENT_ARN=""
CURRENT_USER=""
CURRENT_ROLE=""

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
    .modules.iam_cleanup_module.last_run_at=$now
    | .modules.iam_cleanup_module.last_result=$result
    | .modules.iam_cleanup_module.status="PENDING_SECONDARY_VERIFICATION"
  ' "${REGISTRY_FILE}" > "${tmp}" && mv "${tmp}" "${REGISTRY_FILE}"
}

current_identity() {
  local arn
  arn="$(aws sts get-caller-identity --query Arn --output text)"
  CURRENT_ARN="${arn}"
  CURRENT_USER=""
  CURRENT_ROLE=""
  if [[ "${arn}" == *":user/"* ]]; then
    CURRENT_USER="${arn##*:user/}"
  elif [[ "${arn}" == *":assumed-role/"* ]]; then
    CURRENT_ROLE="$(echo "${arn}" | sed -E 's#.*:assumed-role/([^/]+)/.*#\1#')"
  fi
  log "Caller: ${CURRENT_ARN}"
}

is_service_linked_role() {
  local name="$1"
  [[ "${name}" == AWSServiceRoleFor* ]] && return 0
  local path
  path="$(aws iam get-role --role-name "${name}" --query 'Role.Path' --output text 2>/dev/null || true)"
  [[ "${path}" == /aws-service-role/* ]]
}

delete_user() {
  local user="$1"
  log "==> IAM user: ${user}"

  if [[ -n "${CURRENT_USER}" && "${user}" == "${CURRENT_USER}" ]]; then
    log "   skip current user"
    return 0
  fi

  # 1) Access keys first
  aws iam list-access-keys --user-name "${user}" --query 'AccessKeyMetadata[].AccessKeyId' --output text \
    | tr '\t' '\n' | while read -r key; do
      [[ -z "${key}" ]] && continue
      log "   delete access key ${key}"
      quiet aws iam delete-access-key --user-name "${user}" --access-key-id "${key}"
    done

  # 2) Other credentials / login
  aws iam list-signing-certificates --user-name "${user}" --query 'Certificates[].CertificateId' --output text \
    | tr '\t' '\n' | while read -r cid; do
      [[ -z "${cid}" ]] && continue
      quiet aws iam delete-signing-certificate --user-name "${user}" --certificate-id "${cid}"
    done

  aws iam list-ssh-public-keys --user-name "${user}" --query 'SSHPublicKeys[].SSHPublicKeyId' --output text \
    | tr '\t' '\n' | while read -r sid; do
      [[ -z "${sid}" ]] && continue
      quiet aws iam delete-ssh-public-key --user-name "${user}" --ssh-public-key-id "${sid}"
    done

  aws iam list-service-specific-credentials --user-name "${user}" --query 'ServiceSpecificCredentials[].ServiceSpecificCredentialId' --output text \
    | tr '\t' '\n' | while read -r scid; do
      [[ -z "${scid}" ]] && continue
      quiet aws iam delete-service-specific-credential --user-name "${user}" --service-specific-credential-id "${scid}"
    done

  aws iam list-mfa-devices --user-name "${user}" --query 'MFADevices[].SerialNumber' --output text \
    | tr '\t' '\n' | while read -r serial; do
      [[ -z "${serial}" ]] && continue
      log "   deactivate MFA ${serial}"
      quiet aws iam deactivate-mfa-device --user-name "${user}" --serial-number "${serial}"
      quiet aws iam delete-virtual-mfa-device --serial-number "${serial}"
    done

  quiet aws iam delete-login-profile --user-name "${user}"

  # 3) Detach policies / groups
  aws iam list-attached-user-policies --user-name "${user}" --query 'AttachedPolicies[].PolicyArn' --output text \
    | tr '\t' '\n' | while read -r arn; do
      [[ -z "${arn}" ]] && continue
      quiet aws iam detach-user-policy --user-name "${user}" --policy-arn "${arn}"
    done

  aws iam list-user-policies --user-name "${user}" --query 'PolicyNames[]' --output text \
    | tr '\t' '\n' | while read -r pname; do
      [[ -z "${pname}" ]] && continue
      quiet aws iam delete-user-policy --user-name "${user}" --policy-name "${pname}"
    done

  aws iam list-groups-for-user --user-name "${user}" --query 'Groups[].GroupName' --output text \
    | tr '\t' '\n' | while read -r gname; do
      [[ -z "${gname}" ]] && continue
      quiet aws iam remove-user-from-group --user-name "${user}" --group-name "${gname}"
    done

  quiet aws iam delete-user-permissions-boundary --user-name "${user}"

  # 4) Delete user last
  if aws iam delete-user --user-name "${user}" >/dev/null 2>&1; then
    log "   deleted"
  else
    log "   FAILED"
    FAILED+=("user:${user}")
  fi
}

delete_role() {
  local role="$1"
  log "==> IAM role: ${role}"

  if [[ -n "${CURRENT_ROLE}" && "${role}" == "${CURRENT_ROLE}" ]]; then
    log "   skip current role"
    return 0
  fi

  if is_service_linked_role "${role}"; then
    log "   skip service-linked role"
    return 0
  fi

  aws iam list-instance-profiles-for-role --role-name "${role}" --query 'InstanceProfiles[].InstanceProfileName' --output text \
    | tr '\t' '\n' | while read -r ip; do
      [[ -z "${ip}" ]] && continue
      log "   remove from instance profile ${ip}"
      quiet aws iam remove-role-from-instance-profile --instance-profile-name "${ip}" --role-name "${role}"
    done

  aws iam list-attached-role-policies --role-name "${role}" --query 'AttachedPolicies[].PolicyArn' --output text \
    | tr '\t' '\n' | while read -r arn; do
      [[ -z "${arn}" ]] && continue
      quiet aws iam detach-role-policy --role-name "${role}" --policy-arn "${arn}"
    done

  aws iam list-role-policies --role-name "${role}" --query 'PolicyNames[]' --output text \
    | tr '\t' '\n' | while read -r pname; do
      [[ -z "${pname}" ]] && continue
      quiet aws iam delete-role-policy --role-name "${role}" --policy-name "${pname}"
    done

  quiet aws iam delete-role-permissions-boundary --role-name "${role}"

  if aws iam delete-role --role-name "${role}" >/dev/null 2>&1; then
    log "   deleted"
  else
    log "   FAILED"
    FAILED+=("role:${role}")
  fi
}

main() {
  init_records
  log "Starting IAM cleanup module"
  current_identity

  local users roles
  users="$(aws iam list-users --query 'Users[].UserName' --output text | tr '\t' '\n')"
  roles="$(aws iam list-roles --query 'Roles[].RoleName' --output text | tr '\t' '\n')"

  log "Users found: $(echo "${users}" | sed '/^$/d' | wc -l | tr -d ' ')"
  log "Roles found: $(echo "${roles}" | sed '/^$/d' | wc -l | tr -d ' ')"

  while read -r user; do
    [[ -z "${user}" ]] && continue
    delete_user "${user}"
  done <<< "${users}"

  while read -r role; do
    [[ -z "${role}" ]] && continue
    delete_role "${role}"
  done <<< "${roles}"

  if [[ "${#FAILED[@]}" -gt 0 ]]; then
    log "FAILED=${#FAILED[@]}"
    for item in "${FAILED[@]}"; do log " - ${item}"; done
    update_registry "PARTIAL_FAIL"
    exit 1
  fi

  log "IAM users and roles processed"
  update_registry "SUCCESS"
}

main "$@"
