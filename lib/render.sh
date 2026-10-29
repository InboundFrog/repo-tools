# shellcheck shell=bash
# shellcheck disable=SC2154 # globals are defined in common.sh
# Renders the managed files written into target repos:
#   .github/dependabot.yml               (rt_render_dependabot)
#   .github/workflows/repo-tools-ci.yml  (rt_render_ci)
# Both read per-repo overrides from RT_CONF (see rt_conf_load).

# Reusable workflow each CI language calls.
declare -gA RT_WORKFLOW=(
  [python]=python.yml [node]=node.yml [rust]=rust.yml
  [gradle]=jvm.yml [maven]=jvm.yml [terraform]=terraform.yml
  [ansible]=ansible.yml [shell]=shell.yml
)

# Config key -> workflow input for the toolchain version, per language.
declare -gA RT_VERSION_KEY=(
  [python]=PYTHON_VERSION:python-version [node]=NODE_VERSION:node-version
  [gradle]=JAVA_VERSION:java-version [maven]=JAVA_VERSION:java-version
  [terraform]=TERRAFORM_VERSION:terraform-version
)

RT_DEPENDABOT_INTERVALS=" daily weekly monthly quarterly semiannually yearly "

# Single-quoted YAML scalar.
_rt_yq() { printf "'%s'" "${1//\'/\'\'}"; }

# "." -> "/", "a/b" -> "/a/b"
_rt_dep_dir() { if [[ $1 == . ]]; then printf '/\n'; else printf '/%s\n' "$1"; fi; }

_rt_in_list() { # NEEDLE LIST
  local item
  while IFS= read -r item; do [[ $item == "$1" ]] && return 0; done < <(rt_list "$2")
  return 1
}

# rt_ci_plan DIR -> "lang<TAB>dir,dir" after applying LANGUAGES / EXCLUDE / *_DIRS.
rt_ci_plan() {
  local dir=$1 lang dirs langs exclude
  local -A detected=()
  while IFS=$'\t' read -r lang dirs; do
    [[ -n $lang ]] && detected[$lang]=$dirs
  done < <(rt_detect_langs "$dir")

  langs=$(rt_conf LANGUAGES)
  exclude=$(rt_conf EXCLUDE)
  if [[ -n $langs ]]; then
    while IFS= read -r lang; do
      [[ -n ${RT_WORKFLOW[$lang]:-} ]] || warn "LANGUAGES: unknown language '$lang' (known: ${RT_LANGS[*]})"
    done < <(rt_list "$langs")
  fi

  for lang in "${RT_LANGS[@]}"; do
    if [[ -n $langs ]]; then
      _rt_in_list "$lang" "$langs" || continue
    else
      [[ -n ${detected[$lang]:-} ]] || continue
    fi
    _rt_in_list "$lang" "$exclude" && continue
    dirs=$(rt_conf "${lang^^}_DIRS" "${detected[$lang]:-.}")
    printf '%s\t%s\n' "$lang" "$(rt_list "$dirs" | paste -sd, -)"
  done
}

_rt_render_job() { # LANG DIRS
  local lang=$1 dirs=$2 matrix='' d key input val kind
  while IFS= read -r d; do
    matrix+="${matrix:+, }$(_rt_yq "$d")"
  done < <(rt_list "$dirs")

  cat <<EOF
  ${lang}:
    uses: ${RT_SOURCE_REPO}/.github/workflows/${RT_WORKFLOW[$lang]}@${RT_REF}
    strategy:
      fail-fast: false
      matrix:
        dir: [${matrix}]
    with:
      working-directory: \${{ matrix.dir }}
EOF
  case $lang in gradle | maven) printf '      build-tool: %s\n' "$lang" ;; esac

  if [[ -n ${RT_VERSION_KEY[$lang]:-} ]]; then
    key=${RT_VERSION_KEY[$lang]%%:*}
    input=${RT_VERSION_KEY[$lang]#*:}
    val=$(rt_conf "$key")
    [[ -n $val ]] && printf '      %s: %s\n' "$input" "$(_rt_yq "$val")"
  fi
  for kind in lint test build; do
    val=$(rt_conf "${lang^^}_${kind^^}")
    [[ -n $val ]] && printf '      %s-command: %s\n' "$kind" "$(_rt_yq "$val")"
  done
  return 0
}

# rt_render_ci DIR DEFAULT_BRANCH
rt_render_ci() {
  local dir=$1 branch=$2 plan lang dirs needs=()
  plan=$(rt_ci_plan "$dir")

  cat <<EOF
# ${RT_MARKER} (bin/repo-ci). Local edits will be overwritten.
# Customise via ${RT_CONF_FILE} instead: https://github.com/${RT_SOURCE_REPO}
name: CI

on:
  pull_request:
  push:
    branches: [$(_rt_yq "$branch")]
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: \${{ github.workflow }}-\${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true

jobs:
EOF
  while IFS=$'\t' read -r lang dirs; do
    [[ -n $lang ]] || continue
    ((${#needs[@]} == 0)) || echo
    needs+=("$lang")
    _rt_render_job "$lang" "$dirs"
  done <<<"$plan"

  # Single, stable check to require in branch protection regardless of language.
  ((${#needs[@]} == 0)) || echo
  cat <<EOF
  ci-ok:
    name: ${RT_CI_CHECK_NAME}
    if: always()
EOF
  if ((${#needs[@]})); then
    local joined
    joined=$(IFS=,; echo "${needs[*]}")
    printf '    needs: [%s]\n' "${joined//,/, }"
  fi
  cat <<'EOF'
    runs-on: ubuntu-latest
    steps:
      - name: Check job results
        env:
          NEEDS: ${{ toJSON(needs) }}
        run: |
          jq -r 'to_entries[] | "\(.key): \(.value.result)"' <<<"$NEEDS"
          jq -e 'all(.[]; .result == "success" or .result == "skipped")' <<<"$NEEDS" >/dev/null
EOF
}

# rt_render_dependabot DIR
rt_render_dependabot() {
  local dir=$1 eco dirs d interval cooldown exclude
  interval=$(rt_conf DEPENDABOT_INTERVAL weekly)
  cooldown=$(rt_conf DEPENDABOT_COOLDOWN_DAYS 3)
  exclude=$(rt_conf DEPENDABOT_EXCLUDE)
  [[ $RT_DEPENDABOT_INTERVALS == *" $interval "* ]] ||
    die "DEPENDABOT_INTERVAL must be one of:$RT_DEPENDABOT_INTERVALS"
  [[ $cooldown =~ ^[0-9]+$ ]] || die "DEPENDABOT_COOLDOWN_DAYS must be a number"

  cat <<EOF
# ${RT_MARKER} (bin/repo-dependabot). Local edits will be overwritten.
# Customise via ${RT_CONF_FILE} instead: https://github.com/${RT_SOURCE_REPO}
version: 2
updates:
EOF
  while IFS=$'\t' read -r eco dirs; do
    [[ -n $eco ]] || continue
    _rt_in_list "$eco" "$exclude" && continue
    printf '  - package-ecosystem: %s\n    directories:\n' "$eco"
    while IFS= read -r d; do
      printf '      - %s\n' "$(_rt_yq "$(_rt_dep_dir "$d")")"
    done < <(rt_list "$dirs")
    printf '    schedule:\n      interval: %s\n' "$interval"
    ((cooldown > 0)) && printf '    cooldown:\n      default-days: %s\n' "$cooldown"
    if [[ $eco == github-actions ]]; then
      # Action bumps are low-risk; one PR for all of them.
      printf '    groups:\n      %s:\n        patterns: ["*"]\n' "$eco"
    else
      # Batch minor/patch bumps; majors still get their own PRs.
      printf '    groups:\n      %s-minor-patch:\n        patterns: ["*"]\n        update-types: [minor, patch]\n' "$eco"
    fi
  done < <(rt_detect_ecosystems "$dir")
}
