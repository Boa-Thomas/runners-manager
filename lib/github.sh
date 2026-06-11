#!/usr/bin/env bash
# GitHub API helpers.

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

GH_API="https://api.github.com"

gh_curl() {
  local method="$1" path="$2"
  shift 2
  curl -sS -X "$method" \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@" \
    "${GH_API}${path}"
}

# Fetch a fresh registration token (valid ~1h, single-use).
gh_registration_token() {
  local resp
  resp=$(gh_curl POST "/repos/${GITHUB_REPO}/actions/runners/registration-token")
  local token
  token=$(echo "$resp" | jq -r '.token // empty')
  [[ -n "$token" ]] || die "Failed to get registration token: $resp"
  echo "$token"
}

# Fetch a remove token (used to gracefully unregister).
gh_remove_token() {
  local resp
  resp=$(gh_curl POST "/repos/${GITHUB_REPO}/actions/runners/remove-token")
  local token
  token=$(echo "$resp" | jq -r '.token // empty')
  [[ -n "$token" ]] || die "Failed to get remove token: $resp"
  echo "$token"
}

# List runners registered on the repo. Returns raw JSON array.
gh_list_runners() {
  gh_curl GET "/repos/${GITHUB_REPO}/actions/runners?per_page=100" \
    | jq '.runners // []'
}

# Find a runner ID by name. Empty if not found.
gh_runner_id_by_name() {
  local name="$1"
  gh_list_runners | jq -r --arg n "$name" '.[] | select(.name == $n) | .id' | head -1
}

# Delete a runner by GitHub ID.
gh_delete_runner() {
  local id="$1"
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X DELETE \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${GH_API}/repos/${GITHUB_REPO}/actions/runners/${id}")
  [[ "$code" == "204" ]] || log_warn "Delete runner $id returned HTTP $code"
}

# Latest stable runner version (e.g. "2.334.0").
gh_latest_runner_version() {
  curl -sS "https://api.github.com/repos/actions/runner/releases/latest" \
    -H "Accept: application/vnd.github+json" \
    | jq -r '.tag_name' | sed 's/^v//'
}

# Validate the configured token + repo combo.
gh_validate_auth() {
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "${GH_API}/repos/${GITHUB_REPO}")
  case "$code" in
    200) return 0 ;;
    401) die "GitHub auth failed (401) — token invalid or expired" ;;
    404) die "Repo not found or token lacks access: $GITHUB_REPO" ;;
    *)   die "Unexpected status $code from GitHub API" ;;
  esac
}
