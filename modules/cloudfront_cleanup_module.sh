#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="cloudfront"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

# Bill: Amazon CloudFront
# Pay-as-you-go is not a distribution field. Cancel the flat-rate subscription first.
# Free plans end immediately; Pro/Business/Premium stay until the billing period ends.
# Then delete tenants, detach continuous deployment, disable, wait Deployed, delete.
# Skip WAF, Route53, and KeyValueStore that were bundled on the plan.

CF_WAIT_SECONDS="${CF_WAIT_SECONDS:-900}"
export AWS_PAGER=""

fail() {
  local out="$1"
  shift
  out="$(printf '%s' "${out}" | tr '\n' ' ')"
  mkdir -p "$(dirname "${ERR_FILE}")"
  printf '%s\n' "[${MODULE_NAME}] $* | ${out}" >> "${ERR_FILE}"
  log "    FAIL ${out}"
  return 1
}

# One Pricing Plan Manager call. Stdout is the JSON body only, so callers can capture it.
# Return 2 when the service throttles. CLI retries are disabled so they do not burn the quota.
ppm_once() {
  local out
  if out="$(AWS_MAX_ATTEMPTS=1 AWS_RETRY_MODE=standard aws pricing-plan-manager --region us-east-1 "$@" 2>&1)"; then
    printf '%s\n' "${out}"
    return 0
  fi
  printf '%s\n' "${out}" > /tmp/cf-ppm.err
  if [[ "${out}" == *TooManyRequests* || "${out}" == *Throttl* || "${out}" == *RequestLimitExceeded* ]]; then
    return 2
  fi
  return 1
}

ppm_retry() {
  local attempt=0 wait_s=8 rc
  while (( attempt < 8 )); do
    if ppm_once "$@"; then
      return 0
    fi
    rc=$?
    if [[ "${rc}" -ne 2 ]]; then
      return 1
    fi
    printf '%s\n' "[$(date '+%F %T')] [${MODULE_NAME}] throttled, retry in ${wait_s}s" >&2
    sleep "${wait_s}"
    if [[ "${wait_s}" -lt 60 ]]; then
      wait_s=$((wait_s * 2))
    fi
    attempt=$((attempt + 1))
  done
  echo "still throttled" > /tmp/cf-ppm.err
  return 1
}

try() {
  local out
  if ! out="$("$@" 2>&1)"; then
    fail "${out}" "$@"
    return 1
  fi
}

list_cf_subs() {
  local token="" page acc='[]'
  while :; do
    if [[ -n "${token}" ]]; then
      page="$(ppm_retry list-subscriptions --next-token "${token}" --output json)" || return 1
    else
      page="$(ppm_retry list-subscriptions --output json)" || return 1
    fi
    acc="$(jq -c --argjson page "${page}" '. + [($page.subscriptionSummaries // [])[] | select(.planFamily=="CloudFront")]' <<<"${acc}")" || return 1
    token="$(jq -r '.nextToken // empty' <<<"${page}")"
    [[ -z "${token}" ]] && break
  done
  printf '%s\n' "${acc}"
}

cancel_plans() {
  local subs="$1" sub arn etag tier status change err
  printf '%s\n' "${subs}" | jq -c '.[]' | while read -r sub; do
    [[ -z "${sub}" ]] && continue
    arn="$(jq -r '.arn' <<<"${sub}")"
    etag="$(jq -r '.eTag // .ETag // empty' <<<"${sub}")"
    tier="$(jq -r '.planTier // "unknown"' <<<"${sub}")"
    status="$(jq -r '.status // "unknown"' <<<"${sub}")"
    change="$(jq -r '.scheduledChange.changeType // empty' <<<"${sub}")"
    [[ -z "${arn}" || -z "${etag}" ]] && continue
    if [[ "${change}" == "CANCELLATION" ]]; then
      log "  plan already cancelling tier=${tier} ${arn}"
      continue
    fi
    if [[ "${change}" == "DOWNGRADE" ]]; then
      log "  undo pending downgrade tier=${tier} ${arn}"
      ppm_retry cancel-subscription-change --arn "${arn}" --if-match "${etag}" >/dev/null || fail "$(cat /tmp/cf-ppm.err 2>/dev/null || true)" cancel-subscription-change "${arn}" || true
      sleep 5
      continue
    fi
    if [[ "${status}" == "SYNC_IN_PROGRESS" ]]; then
      log "  plan syncing tier=${tier} ${arn}"
      continue
    fi
    log "  cancel plan tier=${tier} status=${status} ${arn}"
    if ! ppm_retry cancel-subscription --arn "${arn}" --if-match "${etag}" >/dev/null; then
      err="$(cat /tmp/cf-ppm.err 2>/dev/null || true)"
      if [[ "${err}" == *Conflict* || "${err}" == *Precondition* ]]; then
        etag="$(ppm_retry get-subscription --arn "${arn}" --output json | jq -r '.eTag // .subscription.eTag // .ETag // empty' || true)"
        if [[ -n "${etag}" ]] && ppm_retry cancel-subscription --arn "${arn}" --if-match "${etag}" >/dev/null; then
          :
        else
          fail "$(cat /tmp/cf-ppm.err 2>/dev/null || true)" cancel-subscription "${arn}" || true
        fi
      else
        fail "${err}" cancel-subscription "${arn}" || true
      fi
    fi
    sleep 5
  done || true
}

wait_plans_settled() {
  local deadline syncing downgrade
  deadline=$((SECONDS + 480))
  while (( SECONDS < deadline )); do
    subs="$(list_cf_subs)" || return 1
    syncing="$(jq '[.[] | select(.status=="SYNC_IN_PROGRESS")] | length' <<<"${subs}")"
    downgrade="$(jq '[.[] | select(.scheduledChange.changeType=="DOWNGRADE")] | length' <<<"${subs}")"
    if [[ "${syncing}" == "0" && "${downgrade}" == "0" ]]; then
      return 0
    fi
    if [[ "${downgrade}" != "0" ]]; then
      cancel_plans "${subs}"
    fi
    log "  plans syncing=${syncing} downgrade=${downgrade}"
    sleep 15
  done
}

wait_distribution() {
  local id="$1" want_disabled="${2:-0}"
  local start now elapsed status enabled
  start="$(date +%s)"
  while true; do
    now="$(date +%s)"
    elapsed=$((now - start))
    if [[ "${elapsed}" -ge "${CF_WAIT_SECONDS}" ]]; then
      log "    ${id} still not ready after ${elapsed}s"
      return 1
    fi
    status="$(aws cloudfront get-distribution --id "${id}" --query 'Distribution.Status' --output text 2>/dev/null || echo unknown)"
    enabled="$(aws cloudfront get-distribution --id "${id}" --query 'Distribution.DistributionConfig.Enabled' --output text 2>/dev/null || echo unknown)"
    log "    ${id} Status=${status} Enabled=${enabled} (${elapsed}s)"
    if [[ "${status}" == "Deployed" ]]; then
      if [[ "${want_disabled}" == "0" || "${enabled}" == "False" || "${enabled}" == "false" ]]; then
        return 0
      fi
    fi
    sleep 15
  done
}

disable_distribution() {
  local id="$1" cfg etag enabled policy attempt
  for attempt in 1 2 3; do
    wait_distribution "${id}" 0 || return 1
    cfg="$(aws cloudfront get-distribution-config --id "${id}" --output json 2>/tmp/cf-dist.err)" || {
      fail "$(cat /tmp/cf-dist.err)" get-distribution-config "${id}" || true
      return 1
    }
    etag="$(jq -r '.ETag' <<<"${cfg}")"
    enabled="$(jq -r '.DistributionConfig.Enabled' <<<"${cfg}")"
    policy="$(jq -r '.DistributionConfig.ContinuousDeploymentPolicyId // empty' <<<"${cfg}")"
    if [[ "${enabled}" == "false" && -z "${policy}" ]]; then
      return 0
    fi
    log "  disable ${id}"
    jq '.DistributionConfig | .Enabled=false | del(.ContinuousDeploymentPolicyId)' <<<"${cfg}" >"/tmp/cf-${id}.json"
    if try aws cloudfront update-distribution --id "${id}" --if-match "${etag}" --distribution-config "file:///tmp/cf-${id}.json"; then
      wait_distribution "${id}" 1 || return 1
      return 0
    fi
    log "    update ${id} retry ${attempt}"
    sleep 20
  done
  return 1
}

delete_distribution() {
  local id="$1" etag
  etag="$(aws cloudfront get-distribution-config --id "${id}" --query 'ETag' --output text 2>/dev/null || true)"
  [[ -z "${etag}" || "${etag}" == "None" ]] && return 1
  log "  delete ${id}"
  try aws cloudfront delete-distribution --id "${id}" --if-match "${etag}"
}

delete_tenants() {
  local items='[]' marker="" prev="" page tid parent traw tetag tenabled tstatus tstart elapsed
  blocked_parents=" "
  while :; do
    if [[ -n "${marker}" ]]; then
      page="$(aws cloudfront list-distribution-tenants --marker "${marker}" --output json 2>/tmp/cf-tenant.err)" || return 1
    else
      page="$(aws cloudfront list-distribution-tenants --output json 2>/tmp/cf-tenant.err)" || return 1
    fi
    items="$(jq -c --argjson page "${page}" '. + ($page.DistributionTenantList.Items // [])' <<<"${items}")"
    prev="${marker}"
    marker="$(jq -r '.DistributionTenantList.NextMarker // .NextMarker // empty' <<<"${page}")"
    [[ -z "${marker}" || "${marker}" == "${prev}" ]] && break
  done
  while read -r tid; do
    [[ -z "${tid}" ]] && continue
    parent="$(jq -r --arg id "${tid}" '.[] | select(.Id==$id) | .DistributionId // empty' <<<"${items}")"
    traw="$(aws cloudfront get-distribution-tenant --id "${tid}" --output json 2>/tmp/cf-tenant.err)" || \
      traw="$(aws cloudfront get-distribution-tenant --identifier "${tid}" --output json 2>/tmp/cf-tenant.err)" || {
        log "  tenant ${tid} unreadable, keep parent ${parent}"
        blocked_parents+="${parent} "
        continue
      }
    tetag="$(jq -r '.ETag' <<<"${traw}")"
    tenabled="$(jq -r '.DistributionTenant.Enabled' <<<"${traw}")"
    if [[ "${tenabled}" == "true" ]]; then
      log "  disable tenant ${tid}"
      try aws cloudfront update-distribution-tenant --id "${tid}" --if-match "${tetag}" --no-enabled || {
        blocked_parents+="${parent} "
        continue
      }
    fi
    tstart="$(date +%s)"
    tenabled="true"
    tstatus="InProgress"
    while true; do
      elapsed=$(( $(date +%s) - tstart ))
      if [[ "${elapsed}" -ge "${CF_WAIT_SECONDS}" ]]; then
        log "  tenant ${tid} not Deployed after ${elapsed}s"
        blocked_parents+="${parent} "
        tenabled="true"
        break
      fi
      traw="$(aws cloudfront get-distribution-tenant --id "${tid}" --output json 2>/dev/null || aws cloudfront get-distribution-tenant --identifier "${tid}" --output json 2>/dev/null || true)"
      [[ -z "${traw}" ]] && { sleep 15; continue; }
      tstatus="$(jq -r '.DistributionTenant.Status' <<<"${traw}")"
      tenabled="$(jq -r '.DistributionTenant.Enabled' <<<"${traw}")"
      log "    tenant ${tid} Status=${tstatus} Enabled=${tenabled} (${elapsed}s)"
      [[ "${tenabled}" == "false" && "${tstatus}" == "Deployed" ]] && break
      sleep 15
    done
    [[ "${tenabled}" == "false" && "${tstatus}" == "Deployed" ]] || continue
    tetag="$(jq -r '.ETag' <<<"${traw}")"
    log "  delete tenant ${tid}"
    try aws cloudfront delete-distribution-tenant --id "${tid}" --if-match "${tetag}" || blocked_parents+="${parent} "
  done < <(jq -r '.[]?.Id' <<<"${items}")
}

delete_policies() {
  local policies pid petag
  policies="$(aws cloudfront list-continuous-deployment-policies --output json 2>/tmp/cf-cd.err)" || {
    grep -Eqi 'invalid choice|unknown operation' /tmp/cf-cd.err || fail "$(cat /tmp/cf-cd.err)" list-continuous-deployment-policies || true
    return 0
  }
  while read -r pid; do
    [[ -z "${pid}" ]] && continue
    petag="$(aws cloudfront get-continuous-deployment-policy --id "${pid}" --query 'ETag' --output text 2>/dev/null || true)"
    [[ -z "${petag}" || "${petag}" == "None" ]] && continue
    log "  delete continuous deployment policy ${pid}"
    try aws cloudfront delete-continuous-deployment-policy --id "${pid}" --if-match "${petag}" || true
  done < <(jq -r '[.ContinuousDeploymentPolicyList.Items[]?.ContinuousDeploymentPolicy.Id, .ContinuousDeploymentPolicyList.Items[]?.Id] | .[] | select(. != null)' <<<"${policies}")
}

cleanup_after_distributions() {
  local groups gid graw getag anycast aid aetag vpcs vid vetag streaming sid sraw setag sstatus senabled sstart elapsed
  if groups="$(aws cloudfront list-connection-groups --output json 2>/tmp/cf-cg.err)"; then
    while read -r gid; do
      [[ -z "${gid}" ]] && continue
      graw="$(aws cloudfront get-connection-group --id "${gid}" --output json 2>/tmp/cf-cg.err || aws cloudfront get-connection-group --identifier "${gid}" --output json 2>/tmp/cf-cg.err || true)"
      [[ -z "${graw}" ]] && continue
      if [[ "$(jq -r '.ConnectionGroup.IsDefault // .IsDefault // false' <<<"${graw}")" == "true" ]]; then
        log "  keep default connection group ${gid}"
        continue
      fi
      getag="$(jq -r '.ETag' <<<"${graw}")"
      if [[ "$(jq -r '.ConnectionGroup.Enabled // true' <<<"${graw}")" == "true" ]]; then
        try aws cloudfront update-connection-group --id "${gid}" --if-match "${getag}" --no-enabled || true
        graw="$(aws cloudfront get-connection-group --id "${gid}" --output json 2>/dev/null || true)"
        getag="$(jq -r '.ETag // empty' <<<"${graw:-null}")"
      fi
      [[ -z "${getag}" || "${getag}" == "null" ]] && continue
      log "  delete connection group ${gid}"
      try aws cloudfront delete-connection-group --id "${gid}" --if-match "${getag}" || true
    done < <(jq -r '[.ConnectionGroups[]?.Id, .ConnectionGroupList.Items[]?.Id] | .[] | select(. != null)' <<<"${groups}")
  fi

  if anycast="$(aws cloudfront list-anycast-ip-lists --output json 2>/tmp/cf-ip.err)"; then
    while read -r aid; do
      [[ -z "${aid}" ]] && continue
      aetag="$(aws cloudfront get-anycast-ip-list --id "${aid}" --query 'ETag' --output text 2>/dev/null || true)"
      [[ -z "${aetag}" || "${aetag}" == "None" ]] && continue
      log "  delete anycast ip list ${aid}"
      try aws cloudfront delete-anycast-ip-list --id "${aid}" --if-match "${aetag}" || true
    done < <(jq -r '[.AnycastIpLists.Items[]?.Id, .AnycastIpListList.Items[]?.Id, .AnycastIpLists[]?.Id] | .[] | select(. != null)' <<<"${anycast}")
  fi

  if vpcs="$(aws cloudfront list-vpc-origins --output json 2>/tmp/cf-vpc.err)"; then
    while read -r vid; do
      [[ -z "${vid}" ]] && continue
      vetag="$(aws cloudfront get-vpc-origin --id "${vid}" --query 'ETag' --output text 2>/dev/null || true)"
      [[ -z "${vetag}" || "${vetag}" == "None" ]] && continue
      log "  delete vpc origin ${vid}"
      try aws cloudfront delete-vpc-origin --id "${vid}" --if-match "${vetag}" || true
    done < <(jq -r '[.VpcOriginList.Items[]?.Id, .VpcOrigins.Items[]?.Id] | .[] | select(. != null)' <<<"${vpcs}")
  fi

  if streaming="$(aws cloudfront list-streaming-distributions --output json 2>/tmp/cf-rtmp.err)"; then
    while read -r sid; do
      [[ -z "${sid}" ]] && continue
      sraw="$(aws cloudfront get-streaming-distribution-config --id "${sid}" --output json 2>/dev/null || true)"
      [[ -z "${sraw}" ]] && continue
      setag="$(jq -r '.ETag' <<<"${sraw}")"
      if [[ "$(jq -r '.StreamingDistributionConfig.Enabled' <<<"${sraw}")" == "true" ]]; then
        log "  disable streaming ${sid}"
        jq '.StreamingDistributionConfig | .Enabled=false' <<<"${sraw}" >"/tmp/cf-rtmp-${sid}.json"
        try aws cloudfront update-streaming-distribution --id "${sid}" --if-match "${setag}" --streaming-distribution-config "file:///tmp/cf-rtmp-${sid}.json" || continue
        sstart="$(date +%s)"
        while true; do
          elapsed=$(( $(date +%s) - sstart ))
          [[ "${elapsed}" -ge "${CF_WAIT_SECONDS}" ]] && break
          sstatus="$(aws cloudfront get-streaming-distribution --id "${sid}" --query 'StreamingDistribution.Status' --output text 2>/dev/null || echo unknown)"
          senabled="$(aws cloudfront get-streaming-distribution --id "${sid}" --query 'StreamingDistribution.StreamingDistributionConfig.Enabled' --output text 2>/dev/null || echo unknown)"
          log "    streaming ${sid} Status=${sstatus} Enabled=${senabled} (${elapsed}s)"
          [[ "${sstatus}" == "Deployed" && ( "${senabled}" == "False" || "${senabled}" == "false" ) ]] && break
          sleep 15
        done
      fi
      setag="$(aws cloudfront get-streaming-distribution-config --id "${sid}" --query 'ETag' --output text 2>/dev/null || true)"
      [[ -z "${setag}" || "${setag}" == "None" ]] && continue
      log "  delete streaming ${sid}"
      try aws cloudfront delete-streaming-distribution --id "${sid}" --if-match "${setag}" || true
    done < <(jq -r '.StreamingDistributionList.Items[]?.Id' <<<"${streaming}")
  fi
}

init_records
log "cancel flat-rate plans so distributions return to pay-as-you-go"
if ! subs="$(list_cf_subs)"; then
  log "cannot list pricing plans; CloudFront distributions were not disabled or deleted"
  cat /tmp/cf-ppm.err >> "${ERR_FILE}" 2>/dev/null || true
  update_registry "SUCCESS"
  exit 0
fi
cancel_plans "${subs}"
if ! wait_plans_settled; then
  log "cannot refresh pricing plans; CloudFront distributions were not disabled or deleted"
  update_registry "SUCCESS"
  exit 0
fi
cancel_plans "${subs}"
if ! wait_plans_settled; then
  log "cannot refresh pricing plans; CloudFront distributions were not disabled or deleted"
  update_registry "SUCCESS"
  exit 0
fi

locked=" "
while read -r row; do
  [[ -z "${row}" ]] && continue
  dist_id="${row%%$'\t'*}"
  rest="${row#*$'\t'}"
  tier="${rest%%$'\t'*}"
  when="${rest#*$'\t'}"
  locked+="${dist_id} "
  log "  skip ${dist_id} plan=${tier} pay-as-you-go at ${when}; re-run after that"
done < <(jq -r '.[] | . as $s | ($s.resourceArns // [])[] | select(test("distribution/")) | "\(split("/")[-1])\t\($s.planTier // "unknown")\t\($s.scheduledChange.effectiveDate // $s.status // "pending")"' <<<"${subs}")

jq -r '.[] | (.resourceArns // [])[] | select(test("distribution/")|not)' <<<"${subs}" | while read -r arn; do
  [[ -n "${arn}" ]] && log "  plan resource left in place ${arn}"
done || true

plan_blocks() {
  [[ "${locked}" == *" $1 "* || "${subs}" == *"distribution/${1}\""* ]]
}

if ! delete_tenants; then
  if grep -Eqi 'invalid choice|unknown operation' /tmp/cf-tenant.err 2>/dev/null; then
    verbose "distribution tenant API unavailable"
  else
    log "  list tenants failed; continuing with standard distributions"
    cat /tmp/cf-tenant.err >> "${ERR_FILE}" 2>/dev/null || true
  fi
  blocked_parents=" "
fi

dists="$(aws cloudfront list-distributions --output json 2>/dev/null || echo '{}')"
primary_ids="$(jq -r '.DistributionList.Items[]? | select(.Staging!=true) | .Id' <<<"${dists}")"
staging_ids="$(jq -r '.DistributionList.Items[]? | select(.Staging==true) | .Id' <<<"${dists}")"
ready=" "

while read -r id; do
  [[ -z "${id}" ]] && continue
  if plan_blocks "${id}"; then
    log "  skip ${id}: still on a flat-rate plan"
    continue
  fi
  if [[ "${blocked_parents}" == *" ${id} "* ]]; then
    log "  skip ${id}: tenants remain"
    continue
  fi
  if disable_distribution "${id}"; then
    ready+="${id} "
  else
    log "  skip delete ${id}: disable did not finish"
  fi
done <<<"${primary_ids}"

delete_policies

while read -r id; do
  [[ -z "${id}" ]] && continue
  if plan_blocks "${id}"; then
    continue
  fi
  if disable_distribution "${id}"; then
    delete_distribution "${id}" || true
  fi
done <<<"${staging_ids}"

while read -r id; do
  [[ -z "${id}" ]] && continue
  if [[ "${ready}" == *" ${id} "* ]]; then
    delete_distribution "${id}" || true
  fi
done <<<"${primary_ids}"

cleanup_after_distributions
update_registry "SUCCESS"
