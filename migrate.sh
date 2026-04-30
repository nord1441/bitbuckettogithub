#!/usr/bin/env bash
# Migrate every repository from a Bitbucket Cloud (Free) workspace to GitHub
# (Free), preserving private/public flag and Git LFS objects.
#
# Required tools : bash, curl, jq, git, git-lfs (optional)
# Required env   : BITBUCKET_API_TOKEN, GITHUB_TOKEN, BB_WORKSPACE
# Optional env   : BITBUCKET_EMAIL, GH_ORG, WORK_DIR, DRY_RUN, SKIP_EXISTING,
#                  BB_GIT_SSH (=1 to use SSH for Bitbucket git transport)

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
OVERWRITE_EXISTING="${OVERWRITE_EXISTING:-0}"  # 1 = DELETE+recreate existing GitHub repo
BB_GIT_SSH="${BB_GIT_SSH:-0}"            # 1 = use ssh for clone/push from Bitbucket
AUTO_LFS_MIGRATE="${AUTO_LFS_MIGRATE:-0}"           # 1 = on push reject, migrate large files to LFS and retry
LFS_MIGRATE_THRESHOLD="${LFS_MIGRATE_THRESHOLD:-100MB}"  # threshold for that migration

if [ "$SKIP_EXISTING" = "1" ] && [ "$OVERWRITE_EXISTING" = "1" ]; then
  printf '[error] SKIP_EXISTING and OVERWRITE_EXISTING are mutually exclusive\n' >&2
  exit 2
fi

BB_API="https://api.bitbucket.org/2.0"
GH_API="https://api.github.com"
UA="bb2gh-shell/0.1"

# Filled in by detect_bb_auth(): the Authorization header that succeeded
# against the REST API.
BB_AUTH_HEADER=""

# Filled in by detect_git_transport(): how to authenticate `git` against
# bitbucket.org for clone/push.
#   "header"     → use http.extraHeader with $BB_AUTH_HEADER
#   "url-token"  → embed https://x-token-auth:TOKEN@... in the clone URL
BB_GIT_MODE=""

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
# git transport detection (separate from REST auth)
# -----------------------------------------------------------------------------
# Atlassian API tokens authenticate fine against api.bitbucket.org but are
# *rejected* by bitbucket.org for the git smart protocol. To handle that, we
# probe the live git transport using a known repo URL before kicking off the
# real migration. Two strategies are tried in turn:
#
#   1. http.extraHeader = $BB_AUTH_HEADER
#        Works for Bearer-capable tokens (Workspace/Repo Access Tokens) and
#        for legacy App Passwords used via the Basic header.
#   2. URL-embedded https://x-token-auth:TOKEN@bitbucket.org/...
#        Works for Workspace/Repo Access Tokens.
#
# If both fail, the user almost certainly has an Atlassian-only API token and
# needs a Bitbucket-side Workspace Access Token instead.
detect_git_transport() {
  local probe_https="$1" probe_ssh="${2:-}"

  # SSH mode (BB_GIT_SSH=1): rely on the user's SSH key. Verify reachability
  # with `git ls-remote` against the first repo's ssh URL.
  if [ "$BB_GIT_SSH" = "1" ]; then
    if [ -z "$probe_ssh" ] || [ "$probe_ssh" = "null" ]; then
      err "BB_GIT_SSH=1 but no ssh clone URL was returned by Bitbucket"
      return 1
    fi
    step "verifying git ssh transport against ${probe_ssh}"
    if GIT_SSH_COMMAND="ssh -o BatchMode=yes" \
       git ls-remote "$probe_ssh" >/dev/null 2>&1; then
      log "git transport ok (ssh mode)"
      BB_GIT_MODE="ssh"
      return 0
    fi
    err "ssh authentication to bitbucket.org failed."
    err "  Run this to debug:"
    err "    ssh -T git@bitbucket.org"
    err "  If your key isn't registered, add it at:"
    err "    https://bitbucket.org/account/settings/ssh-keys/"
    return 1
  fi

  # HTTPS modes.
  step "verifying git transport against ${probe_https}"

  if git -c "http.https://bitbucket.org/.extraHeader=${BB_AUTH_HEADER}" \
         ls-remote "$probe_https" >/dev/null 2>&1; then
    log "git transport ok (extraHeader mode)"
    BB_GIT_MODE="header"
    return 0
  fi
  warn "git extraHeader auth rejected; trying x-token-auth URL"

  local rest authed
  rest="${probe_https#https://}"
  authed="https://x-token-auth:$(urlenc "$BITBUCKET_API_TOKEN")@${rest}"
  if git ls-remote "$authed" >/dev/null 2>&1; then
    log "git transport ok (x-token-auth URL mode)"
    BB_GIT_MODE="url-token"
    return 0
  fi

  err "git transport authentication failed for every HTTPS mode."
  err "  Your token authenticates against the REST API but cannot push/clone"
  err "  via git over HTTPS. This is the typical behavior of an"
  err "  Atlassian-account API token (id.atlassian.com)."
  err ""
  err "  Two ways to fix this:"
  err "    A) Use SSH for git transport. Re-run with:"
  err "         export BB_GIT_SSH=1"
  err "       and make sure 'ssh -T git@bitbucket.org' succeeds."
  err "    B) Create a *Bitbucket Workspace Access Token* and use it as"
  err "       BITBUCKET_API_TOKEN (unset BITBUCKET_EMAIL):"
  err "         https://bitbucket.org/${BB_WORKSPACE}/workspace/settings/access-tokens"
  err "       Permissions: Repositories: Read (Account: Read recommended)."
  return 1
}

# Build a clone URL appropriate for the active git transport mode.
# Args: <https-url> [<ssh-url>]
bb_clone_url() {
  local https_url="$1" ssh_url="${2:-}"
  case "$BB_GIT_MODE" in
    ssh)
      if [ -z "$ssh_url" ] || [ "$ssh_url" = "null" ]; then
        # Fall back: synthesize the canonical SSH form from the HTTPS URL.
        local path="${https_url#https://bitbucket.org/}"
        printf 'git@bitbucket.org:%s' "$path"
      else
        printf '%s' "$ssh_url"
      fi
      ;;
    url-token)
      local rest="${https_url#https://}"
      printf 'https://x-token-auth:%s@%s' \
        "$(urlenc "$BITBUCKET_API_TOKEN")" "$rest"
      ;;
    *)
      printf '%s' "$https_url"
      ;;
  esac
}

# Extra `git -c` flags appropriate for the active git transport mode.
bb_git_cfg() {
  if [ "$BB_GIT_MODE" = "header" ]; then
    printf '%s\n' "-c" \
      "http.https://bitbucket.org/.extraHeader=${BB_AUTH_HEADER}"
  fi
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

# Push the bare mirror to GitHub. On failure due to GitHub's per-file size
# cap, optionally rewrite history with `git lfs migrate import` to move
# large files into LFS, then retry. Only runs the migrate step when
# AUTO_LFS_MIGRATE=1 (rewriting history is destructive).
gh_push_mirror() {
  local local_dir="$1" gh_authed="$2"
  local log_file rc
  log_file="$(mktemp)"

  ( cd "$local_dir" && git push --mirror "$gh_authed" ) 2>&1 | tee "$log_file"
  rc="${PIPESTATUS[0]}"
  if [ "$rc" -eq 0 ]; then
    rm -f "$log_file"
    return 0
  fi

  # Did GitHub reject because of the 100MB-per-file cap?
  if grep -qE "exceeds GitHub's file size limit|GH001: Large files detected" \
       "$log_file"; then
    if [ "$AUTO_LFS_MIGRATE" != "1" ]; then
      err "    push rejected: a file exceeds GitHub's per-file size limit (100MB)."
      err "    Re-run with AUTO_LFS_MIGRATE=1 to convert files larger than"
      err "    \${LFS_MIGRATE_THRESHOLD} (currently ${LFS_MIGRATE_THRESHOLD}) to Git LFS"
      err "    before pushing. Note: this REWRITES history (commit SHAs change)."
      rm -f "$log_file"
      return 1
    fi
    if ! command -v git-lfs >/dev/null 2>&1; then
      err "    git-lfs not installed; cannot auto-migrate large files"
      rm -f "$log_file"
      return 1
    fi
    rm -f "$log_file"

    warn "    AUTO_LFS_MIGRATE=1: moving files >${LFS_MIGRATE_THRESHOLD} to Git LFS and retrying push"
    if ! ( cd "$local_dir" && \
           git lfs migrate import --everything \
             --above="$LFS_MIGRATE_THRESHOLD" ); then
      err "    git lfs migrate import failed"
      return 1
    fi

    # Second push attempt — the rewrite changed every commit that touched
    # a large file, so it MUST be a force update on the destination.
    log_file="$(mktemp)"
    ( cd "$local_dir" && git push --mirror "$gh_authed" ) 2>&1 | tee "$log_file"
    rc="${PIPESTATUS[0]}"
    rm -f "$log_file"
    return "$rc"
  fi

  rm -f "$log_file"
  return 1
}

gh_delete_repo() {
  # DELETE /repos/{owner}/{repo}. Requires the PAT to carry the delete_repo
  # scope (not included in plain `repo`). 204 = deleted, 404 = already gone.
  local owner="$1" name="$2" out http
  out="$(gh_curl DELETE "/repos/${owner}/${name}")"
  http="${out##*$'\n'}"
  case "$http" in
    204|404) return 0 ;;
    403)
      err "GitHub delete-repo ${owner}/${name} forbidden (HTTP 403)."
      err "  The PAT in GITHUB_TOKEN is missing the 'delete_repo' scope."
      err "  Add it at https://github.com/settings/tokens and rerun."
      return 1
      ;;
    *)
      err "GitHub delete-repo ${owner}/${name} failed (HTTP $http): ${out%$'\n'*}"
      return 1
      ;;
  esac
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
    # We synthesize clone URLs from `.full_name` (which is the canonical
    # `<workspace_slug>/<repo_slug>`, always lowercase), instead of trusting
    # `links.clone[].href`. Some older Bitbucket repos return mixed-case URLs
    # via that link list, which then fail to clone.
    printf '%s' "$page" | jq -c '
      .values[]
      | ( .full_name
          // ((.workspace.slug // "") + "/" + (.slug // ""))
        ) as $fn
      | select($fn != "/" and $fn != "")
      | {
          slug,
          name: (.name // .slug),
          description: (.description // ""),
          is_private: (.is_private // true),
          full_name: $fn,
          https: ("https://bitbucket.org/" + $fn + ".git"),
          ssh:   ("git@bitbucket.org:"   + $fn + ".git")
        }
    '
    url="$(printf '%s' "$page" | jq -r '.next // empty')"
  done
}

# -----------------------------------------------------------------------------
# Per-repo migration
# -----------------------------------------------------------------------------
migrate_one() {
  local slug="$1" name="$2" desc="$3" private="$4"
  local bb_https="$5" bb_ssh="$6" gh_owner="$7"
  local privacy_label
  [ "$private" = "true" ] && privacy_label="private" || privacy_label="public"
  log "==> ${slug}  [${privacy_label}]"

  # 1. Ensure GitHub side exists in the desired clean state.
  if gh_repo_exists "$gh_owner" "$slug"; then
    log "    github repo ${gh_owner}/${slug} already exists"
    if [ "$SKIP_EXISTING" = "1" ]; then
      log "    SKIP_EXISTING=1; leaving destination untouched"
      return 0
    fi
    if [ "$OVERWRITE_EXISTING" = "1" ]; then
      step "    OVERWRITE_EXISTING=1: deleting and recreating ${gh_owner}/${slug}"
      if [ "$DRY_RUN" != "1" ]; then
        gh_delete_repo "$gh_owner" "$slug" || return 1
        gh_create_repo "$slug" "$desc" "$private" || return 1
      fi
    fi
  else
    step "    creating github repo ${gh_owner}/${slug} (${privacy_label})"
    if [ "$DRY_RUN" != "1" ]; then
      gh_create_repo "$slug" "$desc" "$private" || return 1
    fi
  fi

  # 2. Build URLs / git config.
  local gh_authed local_dir bb_url
  gh_authed="https://x-access-token:$(urlenc "$GITHUB_TOKEN")@github.com/${gh_owner}/${slug}.git"
  local_dir="${WORK_DIR}/${slug}.git"
  bb_url="$(bb_clone_url "$bb_https" "$bb_ssh")"

  # Read bb_git_cfg into an array (may be empty).
  local -a bb_cfg=()
  if [ "$BB_GIT_MODE" = "header" ]; then
    bb_cfg=(-c "http.https://bitbucket.org/.extraHeader=${BB_AUTH_HEADER}")
  fi

  if [ "$DRY_RUN" = "1" ]; then
    log "    [dry-run] would clone --mirror ${bb_https}"
    log "    [dry-run] would push  --mirror -> https://github.com/${gh_owner}/${slug}.git"
    return 0
  fi

  # 3. mirror clone (bare) — idempotent: nuke any leftover.
  rm -rf -- "$local_dir"
  step "    clone --mirror ${bb_url}"
  git "${bb_cfg[@]}" clone --mirror "$bb_url" "$local_dir" \
    || { err "    clone failed for ${slug} (url=${bb_url})"; return 1; }

  # 4. LFS fetch (no-op when not used; warn-only if git-lfs missing)
  if command -v git-lfs >/dev/null 2>&1; then
    step "    git lfs fetch --all"
    ( cd "$local_dir" && git "${bb_cfg[@]}" lfs fetch --all ) \
      || warn "    git lfs fetch failed (likely no LFS data); continuing"
  else
    warn "    git-lfs not installed; skipping LFS fetch/push"
  fi

  # 5. mirror push to GitHub (with optional auto-LFS-migrate fallback)
  step "    push --mirror -> https://github.com/${gh_owner}/${slug}.git"
  gh_push_mirror "$local_dir" "$gh_authed" \
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
  if [ "$total" -eq 0 ]; then
    die "no repositories returned by Bitbucket; aborting"
  fi

  # Probe git transport with the first repo's clone URL before kicking off
  # the (potentially long) migration loop. This converts a token type
  # mismatch from "all 25 fail with the same message" into one clear error.
  local probe_https probe_ssh
  probe_https="$(printf '%s' "$repos_jsonl" | head -1 | jq -r .https)"
  probe_ssh="$(printf '%s' "$repos_jsonl" | head -1 | jq -r '.ssh // empty')"
  if [ "$DRY_RUN" != "1" ]; then
    detect_git_transport "$probe_https" "$probe_ssh" || exit 1
  fi

  local gh_owner
  gh_owner="$(gh_owner_login)"
  log "GitHub destination owner: ${gh_owner}"

  local idx=0 failures=0 ok=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    idx=$((idx + 1))
    local slug name desc is_private https ssh
    slug="$(printf '%s' "$line"        | jq -r .slug)"
    name="$(printf '%s' "$line"        | jq -r .name)"
    desc="$(printf '%s' "$line"        | jq -r .description)"
    is_private="$(printf '%s' "$line"  | jq -r .is_private)"
    https="$(printf '%s' "$line"       | jq -r .https)"
    ssh="$(printf '%s' "$line"         | jq -r '.ssh // empty')"
    if [ -z "$slug" ] || [ -z "$https" ] || [ "$https" = "null" ]; then
      warn "  skipping malformed entry: $line"
      continue
    fi
    if migrate_one "$slug" "$name" "$desc" "$is_private" \
                   "$https" "$ssh" "$gh_owner"; then
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
