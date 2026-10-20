#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="waf"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

# Bill: AWS WAF
# Detach CloudFront (empty WebACLId) and regional resources, delete logging,
# then web ACLs, rule groups, IP sets, and regex pattern sets.
# Includes web ACLs CloudFront created. Skip Firewall Manager owned ACLs.
# A flat-rate CloudFront plan keeps its web ACL until that plan ends.

CF_WAIT_SECONDS="${CF_WAIT_SECONDS:-900}"
export AWS_PAGER=""
deleted_acl=0
skipped_fms=0
held_acl=0
held_err=""

fail() {
  local out="$1"
  shift
  out="$(printf '%s' "${out}" | tr '\n' ' ')"
  mkdir -p "$(dirname "${ERR_FILE}")"
  printf '%s\n' "[${MODULE_NAME}] $* | ${out}" >> "${ERR_FILE}"
  log "    FAIL ${out}"
  return 1
}

api_once() {
  local out
  if out="$(AWS_MAX_ATTEMPTS=1 AWS_RETRY_MODE=standard aws "$@" 2>&1)"; then
    printf '%s\n' "${out}"
    return 0
  fi
  printf '%s\n' "${out}" > /tmp/waf-api.err
  if [[ "${out}" == *Throttl* || "${out}" == *Rate\ exceeded* || "${out}" == *TooManyRequests* || "${out}" == *RequestLimitExceeded* ]]; then
    return 2
  fi
  return 1
}

api_retry() {
  local attempt=0 wait_s=8 rc
  while (( attempt < 8 )); do
    if api_once "$@"; then
      return 0
    fi
    rc=$?
    [[ "${rc}" -ne 2 ]] && return 1
    printf '%s\n' "[$(date '+%F %T')] [${MODULE_NAME}] throttled, retry in ${wait_s}s" >&2
    sleep "${wait_s}"
    [[ "${wait_s}" -lt 60 ]] && wait_s=$((wait_s * 2))
    attempt=$((attempt + 1))
  done
  echo "still throttled" > /tmp/waf-api.err
  return 2
}

err_text() {
  printf '%s' "$(cat /tmp/waf-api.err 2>/dev/null || true)" | tr '\n' ' '
}

plan_blocked_text() {
  local err="$1"
  [[ "${err}" == *[Pp]ricing*[Pp]lan* || "${err}" == *ubscribed* || "${err}" == *pay-as-you-go* || "${err}" == *must\ remain\ associated* || "${err}" == *flat-rate* || "${err}" == *Flat-rate* ]]
}

list_pages() {
  local key="$1"
  shift
  local marker="" page acc='[]' rc
  while :; do
    rc=0
    if [[ -n "${marker}" ]]; then
      page="$(api_retry "$@" --next-marker "${marker}" --limit 100 --output json)" || rc=$?
    else
      page="$(api_retry "$@" --limit 100 --output json)" || rc=$?
    fi
    if [[ "${rc}" -ne 0 || -z "${page}" ]]; then
      [[ "${rc}" -ne 0 ]] && log "  list failed: $(err_text)"
      printf '%s\n' "${acc}"
      return 0
    fi
    acc="$(jq -c --arg key "${key}" --argjson page "${page}" '. + (($page | .[$key]) // [])' <<<"${acc}" 2>/dev/null || printf '%s' "${acc}")"
    marker="$(jq -r '.NextMarker // empty' <<<"${page}" 2>/dev/null || true)"
    [[ -z "${marker}" || "${marker}" == "null" ]] && break
  done
  printf '%s\n' "${acc}"
}

in_file() {
  local needle="$1" file="$2"
  [[ -n "${needle}" && -f "${file}" ]] || return 1
  awk -F '\t' -v a="${needle}" 'index($0, a) && ($1 == a || $0 == a) { found=1 } END { exit !found }' "${file}"
}

remember_held() {
  local err="$1"
  held_acl=$((held_acl + 1))
  [[ -z "${held_err}" ]] && held_err="$(printf '%s' "${err}" | tr '\n' ' ')"
}

wait_deployed() {
  local id="$1" start status elapsed
  start="$(date +%s)"
  while :; do
    status="$(api_retry cloudfront get-distribution --id "${id}" --query 'Distribution.Status' --output text 2>/dev/null || echo unknown)"
    status="${status//$'\n'/}"
    [[ "${status}" == "Deployed" ]] && return 0
    elapsed=$(( $(date +%s) - start ))
    if [[ "${elapsed}" -ge "${CF_WAIT_SECONDS}" ]]; then
      log "  distribution ${id} still ${status} after ${elapsed}s"
      return 1
    fi
    log "    ${id} Status=${status} (${elapsed}s)"
    sleep 15
  done
}

clear_one_distribution() {
  local id="$1" cfg etag acl rc err
  rc=0
  cfg="$(api_retry cloudfront get-distribution-config --id "${id}" --output json)" || rc=$?
  if [[ "${rc}" -ne 0 || -z "${cfg}" ]]; then
    log "  could not read distribution ${id}"
    return 1
  fi
  acl="$(jq -r '.DistributionConfig.WebACLId // empty' <<<"${cfg}")"
  [[ -z "${acl}" || "${acl}" == "null" ]] && return 0
  etag="$(jq -r '.ETag // empty' <<<"${cfg}")"
  log "  detach web ACL from distribution ${id}"
  jq '.DistributionConfig | .WebACLId=""' <<<"${cfg}" > "/tmp/waf-cf-${id}.json"
  rc=0
  api_retry cloudfront update-distribution --id "${id}" --if-match "${etag}" --distribution-config "file:///tmp/waf-cf-${id}.json" >/dev/null || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    err="$(err_text)"
    if plan_blocked_text "${err}"; then
      printf '%s\n' "${acl}" >> /tmp/waf-blocked.txt
      log "  distribution ${id} keeps its web ACL until the CloudFront plan ends"
      remember_held "${err}"
      return 2
    fi
    fail "${err}" update-distribution "${id}" || true
    return 1
  fi
  sleep 2
  printf '%s\n' "${id}" >> /tmp/waf-updated.txt
  return 0
}

clear_cloudfront_web_acls() {
  local dists='{}' marker="" page id status
  : > /tmp/waf-assoc.txt
  : > /tmp/waf-blocked.txt
  : > /tmp/waf-updated.txt
  : > /tmp/waf-pending.txt
  page="$(api_retry cloudfront list-distributions --output json)" || page='{}'
  dists="${page}"
  marker="$(jq -r '.DistributionList.NextMarker // empty' <<<"${dists}" 2>/dev/null || true)"
  while [[ -n "${marker}" && "${marker}" != "null" ]]; do
    page="$(api_retry cloudfront list-distributions --marker "${marker}" --output json)" || page='{}'
    dists="$(jq -c --argjson page "${page}" '.DistributionList.Items += ($page.DistributionList.Items // [])' <<<"${dists}")"
    marker="$(jq -r '.DistributionList.NextMarker // empty' <<<"${page}" 2>/dev/null || true)"
  done
  while read -r id; do
    [[ -z "${id}" ]] && continue
    status="$(api_retry cloudfront get-distribution --id "${id}" --query 'Distribution.Status' --output text)" || status="unknown"
    status="${status//$'\n'/}"
    acl="$(api_retry cloudfront get-distribution-config --id "${id}" --query 'DistributionConfig.WebACLId' --output text)" || acl=""
    acl="${acl//$'\n'/}"
    acl="${acl//\"/}"
    [[ -z "${acl}" || "${acl}" == "None" || "${acl}" == "null" ]] && continue
    printf '%s\t%s\n' "${acl}" "${id}" >> /tmp/waf-assoc.txt
    if [[ "${status}" != "Deployed" ]]; then
      printf '%s\n' "${id}" >> /tmp/waf-pending.txt
      continue
    fi
    clear_one_distribution "${id}" || true
  done < <(jq -r '.DistributionList.Items[]?.Id // empty' <<<"${dists}" 2>/dev/null || true)
}

detach_regional() {
  local region="$1" arn="$2" rtype resources rid rc err
  for rtype in "" APPLICATION_LOAD_BALANCER API_GATEWAY APPSYNC COGNITO_USER_POOL APP_RUNNER_SERVICE VERIFIED_ACCESS_INSTANCE; do
    if [[ -n "${rtype}" ]]; then
      resources="$(list_pages ResourceArns wafv2 --region "${region}" list-resources-for-web-acl --web-acl-arn "${arn}" --resource-type "${rtype}")"
    else
      resources="$(list_pages ResourceArns wafv2 --region "${region}" list-resources-for-web-acl --web-acl-arn "${arn}")"
    fi
    while read -r rid; do
      [[ -z "${rid}" ]] && continue
      log "  disassociate ${rid}"
      rc=0
      api_retry wafv2 --region "${region}" disassociate-web-acl --resource-arn "${rid}" >/dev/null || rc=$?
      if [[ "${rc}" -ne 0 ]]; then
        err="$(err_text)"
        plan_blocked_text "${err}" && remember_held "${err}" || fail "${err}" disassociate-web-acl "${rid}" || true
      fi
    done < <(jq -r '.[]? | strings' <<<"${resources}" 2>/dev/null || true)
  done
}

delete_v2_acl() {
  local region="$1" scope="$2" name="$3" id="$4" raw token arn managed rc err
  rc=0
  raw="$(api_retry wafv2 --region "${region}" get-web-acl --name "${name}" --scope "${scope}" --id "${id}" --output json)" || rc=$?
  if [[ "${rc}" -ne 0 || -z "${raw}" ]]; then
    err="$(err_text)"
    [[ "${err}" == *Nonexistent* ]] && return 0
    fail "${err}" get-web-acl "${name}" || true
    return 1
  fi
  managed="$(jq -r '.WebACL.ManagedByFirewallManager // false' <<<"${raw}")"
  if [[ "${managed}" == "true" ]]; then
    log "  skip ${name}: Firewall Manager owns it"
    skipped_fms=$((skipped_fms + 1))
    return 0
  fi
  token="$(jq -r '.LockToken // empty' <<<"${raw}")"
  arn="$(jq -r '.WebACL.ARN // empty' <<<"${raw}")"
  if [[ -n "${arn}" ]]; then
    api_retry wafv2 --region "${region}" delete-logging-configuration --resource-arn "${arn}" >/dev/null || true
    [[ "${scope}" == "REGIONAL" ]] && detach_regional "${region}" "${arn}"
  fi
  if in_file "${arn}" /tmp/waf-blocked.txt || in_file "${id}" /tmp/waf-blocked.txt; then
    log "  ${name} stays until the CloudFront plan ends"
    return 0
  fi
  log "  delete web ACL ${name} (${scope})"
  rc=0
  api_retry wafv2 --region "${region}" delete-web-acl --name "${name}" --scope "${scope}" --id "${id}" --lock-token "${token}" >/dev/null || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    err="$(err_text)"
    if [[ "${err}" == *OptimisticLock* ]]; then
      token="$(api_retry wafv2 --region "${region}" get-web-acl --name "${name}" --scope "${scope}" --id "${id}" --query 'LockToken' --output text)" || token=""
      token="${token//$'\n'/}"
      rc=0
      api_retry wafv2 --region "${region}" delete-web-acl --name "${name}" --scope "${scope}" --id "${id}" --lock-token "${token}" >/dev/null || rc=$?
      err="$(err_text)"
    fi
  fi
  if [[ "${rc}" -ne 0 ]]; then
    if plan_blocked_text "${err}" || [[ "${err}" == *Associated* ]]; then
      printf '%s\n' "${arn}" >> /tmp/waf-blocked.txt
      log "  ${name} still associated; left in place"
      remember_held "${err}"
      return 0
    fi
    fail "${err}" delete-web-acl "${name}" || true
    return 1
  fi
  deleted_acl=$((deleted_acl + 1))
  sleep 1
}

delete_v2_acls() {
  local region="$1" scope="$2" only_attached="${3:-0}" items row name id arn n
  items="$(list_pages WebACLs wafv2 --region "${region}" list-web-acls --scope "${scope}")"
  n="$(jq -r 'length' <<<"${items}" 2>/dev/null || echo 0)"
  [[ "${only_attached}" == "0" && "${n}" != "0" ]] && log "  ${scope} ${region}: ${n} web ACLs"
  while read -r row; do
    [[ -z "${row}" ]] && continue
    name="$(jq -r '.Name // empty' <<<"${row}")"
    id="$(jq -r '.Id // empty' <<<"${row}")"
    arn="$(jq -r '.ARN // empty' <<<"${row}")"
    [[ -z "${name}" || -z "${id}" ]] && continue
    if [[ "${only_attached}" == "0" ]]; then
      if in_file "${arn}" /tmp/waf-assoc.txt || in_file "${id}" /tmp/waf-assoc.txt; then
        continue
      fi
    else
      if ! in_file "${arn}" /tmp/waf-assoc.txt && ! in_file "${id}" /tmp/waf-assoc.txt; then
        continue
      fi
    fi
    delete_v2_acl "${region}" "${scope}" "${name}" "${id}" || true
  done < <(jq -c '.[]?' <<<"${items}" 2>/dev/null || true)
}

delete_named() {
  local region="$1" scope="$2" list_api="$3" key="$4" del_api="$5" get_api="$6"
  local items row name id token rc err
  items="$(list_pages "${key}" wafv2 --region "${region}" "${list_api}" --scope "${scope}")"
  while read -r row; do
    [[ -z "${row}" ]] && continue
    name="$(jq -r '.Name // empty' <<<"${row}")"
    id="$(jq -r '.Id // empty' <<<"${row}")"
    token="$(jq -r '.LockToken // empty' <<<"${row}")"
    [[ -z "${name}" || -z "${id}" || -z "${token}" ]] && continue
    log "  delete ${del_api} ${name} (${scope} ${region})"
    rc=0
    api_retry wafv2 --region "${region}" "${del_api}" --name "${name}" --scope "${scope}" --id "${id}" --lock-token "${token}" >/dev/null || rc=$?
    if [[ "${rc}" -ne 0 && "$(err_text)" == *OptimisticLock* ]]; then
      token="$(api_retry wafv2 --region "${region}" "${get_api}" --name "${name}" --scope "${scope}" --id "${id}" --query 'LockToken' --output text)" || token=""
      token="${token//$'\n'/}"
      rc=0
      api_retry wafv2 --region "${region}" "${del_api}" --name "${name}" --scope "${scope}" --id "${id}" --lock-token "${token}" >/dev/null || rc=$?
    fi
    if [[ "${rc}" -ne 0 ]]; then
      err="$(err_text)"
      if [[ "${err}" == *Associated* || "${err}" == *referenced* || "${err}" == *"in use"* ]]; then
        log "  ${name} still referenced"
      else
        fail "${err}" "${del_api}" "${name}" || true
      fi
    fi
    sleep 1
  done < <(jq -c '.[]?' <<<"${items}" 2>/dev/null || true)
}

cleanup_scope() {
  local region="$1" scope="$2"
  delete_v2_acls "${region}" "${scope}" 0
  delete_named "${region}" "${scope}" list-rule-groups RuleGroups delete-rule-group get-rule-group
  delete_named "${region}" "${scope}" list-ip-sets IPSets delete-ip-set get-ip-set
  delete_named "${region}" "${scope}" list-regex-pattern-sets RegexPatternSets delete-regex-pattern-set get-regex-pattern-set
}

classic_token() {
  local cli="$1" region="$2" token
  token="$(api_retry "${cli}" --region "${region}" get-change-token --query 'ChangeToken' --output text)" || return 1
  printf '%s' "${token}" | tr -d '\n"'
}

classic_web_acls() {
  local cli="$1" region="$2" only_attached="${3:-0}" items row id name token rules rc err raw
  items="$(list_pages WebACLs "${cli}" --region "${region}" list-web-acls)"
  while read -r row; do
    [[ -z "${row}" ]] && continue
    id="$(jq -r '.WebACLId // empty' <<<"${row}")"
    name="$(jq -r '.Name // empty' <<<"${row}")"
    [[ -z "${id}" ]] && continue
    if [[ "${only_attached}" == "0" ]]; then
      in_file "${id}" /tmp/waf-assoc.txt && continue
    elif ! in_file "${id}" /tmp/waf-assoc.txt; then
      continue
    fi
    if in_file "${id}" /tmp/waf-blocked.txt; then
      log "  classic ${name:-${id}} stays until the CloudFront plan ends"
      continue
    fi
    raw="$(api_retry "${cli}" --region "${region}" get-web-acl --web-acl-id "${id}" --output json)" || continue
    rules="$(jq -c '.WebACL.Rules // []' <<<"${raw}")"
    if [[ "${rules}" != "[]" ]]; then
      token="$(classic_token "${cli}" "${region}")" || continue
      jq -n --arg id "${id}" --arg token "${token}" --argjson rules "${rules}" \
        '{WebACLId:$id, ChangeToken:$token, Updates:[ $rules[] | {Action:"DELETE", ActivatedRule:.} ]}' > /tmp/waf-classic.json
      api_retry "${cli}" --region "${region}" update-web-acl --cli-input-json file:///tmp/waf-classic.json >/dev/null || true
    fi
    token="$(classic_token "${cli}" "${region}")" || continue
    log "  delete classic web ACL ${name:-${id}} (${region})"
    rc=0
    api_retry "${cli}" --region "${region}" delete-web-acl --web-acl-id "${id}" --change-token "${token}" >/dev/null || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
      err="$(err_text)"
      if plan_blocked_text "${err}" || [[ "${err}" == *Associated* || "${err}" == *referenced* ]]; then
        remember_held "${err}"
      else
        fail "${err}" delete-web-acl "${id}" || true
      fi
    else
      deleted_acl=$((deleted_acl + 1))
    fi
  done < <(jq -c '.[]?' <<<"${items}" 2>/dev/null || true)

  [[ "${only_attached}" == "1" ]] && return 0
  items="$(list_pages Rules "${cli}" --region "${region}" list-rules)"
  while read -r row; do
    [[ -z "${row}" ]] && continue
    id="$(jq -r '.RuleId // empty' <<<"${row}")"
    [[ -z "${id}" ]] && continue
    token="$(classic_token "${cli}" "${region}")" || continue
    log "  delete classic rule ${id}"
    api_retry "${cli}" --region "${region}" delete-rule --rule-id "${id}" --change-token "${token}" >/dev/null || true
  done < <(jq -c '.[]?' <<<"${items}" 2>/dev/null || true)
}

finish_attached() {
  local id
  while read -r id; do
    [[ -z "${id}" ]] && continue
    wait_deployed "${id}" || true
    clear_one_distribution "${id}" || true
  done < /tmp/waf-pending.txt
  while read -r id; do
    [[ -z "${id}" ]] && continue
    wait_deployed "${id}" || true
  done < /tmp/waf-updated.txt
  delete_v2_acls us-east-1 CLOUDFRONT 1
  classic_web_acls waf us-east-1 1
}

init_records
log "detach associations, then delete web ACLs, rule groups, IP sets, and regex pattern sets"
clear_cloudfront_web_acls

cleanup_scope us-east-1 CLOUDFRONT
while read -r region; do
  [[ -z "${region}" ]] && continue
  cleanup_scope "${region}" REGIONAL
done < <(each_region)

classic_web_acls waf us-east-1
while read -r region; do
  [[ -z "${region}" ]] && continue
  classic_web_acls waf-regional "${region}"
done < <(each_region)

finish_attached

log "deleted ${deleted_acl} web ACLs, skipped ${skipped_fms} Firewall Manager ACLs, left ${held_acl} because AWS still requires them"
[[ -n "${held_err}" ]] && log "  ${held_err}"
update_registry "SUCCESS"
