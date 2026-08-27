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

# ---------------------------------------------------------------------------
# Config loading
# ---------------------------------------------------------------------------

# Chaves aceitas no .env. Tudo fora desta lista e ignorado com aviso.
RM_ENV_KEYS=(
  GITHUB_TOKEN GITHUB_REPO
  RUNNER_LABELS RUNNER_WORKDIR RUNNER_GROUP
  RUNNER_EPHEMERAL RUNNER_WIPE_WORK RUNNER_SKIP_CHECKSUM
  MAX_RUNNERS RUNNER_MEMORY_MAX MEM_OS_RESERVE_MIB
  WATCHDOG_CHURN_WINDOW
  NTFY_TOPIC NTFY_SERVER NTFY_TOKEN QMON_STUCK_SECS
)

env_key_allowed() {
  local k="$1" allowed
  for allowed in "${RM_ENV_KEYS[@]}"; do
    [[ "$k" == "$allowed" ]] && return 0
  done
  return 1
}

# Le o .env como DADOS, nunca como codigo.
#
# A versao antiga fazia `set -a; source "$RM_ENV"; set +a`. `source` EXECUTA o
# arquivo: um `$(...)` em qualquer valor roda com os nossos privilegios — no
# watchdog, a cada boot. E o .env e gravavel por qualquer job de CI, porque o
# job roda com o mesmo usuario que o gerenciador (veja SECURITY.md). Era o vetor
# de persistencia mais barato do repositorio. Aqui so entram linhas
# CHAVE=VALOR com chave conhecida, e o valor nunca passa por expansao.
load_env() {
  [[ -f "$RM_ENV" ]] || return 1
  local line key val envname
  envname="$(basename "$RM_ENV")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"          # ltrim
    [[ -z "$line" || "$line" == '#'* ]] && continue
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    val="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"             # rtrim da chave
    val="${val#"${val%%[![:space:]]*}"}"             # ltrim do valor
    val="${val%"${val##*[![:space:]]}"}"             # rtrim do valor
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if ! env_key_allowed "$key"; then
      log_warn "${envname}: chave desconhecida ignorada: ${key}"
      continue
    fi
    # Aspas em volta do valor sao delimitador, nao conteudo.
    if [[ ${#val} -ge 2 && "$val" == '"'*'"' ]]; then
      val="${val:1:${#val}-2}"
    elif [[ ${#val} -ge 2 && "$val" == "'"*"'" ]]; then
      val="${val:1:${#val}-2}"
    fi
    printf -v "$key" '%s' "$val"
    export "${key?}"
  done < "$RM_ENV"
  return 0
}

require_env() {
  [[ -f "$RM_ENV" ]] || die "Config not found at $RM_ENV — run: runner-mgr setup"

  local mode
  mode=$(stat -c '%a' "$RM_ENV" 2>/dev/null || echo "")
  case "$mode" in
    600|400) ;;
    *) log_warn "$RM_ENV com permissao ${mode:-?} — o PAT esta legivel por outros. Corrija: chmod 600 $RM_ENV" ;;
  esac

  load_env || die "Falha ao ler $RM_ENV"
  [[ -n "${GITHUB_TOKEN:-}" ]] || die "GITHUB_TOKEN is empty in $RM_ENV"
  [[ -n "${GITHUB_REPO:-}" ]]  || die "GITHUB_REPO is empty in $RM_ENV"

  # O token vai para um arquivo de config do curl entre aspas duplas (para ficar
  # fora do argv — veja gh_auth_config). Um `"` ou `\` ali quebraria o parser do
  # curl e poderia injetar outra opcao. Nenhum formato de PAT do GitHub usa
  # esses caracteres, entao recusar e barato.
  [[ "$GITHUB_TOKEN" =~ ^[A-Za-z0-9_.~-]+$ ]] \
    || die "GITHUB_TOKEN contem caracteres inesperados — verifique $RM_ENV"
  # Interpolado direto em caminhos de URL da API.
  [[ "$GITHUB_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
    || die "GITHUB_REPO invalido: '$GITHUB_REPO' (esperado: owner/repo)"
  # Vira componente de caminho dentro do diretorio do runner.
  [[ "${RUNNER_WORKDIR:-_work}" =~ ^[A-Za-z0-9._-]+$ ]] \
    || die "RUNNER_WORKDIR invalido: '${RUNNER_WORKDIR}'"
}

require_cmd() {
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing dependency: $cmd"
  done
}

# ---------------------------------------------------------------------------
# Validacao de identificadores e caminhos
# ---------------------------------------------------------------------------

# Ponto unico de validacao do ID de runner. Tudo abaixo confia nele: caminhos,
# `rm -rf`, e a invocacao do run.sh.
#
# O ID chega de duas fontes e as DUAS eram atacaveis:
#   1. argv (`runner-mgr start <id>`) — nao havia validacao nenhuma;
#   2. `list_local_runners`, que deriva o ID do NOME DO DIRETORIO em runners/ —
#      e um job de CI tem escrita ali (o workdir dele e runners/runner-N/_work).
# Um diretorio chamado `runner-9';comando;#` fazia o watchdog executar `comando`
# a cada 15s, como servico systemd, sobrevivendo a reboot.
# Valida in-place e aborta. NAO ecoa o ID de volta, de proposito: uma versao que
# devolvesse o valor seria chamada como `id="$(require_runner_id "$1")"`, e ai o
# `die` rodaria dentro da substituicao — `exit` mataria so aquele subshell, e o
# fluxo seguiria com o ID vazio. Dois caminhos reais deixam isso passar batido:
#   - `local id="$(...)"`  — o status vira o do `local`, nunca o da substituicao
#     (SC2155), entao o errexit nem chega a ver a falha;
#   - `x="$(...)"` simples dentro de `( ... ) || fallback` — o bash suspende o
#     errexit inclusive dentro do subshell, e o watchdog usa exatamente essa
#     forma (`( start_runner "$id" ) || ok=0`).
# Como statement simples, o die encerra de verdade nos dois casos.
require_runner_id() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] \
    || die "ID de runner invalido: '${1:-}' (esperado: numero inteiro >= 1)"
}

# Recusa qualquer caminho que nao resolva para dentro de runners/.
# `require_runner_id` ja barra `../`; isto e a segunda tranca, aplicada imediatamente
# antes de cada acao destrutiva — inclusive contra symlink apontando para fora.
assert_within_runners() {
  local path="$1" base resolved
  base="$(realpath -m "$RM_RUNNERS")"
  resolved="$(realpath -m "$path")"
  [[ "$resolved" == "$base"/* ]] \
    || die "recusando operar fora de ${RM_RUNNERS}: ${path}"
}

# `rm -rf` de um diretorio de runner, com o alvo reconferido na hora.
#
# O guard `${dir:?}` fechava a variante "variavel vazia", mas nao a travessia:
# `runner-mgr down '1/../../vitima'` passava no teste `[[ -d ]]` e apagava o
# alvo. Agora o caminho resolvido precisa cair sob runners/ e ter o prefixo
# runner-.
safe_rm_runner_dir() {
  local dir="$1" base resolved
  base="$(realpath -m "$RM_RUNNERS")"
  resolved="$(realpath -m "$dir")"
  [[ "$resolved" == "$base"/runner-* ]] \
    || die "recusando rm -rf fora de ${RM_RUNNERS}: ${dir}"
  rm -rf "${resolved:?caminho do runner vazio — abortando}"
}

# Diretorio de trabalho com permissao restrita.
#
# Log de runner carrega saida de job, que eventualmente carrega segredo vazado
# por um workflow. Os arquivos nascem com o umask do processo (tipicamente 644);
# o diretorio 700 protege de outros usuarios de qualquer jeito.
ensure_private_dir() {
  local d
  for d in "$@"; do
    mkdir -p "$d"
    chmod 700 "$d" 2>/dev/null || true
  done
}

verify_sha256() {
  local file="$1" expected="$2" actual
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
  actual=$(sha256sum "$file" 2>/dev/null | awk '{print $1}') || return 1
  [[ "$actual" == "$expected" ]]
}

# ---------------------------------------------------------------------------
# systemd
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Memoria
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Estado por runner
# ---------------------------------------------------------------------------

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
#
# O temporario vem de `mktemp` (nasce 600 e com nome imprevisivel) em vez de
# `${file}.tmp.$$`, que era adivinhavel.
runner_state_set() {
  local id="$1" key="$2" value="$3" file tmp
  file="$(runner_state_file "$id")"
  ensure_private_dir "$(dirname "$file")"
  tmp="$(mktemp "${file}.XXXXXX")" || die "mktemp falhou em $(dirname "$file")"
  {
    [[ -f "$file" ]] && grep -vE "^${key}=" "$file" || true
    echo "${key}=${value}"
  } > "$tmp"
  mv -f "$tmp" "$file"
}

# List all local runner IDs (numeric, sorted).
#
# O filtro numerico nao e cosmetico: o nome do diretorio vira ID, e o ID vira
# caminho e argumento de comando. Qualquer coisa que nao seja `runner-<digitos>`
# e descartada aqui e reportada por `list_bogus_runner_dirs`.
list_local_runners() {
  [[ -d "$RM_RUNNERS" ]] || return 0
  find "$RM_RUNNERS" -maxdepth 1 -type d -name 'runner-*' -printf '%f\n' \
    | sed 's/^runner-//' \
    | grep -xE '[1-9][0-9]*' \
    | sort -n
}

# Diretorios sob runners/ que NAO seguem `runner-<digitos>`. Ou e sobra de uma
# remocao incompleta, ou e tentativa de contrabandear metacaractere de shell
# atraves do ID. Nunca usados; so reportados.
list_bogus_runner_dirs() {
  [[ -d "$RM_RUNNERS" ]] || return 0
  find "$RM_RUNNERS" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' \
    | grep -vxE 'runner-[1-9][0-9]*' || true
}

# Check if a runner process is alive via its PID file.
runner_is_running() {
  local id="$1" pidfile pid
  pidfile="$(runner_pidfile "$id")"
  [[ -f "$pidfile" ]] || return 1
  pid=$(cat "$pidfile" 2>/dev/null || echo "")
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  runner_pid_matches "$id" "$pid"
}

# Confirma que o PID ainda e o NOSSO runner.
#
# `kill -0` sozinho so diz "existe um processo com este numero". Depois de um
# reboot ou de reciclagem de PID o pidfile pode apontar para um processo alheio
# — e `stop_runner` manda SIGTERM e depois SIGKILL para o GRUPO INTEIRO desse
# PID. O cwd do processo e o diretorio do runner nos dois caminhos de start (o
# subshell faz `cd "$dir"` antes do exec), entao serve de identidade.
#
# Se /proc nao for introspetavel neste host, volta a confiar no PID — nao fica
# pior que antes.
runner_pid_matches() {
  local id="$1" pid="$2" dir cwd
  [[ -e "/proc/$$/cwd" ]] || return 0
  dir=$(readlink -f "$(runner_dir "$id")" 2>/dev/null) || return 1
  [[ -n "$dir" ]] || return 1
  cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null) || return 1
  [[ -n "$cwd" ]] || return 1
  [[ "$cwd" == "$dir" || "$cwd" == "$dir"/* ]]
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
