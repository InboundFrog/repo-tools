# shellcheck shell=bash
# shellcheck disable=SC2034 # constants are used by the scripts that source this
# Shared helpers for repo-tools. Sourced by bin/repo-protect and the tests — not
# executable on its own.

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  echo "repo-tools needs bash >= 4.4 (macOS: brew install bash)" >&2
  exit 1
fi

# --- Settings (override via environment) -------------------------------------

# Repo hosting the reusable workflows. Callers pin its release tags, so
# repo-protect guards those tags when run against it.
RT_SOURCE_REPO="${RT_SOURCE_REPO:-InboundFrog/repo-tools}"
# The job every caller ends with; the one check branch protection requires.
RT_CI_CHECK_NAME="CI OK"
RT_DRY_RUN="${RT_DRY_RUN:-0}"

# --- Logging -----------------------------------------------------------------

if [[ -t 2 ]]; then
  _rt_b=$'\e[1;34m' _rt_y=$'\e[33m' _rt_r=$'\e[31m' _rt_g=$'\e[32m' _rt_0=$'\e[0m'
else
  _rt_b='' _rt_y='' _rt_r='' _rt_g='' _rt_0=''
fi

log() { printf '%s==>%s %s\n' "$_rt_b" "$_rt_0" "$*" >&2; }
info() { printf '    %s\n' "$*" >&2; }
ok() { printf '    %s✓%s %s\n' "$_rt_g" "$_rt_0" "$*" >&2; }
warn() { printf '    %swarn:%s %s\n' "$_rt_y" "$_rt_0" "$*" >&2; }
die() {
  printf '%serror:%s %s\n' "$_rt_r" "$_rt_0" "$*" >&2
  exit 1
}

[[ $RT_SOURCE_REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
  die "RT_SOURCE_REPO must look like owner/name (got: $RT_SOURCE_REPO)"

rt_require() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
  done
}

# --- Temp space ----------------------------------------------------------------

# Created here, in the top-level shell, so the cleanup trap isn't tied to a
# subshell (e.g. a $(...) call) that would delete it early.
_RT_TMP=$(mktemp -d "${TMPDIR:-/tmp}/repo-tools.XXXXXX")
trap 'rm -rf "$_RT_TMP"' EXIT

rt_tmpdir() { printf '%s\n' "$_RT_TMP"; }

# --- GitHub ----------------------------------------------------------------------

rt_owner() {
  if [[ -z ${RT_OWNER:-} ]]; then
    RT_OWNER=$(gh api user --jq .login) || die "could not determine GitHub user (is gh logged in?)"
  fi
  printf '%s\n' "$RT_OWNER"
}

# "name" -> "owner/name"; "owner/name" passes through. Anything else (an
# option-like "-x", a URL, a path) is refused before it reaches gh.
rt_resolve_repo() {
  [[ $1 =~ ^[A-Za-z0-9_.][A-Za-z0-9_.-]*(/[A-Za-z0-9_.][A-Za-z0-9_.-]*)?$ && /$1/ != */./* && /$1/ != */../* ]] ||
    die "not a repository name: '$1' (expected owner/name or name)"
  if [[ $1 == */* ]]; then printf '%s\n' "$1"; else printf '%s/%s\n' "$(rt_owner)" "$1"; fi
}

# Loads repo metadata into RT_REPO, RT_VISIBILITY, RT_DEFAULT_BRANCH,
# RT_ARCHIVED and RT_PERMISSION.
rt_load_repo() {
  [[ -n ${1:-} ]] || die "empty repository name"
  local json
  json=$(gh repo view "$1" --json nameWithOwner,visibility,defaultBranchRef,isArchived,viewerPermission) ||
    die "cannot read repository $1"
  RT_REPO=$(jq -r .nameWithOwner <<<"$json")
  RT_VISIBILITY=$(jq -r .visibility <<<"$json")
  RT_DEFAULT_BRANCH=$(jq -r '.defaultBranchRef.name // "main"' <<<"$json")
  RT_ARCHIVED=$(jq -r .isArchived <<<"$json")
  RT_PERMISSION=$(jq -r .viewerPermission <<<"$json")
}

# Exits early (successfully) for repos we can't or shouldn't change.
rt_check_repo_usable() {
  if [[ $RT_ARCHIVED == true ]]; then
    warn "$RT_REPO is archived; skipping"
    exit 0
  fi
  [[ $RT_PERMISSION == ADMIN ]] || die "need admin permission on $RT_REPO (have: $RT_PERMISSION)"
}

rt_is_public() { [[ $RT_VISIBILITY == PUBLIC ]]; }

# Success message for a mutating step (silent in dry-run, where rt_api already printed).
rt_done() { ((RT_DRY_RUN)) || ok "$*"; }

# Runs FUNC REPO... once per repo, each in a subshell so one failure doesn't
# stop the rest. Exits non-zero if any repo failed.
rt_for_each_repo() {
  local fn=$1 repo failed=()
  shift
  ((${#@})) || {
    usage >&2
    exit 1
  }
  for repo in "$@"; do
    # Not `( ... ) || ...`: that context silently disables `set -e` inside.
    set +e
    (
      set -e
      "$fn" "$repo"
    )
    local rc=$?
    set -e
    ((rc == 0)) || failed+=("$repo")
  done
  if ((${#failed[@]})); then
    printf '%sfailed:%s %s\n' "$_rt_r" "$_rt_0" "${failed[*]}" >&2
    exit 1
  fi
}

# rt_api METHOD PATH [JSON]
# Mutating API call. JSON (if given) is sent as the request body.
# In dry-run mode the call is printed instead.
rt_api() {
  local method=$1 path=$2 body=${3:-}
  if ((RT_DRY_RUN)); then
    info "[dry-run] $method $path"
    [[ -n $body ]] && jq . <<<"$body" | sed 's/^/      /' >&2
    return 0
  fi
  local args=(--method "$method" -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28" "$path")
  if [[ -n $body ]]; then
    gh api "${args[@]}" --input - <<<"$body" >/dev/null
  else
    gh api "${args[@]}" >/dev/null
  fi
}

# --- Reading workflow files --------------------------------------------------------

# rt_yaml_to_json FILE -> JSON on stdout. Uses whichever YAML parser exists:
# mikefarah yq, the jq-wrapper yq (python), or python3 + PyYAML; fails without
# one, or when FILE doesn't parse. The file comes from a repo and its strings
# end up on the terminal, so control characters are dropped from them. PyYAML
# reads a workflow's bare `on:` key as boolean true; that key is renamed back.
rt_yaml_to_json() {
  local raw
  if command -v yq >/dev/null 2>&1; then
    if yq --version 2>&1 | grep -q mikefarah; then raw=$(yq -o=json '.' "$1"); else raw=$(yq '.' "$1"); fi
  elif python3 -c 'import yaml' 2>/dev/null; then
    raw=$(python3 -c 'import json, sys, yaml; json.dump(yaml.safe_load(open(sys.argv[1])), sys.stdout)' "$1")
  else
    return 2
  fi || return 1
  jq '(if type == "object" and has("true") then with_entries(.key |= if . == "true" then "on" else . end) else . end)
    | walk(if type == "string" then gsub("[\u0000-\u0008\u000b-\u001f\u007f]"; "") else . end)' <<<"${raw:-null}"
}

# rt_workflow_lacks_permissions FILE
# Succeeds if a workflow leaves at least one job on the repo's default token
# permissions: no top-level `permissions:` and a job without its own. Such a
# job gets read-only access once repo-protect makes that the default.
rt_workflow_lacks_permissions() {
  local json
  if json=$(rt_yaml_to_json "$1" 2>/dev/null); then
    jq -e 'type == "object" and (has("permissions") | not)
      and ((.jobs // {}) | to_entries | any(.value | type != "object" or (has("permissions") | not)))' \
      <<<"$json" >/dev/null
  else
    # No YAML parser: only a top-level block is recognised.
    ! grep -qE '^permissions:' "$1"
  fi
}

# rt_workflow_has_job FILE NAME
# Succeeds if a job in the workflow reports its check under NAME (its `name:`).
rt_workflow_has_job() {
  local json
  if json=$(rt_yaml_to_json "$1" 2>/dev/null); then
    jq -e --arg n "$2" '(.jobs // {}) | objects | any(.[]; type == "object" and .name == $n)' <<<"$json" >/dev/null
  else
    grep -qE "^[[:space:]]+name:[[:space:]]*[\"']?$2[\"']?[[:space:]]*$" "$1"
  fi
}
