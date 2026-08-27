#!/usr/bin/env bash
# GitHub API helpers.

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

GH_API="https://api.github.com"

# Emite o header de autorizacao como arquivo de config do curl, no stdout.
#
# O token NUNCA pode ir no argv: /proc/<pid>/cmdline e legivel por qualquer
# processo do host, e neste host rodam jobs de CI de PRs de fork (repo publico).
# Um `grep -h Bearer /proc/*/cmdline` em loop capturava o PAT com escopo `repo`.
# `curl --config -` le o header daqui pelo stdin, que nao aparece em lugar
# nenhum. require_env ja garantiu que o token nao tem `"` nem `\`, que
# quebrariam o parser do curl.
gh_auth_config() {
  printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN"
}

# Chamada autenticada a API. Ecoa o corpo no stdout e devolve != 0 quando a
# chamada nao deu certo.
#
# A versao antiga ignorava o status HTTP por completo: um 401, 403 ou rate limit
# virava corpo de erro que o `jq` transformava em `[]`, e o chamador nao tinha
# como distinguir "nao ha runners" de "nao consegui perguntar". `cmd_clean`
# precisou de uma confirmacao dupla so por causa disso, e `remove_runner`
# continuava deixando registro pendurado no GitHub em silencio.
gh_curl() {
  local method="$1" path="$2"
  shift 2
  local raw rc=0 body code
  raw=$(gh_auth_config | curl -sS --config - -m 30 -X "$method" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -w $'\n%{http_code}' \
        "$@" \
        "${GH_API}${path}") || rc=$?

  if (( rc != 0 )); then
    log_warn "GitHub: falha de rede em ${method} ${path} (curl rc=${rc})"
    return 1
  fi

  # `-w '\n%{http_code}'` cola o status como ultima linha; o corpo pode ter
  # quantas linhas quiser, entao a fatia e sempre a partir da ULTIMA quebra.
  code="${raw##*$'\n'}"
  body="${raw%$'\n'*}"

  if [[ ! "$code" =~ ^2[0-9][0-9]$ ]]; then
    log_warn "GitHub: HTTP ${code} em ${method} ${path}"
    return 1
  fi
  printf '%s\n' "$body"
}

# Status HTTP de um GET autenticado, sem corpo. Ecoa o codigo (000 se a chamada
# nem saiu). Sempre devolve 0 — quem chama decide o que o codigo significa.
gh_http_code() {
  local path="$1" code
  code=$(gh_auth_config | curl -sS --config - -m 20 -o /dev/null -w '%{http_code}' \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "${GH_API}${path}" 2>/dev/null) || code="000"
  [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
  printf '%s\n' "$code"
}

# Fetch a fresh registration token (valid ~1h, single-use).
gh_registration_token() {
  local resp token
  resp=$(gh_curl POST "/repos/${GITHUB_REPO}/actions/runners/registration-token") \
    || die "Failed to get registration token — veja o HTTP acima"
  token=$(echo "$resp" | jq -r '.token // empty')
  [[ -n "$token" ]] || die "Failed to get registration token: resposta sem .token"
  echo "$token"
}

# Fetch a remove token (used to gracefully unregister).
gh_remove_token() {
  local resp token
  resp=$(gh_curl POST "/repos/${GITHUB_REPO}/actions/runners/remove-token") \
    || die "Failed to get remove token — veja o HTTP acima"
  token=$(echo "$resp" | jq -r '.token // empty')
  [[ -n "$token" ]] || die "Failed to get remove token: resposta sem .token"
  echo "$token"
}

# List runners registered on the repo. Returns raw JSON array.
#
# Segue a paginacao. Com `per_page=100` e uma pagina so, uma frota grande fazia
# `gh_runner_id_by_name` nao achar um runner que existe — e `remove_runner`
# deixava a registracao ativa sem host correspondente.
gh_list_runners() {
  local page=1 body chunk n all='[]'
  while (( page <= 20 )); do
    body=$(gh_curl GET "/repos/${GITHUB_REPO}/actions/runners?per_page=100&page=${page}") || return 1
    chunk=$(printf '%s' "$body" | jq -c '.runners // []') || return 1
    n=$(printf '%s' "$chunk" | jq 'length') || return 1
    all=$(jq -nc --argjson a "$all" --argjson b "$chunk" '$a + $b') || return 1
    (( n < 100 )) && break
    page=$(( page + 1 ))
  done
  printf '%s\n' "$all"
}

# Find a runner ID by name. Empty output if not found; != 0 se a API falhou.
gh_runner_id_by_name() {
  local name="$1" json
  json=$(gh_list_runners) || return 1
  printf '%s' "$json" | jq -r --arg n "$name" '.[] | select(.name == $n) | .id' | head -1
}

# Delete a runner by GitHub ID.
gh_delete_runner() {
  local id="$1"
  [[ "$id" =~ ^[0-9]+$ ]] || { log_warn "gh_delete_runner: id invalido '$id'"; return 1; }
  local code
  code=$(gh_auth_config | curl -sS --config - -m 30 -o /dev/null -w '%{http_code}' \
    -X DELETE \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${GH_API}/repos/${GITHUB_REPO}/actions/runners/${id}") || code="000"
  [[ "$code" == "204" ]] || { log_warn "Delete runner $id returned HTTP $code"; return 1; }
}

# Latest stable runner version (e.g. "2.334.0").
gh_latest_runner_version() {
  local body version
  body=$(gh_curl GET "/repos/actions/runner/releases/latest") || return 1
  version=$(printf '%s' "$body" | jq -r '.tag_name // empty' | sed 's/^v//')
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  printf '%s\n' "$version"
}

# SHA256 esperado do tarball linux-x64 de uma versao, vindo dos metadados da
# release. Prefere o digest do asset; cai no marcador que o actions/runner
# publica nas notas da release.
gh_runner_sha256() {
  local version="$1" body sha
  body=$(gh_curl GET "/repos/actions/runner/releases/tags/v${version}") || return 1

  sha=$(printf '%s' "$body" \
        | jq -r --arg f "actions-runner-linux-x64-${version}.tar.gz" \
            '(.assets // [])[] | select(.name == $f) | .digest // empty' \
        | sed 's/^sha256://' | head -1)

  if [[ ! "$sha" =~ ^[0-9a-f]{64}$ ]]; then
    sha=$(printf '%s' "$body" | jq -r '.body // ""' \
          | sed -n 's/.*<!-- BEGIN SHA linux-x64 -->\([0-9a-f]\{64\}\).*/\1/p' | head -1)
  fi

  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$sha"
}

# Validate the configured token + repo combo.
gh_validate_auth() {
  local code
  code=$(gh_http_code "/repos/${GITHUB_REPO}")
  case "$code" in
    200) return 0 ;;
    401) die "GitHub auth failed (401) — token invalid or expired" ;;
    403) die "GitHub recusou (403) — token sem permissao ou rate limit" ;;
    404) die "Repo not found or token lacks access: $GITHUB_REPO" ;;
    000) die "Nao foi possivel falar com a API do GitHub (rede?)" ;;
    *)   die "Unexpected status $code from GitHub API" ;;
  esac
}

# `true` quando o repositorio alvo e publico.
#
# Repo publico + self-hosted runner significa que qualquer PR de fork executa
# codigo arbitrario nesta maquina — o cenario que a documentacao do GitHub
# desaconselha explicitamente. Vale um aviso alto em cada provisionamento.
gh_repo_is_public() {
  local body priv
  body=$(gh_curl GET "/repos/${GITHUB_REPO}") || return 1
  priv=$(printf '%s' "$body" | jq -r '.private // empty')
  [[ "$priv" == "false" ]]
}

# Aviso unico sobre a exposicao de repo publico. Nao bloqueia: quem opera decide.
warn_if_public_repo() {
  gh_repo_is_public 2>/dev/null || return 0
  log_warn "${GITHUB_REPO} e PUBLICO. Qualquer PR de fork roda codigo arbitrario nesta maquina,"
  log_warn "com o mesmo usuario que o runner-mgr — inclusive lendo o .env. Veja SECURITY.md."
}
