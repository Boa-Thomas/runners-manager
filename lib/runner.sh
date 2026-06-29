#!/usr/bin/env bash
# Runner lifecycle: download, install, configure, start, stop, remove.

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/github.sh"

# Download (or reuse cached) runner tarball. Echoes the cached path.
ensure_runner_tarball() {
  local version="${1:-}"
  if [[ -z "$version" ]]; then
    version=$(gh_latest_runner_version)
  fi
  local tarball="$RM_CACHE/actions-runner-linux-x64-${version}.tar.gz"
  local url="https://github.com/actions/runner/releases/download/v${version}/actions-runner-linux-x64-${version}.tar.gz"

  if [[ ! -f "$tarball" ]]; then
    log_info "Downloading runner v${version}..." >&2
    mkdir -p "$RM_CACHE"
    curl -fL --progress-bar -o "$tarball.tmp" "$url" \
      || die "Failed to download $url"
    mv "$tarball.tmp" "$tarball"
    log_ok "Cached: $(basename "$tarball")" >&2
  fi
  echo "$tarball"
}

# Extract the tarball into a fresh runner directory.
install_runner_files() {
  local id="$1" tarball="$2" dir
  dir="$(runner_dir "$id")"
  [[ -d "$dir" ]] && die "Runner dir already exists: $dir"
  mkdir -p "$dir"
  log_info "Extracting runner-$id..."
  tar -xzf "$tarball" -C "$dir"
}

# Register a runner with GitHub.
configure_runner() {
  local id="$1" name="runner-$(hostname)-${id}" labels
  labels="${RUNNER_LABELS:-self-hosted,linux,x64,wsl2},wsl2-${id}"
  local dir token
  dir="$(runner_dir "$id")"
  token=$(gh_registration_token)

  log_info "Registering '$name' (labels: $labels)..."
  (
    cd "$dir"
    ./config.sh \
      --unattended \
      --url "https://github.com/${GITHUB_REPO}" \
      --token "$token" \
      --name "$name" \
      --labels "$labels" \
      --work "${RUNNER_WORKDIR:-_work}" \
      --runnergroup "${RUNNER_GROUP:-default}" \
      --replace
  ) >> "$(runner_log "$id")" 2>&1 || die "Configuration failed — see $(runner_log "$id")"

  runner_state_set "$id" "name" "$name"
  runner_state_set "$id" "labels" "$labels"
  runner_state_set "$id" "registered_at" "$(date +%s)"
  log_ok "Registered $name"
}

# Start runner in background. Captures PID + logs.
# When RUNNER_MEMORY_MAX is set and systemd-run is available, the runner is
# launched inside a transient systemd scope so the kernel enforces the cap.
# A single overloaded job is then OOM-killed in isolation rather than
# thrashing every concurrent runner on the host.
start_runner() {
  local id="$1" dir log pidfile
  dir="$(runner_dir "$id")"
  log="$(runner_log "$id")"
  pidfile="$(runner_pidfile "$id")"

  if runner_is_running "$id"; then
    log_warn "runner-$id already running (PID $(cat "$pidfile"))"
    return 0
  fi

  mkdir -p "$RM_LOGS" "$RM_STATE"
  log_info "Starting runner-$id..."
  local pid

  if [[ -n "${RUNNER_MEMORY_MAX:-}" ]] && systemd_run_available; then
    local unit="runner-mgr-${id}"
    # Stop any stale scope from a previous crash before (re)creating it.
    systemctl --user stop "${unit}.scope" 2>/dev/null || true
    # Launch in a transient user scope with a hard memory ceiling and no swap.
    # systemd-run stays alive as the scope controller until run.sh exits, so
    # the captured $! PID remains a valid liveness proxy for runner_is_running.
    systemd-run --user --scope --quiet --unit="$unit" \
      -p MemoryMax="${RUNNER_MEMORY_MAX}" -p MemorySwapMax=0 \
      setsid bash -c "cd '$dir' && exec ./run.sh" >> "$log" 2>&1 < /dev/null &
    pid=$!
    runner_state_set "$id" "scope_unit" "${unit}.scope"
    log_info "Memory cap: ${RUNNER_MEMORY_MAX} (scope: ${unit}.scope)"
  else
    # Fallback: no cgroup memory cap. Use setsid so the process survives
    # parent shell exit.
    setsid bash -c "cd '$dir' && exec ./run.sh" >> "$log" 2>&1 < /dev/null &
    pid=$!
  fi

  echo "$pid" > "$pidfile"
  runner_state_set "$id" "started_at" "$(date +%s)"
  runner_state_set "$id" "pid" "$pid"
  sleep 1
  if kill -0 "$pid" 2>/dev/null; then
    log_ok "runner-$id started (PID $pid)"
  else
    rm -f "$pidfile"
    die "runner-$id died immediately — see $log"
  fi
}

# Gracefully stop a runner process.
stop_runner() {
  local id="$1" pidfile pid
  pidfile="$(runner_pidfile "$id")"
  if ! runner_is_running "$id"; then
    log_dim "runner-$id not running"
    rm -f "$pidfile"
    return 0
  fi
  pid=$(cat "$pidfile")
  log_info "Stopping runner-$id (PID $pid)..."

  # If a systemd scope was created, stop it first — that sends SIGTERM to all
  # processes in the scope and cleans up the cgroup.
  # Use || true: runner_state_get pipes through grep, which exits 1 when the
  # key is absent; that would trip set -e on the bare assignment.
  local scope_unit
  scope_unit=$(runner_state_get "$id" "scope_unit") || true
  if [[ -n "$scope_unit" ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl --user stop "$scope_unit" 2>/dev/null || true
  fi

  # SIGTERM to the process group — run.sh spawns Runner.Listener as a child.
  kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in {1..15}; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then
    log_warn "runner-$id did not stop, sending SIGKILL"
    kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "$pidfile"
  log_ok "runner-$id stopped"
}

# Unregister runner from GitHub and delete local files.
remove_runner() {
  local id="$1" dir name gh_id
  dir="$(runner_dir "$id")"
  name=$(runner_state_get "$id" "name")

  stop_runner "$id" || true

  if [[ -d "$dir" && -x "$dir/config.sh" ]]; then
    local token
    if token=$(gh_remove_token 2>/dev/null); then
      log_info "Unregistering runner-$id from GitHub..."
      ( cd "$dir" && ./config.sh remove --token "$token" ) \
        >> "$(runner_log "$id")" 2>&1 \
        || log_warn "Local unregister failed, will try API delete"
    fi
  fi

  if [[ -n "$name" ]]; then
    gh_id=$(gh_runner_id_by_name "$name" || true)
    if [[ -n "$gh_id" ]]; then
      log_info "Force-deleting GitHub runner $name (id=$gh_id)..."
      gh_delete_runner "$gh_id"
    fi
  fi

  rm -rf "$dir"
  rm -f "$(runner_state_file "$id")" "$(runner_pidfile "$id")"
  log_ok "runner-$id removed"
}

# Provision a new runner end-to-end.
provision_runner() {
  local id="$1" version="${2:-}" tarball
  tarball=$(ensure_runner_tarball "$version")
  install_runner_files "$id" "$tarball"
  configure_runner "$id"
  start_runner "$id"
}
