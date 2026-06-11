#!/usr/bin/env bash
# Status snapshot + live monitor dashboard.

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/github.sh"

# Per-process resource usage (CPU%, RSS in MB) for a runner including children.
process_stats() {
  local pid="$1"
  [[ -n "$pid" ]] || { echo "0.0 0"; return; }
  # Sum CPU% and RSS across the runner's process group / descendants.
  local pids
  pids=$(pgrep -g "$pid" 2>/dev/null || echo "$pid")
  ps -o pcpu=,rss= -p $pids 2>/dev/null \
    | awk '{cpu+=$1; rss+=$2} END {printf "%.1f %d\n", cpu+0, int((rss+0)/1024)}'
}

# Render the status table to stdout.
render_status() {
  require_env

  local gh_json
  gh_json=$(gh_list_runners 2>/dev/null || echo '[]')

  # Header
  printf '%s\n' "${C_BOLD}Runners Manager — ${GITHUB_REPO}${C_RESET}"
  printf '%s\n' "${C_DIM}$(date '+%Y-%m-%d %H:%M:%S')  •  $(hostname)${C_RESET}"
  echo

  # System summary
  local cpus mem_total mem_used load
  cpus=$(nproc)
  read -r mem_total mem_used <<<"$(free -m | awk '/^Mem:/ {print $2, $3}')"
  load=$(awk '{print $1, $2, $3}' /proc/loadavg)
  printf '%sHost%s  %d CPUs  •  RAM %d/%d MiB  •  load %s\n' \
    "$C_BOLD" "$C_RESET" "$cpus" "$mem_used" "$mem_total" "$load"
  echo

  # Table header
  printf '%s%-4s %-30s %-9s %-7s %-8s %-9s %-10s %s%s\n' \
    "$C_BOLD" "ID" "NAME" "PROC" "CPU%" "RAM(MB)" "UPTIME" "GH STATUS" "BUSY" "$C_RESET"

  local ids id name pid cpu rss started uptime gh_status busy color
  ids=$(list_local_runners)
  if [[ -z "$ids" ]]; then
    printf '%s(no local runners — start with: runner-mgr up N)%s\n' "$C_DIM" "$C_RESET"
  fi

  for id in $ids; do
    name=$(runner_state_get "$id" "name")
    pid=$(cat "$(runner_pidfile "$id")" 2>/dev/null || echo "")
    started=$(runner_state_get "$id" "started_at")
    uptime="—"
    [[ -n "$started" ]] && uptime=$(human_elapsed "$started")

    if runner_is_running "$id"; then
      read -r cpu rss <<<"$(process_stats "$pid")"
      proc_status="${C_GREEN}running${C_RESET}"
    else
      cpu="—"; rss="—"; proc_status="${C_RED}stopped${C_RESET}"
    fi

    # GitHub view
    gh_status=$(echo "$gh_json" | jq -r --arg n "$name" \
      '.[] | select(.name == $n) | .status' | head -1)
    busy=$(echo "$gh_json" | jq -r --arg n "$name" \
      '.[] | select(.name == $n) | .busy' | head -1)
    [[ -z "$gh_status" ]] && gh_status="—"
    case "$gh_status" in
      online)  color="$C_GREEN" ;;
      offline) color="$C_RED" ;;
      *)       color="$C_DIM" ;;
    esac
    case "$busy" in
      true)  busy="${C_YELLOW}yes${C_RESET}" ;;
      false) busy="no" ;;
      *)     busy="—" ;;
    esac

    printf '%-4s %-30s %-18s %-7s %-8s %-9s %s%-10s%s %s\n' \
      "$id" "${name:-—}" "$proc_status" "$cpu" "$rss" "$uptime" \
      "$color" "$gh_status" "$C_RESET" "$busy"
  done

  # Summary
  echo
  local total online_count busy_count
  total=$(echo "$gh_json" | jq 'length')
  online_count=$(echo "$gh_json" | jq '[.[] | select(.status=="online")] | length')
  busy_count=$(echo "$gh_json" | jq '[.[] | select(.busy==true)] | length')
  printf '%sGitHub:%s %d total  •  %d online  •  %d busy\n' \
    "$C_BOLD" "$C_RESET" "$total" "$online_count" "$busy_count"
}

# Live dashboard — re-renders every N seconds.
live_monitor() {
  local interval="${1:-2}"
  trap 'echo; exit 0' INT
  while true; do
    clear
    render_status
    echo
    printf '%s(refresh %ss — Ctrl-C to exit)%s\n' "$C_DIM" "$interval" "$C_RESET"
    sleep "$interval"
  done
}
