#!/usr/bin/env bash
# Queue monitor — detects a stuck GitHub Actions queue (jobs waiting but not
# being consumed) and unhealthy/offline runners, then logs the result and pushes
# an ntfy alert. Designed to run one-shot from a systemd timer every ~30 min.
#
# Alerts (only these push to ntfy; every run appends a line to the log):
#   - GitHub unreachable / PAT rejected (runners invisible from our side).
#   - Fewer runners online than expected (a runner died / went offline).
#   - Queue non-empty AND no runner online at all (nothing can consume it).
#   - Queue non-empty AND zero idle capacity, sustained across checks
#     (>= QMON_STUCK_SECS) — a transient burst that drains in one interval does
#     not alert.
#
# De-dup: a given problem signature pushes once; it re-pushes only when the
# situation changes, and sends one recovery ping when things normalise.

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/github.sh"

# How long the queue must stay full (0 idle) before it counts as "stuck".
QMON_STUCK_SECS="${QMON_STUCK_SECS:-1500}"   # 25 min — under the 30 min cadence

qmon_log_file()   { echo "$RM_LOGS/queue-monitor.log"; }
qmon_state_file() { echo "$RM_STATE/qmon.state"; }

qmon_state_get() {
  local key="$1" file; file="$(qmon_state_file)"
  [[ -f "$file" ]] || { echo ""; return; }
  grep -E "^${key}=" "$file" | tail -1 | cut -d= -f2-
}

qmon_state_set() {
  local key="$1" val="$2" file; file="$(qmon_state_file)"
  mkdir -p "$(dirname "$file")"
  if [[ -f "$file" ]] && grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  else
    echo "${key}=${val}" >> "$file"
  fi
}

qmon_log() {
  local line="$1" file; file="$(qmon_log_file)"
  mkdir -p "$(dirname "$file")"
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line" >> "$file"
}

# Push an ntfy notification. No-op (warns) when NTFY_TOPIC is unset.
qmon_notify() {
  local title="$1" body="$2" priority="${3:-high}" tags="${4:-warning}"
  local topic="${NTFY_TOPIC:-}" server="${NTFY_SERVER:-https://ntfy.sh}"
  [[ -n "$topic" ]] || { log_warn "NTFY_TOPIC unset in .env — skipping push (logged only)"; return 0; }
  local -a auth=()
  [[ -n "${NTFY_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${NTFY_TOKEN}")
  curl -sS -m 15 "${auth[@]}" \
    -H "Title: ${title}" \
    -H "Priority: ${priority}" \
    -H "Tags: ${tags}" \
    -d "${body}" \
    "${server%/}/${topic}" >/dev/null 2>&1 \
    || log_warn "ntfy push to ${server%/}/${topic} failed"
}

# Push only when the problem signature differs from the last one pushed, so an
# ongoing issue doesn't re-notify every interval. Always marks state=alerting.
qmon_maybe_notify() {
  local sig="$1" title="$2" body="$3" prio="${4:-high}" tags="${5:-warning}"
  qmon_state_set alerting 1
  local last; last="$(qmon_state_get last_alert_sig)"
  if [[ "$sig" != "$last" ]]; then
    qmon_notify "$title" "$body" "$prio" "$tags"
    qmon_state_set last_alert_sig "$sig"
  fi
}

# Count workflow runs currently in a given status (capped at 100 — enough to
# distinguish "empty" from "backed up").
qmon_count_runs() {
  local status="$1" n
  n=$(gh_curl GET "/repos/${GITHUB_REPO}/actions/runs?status=${status}&per_page=100" \
        | jq '(.workflow_runs // []) | length' 2>/dev/null || echo 0)
  [[ "$n" =~ ^[0-9]+$ ]] && echo "$n" || echo 0
}

# One evaluation pass. Returns 0 always (a monitor shouldn't fail the timer);
# problems are reported via log + ntfy.
qmon_check() {
  require_env

  # Expected online = local runners not deliberately stopped (matches watchdog).
  local expected=0 id ds
  for id in $(list_local_runners); do
    ds="$(runner_state_get "$id" desired_state)"
    [[ "$ds" == "stopped" ]] || expected=$((expected + 1))
  done

  # --- GitHub reachability / auth ---
  local repo_code
  repo_code=$(curl -sS -o /dev/null -w '%{http_code}' -m 20 \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "${GH_API}/repos/${GITHUB_REPO}" 2>/dev/null || echo 000)
  if [[ "$repo_code" != "200" ]]; then
    qmon_log "ALERT github-unreachable http=${repo_code} (PAT expired? network down?)"
    qmon_maybe_notify "gh-${repo_code}" "runner-mgr: sem acesso ao GitHub" \
      "HTTP ${repo_code} ao consultar ${GITHUB_REPO}. PAT expirado ou rede caiu — runners invisiveis." \
      max rotating_light
    return 0
  fi

  # --- runner health ---
  local runners_json total online busy offline_names idle
  runners_json="$(gh_list_runners)"
  total=$(echo   "$runners_json" | jq 'length')
  online=$(echo  "$runners_json" | jq '[.[]|select(.status=="online")]|length')
  busy=$(echo    "$runners_json" | jq '[.[]|select(.busy==true)]|length')
  offline_names=$(echo "$runners_json" | jq -r '[.[]|select(.status!="online")|.name]|join(", ")')
  idle=$(( online - busy )); (( idle < 0 )) && idle=0

  # --- queue depth ---
  local queued now queued_since queued_for
  queued="$(qmon_count_runs queued)"
  now=$(date +%s)
  queued_since="$(qmon_state_get queued_since)"
  if (( queued > 0 )); then
    [[ "$queued_since" =~ ^[0-9]+$ ]] && (( queued_since > 0 )) || queued_since="$now"
  else
    queued_since=0
  fi
  qmon_state_set queued_since "$queued_since"
  queued_for=0
  (( queued_since > 0 )) && queued_for=$(( now - queued_since ))

  # --- decide ---
  local -a problems=()
  if (( online < expected )); then
    problems+=("runners down: ${online}/${expected} online${offline_names:+ (offline: ${offline_names})}")
  fi
  if (( queued > 0 )); then
    if (( online == 0 )); then
      problems+=("fila com ${queued} run(s) e NENHUM runner online")
    elif (( idle == 0 && queued_for >= QMON_STUCK_SECS )); then
      problems+=("fila parada: ${queued} run(s) ha $((queued_for/60))min sem runner ocioso")
    fi
  fi

  local summary="queued=${queued} online=${online}/${expected} busy=${busy} idle=${idle}"

  if (( ${#problems[@]} > 0 )); then
    local msg; msg="$(printf '%s; ' "${problems[@]}")"; msg="${msg%; }"
    qmon_log "ALERT ${summary} :: ${msg}"
    local sig="down$((expected-online))|q$(( queued>0 ? 1 : 0 ))|idle${idle}"
    qmon_maybe_notify "$sig" "runner-mgr: fila/runners com problema" \
      "${msg} [${summary}]" high warning
  else
    qmon_log "OK ${summary}"
    if [[ "$(qmon_state_get alerting)" == "1" ]]; then
      qmon_notify "runner-mgr: recuperado" "Fila/runners normalizaram. ${summary}" default white_check_mark
    fi
    qmon_state_set alerting 0
    qmon_state_set last_alert_sig ""
  fi
  return 0
}
