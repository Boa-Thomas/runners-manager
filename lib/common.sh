#!/usr/bin/env bash
# Shared helpers — sourced by other lib files and the main CLI.

set -euo pipefail

# Resolve project root regardless of where the caller lives.
RM_ROOT="${RM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RM_LIB="$RM_ROOT/lib"
RM_CACHE="$RM_ROOT/cache"
RM_RUNNERS="$RM_ROOT/runners"
RM_LOGS="$RM_ROOT/logs"
RM_STATE="$RM_ROOT/state"
RM_ENV="$RM_ROOT/.env"

# Colors (no-op if NO_COLOR set or stdout is not a tty)
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_CYAN=$'\033[36m'
else
  C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

log_info()  { printf '%s[i]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
log_ok()    { printf '%s[ok]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_warn()  { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error() { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
log_dim()   { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

die() { log_error "$*"; exit 1; }

require_env() {
  [[ -f "$RM_ENV" ]] || die "Config not found at $RM_ENV — run: runner-mgr setup"
  # shellcheck disable=SC1090
  set -a; source "$RM_ENV"; set +a
  [[ -n "${GITHUB_TOKEN:-}" ]] || die "GITHUB_TOKEN is empty in $RM_ENV"
  [[ -n "${GITHUB_REPO:-}" ]]  || die "GITHUB_REPO is empty in $RM_ENV"
}

require_cmd() {
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing dependency: $cmd"
  done
}

# Returns 0 when systemd-run --user --scope with memory limits is usable:
# requires the binary, systemd as PID 1, and cgroup v2 memory controller.
systemd_run_available() {
  command -v systemd-run >/dev/null 2>&1 || return 1
  [[ "$(ps -p 1 -o comm= 2>/dev/null)" == "systemd" ]] || return 1
  [[ -f /sys/fs/cgroup/cgroup.controllers ]] \
    && grep -q '\bmemory\b' /sys/fs/cgroup/cgroup.controllers 2>/dev/null
}

# State file per runner — JSON-ish key=value, one per line.
runner_state_file() { echo "$RM_STATE/runner-$1.state"; }
runner_dir()        { echo "$RM_RUNNERS/runner-$1"; }
runner_log()        { echo "$RM_LOGS/runner-$1.log"; }
runner_pidfile()    { echo "$RM_STATE/runner-$1.pid"; }

# Read a key from a runner state file. Returns empty if missing.
runner_state_get() {
  local id="$1" key="$2" file
  file="$(runner_state_file "$id")"
  [[ -f "$file" ]] || { echo ""; return; }
  grep -E "^${key}=" "$file" | tail -1 | cut -d= -f2-
}

# Set a key in a runner state file (create or replace).
runner_state_set() {
  local id="$1" key="$2" value="$3" file
  file="$(runner_state_file "$id")"
  mkdir -p "$(dirname "$file")"
  if [[ -f "$file" ]] && grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

# List all local runner IDs (numeric, sorted).
list_local_runners() {
  [[ -d "$RM_RUNNERS" ]] || return 0
  find "$RM_RUNNERS" -maxdepth 1 -type d -name 'runner-*' -printf '%f\n' \
    | sed 's/^runner-//' | sort -n
}

# Returns the next available runner ID (1, 2, 3, ...).
next_runner_id() {
  local used max=0 id
  used=$(list_local_runners)
  for id in $used; do (( id > max )) && max=$id; done
  echo $((max + 1))
}

# Check if a runner process is alive via its PID file.
runner_is_running() {
  local id="$1" pidfile pid
  pidfile="$(runner_pidfile "$id")"
  [[ -f "$pidfile" ]] || return 1
  pid=$(cat "$pidfile" 2>/dev/null || echo "")
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# Human-readable elapsed time from epoch.
human_elapsed() {
  local start="$1" now diff
  now=$(date +%s)
  diff=$((now - start))
  if   (( diff < 60 ));    then echo "${diff}s"
  elif (( diff < 3600 ));  then echo "$((diff/60))m"
  elif (( diff < 86400 )); then echo "$((diff/3600))h"
  else                          echo "$((diff/86400))d"
  fi
}
