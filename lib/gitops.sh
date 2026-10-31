# shellcheck shell=bash
# shellcheck disable=SC2154 # globals are defined in common.sh
# Cloning target repos and publishing managed files as pull requests.

# rt_clone REPO -> prints path of a fresh shallow clone of the default branch.
rt_clone() {
  local dest
  dest=$(mktemp -d "$(rt_tmpdir)/$(tr '/' '_' <<<"$1").XXXXXX")
  gh repo clone "$1" "$dest" -- --depth 1 --quiet --no-tags >&2 || die "failed to clone $1"
  printf '%s\n' "$dest"
}

# rt_write_managed CLONE RELPATH  (content on stdin)
# Refuses to overwrite a file that exists but isn't managed, unless --force.
rt_write_managed() {
  local dest="$1/$2" content
  content=$(cat)
  if ! rt_path_inside "$1" "$2"; then
    # Never --force-able: writing through it would land outside the clone.
    warn "$2 (or a directory above it) is a symlink; refusing to write it"
    return 1
  fi
  if [[ -e $dest && ! -f $dest ]]; then
    warn "$2 exists and isn't a regular file; leaving it alone"
    return 1
  fi
  if [[ -f $dest ]] && ! grep -qF "$RT_MARKER" "$dest"; then
    if ((RT_FORCE)); then
      warn "$2 exists and isn't managed by repo-tools; replacing it (--force)"
    else
      warn "$2 exists and isn't managed by repo-tools; leaving it alone (use --force to replace)"
      return 1
    fi
  fi
  mkdir -p "$(dirname "$dest")"
  printf '%s\n' "$content" >"$dest"
}

# rt_publish_pr CLONE BRANCH TITLE BODY PATH...
# Commits PATHs to BRANCH and opens (or refreshes) a PR against the default
# branch. Does nothing if the default branch, or the open PR branch, already
# has identical content — so re-running is cheap and doesn't spam CI.
#
# "Identical" means the whole tree, not just PATHs: anything else someone
# pushed to BRANCH (which the PR would then quietly carry) is overwritten.
# Only same-repo PRs count as ours; a fork can open a PR from a branch with
# the same name, and must not be reported as the repo-tools PR.
rt_publish_pr() {
  local dir=$1 branch=$2 title=$3 body=$4 url
  shift 4
  local g=(git -C "$dir")

  "${g[@]}" add -A -- "$@"
  if "${g[@]}" diff --cached --quiet HEAD -- "$@"; then
    ok "already up to date on $RT_DEFAULT_BRANCH"
    return 0
  fi

  if ((RT_DRY_RUN)); then
    info "[dry-run] would open a PR from '$branch' with:"
    "${g[@]}" --no-pager diff --cached --stat HEAD -- "$@" | sed 's/^/      /' >&2
    "${g[@]}" --no-pager diff --cached HEAD -- "$@" | sed 's/^/      /' >&2
    return 0
  fi

  if "${g[@]}" fetch --quiet --depth 1 origin "refs/heads/$branch" 2>/dev/null &&
    "${g[@]}" diff --cached --quiet FETCH_HEAD; then
    ok "branch '$branch' already has these changes"
  else
    "${g[@]}" commit --quiet -m "$title" -m "$body" -- "$@"
    "${g[@]}" push --quiet --force origin "HEAD:refs/heads/$branch" || die "push to $branch failed"
    ok "pushed '$branch'"
  fi

  url=$(gh pr list -R "$RT_REPO" --head "$branch" --state open --json url,isCrossRepository \
    --jq 'map(select(.isCrossRepository | not)) | .[0].url // empty')
  if [[ -n $url ]]; then
    ok "PR already open: $url"
  else
    url=$(gh pr create -R "$RT_REPO" --base "$RT_DEFAULT_BRANCH" --head "$branch" \
      --title "$title" --body "$body") || die "failed to create PR"
    ok "opened PR: $url"
  fi
}

# rt_replace_workflows CLONE -> prints the repo-relative path of each workflow
# named in REPLACE_WORKFLOWS that it deleted from CLONE, for rt_publish_pr.
# Names are file names in .github/workflows ("ci.yml"); anything else, and
# repo-tools' own files, are refused with a warning.
rt_replace_workflows() {
  local dir=$1 wf path
  while IFS= read -r wf; do
    [[ $wf == .github/workflows/* ]] && wf=${wf#.github/workflows/}
    if [[ ! $wf =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.ya?ml$ ]]; then
      warn "REPLACE_WORKFLOWS: '$wf' isn't a workflow file name in .github/workflows; ignoring it"
      continue
    fi
    path=.github/workflows/$wf
    if ! rt_path_inside "$dir" "$path"; then
      warn "REPLACE_WORKFLOWS: $path (or a directory above it) is a symlink; not removing it"
    elif [[ $path == "$RT_CI_FILE" ]] || { [[ -f $dir/$path ]] && grep -qF "$RT_MARKER" "$dir/$path"; }; then
      warn "REPLACE_WORKFLOWS: $path is managed by repo-tools; not removing it"
    elif [[ -f $dir/$path ]]; then
      rm -- "$dir/$path"
      info "removing $path (REPLACE_WORKFLOWS)"
      printf '%s\n' "$path"
    else
      info "REPLACE_WORKFLOWS: $path is already gone"
    fi
  done < <(rt_list "$(rt_conf REPLACE_WORKFLOWS)")
  return 0
}
