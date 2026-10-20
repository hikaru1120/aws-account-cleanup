#!/usr/bin/env bash
set -euo pipefail
MODULE_NAME="cloudfront"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"

# Bill: Amazon CloudFront
# Pay-as-you-go is not a distribution field. Cancel the flat-rate subscription first.
# Free plans end immediately. Paid plans stay billed until the period ends, but disable
# and attempt delete in this run. AWS may reject delete while the subscription is active.
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

dist_snapshot() {
  aws cloudfront get-distribution --id "$1" \
    --query 'Distribution.[Status,DistributionConfig.Enabled,DistributionConfig.ContinuousDeploymentPolicyId]' \
    --output text 2>/dev/null || echo -e "unknown\tunknown\tNone"
}

ready_to_delete() {
  local status="$1" enabled="$2" policy="$3"
  [[ "${status}" == "Deployed" && ( "${enabled}" == "False" || "${enabled}" == "false" ) && ( -z "${policy}" || "${policy}" == "None" ) ]]
}

# 0 = ready to delete, 2 = update sent or still deploying, 1 = update failed.
submit_disable() {
  local id="$1" status="" enabled="" policy="" cfg etag
  IFS=$'\t' read -r status enabled policy < <(dist_snapshot "${id}")
  if ready_to_delete "${status}" "${enabled}" "${policy}"; then
    return 0
  fi
  if [[ "${status}" != "Deployed" ]]; then
    return 2
  fi
  cfg="$(aws cloudfront get-distribution-config --id "${id}" --output json 2>/tmp/cf-dist.err)" || {
    fail "$(cat /tmp/cf-dist.err 2>/dev/null || true)" get-distribution-config "${id}" || true
    return 1
  }
  etag="$(jq -r '.ETag' <<<"${cfg}")"
  log "  disable ${id}"
  jq '.DistributionConfig | .Enabled=false | del(.ContinuousDeploymentPolicyId)' <<<"${cfg}" >"/tmp/cf-${id}.json"
  try aws cloudfront update-distribution --id "${id}" --if-match "${etag}" --distribution-config "file:///tmp/cf-${id}.json" || return 1
  return 2
}

# Disable every id first. While one distribution is still deploying, delete any other that is already Deployed.
drain_distributions() {
  local pending="$1" wave="" next="" id status enabled policy rc drc start elapsed
  while read -r id; do
    [[ -z "${id}" ]] && continue
    rc=0
    submit_disable "${id}" || rc=$?
    if [[ "${rc}" -eq 0 ]]; then
      drc=0
      delete_distribution "${id}" || drc=$?
      if [[ "${drc}" -ne 0 && "${drc}" -ne 3 ]]; then
        wave+="${id} "
      fi
    elif [[ "${rc}" -eq 1 ]]; then
      log "  skip ${id}: disable failed"
    else
      wave+="${id} "
    fi
  done <<<"${pending}"

  start="$(date +%s)"
  while [[ -n "${wave// /}" ]]; do
    elapsed=$(( $(date +%s) - start ))
    if [[ "${elapsed}" -ge "${CF_WAIT_SECONDS}" ]]; then
      log "  still deploying after ${elapsed}s: ${wave}"
      return 0
    fi
    next=""
    for id in ${wave}; do
      [[ -z "${id}" ]] && continue
      IFS=$'\t' read -r status enabled policy < <(dist_snapshot "${id}")
      log "    ${id} Status=${status} Enabled=${enabled} (${elapsed}s)"
      if ready_to_delete "${status}" "${enabled}" "${policy}"; then
        drc=0
        delete_distribution "${id}" || drc=$?
        if [[ "${drc}" -ne 0 && "${drc}" -ne 3 ]]; then
          next+="${id} "
        fi
      elif [[ "${status}" == "Deployed" ]]; then
        rc=0
        submit_disable "${id}" || rc=$?
        if [[ "${rc}" -eq 0 ]]; then
          drc=0
          delete_distribution "${id}" || drc=$?
          if [[ "${drc}" -ne 0 && "${drc}" -ne 3 ]]; then
            next+="${id} "
          fi
        elif [[ "${rc}" -eq 1 ]]; then
          log "  skip ${id}: disable failed"
        else
          next+="${id} "
        fi
      else
        next+="${id} "
      fi
    done
    wave="${next}"
    [[ -z "${wave// /}" ]] && break
    sleep 15
  done
}

delete_distribution() {
  local id="$1" etag out
  etag="$(aws cloudfront get-distribution-config --id "${id}" --query 'ETag' --output text 2>/dev/null || true)"
  [[ -z "${etag}" || "${etag}" == "None" ]] && return 1
  log "  delete ${id}"
  if out="$(aws cloudfront delete-distribution --id "${id}" --if-match "${etag}" 2>&1)"; then
    return 0
  fi
  if [[ "${out}" == *[Pp]ricing*[Pp]lan* || "${out}" == *ubscribed* ]]; then
    plan_held=$((plan_held + 1))
    [[ -z "${plan_held_err}" ]] && plan_held_err="$(printf '%s' "${out}" | tr '\n' ' ')"
    return 3
  fi
  fail "${out}" delete-distribution "${id}"
  return 1
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
    items="$(jq -c --argjson page "${page}" '
      def tenants:
        if ($page.DistributionTenantList | type) == "array" then $page.DistributionTenantList
        elif ($page.DistributionTenantList | type) == "object" then ($page.DistributionTenantList.Items // [])
        else ($page.Items // []) end;
      . + tenants
    ' <<<"${items}")" || return 1
    prev="${marker}"
    marker="$(jq -r '
      if (.DistributionTenantList | type) == "object" then (.DistributionTenantList.NextMarker // .NextMarker // empty)
      else (.NextMarker // empty) end
    ' <<<"${page}" 2>/dev/null || true)"
    [[ -z "${marker}" || "${marker}" == "${prev}" ]] && break
  done
  while read -r tid; do
    [[ -z "${tid}" ]] && continue
    parent="$(jq -r --arg id "${tid}" '.[] | objects | select(.Id==$id) | .DistributionId // empty' <<<"${items}" 2>/dev/null || true)"
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
  done < <(jq -r '.[] | objects | .Id // empty | select(. != "")' <<<"${items}" 2>/dev/null || true)
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
  done < <(jq -r '
    def rows:
      if type == "array" then .
      elif type == "object" and (.Items | type) == "array" then .Items
      else [] end;
    def rid:
      if type == "object" then (.ContinuousDeploymentPolicy.Id // .Id // empty)
      else empty end;
    (.ContinuousDeploymentPolicyList // []) | rows | .[] | rid | select(. != "")
  ' <<<"${policies}" 2>/dev/null || true)
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
    done < <(jq -r '
      def rows:
        if type == "array" then .
        elif type == "object" and (.Items | type) == "array" then .Items
        else [] end;
      (.ConnectionGroups // .ConnectionGroupList // []) | rows | .[]? | objects | .Id // empty | select(. != "")
    ' <<<"${groups}" 2>/dev/null || true)
  fi

  if anycast="$(aws cloudfront list-anycast-ip-lists --output json 2>/tmp/cf-ip.err)"; then
    while read -r aid; do
      [[ -z "${aid}" ]] && continue
      aetag="$(aws cloudfront get-anycast-ip-list --id "${aid}" --query 'ETag' --output text 2>/dev/null || true)"
      [[ -z "${aetag}" || "${aetag}" == "None" ]] && continue
      log "  delete anycast ip list ${aid}"
      try aws cloudfront delete-anycast-ip-list --id "${aid}" --if-match "${aetag}" || true
    done < <(jq -r '
      def rows:
        if type == "array" then .
        elif type == "object" and (.Items | type) == "array" then .Items
        else [] end;
      (.AnycastIpLists // .AnycastIpListList // []) | rows | .[]? | objects | .Id // empty | select(. != "")
    ' <<<"${anycast}" 2>/dev/null || true)
  fi

  if vpcs="$(aws cloudfront list-vpc-origins --output json 2>/tmp/cf-vpc.err)"; then
    while read -r vid; do
      [[ -z "${vid}" ]] && continue
      vetag="$(aws cloudfront get-vpc-origin --id "${vid}" --query 'ETag' --output text 2>/dev/null || true)"
      [[ -z "${vetag}" || "${vetag}" == "None" ]] && continue
      log "  delete vpc origin ${vid}"
      try aws cloudfront delete-vpc-origin --id "${vid}" --if-match "${vetag}" || true
    done < <(jq -r '
      def rows:
        if type == "array" then .
        elif type == "object" and (.Items | type) == "array" then .Items
        else [] end;
      (.VpcOriginList // .VpcOrigins // []) | rows | .[]? | objects | .Id // empty | select(. != "")
    ' <<<"${vpcs}" 2>/dev/null || true)
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
    done < <(jq -r '
      def rows:
        if type == "array" then .
        elif type == "object" and (.Items | type) == "array" then .Items
        else [] end;
      (.StreamingDistributionList // []) | rows | .[]? | objects | .Id // empty | select(. != "")
    ' <<<"${streaming}" 2>/dev/null || true)
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

paid="$(jq -r '[.[] | select(.planTier != "FREE" and .planTier != null)] | length' <<<"${subs}")"
when="$(jq -r '[.[] | .scheduledChange.effectiveDate // empty] | unique | .[0] // "end of the billing period"' <<<"${subs}")"
if [[ "${paid}" != "0" ]]; then
  log "  ${paid} paid plans stay billed until ${when}. Cancellation is scheduled, so the next billing period has no plan fee. Disabling and deleting those distributions now."
fi
other="$(jq -r '[.[] | (.resourceArns // [])[] | select(test("distribution/")|not)] | length' <<<"${subs}")"
[[ "${other}" != "0" ]] && log "  ${other} bundled WAF or other plan resources left in place"
plan_held=0
plan_held_err=""

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
marker="$(jq -r '.DistributionList.NextMarker // empty' <<<"${dists}")"
while [[ -n "${marker}" && "${marker}" != "null" ]]; do
  page="$(aws cloudfront list-distributions --marker "${marker}" --output json 2>/dev/null || echo '{}')"
  dists="$(jq -c --argjson page "${page}" '.DistributionList.Items += ($page.DistributionList.Items // [])' <<<"${dists}")"
  marker="$(jq -r '.DistributionList.NextMarker // empty' <<<"${page}")"
done
primary_ids="$(jq -r '.DistributionList.Items[]? | select(.Staging!=true) | .Id' <<<"${dists}")"
staging_ids="$(jq -r '.DistributionList.Items[]? | select(.Staging==true) | .Id' <<<"${dists}")"
listed="$(jq -r '[.DistributionList.Items[]?] | length' <<<"${dists}")"
batch=""
processing=0
skipped_tenant=0

while read -r id; do
  [[ -z "${id}" ]] && continue
  if [[ "${blocked_parents}" == *" ${id} "* ]]; then
    skipped_tenant=$((skipped_tenant + 1))
    log "  skip ${id}: tenants remain"
    continue
  fi
  processing=$((processing + 1))
  batch+="${id}"$'\n'
done <<<"${primary_ids}"
staging_n="$(printf '%s\n' "${staging_ids}" | sed '/^$/d' | wc -l | tr -d ' ')"
log "listed ${listed} distributions: disabling ${processing} now, ${staging_n} staging after that, skipped ${skipped_tenant} because tenants remain"
drain_distributions "${batch}"

delete_policies

batch=""
while read -r id; do
  [[ -z "${id}" ]] && continue
  batch+="${id}"$'\n'
done <<<"${staging_ids}"
drain_distributions "${batch}"

if [[ "${plan_held}" != "0" ]]; then
  log "  ${plan_held} distributions are disabled. AWS rejected delete: ${plan_held_err}"
  log "  the plan fee stops at ${when}. Run the same command again after that time to delete them."
fi

cleanup_after_distributions
update_registry "SUCCESS"
