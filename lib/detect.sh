# shellcheck shell=bash
# shellcheck disable=SC2154 # globals are defined in common.sh
# Detects languages (for CI) and Dependabot ecosystems from a repo checkout.
# Only git-tracked files are considered, so node_modules, build output etc.
# are naturally ignored.

# Paths never treated as project roots, even if tracked.
RT_DETECT_IGNORE='(^|/)(node_modules|vendor|third_party|\.terraform|testdata|fixtures)/'

# Every CI language repo-tools knows, in render order (used by render.sh).
# shellcheck disable=SC2034
RT_LANGS=(python node rust gradle maven terraform ansible shell)

_rt_files() {
  git -C "$1" ls-files | grep -Ev "$RT_DETECT_IGNORE" || true
}

# Prints the directory of each path read on stdin ("." for the repo root), unique.
_rt_dirs() {
  local f
  while IFS= read -r f; do
    if [[ $f == */* ]]; then printf '%s\n' "${f%/*}"; else printf '.\n'; fi
  done | LC_ALL=C sort -u
}

# Keeps only directories not nested inside another listed directory.
_rt_rootmost() {
  local kept=() d k nested
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    nested=0
    for k in "${kept[@]+"${kept[@]}"}"; do
      if [[ $k == . || $d == "$k"/* ]]; then
        nested=1
        break
      fi
    done
    ((nested)) || kept+=("$d")
  done < <(LC_ALL=C sort -u)
  ((${#kept[@]} == 0)) || printf '%s\n' "${kept[@]}"
}

# _rt_match FILES REGEX -> matching paths
_rt_match() { grep -E "$2" <<<"$1" || true; }

# Lists tracked shell scripts: by extension, or extensionless with a sh shebang.
rt_shell_files() {
  local dir=$1 f first shebang='^#!.*(/|[[:space:]])(ba|da|k)?sh([[:space:]]|$)'
  while IFS= read -r f; do
    case $f in
      *.sh | *.bash) printf '%s\n' "$f" ;;
      */*.* | *.*) ;;
      *)
        [[ -f $dir/$f && ! -L $dir/$f ]] || continue
        IFS= read -r first <"$dir/$f" 2>/dev/null || continue
        [[ $first =~ $shebang ]] && printf '%s\n' "$f"
        ;;
    esac
  done < <(_rt_files "$dir")
  return 0
}

# rt_detect_langs DIR
# Prints "lang<TAB>dir,dir" for each detected CI language.
rt_detect_langs() {
  local dir=$1 files dirs
  files=$(_rt_files "$dir")

  _emit() { [[ -z $2 ]] || printf '%s\t%s\n' "$1" "$(paste -sd, - <<<"$2")"; }

  # Python: needs project metadata, or requirements files plus actual .py code.
  # Standalone scripts (.py files and no project anywhere) get one job at the
  # root, which lints them; pytest and the build find nothing and pass.
  dirs=$(_rt_match "$files" '(^|/)(pyproject\.toml|setup\.py|setup\.cfg|Pipfile)$' | _rt_dirs)
  if grep -qE '\.py$' <<<"$files"; then
    dirs=$(printf '%s\n%s\n' "$dirs" "$(_rt_match "$files" '(^|/)requirements[^/]*\.txt$' | _rt_dirs)")
    [[ -n ${dirs//[[:space:]]/} ]] || dirs=.
  fi
  _emit python "$(_rt_rootmost <<<"$dirs")"

  _emit node "$(_rt_match "$files" '(^|/)package\.json$' | _rt_dirs | _rt_rootmost)"
  _emit rust "$(_rt_match "$files" '(^|/)Cargo\.toml$' | _rt_dirs | _rt_rootmost)"
  _emit gradle "$(_rt_match "$files" '(^|/)(settings|build)\.gradle(\.kts)?$' | _rt_dirs | _rt_rootmost)"
  _emit maven "$(_rt_match "$files" '(^|/)pom\.xml$' | _rt_dirs | _rt_rootmost)"

  # Terraform and shell jobs scan the whole repo themselves, so run from root.
  grep -qE '\.tf$' <<<"$files" && _emit terraform .

  # Ansible: ansible.cfg / galaxy.yml dirs, or the parent of a roles/ tree.
  dirs=$(
    _rt_match "$files" '(^|/)(ansible\.cfg|galaxy\.ya?ml)$' | _rt_dirs
    _rt_match "$files" '(^|/)roles/[^/]+/tasks/main\.ya?ml$' | sed -E 's#(^|/)roles/[^/]+/tasks/main\.ya?ml$##; s#^$#.#'
  )
  _emit ansible "$(_rt_rootmost <<<"$dirs")"

  [[ -n $(rt_shell_files "$dir" | head -n1) ]] && _emit shell .
  unset -f _emit
  return 0
}

# rt_detect_ecosystems DIR
# Prints "ecosystem<TAB>dir,dir" for Dependabot. Workspace-style ecosystems
# (npm, cargo, gradle, maven) use only the root-most manifests; the others
# need every directory listed.
rt_detect_ecosystems() {
  local dir=$1 files uv_dirs pip_dirs d u under

  files=$(_rt_files "$dir")
  _emit() { [[ -z $2 ]] || printf '%s\t%s\n' "$1" "$(paste -sd, - <<<"$2")"; }

  _emit github-actions .
  _emit npm "$(_rt_match "$files" '(^|/)package\.json$' | _rt_dirs | _rt_rootmost)"

  uv_dirs=$(_rt_match "$files" '(^|/)uv\.lock$' | _rt_dirs)
  pip_dirs=$(_rt_match "$files" '(^|/)(pyproject\.toml|setup\.py|setup\.cfg|Pipfile|requirements[^/]*\.txt)$' | _rt_dirs |
    while IFS= read -r d; do
      under=0
      while IFS= read -r u; do
        [[ -n $u && ($d == "$u" || $u == . || $d == "$u"/*) ]] && under=1
      done <<<"$uv_dirs"
      ((under)) || printf '%s\n' "$d"
    done)
  _emit uv "$uv_dirs"
  _emit pip "$pip_dirs"

  _emit cargo "$(_rt_match "$files" '(^|/)Cargo\.toml$' | _rt_dirs | _rt_rootmost)"
  _emit gradle "$(_rt_match "$files" '(^|/)(settings|build)\.gradle(\.kts)?$' | _rt_dirs | _rt_rootmost)"
  _emit maven "$(_rt_match "$files" '(^|/)pom\.xml$' | _rt_dirs | _rt_rootmost)"
  _emit terraform "$(_rt_match "$files" '\.tf$' | _rt_dirs)"
  _emit docker "$(_rt_match "$files" '(^|/)(Dockerfile|Containerfile)([.-][^/]*)?$|\.[Dd]ockerfile$' | _rt_dirs)"
  unset -f _emit
  return 0
}
