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

# Fully tear down a transient user scope by unit stem (without ".scope") and
# block until systemd no longer knows the name, so a subsequent
# 'systemd-run --unit=<stem>' can't collide with a lingering/failed unit.
# 'systemctl stop' is async for a unit that is already dying (e.g. OOM-killed),
# and OOM-killed scopes stay 'loaded' in failed state until reset-failed — both
# caused the "Unit runner-mgr-N.scope was already loaded" start failure.
scope_teardown() {
  local unit="$1" scope="${1}.scope" i=0 load
  systemctl --user stop "$scope" 2>/dev/null || true
  systemctl --user reset-failed "$scope" 2>/dev/null || true
  # Poll LoadState until the unit name is released (or ~5s elapses).
  while (( i++ < 50 )); do
    load=$(systemctl --user show "$scope" -p LoadState --value 2>/dev/null || echo "")
    [[ "$load" == "not-found" || -z "$load" ]] && return 0
    systemctl --user reset-failed "$scope" 2>/dev/null || true
    sleep 0.1
  done
  return 0
}

# RAM to reserve for the OS + runner agents when sizing the memory budget.
MEM_OS_RESERVE_MIB="${MEM_OS_RESERVE_MIB:-2048}"

# Parse a memory size (e.g. "4096M", "3.5G", "512", "8GB") to integer MiB.
# Bare numbers are treated as MiB (matches systemd's default-ish usage here).
mem_to_mib() {
  local v="${1:-}" n unit
  v="${v//[[:space:]]/}"
  [[ -n "$v" ]] || { echo 0; return; }
  n="${v//[^0-9.]/}"; unit="${v//[0-9.]/}"
  [[ -n "$n" ]] || { echo 0; return; }
  case "${unit^^}" in
    ""|M|MB|MI|MIB) awk -v n="$n" 'BEGIN{printf "%d", n}' ;;
    G|GB|GI|GIB)    awk -v n="$n" 'BEGIN{printf "%d", n*1024}' ;;
    K|KB|KI|KIB)    awk -v n="$n" 'BEGIN{printf "%d", n/1024}' ;;
    T|TB|TI|TIB)    awk -v n="$n" 'BEGIN{printf "%d", n*1024*1024}' ;;
    *)              echo 0 ;;
  esac
}

# Verify a runner count fits VM RAM: count × RUNNER_MEMORY_MAX + OS reserve
# must be <= total VM memory. Sets MB_NEED/MB_TOTAL/MB_CAP globals for callers
# to print. Returns 0 if it fits, 1 if oversubscribed, 2 if not checkable.
memory_budget_check() {
  local n="${1:-0}" cap="${RUNNER_MEMORY_MAX:-}"
  MB_NEED=0 MB_TOTAL=0 MB_CAP=0
  [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )) || return 2
  [[ -n "$cap" ]] || return 2
  local cap_mib total_mib
  cap_mib=$(mem_to_mib "$cap"); (( cap_mib > 0 )) || return 2
  total_mib=$(free -m | awk '/^Mem:/ {print $2}')
  MB_CAP=$cap_mib; MB_TOTAL=$total_mib
  MB_NEED=$(( n * cap_mib + MEM_OS_RESERVE_MIB ))
  (( MB_NEED <= total_mib ))
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
#
# Rewrite-then-move instead of `sed -i "s|^${key}=.*|${key}=${value}|"`: that
# used `|` as the sed delimiter, so any value CONTAINING `|` blew up with
# "unknown option to `s'" and left the old value in place, silently. Reachable
# today via `labels` (comes from RUNNER_LABELS in .env — user-controlled). The
# same bug bit qmon_state_set for real, where the stuck-queue signature has
# literal `|` in it. No delimiter here means no value can break it.
runner_state_set() {
  local id="$1" key="$2" value="$3" file
  file="$(runner_state_file "$id")"
  mkdir -p "$(dirname "$file")"
  local tmp="${file}.tmp.$$"
  {
    [[ -f "$file" ]] && grep -vE "^${key}=" "$file" || true
    echo "${key}=${value}"
  } > "$tmp"
  mv -f "$tmp" "$file"
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
