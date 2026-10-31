# shellcheck shell=bash
# shellcheck disable=SC2034 # constants are used by the scripts that source this
# Shared helpers for repo-tools. Sourced by bin/* — not executable on its own.

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  echo "repo-tools needs bash >= 4.4 (macOS: brew install bash)" >&2
  exit 1
fi

# --- Settings (override via environment) -------------------------------------

# Repo hosting the reusable workflows, and the ref callers pin to. Empty RT_REF
# means the newest vX.Y.Z release tag, pinned by commit SHA (rt_resolve_ref),
# so callers only move when Dependabot proposes the next release.
RT_SOURCE_REPO="${RT_SOURCE_REPO:-InboundFrog/repo-tools}"
RT_REF="${RT_REF:-}"
RT_REF_COMMENT='' # the tag behind a SHA-pinned RT_REF, as "# vX.Y.Z" for Dependabot

# Files carrying this marker are owned by repo-tools and may be overwritten.
RT_MARKER="Managed by repo-tools"
RT_CI_FILE=".github/workflows/repo-tools-ci.yml"
RT_DEPENDABOT_FILE=".github/dependabot.yml"
RT_CONF_FILE=".github/repo-tools.conf"
RT_CI_CHECK_NAME="CI OK"

RT_DRY_RUN="${RT_DRY_RUN:-0}"
RT_FORCE="${RT_FORCE:-0}"

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

# Both end up verbatim in the generated workflow's `uses:` line.
[[ $RT_SOURCE_REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
  die "RT_SOURCE_REPO must look like owner/name (got: $RT_SOURCE_REPO)"
[[ -z $RT_REF || ($RT_REF =~ ^[A-Za-z0-9_.][A-Za-z0-9_./-]*$ && $RT_REF != *..*) ]] ||
  die "RT_REF must be a branch, tag or commit SHA (got: $RT_REF)"

_rt_ls_tags() { git ls-remote --tags "https://github.com/$RT_SOURCE_REPO" 'v*'; }

# rt_resolve_ref: if RT_REF is unset, sets it to the commit SHA of the newest
# vX.Y.Z tag in RT_SOURCE_REPO, and RT_REF_COMMENT to that tag. Returns 1
# (with a warning) if that can't be done. Call once, in the top-level shell,
# before rendering a CI workflow.
rt_resolve_ref() {
  local refs tag sha
  [[ -z $RT_REF ]] || return 0
  if ! refs=$(_rt_ls_tags); then
    warn "could not list release tags of $RT_SOURCE_REPO (set RT_REF to pin a ref yourself)"
    return 1
  fi
  tag=$(sed -nE 's#^[0-9a-f]{40}[[:space:]]+refs/tags/v([0-9]+\.[0-9]+\.[0-9]+)$#\1#p' <<<"$refs" |
    sort -t. -k1,1n -k2,2n -k3,3n | tail -n1)
  if [[ -z $tag ]]; then
    warn "$RT_SOURCE_REPO has no vX.Y.Z release tag yet; tag one, or set RT_REF (e.g. RT_REF=main)"
    return 1
  fi
  tag=v$tag
  # An annotated tag's own object is listed too; the commit is the peeled "^{}" entry.
  sha=$(awk -v t="refs/tags/$tag^{}" '$2 == t { print $1 }' <<<"$refs")
  [[ -n $sha ]] || sha=$(awk -v t="refs/tags/$tag" '$2 == t { print $1 }' <<<"$refs")
  RT_REF=$sha RT_REF_COMMENT=$tag
}

rt_require() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
  done
}

# --- Argument parsing ----------------------------------------------------------

# Parses the flags shared by every per-repo command. Positional args end up
# in RT_ARGS. Each script defines usage() before calling this.
rt_parse_args() {
  RT_ARGS=()
  while (($#)); do
    case $1 in
      -n | --dry-run) RT_DRY_RUN=1 ;;
      -f | --force) RT_FORCE=1 ;;
      -h | --help)
        usage
        exit 0
        ;;
      --)
        shift
        RT_ARGS+=("$@")
        break
        ;;
      -*) die "unknown option: $1 (see --help)" ;;
      *) RT_ARGS+=("$1") ;;
    esac
    shift
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

# --- Paths inside a target repo checkout -------------------------------------------

# rt_path_inside DIR RELPATH
# Succeeds if RELPATH stays inside DIR: relative, no ".." component, and no
# existing component (the file itself included) is a symlink. Target repos are
# untrusted input, and a committed symlink (".github -> /home/me") would
# otherwise make repo-tools read, write or delete files outside the clone.
rt_path_inside() {
  local path=$1 part
  local -a parts
  [[ -n $2 && $2 != /* ]] || return 1
  IFS=/ read -ra parts <<<"$2"
  for part in "${parts[@]}"; do
    [[ -n $part && $part != . ]] || continue
    [[ $part != .. ]] || return 1
    path+=/$part
    [[ ! -L $path ]] || return 1
  done
}

# --- Per-repo config (.github/repo-tools.conf) --------------------------------------

declare -gA RT_CONF=()

# Parses KEY=VALUE lines (no shell evaluation — the file is data, not code).
rt_conf_load() {
  local file="$1/$RT_CONF_FILE" line key val
  RT_CONF=()
  rt_path_inside "$1" "$RT_CONF_FILE" || die "$RT_CONF_FILE (or a directory above it) is a symlink; refusing to read it"
  [[ -f $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*([A-Z][A-Z0-9_]*)[[:space:]]*=(.*)$ ]] || continue
    key=${BASH_REMATCH[1]}
    val=${BASH_REMATCH[2]}
    val=${val#"${val%%[![:space:]]*}"} # trim leading space
    val=${val%"${val##*[![:space:]]}"} # trim trailing space
    if [[ $val =~ ^\"(.*)\"$ || $val =~ ^\'(.*)\'$ ]]; then
      val=${BASH_REMATCH[1]}
    elif [[ $val =~ ^(.*[^[:space:]])[[:space:]]+#.*$ ]]; then
      val=${BASH_REMATCH[1]} # unquoted: drop a trailing " # comment"
    fi
    # Control characters (e.g. terminal escape sequences) have no legitimate
    # use here, and values are echoed to the terminal and into PRs.
    if [[ $val == *[[:cntrl:]]* ]]; then
      warn "$RT_CONF_FILE: $key contains control characters; ignoring it"
      continue
    fi
    RT_CONF[$key]=$val
  done <"$file"
}

# rt_conf KEY [DEFAULT]
rt_conf() { printf '%s\n' "${RT_CONF[$1]:-${2:-}}"; }

# "name<TAB>dir,dir" lines (a CI plan or ecosystem list) -> a Markdown list for
# PR bodies. Directory names come from the target repo, so each is put in a
# code span: a directory like "@org" must not mention (notify) anyone.
rt_md_plan() {
  local name dirs d out
  while IFS=$'\t' read -r name dirs; do
    [[ -n $name ]] || continue
    out=''
    while IFS= read -r d; do
      d=${d//\`/\'}
      out+="${out:+, }\`$d\`"
    done < <(tr ',' '\n' <<<"$dirs")
    # shellcheck disable=SC2016 # Markdown backticks
    printf -- '- `%s`: %s\n' "$name" "$out"
  done
}

# Splits a comma/space separated list into lines.
rt_list() {
  local -a parts
  read -ra parts <<<"${1//,/ }"
  ((${#parts[@]} == 0)) || printf '%s\n' "${parts[@]}"
}
