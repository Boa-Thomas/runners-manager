#!/usr/bin/env bash
# Queue monitor — detects a stuck GitHub Actions queue (jobs waiting but not
# being consumed) and unhealthy/offline runners, then logs the result and pushes
# an ntfy alert. Designed to run one-shot from a systemd timer every ~30 min.
#
# Alerts (only these push to ntfy; every run appends a line to the log):
#   - GitHub unreachable / PAT rejected (runners invisible from our side).
#   - Fewer runners online than expected (a runner died / went offline).
#   - Queue non-empty AND no runner online at all (nothing can consume it).
#   - Zero idle capacity AND o run mais antigo em que NADA comecou espera
#     >= QMON_STUCK_SECS.
#
#     Duas armadilhas ja pisadas nessa metrica, as duas por confiar num numero
#     agregado sem checar o que ele mede:
#       1. "ha quanto tempo a fila esta nao-vazia" nunca resetava com 100% de
#          utilizacao, entao saude virava alerta.
#       2. "idade do run `queued` mais antigo" tambem engana: o GitHub marca o
#          RUN como queued enquanto QUALQUER job dele espera slot. Visto aqui um
#          run com 8 de 9 jobs concluidos ainda rotulado "queued".
#     Por isso a medida e sobre run em que NENHUM job comecou.
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

# Rewrite-then-move instead of `sed -i "s|...|...|"`. The old version used `|`
# as the sed delimiter, and the stuck-queue signature CONTAINS `|`
# ("down0|q1|idle0"), so any transition into that signature died with
# "unknown option to `s'" and silently left last_alert_sig stale. With the
# signature never persisting, the de-dup in qmon_maybe_notify compared against
# the old value forever and re-pushed the same ntfy alert every 30 min.
# No delimiter here means no value can break it.
qmon_state_set() {
  local key="$1" val="$2" file; file="$(qmon_state_file)"
  mkdir -p "$(dirname "$file")"
  local tmp="${file}.tmp.$$"
  {
    [[ -f "$file" ]] && grep -vE "^${key}=" "$file" || true
    echo "${key}=${val}"
  } > "$tmp"
  mv -f "$tmp" "$file"
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
# Runs com `event == "dynamic"` sao do Dependabot (os "npm_and_yarn in /x").
# Eles rodam na infraestrutura do GitHub e NUNCA consomem runner self-hosted,
# mas ficam em `queued` por horas — foram vistos 7 parados de 4h a 16h com os
# 4 runners ociosos. Contar isso criava um piso permanente na profundidade da
# fila: a fila nunca aparecia vazia, e bastava os 4 runners ficarem ocupados
# para o alerta de "fila parada" disparar por causa de runs que nao dependem
# de runner nenhum. So conta o que a nossa capacidade pode de fato consumir.
qmon_count_runs() {
  local status="$1" n
  n=$(gh_curl GET "/repos/${GITHUB_REPO}/actions/runs?status=${status}&per_page=100" \
        | jq '[(.workflow_runs // [])[] | select(.event != "dynamic")] | length' 2>/dev/null || echo 0)
  [[ "$n" =~ ^[0-9]+$ ]] && echo "$n" || echo 0
}

# Idade em segundos do run mais antigo que AINDA NAO COMECOU — nenhum job dele
# iniciado. Ecoa 0 quando nao ha nenhum.
#
# Por que nao basta olhar `status=queued`: o GitHub marca o RUN como `queued`
# enquanto QUALQUER job dele espera slot, mesmo com os outros ja rodando ou
# concluidos. Observado neste repo: um run com `completed: 8, queued: 1` — 8 de
# 9 jobs prontos — aparecia como "enfileirado". Medir a idade desse run diria
# "esperando ha 30min" sobre algo que esta quase terminando, e o alerta de fila
# parada dispararia com a fila andando normalmente.
#
# O que interessa e run em que NADA comecou: esse sim esta realmente esperando.
# Varre do mais antigo para o mais novo e para no primeiro que nao tem job
# iniciado — normalmente 1 ou 2 chamadas extras, nao uma por run.
qmon_oldest_unstarted_age() {
  local runs ids id created t now started
  runs=$(gh_curl GET "/repos/${GITHUB_REPO}/actions/runs?status=queued&per_page=100" \
        | jq -r '[(.workflow_runs // [])[] | select(.event != "dynamic")]
                 | sort_by(.created_at) | .[] | "\(.id) \(.created_at)"' 2>/dev/null)
  [[ -z "$runs" ]] && { echo 0; return; }
  now=$(date +%s)
  while read -r id created; do
    [[ -n "$id" ]] || continue
    # Algum job deste run ja saiu de `queued`?
    started=$(gh_curl GET "/repos/${GITHUB_REPO}/actions/runs/${id}/jobs?per_page=100" \
          | jq '[(.jobs // [])[] | select(.status != "queued")] | length' 2>/dev/null || echo 0)
    [[ "$started" =~ ^[0-9]+$ ]] || started=0
    (( started > 0 )) && continue          # ja esta sendo trabalhado, nao conta
    t=$(date -d "$created" +%s 2>/dev/null) || continue
    (( now > t )) && echo $(( now - t )) || echo 0
    return
  done <<< "$runs"
  echo 0                                    # todos os enfileirados ja comecaram
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
  # `queued_for` = idade do run enfileirado MAIS ANTIGO, nao ha quanto tempo a
  # fila esta continuamente nao-vazia (que era o que o antigo `queued_since`
  # media). A diferenca importa: um CI saudavel e bem utilizado quase sempre
  # tem algum run esperando, entao aquele contador nunca zerava e crescia para
  # sempre — 100% de utilizacao disparava "fila parada". Visto na pratica:
  # alerta de "2 run(s) ha 26min sem runner ocioso" com a fila drenando normal.
  # Idade do mais antigo distingue os dois casos: fila cheia com runs jovens e
  # saude; run especifico parado ha 25min e problema.
  local queued queued_for
  queued="$(qmon_count_runs queued)"
  queued_for="$(qmon_oldest_unstarted_age)"

  # --- decide ---
  local -a problems=()
  if (( online < expected )); then
    problems+=("runners down: ${online}/${expected} online${offline_names:+ (offline: ${offline_names})}")
  fi
  if (( queued > 0 )); then
    if (( online == 0 )); then
      problems+=("fila com ${queued} run(s) e NENHUM runner online")
    elif (( idle == 0 && queued_for >= QMON_STUCK_SECS )); then
      problems+=("fila parada: run mais antigo esperando ha $((queued_for/60))min com 0 runner ocioso (${queued} na fila)")
    fi
  fi

  local summary="queued=${queued} espera_max=$((queued_for/60))min online=${online}/${expected} busy=${busy} idle=${idle}"

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
