#!/usr/bin/env bash
# Testa as defesas adicionadas na revisao de seguranca.
#
# Cada caso corresponde a um achado da auditoria e falha se a defesa regredir.
# Nao precisa de token, de rede nem de systemd: roda em qualquer maquina com
# bash + coreutils.
#
#   ./tests/security-checks.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
PASS=0; FAIL=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
group(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

# Roda um trecho num bash isolado com as libs carregadas. Ecoa a saida.
# Devolve o codigo de saida do trecho.
in_sandbox() {
  local snippet="$1"
  RM_ROOT="$SANDBOX" bash -c "
    set -uo pipefail
    source '$REPO_ROOT/lib/common.sh' 2>/dev/null
    source '$REPO_ROOT/lib/github.sh' 2>/dev/null
    source '$REPO_ROOT/lib/runner.sh' 2>/dev/null
    $snippet
  " 2>&1
}

# Espera que o trecho ABORTE (die). Passa se o exit for != 0.
expect_refuse() {
  local desc="$1" snippet="$2" out
  out="$(in_sandbox "$snippet")"
  if (( $? != 0 )); then ok "$desc"; else bad "$desc — NAO recusou (saida: ${out:0:80})"; fi
}

expect_ok() {
  local desc="$1" snippet="$2" out
  out="$(in_sandbox "$snippet")"
  if (( $? == 0 )); then ok "$desc"; else bad "$desc — abortou: ${out:0:120}"; fi
}

expect_eq() {
  local desc="$1" expected="$2" snippet="$3" got
  got="$(in_sandbox "$snippet")"
  if [[ "$got" == "$expected" ]]; then ok "$desc"; else bad "$desc — esperado '$expected', veio '$got'"; fi
}

# `kill -0` responde com sucesso para um zumbi: o processo ja morreu, so falta o
# pai colher. Em container cujo PID 1 nao reapa prontamente, um `kill -0` puro
# faz o teste de stop_runner reportar falha apesar do encerramento correto.
pid_alive() {
  local p="$1" st
  kill -0 "$p" 2>/dev/null || return 1
  st=$(sed 's/^.*) //' "/proc/$p/stat" 2>/dev/null | awk '{print $1}')
  [[ "$st" == "Z" ]] && return 1
  return 0
}

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/runners" "$SANDBOX/state" "$SANDBOX/logs"

printf '\033[1mrunner-mgr — verificacoes de seguranca\033[0m\n'
printf 'sandbox: %s\n' "$SANDBOX"

# --------------------------------------------------------------------------
group "RCE-01 — ID de runner nunca vira comando"
# --------------------------------------------------------------------------
expect_refuse "recusa ID com aspa simples (payload do RCE no watchdog)" \
  $'require_runner_id "9\';id>/tmp/pwned;#"'
expect_refuse "recusa ID com substituicao de comando" \
  'require_runner_id "1\$(id)"'
expect_refuse "recusa ID com travessia de caminho" \
  'require_runner_id "1/../../etc"'
expect_refuse "recusa ID vazio" 'require_runner_id ""'
expect_refuse "recusa ID nao numerico" 'require_runner_id "all"'
expect_ok      "aceita ID numerico" 'require_runner_id "7"'

mkdir -p "$SANDBOX/runners/runner-3" "$SANDBOX/runners/runner-11"
mkdir -p "$SANDBOX/runners/runner-9';id>RCE.txt;#" "$SANDBOX/runners/lixo"
expect_eq "list_local_runners devolve so os numericos" $'3\n11' 'list_local_runners'
expect_eq "list_bogus_runner_dirs denuncia os demais" 2 'list_bogus_runner_dirs | wc -l'
rm -rf "$SANDBOX/runners/runner-9';id>RCE.txt;#" "$SANDBOX/runners/lixo"

# --------------------------------------------------------------------------
group "DEL-01 — rm -rf nao sai de runners/"
# --------------------------------------------------------------------------
mkdir -p "$SANDBOX/vitima"; touch "$SANDBOX/vitima/importante.txt"
expect_refuse "recusa apagar via ../ (o caso que passava no [[ -d ]])" \
  'safe_rm_runner_dir "$RM_RUNNERS/runner-3/../../vitima"'
[[ -f "$SANDBOX/vitima/importante.txt" ]] \
  && ok "arquivo fora de runners/ sobreviveu" \
  || bad "arquivo fora de runners/ FOI APAGADO"

expect_refuse "recusa caminho absoluto fora de runners/" 'safe_rm_runner_dir "/tmp"'
expect_refuse "recusa o proprio runners/" 'safe_rm_runner_dir "$RM_RUNNERS"'
mkdir -p "$SANDBOX/runners/runner-42"
expect_ok "apaga um diretorio de runner legitimo" 'safe_rm_runner_dir "$RM_RUNNERS/runner-42"'
[[ ! -d "$SANDBOX/runners/runner-42" ]] && ok "runner-42 removido" || bad "runner-42 continua la"

# --------------------------------------------------------------------------
group "CFG-01 — .env e lido como dado, nunca executado"
# --------------------------------------------------------------------------
cat > "$SANDBOX/.env" <<EOF
GITHUB_TOKEN=ghp_teste123
GITHUB_REPO=dono/repo
RUNNER_LABELS=self-hosted,\$(touch $SANDBOX/EXECUTOU)
MAX_RUNNERS=4
EOF
in_sandbox 'load_env' >/dev/null
[[ -f "$SANDBOX/EXECUTOU" ]] \
  && bad "load_env EXECUTOU a substituicao de comando do .env" \
  || ok "substituicao de comando no .env nao foi executada"
expect_eq "o valor chega literal, sem expansao" 'self-hosted,$(touch '"$SANDBOX"'/EXECUTOU)' \
  'load_env; printf "%s" "$RUNNER_LABELS"'

cat > "$SANDBOX/.env" <<'EOF'
GITHUB_TOKEN=ghp_teste123
GITHUB_REPO=dono/repo
PATH=/caminho/do/atacante
LD_PRELOAD=/tmp/evil.so
EOF
expect_eq "chave fora da allowlist e ignorada (PATH intacto)" "sim" \
  'load_env >/dev/null 2>&1; [[ "$PATH" == "/caminho/do/atacante" ]] && printf nao || printf sim'

# --------------------------------------------------------------------------
group "require_env — valida o que vira URL e header"
# --------------------------------------------------------------------------
mk_env() { printf 'GITHUB_TOKEN=%s\nGITHUB_REPO=%s\n' "$1" "$2" > "$SANDBOX/.env"; }
mk_env 'ghp_ok123' 'dono/repo'
expect_ok "aceita token e repo bem formados" 'require_env'
mk_env 'tok"en' 'dono/repo'
expect_refuse 'recusa token com aspa dupla (quebraria o config do curl)' 'require_env'
mk_env 'ghp_ok123' 'dono/repo/../../outro'
expect_refuse "recusa GITHUB_REPO com travessia" 'require_env'
mk_env 'ghp_ok123' 'dono repo'
expect_refuse "recusa GITHUB_REPO com espaco" 'require_env'
mk_env 'ghp_ok123' 'dono/repo'

# --------------------------------------------------------------------------
group "TOK-01 — o token nunca aparece no argv"
# --------------------------------------------------------------------------
# curl falso: grava o proprio argv e responde como a API responderia.
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARGV_LOG"
cat >/dev/null 2>&1 || true
printf '{"ok":true}\n200\n'
FAKE
chmod +x "$SANDBOX/bin/curl"

ARGV_LOG="$SANDBOX/argv.log"; : > "$ARGV_LOG"
RM_ROOT="$SANDBOX" ARGV_LOG="$ARGV_LOG" PATH="$SANDBOX/bin:$PATH" bash -c "
  set -uo pipefail
  source '$REPO_ROOT/lib/github.sh'
  GITHUB_TOKEN=ghp_SEGREDO_QUE_NAO_PODE_VAZAR
  GITHUB_REPO=dono/repo
  gh_curl GET /repos/dono/repo >/dev/null 2>&1
" >/dev/null 2>&1

if grep -q 'ghp_SEGREDO_QUE_NAO_PODE_VAZAR' "$ARGV_LOG" 2>/dev/null; then
  bad "o token apareceu no argv do curl"
else
  ok "o token nao aparece no argv do curl"
fi
grep -q -- '--config -' "$ARGV_LOG" 2>/dev/null \
  && ok "o header vai por --config no stdin" \
  || bad "nao usou --config"

# --------------------------------------------------------------------------
group "API-01 — status HTTP deixou de ser ignorado"
# --------------------------------------------------------------------------
# curl falso configuravel: responde o corpo/codigo que o teste mandar, e conta
# as chamadas para exercitar a paginacao.
cat > "$SANDBOX/bin/curl" <<'FAKE'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
n=$(( $(cat "$CALL_COUNT" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$CALL_COUNT"
body_file="$FAKE_DIR/body${n}.json"
[[ -f "$body_file" ]] || body_file="$FAKE_DIR/body1.json"
cat "$body_file"
printf '\n%s\n' "$FAKE_CODE"
FAKE
chmod +x "$SANDBOX/bin/curl"

api() {  # api <codigo-http> <trecho>
  CALL_COUNT="$SANDBOX/calls" FAKE_DIR="$SANDBOX" FAKE_CODE="$1" \
  PATH="$SANDBOX/bin:$PATH" RM_ROOT="$SANDBOX" bash -c "
    set -uo pipefail
    source '$REPO_ROOT/lib/github.sh'
    GITHUB_TOKEN=ghp_x; GITHUB_REPO=dono/repo
    $2
  " 2>/dev/null
}

: > "$SANDBOX/calls"
printf '{\n  "full_name": "dono/repo",\n  "private": false\n}\n' > "$SANDBOX/body1.json"
got="$(api 200 'gh_curl GET /repos/dono/repo | jq -r .full_name')"
[[ "$got" == "dono/repo" ]] \
  && ok "corpo multi-linha e devolvido inteiro, sem a linha do status" \
  || bad "corpo multi-linha veio errado: '$got'"

: > "$SANDBOX/calls"
if api 401 'gh_curl GET /repos/dono/repo' >/dev/null; then
  bad "gh_curl devolveu 0 num 401 (era o bug: erro virava corpo vazio)"
else
  ok "gh_curl devolve != 0 num 401"
fi

: > "$SANDBOX/calls"
if api 403 'gh_list_runners' >/dev/null; then
  bad "gh_list_runners devolveu 0 num 403 — voltaria a virar '[]' silencioso"
else
  ok "gh_list_runners propaga a falha em vez de devolver lista vazia"
fi

# Paginacao: pagina cheia (100) obriga a buscar a proxima.
: > "$SANDBOX/calls"
jq -nc '{runners: [range(100) | {id: ., name: "r\(.)"}]}' > "$SANDBOX/body1.json"
jq -nc '{runners: [{id: 100, name: "r100"}]}'              > "$SANDBOX/body2.json"
total="$(api 200 'gh_list_runners | jq length')"
[[ "$total" == "101" ]] \
  && ok "gh_list_runners segue a paginacao (101 runners em 2 paginas)" \
  || bad "paginacao nao seguida: veio '$total' em vez de 101"
[[ "$(cat "$SANDBOX/calls")" == "2" ]] \
  && ok "parou na segunda pagina (nao pagina infinitamente)" \
  || bad "numero de chamadas inesperado: $(cat "$SANDBOX/calls")"

# --------------------------------------------------------------------------
group "SUP-01 — integridade do tarball"
# --------------------------------------------------------------------------
echo "conteudo" > "$SANDBOX/arquivo.bin"
REAL_SHA="$(sha256sum "$SANDBOX/arquivo.bin" | awk '{print $1}')"
expect_ok      "aceita SHA256 correto" "verify_sha256 '$SANDBOX/arquivo.bin' '$REAL_SHA'"
expect_refuse  "rejeita SHA256 errado" \
  "verify_sha256 '$SANDBOX/arquivo.bin' '$(printf '0%.0s' {1..64})'"
expect_refuse  "rejeita SHA256 malformado" "verify_sha256 '$SANDBOX/arquivo.bin' 'abc'"

# --------------------------------------------------------------------------
group "PID-01 — PID reciclado nao e confundido com o runner"
# --------------------------------------------------------------------------
mkdir -p "$SANDBOX/runners/runner-5"
( cd "$SANDBOX/runners/runner-5" && exec sleep 30 ) &
RUNNER_PID=$!
sleep 0.3
expect_ok "reconhece o processo cujo cwd e o diretorio do runner" \
  "runner_pid_matches 5 $RUNNER_PID"
( cd /tmp && exec sleep 30 ) &
ALHEIO_PID=$!
sleep 0.3
expect_refuse "recusa um PID vivo com outro cwd (o caso do PID reciclado)" \
  "runner_pid_matches 5 $ALHEIO_PID"
kill "$RUNNER_PID" "$ALHEIO_PID" 2>/dev/null || true

echo "$ALHEIO_PID" > "$SANDBOX/state/runner-5.pid"
expect_refuse "runner_is_running rejeita pidfile apontando para processo alheio" \
  'runner_is_running 5'
rm -f "$SANDBOX/state/runner-5.pid"

# --------------------------------------------------------------------------
group "Ciclo de vida — start/stop reais com o runner substituido por um stub"
# --------------------------------------------------------------------------
# start_runner deixou de montar `bash -c "cd '$dir' && ..."`. Este grupo prova
# que o substituto preserva o que aquela forma garantia: cwd certo, sessao
# propria (para o `kill -TERM -$pid` atingir o grupo) e PID rastreavel.
LIFE="$SANDBOX/runners/runner-1"
mkdir -p "$LIFE"
printf '#!/usr/bin/env bash\nexec sleep 60\n' > "$LIFE/run.sh"
chmod +x "$LIFE/run.sh"
echo '{}' > "$LIFE/.runner"; echo '{}' > "$LIFE/.credentials"

life() {
  RM_ROOT="$SANDBOX" bash -c "
    set -uo pipefail
    source '$REPO_ROOT/lib/runner.sh'
    GITHUB_TOKEN=ghp_x; GITHUB_REPO=dono/repo
    $1
  " 2>&1
}

life 'start_runner 1 >/dev/null 2>&1' >/dev/null
LPID="$(cat "$SANDBOX/state/runner-1.pid" 2>/dev/null || echo "")"
if [[ -n "$LPID" ]] && kill -0 "$LPID" 2>/dev/null; then
  ok "start_runner subiu o processo (PID $LPID)"
  [[ "$(readlink -f "/proc/$LPID/cwd")" == "$(readlink -f "$LIFE")" ]] \
    && ok "processo roda com cwd no diretorio do runner" \
    || bad "cwd errado: $(readlink -f "/proc/$LPID/cwd")"
  [[ "$(ps -o sid= -p "$LPID" | tr -d ' ')" == "$LPID" ]] \
    && ok "processo e lider da propria sessao (kill -TERM -PID atinge o grupo)" \
    || bad "processo nao e lider de sessao — o SIGTERM ao grupo erraria o alvo"
  expect_eq "runner_is_running confirma" "sim" \
    'runner_is_running 1 && printf sim || printf nao'
  life 'start_runner 1' | grep -q 'already running' \
    && ok "segunda chamada nao sobe um duplicado" \
    || bad "start_runner duplicou o processo"
  life 'stop_runner 1 >/dev/null 2>&1' >/dev/null
  sleep 0.3
  pid_alive "$LPID" \
    && { bad "stop_runner nao encerrou o processo"; kill -9 "$LPID" 2>/dev/null || true; } \
    || ok "stop_runner encerrou o processo"
  expect_eq "desired_state=stopped persistido (watchdog nao ressuscita)" "stopped" \
    'runner_state_get 1 desired_state'
else
  bad "start_runner nao deixou PID rastreavel"
fi

expect_eq "logs/ e state/ ficam com permissao 700" "700 700" \
  'printf "%s %s" "$(stat -c %a "$RM_LOGS")" "$(stat -c %a "$RM_STATE")"'

# --------------------------------------------------------------------------
group "ISO-01 — re-registro efemero (roda a cada job)"
# --------------------------------------------------------------------------
EPH="$SANDBOX/runners/runner-2"
mkdir -p "$EPH/_work/repo-do-job-anterior"
echo "segredo do job anterior" > "$EPH/_work/vazamento.txt"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "$PWD/config-args.txt"\necho "{}" > "$PWD/.runner"\necho "{}" > "$PWD/.credentials"\n' > "$EPH/config.sh"
chmod +x "$EPH/config.sh"
printf '#!/usr/bin/env bash\nexec sleep 60\n' > "$EPH/run.sh"; chmod +x "$EPH/run.sh"
# sem .runner: e o estado em que o runner efemero fica depois de atender um job

eph() {
  RM_ROOT="$SANDBOX" bash -c "
    set -uo pipefail
    source '$REPO_ROOT/lib/runner.sh'
    GITHUB_TOKEN=ghp_x; GITHUB_REPO=dono/repo
    gh_registration_token() { echo 'token-falso'; }   # nao toca na rede
    $1
  " 2>&1
}

out="$(eph 'ensure_registered 2')"
if [[ -f "$EPH/.runner" && -f "$EPH/.credentials" ]]; then
  ok "runner sem registracao e reconfigurado automaticamente"
else
  bad "ensure_registered nao re-registrou: ${out:0:120}"
fi
grep -q -- '--ephemeral' "$EPH/config-args.txt" 2>/dev/null \
  && ok "config.sh recebe --ephemeral (fronteira entre jobs)" \
  || bad "--ephemeral nao foi passado ao config.sh"
grep -q -- '--replace' "$EPH/config-args.txt" 2>/dev/null \
  && ok "config.sh mantem --replace" || bad "--replace sumiu"
[[ ! -e "$EPH/_work/vazamento.txt" && ! -e "$EPH/_work/repo-do-job-anterior" ]] \
  && ok "_work limpo: nada do job anterior atende o proximo" \
  || bad "_work nao foi limpo — contaminacao entre jobs continua"
[[ -d "$EPH/_work" ]] && ok "_work continua existindo (so o conteudo saiu)" \
  || bad "_work foi removido inteiro"

# Com RUNNER_EPHEMERAL=0 o comportamento antigo tem de voltar intacto.
rm -f "$EPH/.runner" "$EPH/.credentials" "$EPH/config-args.txt"
eph 'RUNNER_EPHEMERAL=0; ensure_registered 2' >/dev/null
grep -q -- '--ephemeral' "$EPH/config-args.txt" 2>/dev/null \
  && bad "RUNNER_EPHEMERAL=0 ainda passou --ephemeral" \
  || ok "RUNNER_EPHEMERAL=0 volta ao runner persistente"

# --------------------------------------------------------------------------
group "Achados da review do PR #1"
# --------------------------------------------------------------------------
# next_runner_id foi perdido ao reescrever common.sh; cmd_up chama e quebrava.
mkdir -p "$SANDBOX/runners/runner-3" "$SANDBOX/runners/runner-11"
expect_eq "next_runner_id continua definido e devolve max+1" 12 'next_runner_id'
mkdir -p "$SANDBOX/runners/runner-99';id;#"
expect_eq "next_runner_id ignora diretorio fora do padrao" 12 'next_runner_id'
rm -rf "$SANDBOX/runners/runner-99';id;#"

# Lista vazia: grep sem match + pipefail derrubava o chamador.
rm -rf "$SANDBOX/runners"; mkdir -p "$SANDBOX/runners"
expect_ok "runners/ vazio nao derruba o chamador sob set -e + pipefail" \
  'set -o pipefail; current=$(list_local_runners | wc -l); [[ "$current" == "0" ]]'
expect_eq "next_runner_id parte de 1 quando nao ha runner" 1 'next_runner_id'
mkdir -p "$SANDBOX/runners/runner-1"

# Contexto aritmetico executa comando embutido no valor: o parser sozinho nao
# fechava a persistencia via .env, so trocava o caminho.
rm -f "$SANDBOX/ARITH_PWN"
cat > "$SANDBOX/.env" <<EOF
GITHUB_TOKEN=ghp_ok
GITHUB_REPO=dono/repo
MEM_OS_RESERVE_MIB=PIPESTATUS[\$(touch $SANDBOX/ARITH_PWN)]
EOF
in_sandbox 'load_env >/dev/null 2>&1; memory_budget_check 4 >/dev/null 2>&1 || true' >/dev/null
[[ -f "$SANDBOX/ARITH_PWN" ]] \
  && bad "valor do .env foi EXECUTADO em contexto aritmetico" \
  || ok "valor nao-numerico e recusado antes de chegar a (( ))"
expect_eq "MEM_OS_RESERVE_MIB mantem o default apos recusar o valor" 2048 \
  'load_env >/dev/null 2>&1; printf "%s" "$MEM_OS_RESERVE_MIB"'

cat > "$SANDBOX/.env" <<'EOF'
GITHUB_TOKEN=ghp_ok
GITHUB_REPO=dono/repo
MAX_RUNNERS=4x
RUNNER_EPHEMERAL=sim
RUNNER_MEMORY_MAX=4096M
EOF
expect_eq "MAX_RUNNERS mal formado e ignorado" "" \
  'load_env >/dev/null 2>&1; printf "%s" "${MAX_RUNNERS:-}"'
# Valor recusado cai no default definido ao carregar a lib — que para
# RUNNER_EPHEMERAL e o seguro (1). Um `.env` com lixo nao consegue desligar o
# isolamento por acidente nem de proposito.
expect_eq "RUNNER_EPHEMERAL nao-booleano cai no default seguro" "1" \
  'load_env >/dev/null 2>&1; printf "%s" "${RUNNER_EPHEMERAL:-}"'
expect_eq "RUNNER_MEMORY_MAX bem formado passa" "4096M" \
  'load_env >/dev/null 2>&1; printf "%s" "$RUNNER_MEMORY_MAX"'

# O valor tambem pode vir do ambiente, sem passar por load_env.
rm -f "$SANDBOX/ARITH_PWN"
MEM_OS_RESERVE_MIB="PIPESTATUS[\$(touch $SANDBOX/ARITH_PWN)]" RM_ROOT="$SANDBOX" \
  bash -c "source '$REPO_ROOT/lib/common.sh' 2>/dev/null; memory_budget_check 4" >/dev/null 2>&1 || true
[[ -f "$SANDBOX/ARITH_PWN" ]] \
  && bad "valor herdado do ambiente foi executado em (( ))" \
  || ok "sanitize_int cobre o valor herdado do ambiente"

# Zumbi: kill -0 responde sucesso, mas o processo ja morreu.
zfile="$SANDBOX/zpid"; rm -f "$zfile"
bash -c "true & echo \$! > '$zfile'; sleep 3" &
sleep 0.4
ZPID="$(cat "$zfile" 2>/dev/null || echo "")"
if [[ -n "$ZPID" ]] && kill -0 "$ZPID" 2>/dev/null; then
  expect_ok "pid_is_zombie identifica o zumbi" "pid_is_zombie $ZPID"
  mkdir -p "$SANDBOX/runners/runner-8"; echo "$ZPID" > "$SANDBOX/state/runner-8.pid"
  expect_refuse "runner_is_running trata zumbi como encerrado" 'runner_is_running 8'
  rm -f "$SANDBOX/state/runner-8.pid"
else
  ok "ambiente reapa zumbis na hora — caso nao reproduzivel aqui (defesa mantida)"
fi
wait 2>/dev/null || true

# Falha ao medir a espera nao pode virar "fila saudavel".
: > "$SANDBOX/calls"
printf '{}\n' > "$SANDBOX/body1.json"
if CALL_COUNT="$SANDBOX/calls" FAKE_DIR="$SANDBOX" FAKE_CODE=500 \
   PATH="$SANDBOX/bin:$PATH" RM_ROOT="$SANDBOX" bash -c "
     set -uo pipefail
     source '$REPO_ROOT/lib/qmon.sh'
     GITHUB_TOKEN=ghp_x; GITHUB_REPO=dono/repo
     qmon_oldest_unstarted_age
   " >/dev/null 2>&1; then
  bad "qmon_oldest_unstarted_age devolveu 0 numa falha de API (fila pareceria saudavel)"
else
  ok "qmon_oldest_unstarted_age propaga a falha em vez de ecoar 0"
fi

# --------------------------------------------------------------------------
group "Regressoes — bugs ja corrigidos no passado continuam corrigidos"
# --------------------------------------------------------------------------
expect_eq "state_set aceita valor contendo '|'" 'down0|q1|idle0' \
  'runner_state_set 5 sig "down0|q1|idle0"; runner_state_get 5 sig'
expect_eq "mem_to_mib: 4096M"  4096  'mem_to_mib 4096M'
expect_eq "mem_to_mib: 3.5G"   3584  'mem_to_mib 3.5G'
expect_eq "mem_to_mib: invalido" 0   'mem_to_mib xyz'
expect_eq "state file nasce com permissao 600" 600 \
  'runner_state_set 6 k v; stat -c "%a" "$(runner_state_file 6)"'

printf '\n\033[1mResultado:\033[0m %d passaram, %d falharam\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
