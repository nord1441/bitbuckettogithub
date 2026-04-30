#!/usr/bin/env bash
# Migrate every repository from a Bitbucket Cloud (Free) workspace to GitHub
# (Free), preserving private/public flag and Git LFS objects.
#
# Required tools : bash, curl, jq, git, git-lfs (optional)
# Required env   : BITBUCKET_API_TOKEN, GITHUB_TOKEN, BB_WORKSPACE
# Optional env   : BITBUCKET_EMAIL, GH_ORG, WORK_DIR, DRY_RUN, SKIP_EXISTING

set -euo pipefail

# Never let git block on a credential prompt — fail fast instead.
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/echo

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
: "${BB_WORKSPACE:?set BB_WORKSPACE to your Bitbucket workspace slug}"
: "${BITBUCKET_API_TOKEN:?set BITBUCKET_API_TOKEN (Atlassian API token or Bitbucket access token)}"
: "${GITHUB_TOKEN:?set GITHUB_TOKEN (GitHub PAT with 'repo' scope)}"

BITBUCKET_EMAIL="${BITBUCKET_EMAIL:-}"   # set if your token wants Basic auth
GH_ORG="${GH_ORG:-}"                     # empty → create under your user
WORK_DIR="${WORK_DIR:-/tmp/bb2gh}"
DRY_RUN="${DRY_RUN:-0}"
SKIP_EXISTING="${SKIP_EXISTING:-0}"

BB_API="https://api.bitbucket.org/2.0"
GH_API="https://api.github.com"
UA="bb2gh-shell/0.1"

# These are filled in by detect_bb_auth(); used by every later HTTP/git call.
BB_AUTH_HEADER=""   # e.g.  "Authorization: Bearer xxx" — used both for the
                    # REST API and (via http.extraHeader) for git transport.

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
log()  { printf '[info] %s\n'  "$*" >&2; }
step() { printf '[step] %s\n'  "$*" >&2; }
warn() { printf '[warn] %s\n'  "$*" >&2; }
err()  { printf '[error] %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"
}

require_cmd curl
require_cmd jq
require_cmd git

# -----------------------------------------------------------------------------
# Bitbucket auth detection
# -----------------------------------------------------------------------------
# Tries (in order): Bearer, Basic with email, Basic with x-token-auth.
# Stops at the first one that returns 200 from /2.0/user.
detect_bb_auth() {
  local mode header status
  for mode in bearer basic token-auth; do
    case "$mode" in
      bearer)
        header="Authorization: Bearer ${BITBUCKET_API_TOKEN}"
        ;;
      basic)
        [ -n "$BITBUCKET_EMAIL" ] || continue
        local b64
        b64="$(printf '%s:%s' "$BITBUCKET_EMAIL" "$BITBUCKET_API_TOKEN" \
               | base64 | tr -d '\n')"
        header="Authorization: Basic ${b64}"
        ;;
      token-auth)
        local b64
        b64="$(printf 'x-token-auth:%s' "$BITBUCKET_API_TOKEN" \
               | base64 | tr -d '\n')"
        header="Authorization: Basic ${b64}"
        ;;
    esac
    status="$(curl -sS -o /dev/null -w '%{http_code}' \
        -H "$header" -H "User-Agent: $UA" \
        "$BB_API/user" || echo 000)"
    if [ "$status" = "200" ]; then
      log "bitbucket auth ok via $mode"
      BB_AUTH_HEADER="$header"
      return 0
    fi
    warn "bitbucket auth via $mode returned HTTP $status"
  done
  die "could not authenticate to Bitbucket. Verify your token type/scopes:
   - Atlassian API token (id.atlassian.com → 'Create API token with scopes')
     scopes:  read:account, read:repository:bitbucket
     set BITBUCKET_EMAIL too if you want forced Basic auth.
   - Bitbucket access token (Bitbucket UI → Settings → Access tokens):
     scopes:  Account: Read, Repositories: Read."
}

bb_curl() {
  # Usage: bb_curl <url>   → prints body, exits non-zero on HTTP >= 400
  local url="$1" tmp http
  tmp="$(mktemp)"
  http="$(curl -sS -o "$tmp" -w '%{http_code}' \
            -H "$BB_AUTH_HEADER" \
            -H "Accept: application/json" \
            -H "User-Agent: $UA" \
            "$url" || echo 000)"
  if [ "$http" -ge 400 ] || [ "$http" = "000" ]; then
    err "Bitbucket GET $url -> HTTP $http"
    sed -n '1,40p' "$tmp" >&2 || true
    rm -f "$tmp"
    return 1
  fi
  cat "$tmp"
  rm -f "$tmp"
}

# URL-encode a single path segment. Handles `@`, `+`, etc.
urlenc() {
  jq -rn --arg v "$1" '$v | @uri'
}

# -----------------------------------------------------------------------------
# GitHub helpers
# -----------------------------------------------------------------------------
gh_curl() {
  # Usage: gh_curl METHOD PATH [json-body]
  local method="$1" path="$2" body="${3:-}"
  local url="${GH_API}${path}" tmp http args=()
  tmp="$(mktemp)"
  args=(-sS -o "$tmp" -w '%{http_code}'
        -X "$method"
        -H "Authorization: Bearer ${GITHUB_TOKEN}"
        -H "Accept: application/vnd.github+json"
        -H "X-GitHub-Api-Version: 2022-11-28"
        -H "User-Agent: $UA")
  if [ -n "$body" ]; then
    args+=(-H "Content-Type: application/json" --data "$body")
  fi
  http="$(curl "${args[@]}" "$url" || echo 000)"
  cat "$tmp"
  rm -f "$tmp"
  printf '\n%s' "$http"
}

gh_owner_login() {
  if [ -n "$GH_ORG" ]; then
    printf '%s' "$GH_ORG"
    return
  fi
  local out body http
  out="$(gh_curl GET /user)" || die "GitHub /user call failed"
  http="${out##*$'\n'}"
  body="${out%$'\n'*}"
  [ "$http" = "200" ] || die "GitHub /user returned HTTP $http: $body"
  printf '%s' "$body" | jq -r .login
}

gh_repo_exists() {
  local owner="$1" name="$2" out http
  out="$(gh_curl GET "/repos/${owner}/${name}")" || true
  http="${out##*$'\n'}"
  [ "$http" = "200" ]
}

gh_create_repo() {
  local name="$1" desc="$2" private="$3" path body out http
  if [ -n "$GH_ORG" ]; then
    path="/orgs/${GH_ORG}/repos"
  else
    path="/user/repos"
  fi
  body="$(jq -n --arg n "$name" --arg d "$desc" --argjson p "$private" '{
    name: $n, description: $d, private: $p,
    has_issues: true, has_wiki: false, auto_init: false
  }')"
  out="$(gh_curl POST "$path" "$body")"
  http="${out##*$'\n'}"
  if [ "$http" != "201" ] && [ "$http" != "202" ]; then
    err "GitHub create-repo $name failed (HTTP $http): ${out%$'\n'*}"
    return 1
  fi
}

# -----------------------------------------------------------------------------
# Repository listing (Bitbucket → JSONL of {slug, is_private, description, https})
# -----------------------------------------------------------------------------
list_bb_repos() {
  local url="${BB_API}/repositories/$(urlenc "$BB_WORKSPACE")?pagelen=100&role=member"
  local page
  while [ -n "$url" ] && [ "$url" != "null" ]; do
    page="$(bb_curl "$url")" || die "failed to list Bitbucket repos"
    printf '%s' "$page" | jq -c '
      .values[]
      | ( [ .links.clone[]? | select(.name == "https") | .href ] | .[0] // "" )
        as $href
      | select($href != "")
      | {
          slug,
          name: (.name // .slug),
          description: (.description // ""),
          is_private: (.is_private // true),
          # strip embedded "user@" if Bitbucket included one
          https: ($href | sub("^https://[^@]+@"; "https://"))
        }
    '
    url="$(printf '%s' "$page" | jq -r '.next // empty')"
  done
}

# -----------------------------------------------------------------------------
# Per-repo migration
# -----------------------------------------------------------------------------
migrate_one() {
  local slug="$1" name="$2" desc="$3" private="$4" bb_https="$5" gh_owner="$6"
  local privacy_label
  [ "$private" = "true" ] && privacy_label="private" || privacy_label="public"
  log "==> ${slug}  [${privacy_label}]"

  # 1. Ensure GitHub side exists
  if gh_repo_exists "$gh_owner" "$slug"; then
    log "    github repo ${gh_owner}/${slug} already exists"
    if [ "$SKIP_EXISTING" = "1" ]; then
      log "    SKIP_EXISTING=1; leaving destination untouched"
      return 0
    fi
  else
    step "    creating github repo ${gh_owner}/${slug} (${privacy_label})"
    if [ "$DRY_RUN" != "1" ]; then
      gh_create_repo "$slug" "$desc" "$private" || return 1
    fi
  fi

  # 2. Build URLs.
  #    - For Bitbucket we authenticate via http.extraHeader, which works
  #      regardless of the underlying token type (Atlassian API token vs
  #      Bitbucket access token vs Bearer-only tokens).
  #    - For GitHub, embedding the PAT in the URL is fine.
  local gh_authed local_dir
  gh_authed="https://x-access-token:$(urlenc "$GITHUB_TOKEN")@github.com/${gh_owner}/${slug}.git"
  local_dir="${WORK_DIR}/${slug}.git"

  local bb_git_cfg=( -c "http.https://bitbucket.org/.extraHeader=${BB_AUTH_HEADER}" )

  if [ "$DRY_RUN" = "1" ]; then
    log "    [dry-run] would clone --mirror ${bb_https}"
    log "    [dry-run] would push  --mirror -> https://github.com/${gh_owner}/${slug}.git"
    return 0
  fi

  # 3. mirror clone (bare) — idempotent: nuke any leftover.
  rm -rf -- "$local_dir"
  step "    clone --mirror ${bb_https}"
  git "${bb_git_cfg[@]}" clone --mirror "$bb_https" "$local_dir" \
    || { err "    clone failed for ${slug}"; return 1; }

  # 4. LFS fetch (no-op when not used; warn-only if git-lfs missing)
  if command -v git-lfs >/dev/null 2>&1; then
    step "    git lfs fetch --all"
    ( cd "$local_dir" && git "${bb_git_cfg[@]}" lfs fetch --all ) \
      || warn "    git lfs fetch failed (likely no LFS data); continuing"
  else
    warn "    git-lfs not installed; skipping LFS fetch/push"
  fi

  # 5. mirror push to GitHub
  step "    push --mirror -> https://github.com/${gh_owner}/${slug}.git"
  ( cd "$local_dir" && git push --mirror "$gh_authed" ) \
    || { err "    push failed for ${slug}"; return 1; }

  # 6. LFS push
  if command -v git-lfs >/dev/null 2>&1; then
    step "    git lfs push --all"
    ( cd "$local_dir" && git lfs push --all "$gh_authed" ) \
      || warn "    git lfs push failed (likely no LFS data); continuing"
  fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  mkdir -p -- "$WORK_DIR"
  detect_bb_auth

  log "listing repositories in Bitbucket workspace ${BB_WORKSPACE}"
  local repos_jsonl
  repos_jsonl="$(list_bb_repos)"
  local total
  total="$(printf '%s' "$repos_jsonl" | grep -c . || true)"
  log "found ${total} repository(ies)"

  local gh_owner
  gh_owner="$(gh_owner_login)"
  log "GitHub destination owner: ${gh_owner}"

  local idx=0 failures=0 ok=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    idx=$((idx + 1))
    local slug name desc is_private https
    slug="$(printf '%s' "$line"        | jq -r .slug)"
    name="$(printf '%s' "$line"        | jq -r .name)"
    desc="$(printf '%s' "$line"        | jq -r .description)"
    is_private="$(printf '%s' "$line"  | jq -r .is_private)"
    https="$(printf '%s' "$line"       | jq -r .https)"
    if [ -z "$slug" ] || [ -z "$https" ] || [ "$https" = "null" ]; then
      warn "  skipping malformed entry: $line"
      continue
    fi
    if migrate_one "$slug" "$name" "$desc" "$is_private" "$https" "$gh_owner"; then
      ok=$((ok + 1))
      log "    done: ${slug}  (${idx}/${total})"
    else
      failures=$((failures + 1))
      err "    FAILED: ${slug}  (${idx}/${total})"
    fi
  done <<<"$repos_jsonl"

  log "completed: ${ok}/${total} succeeded, ${failures} failed"
  [ "$failures" -eq 0 ]
}

main "$@"
