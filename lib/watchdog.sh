#!/usr/bin/env bash
# Watchdog supervisor — keep the configured runners alive.
#
# When a runner's transient scope dies (OOM-kill, crash, or a run.sh exit) its
# PID goes away and, without supervision, it stays down until someone notices.
# Surviving runners then absorb the extra load, OOM more, and the fleet spirals.
# This loop restarts any down runner that is *meant* to be up, and rate-limits a
# runner that keeps dying shortly after each restart (a poison workload) with
# exponential backoff so it can't hot-loop. Every action is logged for auditing.
#
# A runner an operator deliberately stopped ('runner-mgr stop') carries
# desired_state=stopped and is left down.

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/github.sh"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/runner.sh"

watchdog_log_file() { echo "$RM_LOGS/watchdog.log"; }

# A runner that dies less than this many seconds after being (re)started is
# treated as churning and earns backoff; one that ran longer is a fresh incident
# and is restarted immediately.
WATCHDOG_CHURN_WINDOW="${WATCHDOG_CHURN_WINDOW:-180}"

# Supervise loop. Arg: poll interval in seconds (default 15).
watchdog_loop() {
  local interval="${1:-15}"
  [[ "$interval" =~ ^[0-9]+$ ]] && (( interval > 0 )) || interval=15
  require_env
  ensure_private_dir "$RM_LOGS" "$RM_STATE"

  local wlog; wlog="$(watchdog_log_file)"
  # Never let a logging failure (disk full, log removed) take down the
  # supervisor: swallow any write/pipe error. Prints to stdout (journal when run
  # as a service) AND appends to the log file.
  wd_log() {
    local ts; ts="$(date '+%F %T')"
    { printf '%s [watchdog] %s\n' "$ts" "$*" | tee -a "$wlog"; } 2>/dev/null || true
  }

  # Per-runner supervision state (see logic below).
  local -A last_start streak next_ok skipped
  local running=1 bogus_seen="__init__"
  trap 'running=0' INT TERM

  wd_log "started (interval=${interval}s churn_window=${WATCHDOG_CHURN_WINDOW}s pid=$$ mem_cap=${RUNNER_MEMORY_MAX:-none})"

  # Sanity: don't dutifully resurrect runners into an OOM loop.
  local n rc=0
  n=$(list_local_runners | wc -l)
  memory_budget_check "$n" || rc=$?
  if (( rc == 1 )); then
    wd_log "WARNING oversubscribed: ${n} runners × ${RUNNER_MEMORY_MAX} + ${MEM_OS_RESERVE_MIB}MiB > ${MB_TOTAL}MiB VM — expect OOM. Run 'runner-mgr capacity'."
  fi

  while (( running )); do
    local now id bogus
    now=$(date +%s)

    # Diretorio fora do padrao em runners/ nunca vira ID (list_local_runners
    # filtra), mas dizer em voz alta importa: um job de CI tem escrita ali, e
    # nome com metacaractere de shell era o vetor de RCE que passava por aqui.
    # So registra quando o conjunto muda, para nao poluir o log a cada ciclo.
    bogus="$(list_bogus_runner_dirs)"
    if [[ "$bogus" != "$bogus_seen" ]]; then
      bogus_seen="$bogus"
      if [[ -n "$bogus" ]]; then
        wd_log "ALERTA diretorios fora do padrao runner-<numero> em ${RM_RUNNERS}: $(printf '%s' "$bogus" | tr '\n' ' ')"
        wd_log "ALERTA ignorados. Se voce nao criou esses, veja SECURITY.md."
      fi
    fi
    for id in $(list_local_runners); do
      (( running )) || break

      # Honour an intentional 'runner-mgr stop' — never resurrect it.
      local desired
      desired=$(runner_state_get "$id" "desired_state") || true
      if [[ "$desired" == "stopped" ]]; then
        if [[ -z "${skipped[$id]:-}" ]]; then
          wd_log "runner-$id intentionally stopped — leaving down"
          skipped["$id"]=1
        fi
        continue
      fi
      skipped["$id"]=""

      # Healthy — nothing to do.
      runner_is_running "$id" && continue

      # Down and meant to be up. Respect the backoff window.
      (( now < ${next_ok[$id]:-0} )) && continue

      # Quick death? (died < CHURN_WINDOW after its last (re)start.) This is the
      # real churn signal — start_runner's own 1s liveness check can't tell a
      # job-time OOM from a healthy start, but time-since-last-start can.
      #
      # Com RUNNER_EPHEMERAL=1, porem, sair rapido virou o CICLO NORMAL: o
      # runner atende um job e se desregistra. Um job de 40s marcaria churn, o
      # backoff subiria ate 300s e a frota ficaria parada com fila cheia — o
      # oposto do que este loop existe para fazer. Quem TERMINOU um job apaga o
      # proprio .runner ao se desregistrar; quem morreu (OOM, crash) mantem.
      # So o segundo caso conta como churn.
      local prev="${last_start[$id]:-0}" quick=0 finished_job=0
      [[ -f "$(runner_dir "$id")/.runner" ]] || finished_job=1
      (( prev > 0 && now - prev < WATCHDOG_CHURN_WINDOW && ! finished_job )) && quick=1

      if (( quick )); then
        wd_log "runner-$id DOWN (died <${WATCHDOG_CHURN_WINDOW}s after restart) — restarting"
      elif (( finished_job )); then
        wd_log "runner-$id terminou um job (efemero) — re-registrando"
      else
        wd_log "runner-$id DOWN — restarting"
      fi
      last_start["$id"]=$now

      # Subshell contains start_runner's die()/exit so a failed start can never
      # kill the watchdog; its state/pidfile writes still persist.
      local ok=1
      ( start_runner "$id" ) >>"$wlog" 2>&1 || ok=0

      # Grow the backoff streak on a failed start OR a rapid re-death; reset it
      # when a genuinely-recovered runner comes back cleanly.
      if (( ok && ! quick )); then
        streak["$id"]=0
        next_ok["$id"]=0
        wd_log "runner-$id restarted"
      else
        streak["$id"]="$(( ${streak[$id]:-0} + 1 ))"
        local s="${streak[$id]}" sh
        sh=$s; (( sh > 4 )) && sh=4
        local delay=$(( interval * (1 << sh) )); (( delay > 300 )) && delay=300
        next_ok["$id"]="$(( now + delay ))"
        if (( ok )); then
          wd_log "runner-$id restarted but churning (streak $s) — backing off ${delay}s"
        else
          wd_log "runner-$id start FAILED (streak $s) — backing off ${delay}s"
        fi
      fi
    done

    # Stop promptly on signal instead of sleeping out the interval.
    (( running )) || break
    sleep "$interval" & wait $! 2>/dev/null || true
  done

  wd_log "stopped"
}
