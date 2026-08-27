#!/usr/bin/env bash
# Runner lifecycle: download, install, configure, start, stop, remove.

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/github.sh"

# Runner efemero: atende UM job e se desregistra. E a fronteira entre jobs —
# sem ela, o que um job deixa plantado no runner atende o proximo. Custa uma
# reconfiguracao por job. Ponha 0 no .env so se souber o que esta abrindo mao.
RUNNER_EPHEMERAL="${RUNNER_EPHEMERAL:-1}"
# Limpa o _work entre jobs. `--ephemeral` desregistra mas NAO apaga os arquivos
# do job anterior. Custa cache local de build; ponha 0 se preferir a velocidade.
RUNNER_WIPE_WORK="${RUNNER_WIPE_WORK:-1}"

# Download (or reuse cached) runner tarball. Echoes the cached path.
#
# O tarball e extraido e tem config.sh/run.sh EXECUTADOS, entao a integridade
# dele e execucao de codigo. Antes nao havia verificacao nenhuma — e o vetor nem
# precisava de MITM: cache/ e gravavel pelo mesmo usuario que roda os jobs,
# entao um job trocava o tarball em cache e o proximo `runner-mgr up` executava
# o binario do atacante, com a bencao do cache hit. Por isso o SHA256 e
# conferido TAMBEM quando o arquivo ja esta em cache.
ensure_runner_tarball() {
  local version="${1:-}"
  if [[ -z "$version" ]]; then
    version=$(gh_latest_runner_version) \
      || die "Nao foi possivel descobrir a ultima versao do runner"
  fi
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "Versao invalida: '${version}' (esperado: X.Y.Z)"

  local tarball="$RM_CACHE/actions-runner-linux-x64-${version}.tar.gz"
  local url="https://github.com/actions/runner/releases/download/v${version}/actions-runner-linux-x64-${version}.tar.gz"

  local expected=""
  if [[ "${RUNNER_SKIP_CHECKSUM:-0}" == "1" ]]; then
    log_warn "RUNNER_SKIP_CHECKSUM=1 — pulando a verificacao de integridade do tarball." >&2
  else
    expected=$(gh_runner_sha256 "$version") || expected=""
    [[ -n "$expected" ]] \
      || die "Nao foi possivel obter o SHA256 da release v${version}. Recusando executar um tarball nao verificado. Para forcar (nao recomendado): RUNNER_SKIP_CHECKSUM=1"
  fi

  if [[ -f "$tarball" && -n "$expected" ]] && ! verify_sha256 "$tarball" "$expected"; then
    log_warn "Tarball em cache com SHA256 divergente — descartando e baixando de novo." >&2
    rm -f "$tarball"
  fi

  if [[ ! -f "$tarball" ]]; then
    log_info "Downloading runner v${version}..." >&2
    ensure_private_dir "$RM_CACHE"
    curl -fL --progress-bar -m 900 -o "$tarball.tmp" "$url" \
      || die "Failed to download $url"
    if [[ -n "$expected" ]] && ! verify_sha256 "$tarball.tmp" "$expected"; then
      rm -f "$tarball.tmp"
      die "SHA256 do download nao bate com a release v${version} — abortando."
    fi
    mv "$tarball.tmp" "$tarball"
    log_ok "Cached: $(basename "$tarball")" >&2
  fi
  echo "$tarball"
}

# Extract the tarball into a fresh runner directory.
install_runner_files() {
  require_runner_id "$1"
  local id="$1" tarball="$2" dir
  dir="$(runner_dir "$id")"
  [[ -d "$dir" ]] && die "Runner dir already exists: $dir"
  mkdir -p "$dir"
  log_info "Extracting runner-$id..."
  tar -xzf "$tarball" -C "$dir"
}

# Register a runner with GitHub.
configure_runner() {
  require_runner_id "$1"
  local id="$1" name labels dir token
  name="runner-$(hostname)-${id}"
  labels="${RUNNER_LABELS:-self-hosted,linux,x64,wsl2},wsl2-${id}"
  dir="$(runner_dir "$id")"
  token=$(gh_registration_token)

  local -a args=(
    --unattended
    --url "https://github.com/${GITHUB_REPO}"
    --token "$token"
    --name "$name"
    --labels "$labels"
    --work "${RUNNER_WORKDIR:-_work}"
    --runnergroup "${RUNNER_GROUP:-default}"
    --replace
  )
  [[ "${RUNNER_EPHEMERAL}" == "1" ]] && args+=(--ephemeral)

  local mode="persistente"
  [[ "${RUNNER_EPHEMERAL}" == "1" ]] && mode="efemero"
  log_info "Registering '$name' (${mode}, labels: $labels)..."
  ( cd "$dir" && ./config.sh "${args[@]}" ) \
    >> "$(runner_log "$id")" 2>&1 \
    || die "Configuration failed — see $(runner_log "$id")"

  runner_state_set "$id" "name" "$name"
  runner_state_set "$id" "labels" "$labels"
  runner_state_set "$id" "registered_at" "$(date +%s)"
  log_ok "Registered $name"
}

# Apaga o conteudo do _work sem seguir para fora do diretorio do runner.
clean_runner_work() {
  require_runner_id "$1"
  local id="$1" work
  work="$(runner_dir "$id")/${RUNNER_WORKDIR:-_work}"
  [[ -d "$work" ]] || return 0
  assert_within_runners "$work"
  find "$work" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
}

# Garante que o runner tem registracao valida antes de subir.
#
# Um runner efemero se desregistra ao terminar o job e apaga o proprio .runner.
# Sem reconfigurar, o run.sh seguinte sobe e morre na hora com "Not configured"
# — e o watchdog entraria em loop de restart.
ensure_registered() {
  require_runner_id "$1"
  local id="$1" dir
  dir="$(runner_dir "$id")"
  [[ -d "$dir" ]] || die "runner-$id nao esta instalado ($dir nao existe)"
  if [[ -f "$dir/.runner" && -f "$dir/.credentials" ]]; then
    return 0
  fi
  [[ "${RUNNER_WIPE_WORK}" == "1" ]] && clean_runner_work "$id"
  log_info "runner-$id sem registracao (job efemero consumido) — reconfigurando..."
  configure_runner "$id"
}

# Start runner in background. Captures PID + logs.
# When RUNNER_MEMORY_MAX is set and systemd-run is available, the runner is
# launched inside a transient systemd scope so the kernel enforces the cap.
# A single overloaded job is then OOM-killed in isolation rather than
# thrashing every concurrent runner on the host.
start_runner() {
  require_runner_id "$1"
  local id="$1" dir log pidfile
  dir="$(runner_dir "$id")"
  log="$(runner_log "$id")"
  pidfile="$(runner_pidfile "$id")"

  if runner_is_running "$id"; then
    log_warn "runner-$id already running (PID $(cat "$pidfile"))"
    return 0
  fi

  ensure_private_dir "$RM_LOGS" "$RM_STATE"
  ensure_registered "$id"
  log_info "Starting runner-$id..."
  local pid

  # O comando NUNCA e montado como string de shell.
  #
  # Antes era `bash -c "cd '$dir' && exec ./run.sh"`, com o caminho interpolado
  # dentro de aspas simples. Como o $dir carrega o ID e o ID vinha do nome do
  # diretorio, uma aspa simples no nome fechava o literal e o resto virava
  # comando — executado pelo watchdog a cada 15s. `require_runner_id` ja barra
  # isso na entrada; aqui o subshell faz o `cd` de verdade, entao nao ha string
  # para escapar de jeito nenhum.
  if [[ -n "${RUNNER_MEMORY_MAX:-}" ]] && systemd_run_available; then
    local unit="runner-mgr-${id}"
    # Clear any stale scope left by a previous crash (OOM-killed scopes land in
    # "failed" state and block re-creation with the same unit name) and WAIT for
    # systemd to fully release the name. 'systemctl stop' returns before a dying
    # unit is unloaded, so re-creating immediately raced and failed with
    # "Unit runner-mgr-N.scope was already loaded". Poll LoadState until the
    # name is gone (~5s cap) before handing it back to systemd-run.
    scope_teardown "$unit"
    # --collect: garbage-collect the unit even if it later exits in 'failed'
    # state (e.g. OOM-kill), so it never lingers to block the next start.
    # systemd-run stays alive as the scope controller until run.sh exits, so
    # the captured $! PID remains a valid liveness proxy for runner_is_running.
    (
      cd "$dir" || exit 1
      exec systemd-run --user --scope --quiet --collect --unit="$unit" \
        -p MemoryMax="${RUNNER_MEMORY_MAX}" -p MemorySwapMax=0 \
        setsid ./run.sh
    ) >> "$log" 2>&1 < /dev/null &
    pid=$!
    runner_state_set "$id" "scope_unit" "${unit}.scope"
    log_info "Memory cap: ${RUNNER_MEMORY_MAX} (scope: ${unit}.scope)"
  else
    # Fallback: no cgroup memory cap. Use setsid so the process survives
    # parent shell exit.
    (
      cd "$dir" || exit 1
      exec setsid ./run.sh
    ) >> "$log" 2>&1 < /dev/null &
    pid=$!
  fi

  echo "$pid" > "$pidfile"
  runner_state_set "$id" "started_at" "$(date +%s)"
  runner_state_set "$id" "pid" "$pid"
  # Record intent so the watchdog knows this runner is meant to be up.
  runner_state_set "$id" "desired_state" "running"
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
  require_runner_id "$1"
  local id="$1" pidfile pid
  pidfile="$(runner_pidfile "$id")"
  # Record intent BEFORE the early-return path so the watchdog won't resurrect a
  # runner an operator deliberately stopped. Cleared again by start_runner.
  runner_state_set "$id" "desired_state" "stopped"
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
  # runner_is_running ja confirmou, via cwd em /proc, que este PID e o nosso
  # runner e nao um numero reciclado por outro processo. Sem isso o `-$pid`
  # abaixo derrubaria o grupo inteiro de um processo alheio.
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
  require_runner_id "$1"
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
    if gh_id=$(gh_runner_id_by_name "$name"); then
      if [[ -n "$gh_id" ]]; then
        log_info "Force-deleting GitHub runner $name (id=$gh_id)..."
        gh_delete_runner "$gh_id" || true
      fi
    else
      # gh_list_runners falhou. Antes isso era indistinguivel de "nao existe" e
      # o registro ficava pendurado no GitHub sem ninguem saber.
      log_warn "Nao foi possivel confirmar no GitHub se '$name' ainda esta registrado."
      log_warn "Se sobrar registro orfao, rode 'runner-mgr clean' quando a API voltar."
    fi
  fi

  # Reconfere o alvo imediatamente antes de apagar: o `${dir:?}` de antes so
  # pegava variavel vazia, nao travessia (`down '1/../../vitima'` passava).
  safe_rm_runner_dir "$dir"
  rm -f "$(runner_state_file "$id")" "$(runner_pidfile "$id")"
  log_ok "runner-$id removed"
}

# Provision a new runner end-to-end.
provision_runner() {
  require_runner_id "$1"
  local id="$1" version="${2:-}" tarball
  tarball=$(ensure_runner_tarball "$version")
  install_runner_files "$id" "$tarball"
  configure_runner "$id"
  start_runner "$id"
}
