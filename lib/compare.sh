# shellcheck shell=bash
# shellcheck disable=SC2154 # globals are defined in common.sh
# Compares an existing (unmanaged) file in a target repo with what repo-tools
# would generate, so gaps on either side are visible before replacing it.

# rt_yaml_to_json FILE -> JSON on stdout. Uses whichever YAML parser exists:
# mikefarah yq, the jq-wrapper yq (python), or python3 + PyYAML.
rt_yaml_to_json() {
  if command -v yq >/dev/null 2>&1; then
    if yq --version 2>&1 | grep -q mikefarah; then
      yq -o=json '.' "$1"
    else
      yq '.' "$1"
    fi
  elif command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
    python3 -c 'import json, sys, yaml; json.dump(yaml.safe_load(open(sys.argv[1])), sys.stdout)' "$1"
  else
    return 2
  fi
}

# Normalises a dependabot.yml (as JSON) to one object per ecosystem.
# shellcheck disable=SC2016 # jq program, not shell
_RT_JQ_DEPENDABOT='
  def norm_dir: if . == "/" then "/" else "/" + (ltrimstr("/") | rtrimstr("/")) end;
  def known: ["package-ecosystem", "directory", "directories", "schedule", "groups", "cooldown", "ignore"];
  [ (.updates // [])[] | {
      eco: .["package-ecosystem"],
      dirs: ((.directories // [.directory]) | map(select(. != null) | norm_dir)),
      interval: (.schedule.interval // "?"),
      groups: ((.groups // {}) | keys),
      cooldown: .cooldown,
      ignore: (.ignore // []),
      extra: (keys - known)
  } ]
  | group_by(.eco)
  | map({ key: .[0].eco, value: {
      entries: length,
      dirs: (map(.dirs[]) | unique),
      interval: (map(.interval) | unique | join(", ")),
      groups: (map(.groups[]) | unique),
      cooldown: (map(.cooldown | select(. != null)) | first),
      ignore: (map(.ignore[])),
      extra: (map(.extra[]) | unique)
    } })
  | from_entries
'

# shellcheck disable=SC2016
_RT_JQ_REPORT='
  def list: if length == 0 then "none" else join(", ") end;
  def cool: if . == null then "none" else (to_entries | map("\(.key): \(.value)") | join(", ")) end;
  def ign: "\(.["dependency-name"])" +
    (if .["update-types"] then " (" + (.["update-types"] | map(sub("version-update:semver-"; "")) | sort | join(", ")) + ")" else "" end) +
    (if .versions then " versions " + (.versions | tostring) else "" end);
  def row($mark; $label; $text): "      \($mark) \($label | . + " " * (12 - length)) \($text)";

  ($existing.top - ["version", "updates"]) as $top_extra
  | ([$e, $g] | map(keys) | add | unique) as $ecos
  | (
      ($ecos[] as $k |
        if $e[$k] == null then
          "  + \($k)  not covered by the existing config (dirs: \($g[$k].dirs | list))"
        elif $g[$k] == null then
          "  - \($k)  only in the existing config; repo-tools did not detect it (dirs: \($e[$k].dirs | list))"
        else
          $e[$k] as $a | $g[$k] as $b |
          "    \($k)",
          ( ($b.dirs - $a.dirs) as $add | ($a.dirs - $b.dirs) as $del |
            if ($add | length) == 0 and ($del | length) == 0 then row("="; "directories"; $a.dirs | list)
            else
              (if ($add | length) > 0 then row("+"; "directories"; $add | list) else empty end),
              (if ($del | length) > 0 then row("-"; "directories"; $del | list) else empty end)
            end ),
          ( if $a.interval == $b.interval then row("="; "interval"; $a.interval)
            else row("~"; "interval"; "existing \($a.interval), repo-tools \($b.interval)") end ),
          ( if ($a.groups | length) == 0 and ($b.groups | length) > 0 then row("+"; "groups"; $b.groups | list)
            elif ($a.groups | length) > 0 and ($b.groups | length) == 0 then row("-"; "groups"; $a.groups | list)
            elif ($a.groups | length) > 0 then row("~"; "groups"; "existing \($a.groups | list); repo-tools \($b.groups | list)")
            else empty end ),
          ( if $a.cooldown == $b.cooldown then (if $a.cooldown then row("="; "cooldown"; $a.cooldown | cool) else empty end)
            elif $a.cooldown == null then row("+"; "cooldown"; $b.cooldown | cool)
            elif $b.cooldown == null then row("-"; "cooldown"; $a.cooldown | cool)
            else row("~"; "cooldown"; "existing \($a.cooldown | cool); repo-tools \($b.cooldown | cool)") end ),
          ( ($a.ignore | map(ign)) as $ai | ($b.ignore | map(ign)) as $bi |
            (($ai - ($ai - $bi))[] | row("="; "ignore"; .)),
            (($ai - $bi)[] | row("-"; "ignore"; .)),
            (($bi - $ai)[] | row("+"; "ignore"; .)) ),
          ( if ($a.extra | length) > 0 then row("-"; "other keys"; $a.extra | list) else empty end ),
          ( if $a.entries > 1 then row("~"; "entries"; "existing splits this into \($a.entries) update entries") else empty end )
        end),
      (if ($top_extra | length) > 0 then "  - top-level keys only in existing: \($top_extra | list)" else empty end)
    )
'

# rt_compare_dependabot EXISTING_FILE GENERATED_FILE
# Prints a per-ecosystem report: + repo-tools adds, - existing only, ~ differs, = same.
rt_compare_dependabot() {
  local existing generated
  if ! existing=$(rt_yaml_to_json "$1" 2>/dev/null) || ! generated=$(rt_yaml_to_json "$2" 2>/dev/null); then
    warn "no YAML parser (yq, or python3 + PyYAML) found; showing a text diff instead"
    diff -u --label existing --label repo-tools "$1" "$2" || true
    return 0
  fi
  [[ -n $existing && $existing != null ]] || existing='{}'
  jq -rn \
    --argjson existing "$(jq -c '{top: keys}' <<<"$existing")" \
    --argjson e "$(jq -c "$_RT_JQ_DEPENDABOT" <<<"$existing")" \
    --argjson g "$(jq -c "$_RT_JQ_DEPENDABOT" <<<"$generated")" \
    "$_RT_JQ_REPORT"
  echo "  (+ repo-tools adds, - only in existing: lost if replaced, ~ differs, = same)"
}

# What each reusable workflow runs by default (keep in sync with .github/workflows).
declare -gA RT_DEFAULT_STEPS=(
  [python]="lint: ruff check (+ ruff format --check if configured) | test: pytest | build: uv build"
  [node]="lint: lint/typecheck/format:check scripts | test: test script | build: build script"
  [rust]="lint: cargo fmt --check, clippy --workspace --all-targets -D warnings | build: cargo build --workspace --all-targets | test: cargo test --workspace (incl. doc tests) | audit: cargo audit (separate job) | msrv: cargo check --workspace on Cargo.toml rust-version (separate job, if declared) | --locked when Cargo.lock is committed; cache saved from the default branch only"
  [gradle]="lint: gradlew check -x test | test: gradlew test | build: gradlew assemble"
  [maven]="lint: (none) | test: mvn test | build: mvn verify -DskipTests"
  [terraform]="lint: terraform fmt -check, tflint | build: init -backend=false + validate | test: terraform test"
  [ansible]="lint: ansible-lint | test: (none) | build: (none)"
  [shell]="lint: shellcheck | test: bats | build: (none)"
)

# shellcheck disable=SC2016 # jq program
_RT_JQ_WORKFLOW='
  def short_ref: if test("^[0-9a-f]{40}$") then .[0:7] + " (SHA-pinned)" else . end;
  def action: (split("@") | .[0] + "@" + ((.[1] // "") | short_ref));
  def withs: if . == null then "" else
      " (" + (to_entries | map(select(.value | type != "object")) | map("\(.key): \(.value | tostring | .[0:40])") | join(", ")) + ")" end;
  def runlines: split("\n") | map(select(test("\\S"))) | if length > 2 then .[0:2] + ["…"] else . end;
  ((.on // .[true]) | if type == "object" then keys elif type == "array" then . else [.] end) as $on
  | "  \($file)  (on: \($on | join(", ")))",
    ( (.jobs // {}) | to_entries[] |
      "    job \(.key)" + (if .value.name then " \"\(.value.name)\"" else "" end),
      ( if .value.uses then "      calls \(.value.uses | action)"
        else (.value.steps // [])[] |
          if .uses then "      uses \(.uses | action)\(.with | withs)"
          elif .run then (.run | runlines | to_entries[] | "      \(if .key == 0 then "run " else "    " end) \(.value)")
          else empty end
        end ) )
'

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

_rt_in_replace() { # WORKFLOW_FILE_NAME
  local wf
  while IFS= read -r wf; do [[ ${wf#.github/workflows/} == "$1" ]] && return 0; done < <(rt_list "$(rt_conf REPLACE_WORKFLOWS)")
  return 1
}

# rt_overlapping_workflows CLONE -> file names of unmanaged workflows that run on
# push or pull_request and aren't listed in REPLACE_WORKFLOWS: likely CI that
# the generated workflow would duplicate.
rt_overlapping_workflows() {
  local dir=$1 wf json
  while IFS= read -r wf; do
    rt_path_inside "$dir" "$wf" || continue
    grep -qF "$RT_MARKER" "$dir/$wf" && continue
    _rt_in_replace "${wf##*/}" && continue
    if json=$(rt_yaml_to_json "$dir/$wf" 2>/dev/null); then
      # push counts unless it's tags-only (a release workflow, not CI).
      jq -e '(.on // .[true]) | (if type == "object" then . elif type == "array" then map({(.): null}) | add
          else {(.): null} end) as $on
        | ($on | has("pull_request"))
          or (($on | has("push")) and ($on.push | type != "object" or has("branches") or has("branches-ignore")
            or (has("tags") or has("tags-ignore") | not)))' <<<"$json" >/dev/null || continue
    else
      grep -qE '(^|[^a-z_])(push|pull_request)([^a-z_]|$)' "$dir/$wf" || continue
    fi
    printf '%s\n' "${wf##*/}"
  done < <(cd "$dir" && git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml')
  return 0
}

# rt_list_workflows CLONE PLAN
# Lists existing workflows (jobs, actions and commands), then the jobs the
# generated CI would run, so the two can be compared by eye.
rt_list_workflows() {
  local dir=$1 plan=$2 wf json lang dirs kind val i
  local -a files=() steps=()
  mapfile -t files < <(cd "$dir" && git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml')
  echo "Existing:"
  for wf in "${files[@]+"${files[@]}"}"; do
    if ! rt_path_inside "$dir" "$wf"; then
      echo "  ${wf##*/}  (symlink; not read)"
      continue
    fi
    if grep -qF "$RT_MARKER" "$dir/$wf"; then
      echo "  ${wf##*/}  (managed by repo-tools; would be regenerated)"
      continue
    fi
    if _rt_in_replace "${wf##*/}"; then
      echo "  ${wf##*/}  (in REPLACE_WORKFLOWS; repo-ci would remove it)"
      continue
    fi
    if ! json=$(rt_yaml_to_json "$dir/$wf" 2>/dev/null); then
      echo "  ${wf##*/}  (no YAML parser available to summarise it)"
      continue
    fi
    jq -r --arg file "${wf##*/}" "$_RT_JQ_WORKFLOW" <<<"$json"
  done
  ((${#files[@]})) || echo "  (none)"

  echo
  echo "repo-tools ($RT_CI_FILE):"
  while IFS=$'\t' read -r lang dirs; do
    [[ -n $lang ]] || continue
    # One entry per "kind: description". Overrides are spliced in with plain
    # string operations: config values are untrusted data and must never reach
    # a sed/awk program (GNU sed's s///e flag runs the pattern space as a command).
    IFS='|' read -ra steps <<<"${RT_DEFAULT_STEPS[$lang]}"
    for i in "${!steps[@]}"; do
      steps[i]=${steps[i]#"${steps[i]%%[![:space:]]*}"}
      steps[i]=${steps[i]%"${steps[i]##*[![:space:]]}"}
      kind=${steps[i]%%:*}
      case $kind in lint | test | build | audit | msrv) ;; *) continue ;; esac
      val=$(rt_conf "${lang^^}_${kind^^}")
      [[ -z $val ]] || steps[i]="$kind: $val (override)"
    done
    # bats only runs when there are tests to run.
    if [[ $lang == shell && -z $(rt_conf SHELL_TEST) && -z $(git -C "$dir" ls-files '*.bats') ]]; then
      for i in "${!steps[@]}"; do
        [[ ${steps[i]} != "test: bats" ]] || steps[i]="test: bats (skipped: no *.bats files)"
      done
    fi
    echo "    job $lang  (dirs: $dirs)"
    val=$(rt_conf "${lang^^}_OS" "$(rt_conf OS)")
    [[ -z $val ]] || echo "      os: $(rt_list "$val" | paste -sd' ' -)"
    val=$(rt_conf "${lang^^}_APT_PACKAGES" "$(rt_conf APT_PACKAGES)")
    [[ -z $val ]] || echo "      apt: $val"
    for pair in ${RT_INPUT_KEYS[$lang]:-}; do
      [[ ${pair#*:} == *-command ]] && continue
      val=$(rt_conf "${pair%%:*}")
      [[ -z $val ]] || echo "      ${pair#*:}: $val"
    done
    val=$(rt_conf "${lang^^}_EXTRA")
    [[ -z $val || $val == skip ]] || steps+=("extra: $val")
    val=$(rt_conf "${lang^^}_ARTIFACTS")
    [[ -z $val ]] || steps+=("artifacts: $(rt_list "$val" | paste -sd' ' -)")
    printf '      %s\n' "${steps[@]}"
  done <<<"$plan"
  echo "    job ci-ok \"$RT_CI_CHECK_NAME\"  (the check branch protection requires)"
}

# --- Carrying a hand-written dependabot.yml over (repo-dependabot --force) ------

# Splits an existing dependabot.yml (as JSON) into what repo-tools.conf can
# express and what it can't. $gen is the generated file (as JSON), for the
# ecosystems and directories repo-tools covers. Output:
#   keys:  [{key, value}]  repo-tools.conf settings that keep its behaviour
#   lost:  [text]          settings that would be dropped
#   notes: [text]          behaviour repo-tools changes on purpose
# shellcheck disable=SC2016 # jq program
_RT_JQ_MIGRATE='
  def norm_dir: if . == "/" then "/" else "/" + (ltrimstr("/") | rtrimstr("/")) end;
  def dirs: ((.directories // [.directory]) | map(select(. != null) | norm_dir));
  def known: ["package-ecosystem", "directory", "directories", "schedule", "cooldown", "ignore", "groups"];
  def intervals: ["daily", "weekly", "monthly", "quarterly", "semiannually", "yearly"];
  def conf_key: "DEPENDABOT_IGNORE_" + (ascii_upcase | gsub("-"; "_"));
  def semver: test("^version-update:semver-(major|minor|patch)$");
  def ignore_ok: type == "object" and ((keys - ["dependency-name", "update-types"]) | length) == 0
    and (.["dependency-name"] | type == "string" and test("^[^\\s,]+$"))
    and ((.["update-types"] // []) | all(.[]; type == "string" and semver));
  def ignore_entry: .["dependency-name"] + (
    (.["update-types"] // []) | map(sub("^version-update:semver-"; "")) | unique
    | (["major", "minor", "patch"] - (["major", "minor", "patch"] - .)) as $t
    | if ($t | length) > 0 then ":" + ($t | join("+")) else "" end);
  (if type == "object" then . else {} end) as $e
  | (($gen.updates // []) | map({key: .["package-ecosystem"], value: dirs}) | from_entries) as $gdirs
  | ($e.updates // [] | map(select(type == "object"))) as $u
  | ($u | map(.schedule.interval // empty) | unique) as $ints
  | ($u | map(.cooldown["default-days"] // empty) | unique) as $cools
  | ($u | group_by(.["package-ecosystem"])) as $by_eco
  | {
      keys: (
        [ $by_eco[] | .[0]["package-ecosystem"] as $eco
          | [ .[] | (.ignore // [])[] | select(ignore_ok) | ignore_entry ] | unique
          | select(length > 0) | { key: ($eco | conf_key), value: join(", ") } ]
        + (if ($ints | length) == 1 and $ints[0] != "weekly" and ($ints[0] | IN(intervals[]))
            then [{ key: "DEPENDABOT_INTERVAL", value: $ints[0] }] else [] end)
        + (if ($cools | length) == 1 and ($cools[0] | type) == "number" and $cools[0] != 3
            then [{ key: "DEPENDABOT_COOLDOWN_DAYS", value: ($cools[0] | tostring) }] else [] end)
      ),
      lost: (
        [ ($e | keys - ["version", "updates"])[] | "top-level `\(.)`" ]
        + [ $by_eco[] | .[0]["package-ecosystem"] as $eco
            | if $gdirs[$eco] == null then
                "`\($eco)`: repo-tools does not detect it here, so it would no longer be updated"
              else
                ( (map(dirs[]) | unique) - $gdirs[$eco] | select(length > 0)
                  | "`\($eco)`: directories \(map("`\(.)`") | join(", ")) would no longer be updated" ),
                ( select(length > 1) | "`\($eco)`: \(length) separate update entries (e.g. per target branch) would become one" ),
                ( map(keys - known) | add | unique[] | "`\($eco)`: `\(.)`" ),
                ( map((.schedule // {}) | keys - ["interval"]) | add | unique[] | "`\($eco)`: `schedule.\(.)`" ),
                ( map((.cooldown // {}) | keys - ["default-days"]) | add | unique[] | "`\($eco)`: `cooldown.\(.)`" ),
                ( .[] | (.ignore // [])[] | select(ignore_ok | not)
                  | "`\($eco)`: ignore rule for `\(.["dependency-name"] // "?")` (\(keys - ["dependency-name"] | join(", ")))" )
              end ]
        + (if ($ints | length) > 1 then ["ecosystems update on different schedules (\($ints | join(", "))); repo-tools.conf sets one `DEPENDABOT_INTERVAL`"]
           elif ($ints | length) == 1 and ($ints[0] | IN(intervals[]) | not) then ["schedule interval `\($ints[0])`"]
           else [] end)
        + (if ($cools | length) > 1 then ["ecosystems use different cooldowns (\($cools | map(tostring) | join(", ")) days); repo-tools.conf sets one `DEPENDABOT_COOLDOWN_DAYS`"] else [] end)
      ),
      notes: (
        [ $by_eco[] | .[0]["package-ecosystem"] as $eco | (map((.groups // {}) | keys) | add | unique) as $g
          | select($g | length > 0)
          | "`\($eco)`: its groups (\($g | map("`\(.)`") | join(", "))) are replaced by repo-tools grouping" ]
        + (if ($cools | length) == 0 then ["new releases now wait 3 days before being proposed (`DEPENDABOT_COOLDOWN_DAYS=0` turns that off)"] else [] end)
      )
    }
'

# rt_migrate_dependabot EXISTING GENERATED -> the JSON plan above (compact).
# Returns 2 when no YAML parser is available to read them.
rt_migrate_dependabot() {
  local existing generated
  existing=$(rt_yaml_to_json "$1" 2>/dev/null) && generated=$(rt_yaml_to_json "$2" 2>/dev/null) || return 2
  [[ -n $existing && $existing != null ]] || existing='{}'
  jq -c --argjson gen "$generated" "$_RT_JQ_MIGRATE" <<<"$existing"
}

# rt_dependabot_comments FILE -> the comments inside its update entries
# (indented ones), which usually explain an ignore rule. The unindented
# header comments are boilerplate and are skipped.
rt_dependabot_comments() {
  local line
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]+#[[:space:]]?(.*)$ ]] && printf '%s\n' "${BASH_REMATCH[1]}"
  done <"$1"
  return 0
}

# --- Checks that would disappear (repo-ci REPLACE_WORKFLOWS) -------------------------

# rt_workflow_check_names FILE -> the name each job reports its check under
# (its `name:`, else its key). Matrix jobs add " (values)", and jobs calling
# a reusable workflow add " / <inner job>"; rt_match_required allows for both.
rt_workflow_check_names() {
  local json
  json=$(rt_yaml_to_json "$1" 2>/dev/null) || return 2
  jq -r '(if type == "object" then .jobs else null end) // {} | to_entries[]
    | (if (.value | type) == "object" then .value.name else null end) // .key
    | select(type == "string")' <<<"$json"
}

# rt_match_required REQUIRED NAMES
#   REQUIRED: "context<TAB>where it is required" lines (rt_required_checks)
#   NAMES:    "workflow<TAB>check name" lines
# Prints "context<TAB>where<TAB>workflow" for each required check that one of
# the named jobs produces.
rt_match_required() {
  local ctx src wf name
  while IFS=$'\t' read -r ctx src; do
    [[ -n $ctx ]] || continue
    while IFS=$'\t' read -r wf name; do
      [[ -n $name ]] || continue
      if [[ $ctx == "$name" || $ctx == "$name ("* || $ctx == "$name / "* ]]; then
        printf '%s\t%s\t%s\n' "$ctx" "$src" "$wf"
        break
      fi
    done <<<"$2"
  done <<<"$1"
  return 0
}

# rt_required_checks -> "context<TAB>where" for every status check the
# default branch requires: from rulesets (named) and classic branch protection.
rt_required_checks() {
  local ref rules id ctx
  local -A names=()
  ref=$(jq -rn --arg b "$RT_DEFAULT_BRANCH" '$b | @uri')
  rules=$(gh api "repos/$RT_REPO/rules/branches/$ref" 2>/dev/null) || rules='[]'
  while IFS=$'\t' read -r id ctx; do
    [[ -n $ctx ]] || continue
    if [[ -z ${names[$id]+set} ]]; then
      names[$id]=$(gh api "repos/$RT_REPO/rulesets/$id" --jq .name 2>/dev/null) || names[$id]="#$id"
    fi
    printf '%s\truleset "%s"\n' "$ctx" "${names[$id]}"
  done < <(jq -r '.[]? | select(.type == "required_status_checks") | .ruleset_id as $id
    | .parameters.required_status_checks[]? | "\($id)\t\(.context)"' <<<"$rules")
  gh api "repos/$RT_REPO/branches/$ref/protection/required_status_checks" --jq '.contexts[]' 2>/dev/null |
    while IFS= read -r ctx; do printf '%s\tbranch protection\n' "$ctx"; done
  return 0
}

# --- System packages hand-written workflows install --------------------------------

# rt_workflow_apt_packages FILE -> packages installed with apt / apt-get in
# the file's commands, one per line, unique. Continued lines ("\") are
# joined; options, variables and anything after a shell separator are skipped.
rt_workflow_apt_packages() {
  local line buf='' rest word
  local re='apt(-get)?([[:space:]]+-[^[:space:]]+)*[[:space:]]+install([^&;|>#]*)'
  {
    while IFS= read -r line || [[ -n $line ]]; do
      if [[ $line == *\\ ]]; then
        buf+="${line%\\} "
        continue
      fi
      line=$buf$line buf=''
      while [[ $line =~ $re ]]; do
        rest=${BASH_REMATCH[3]}
        line=${line#*"${BASH_REMATCH[0]}"}
        # ${{ expressions }} aren't package names (and contain spaces).
        while [[ $rest =~ \$\{\{[^}]*\}\} ]]; do rest=${rest/"${BASH_REMATCH[0]}"/ }; done
        set -f
        for word in $rest; do
          [[ $word =~ ^[a-z0-9][a-z0-9.+:~=-]*$ ]] && printf '%s\n' "$word"
        done
        set +f
      done
    done <"$1"
  } | LC_ALL=C sort -u
}

# rt_apt_suggestions CLONE -> "workflow<TAB>package package..." for each
# hand-written workflow installing apt packages that no APT_PACKAGES /
# <LANG>_APT_PACKAGES setting in repo-tools.conf installs. Reads workflows from
# the commit, so ones REPLACE_WORKFLOWS already deleted from the clone count.
rt_apt_suggestions() {
  local dir=$1 wf file key missing p
  local -A have=()
  for key in "${!RT_CONF[@]}"; do
    [[ $key == APT_PACKAGES || $key == *_APT_PACKAGES ]] || continue
    while IFS= read -r p; do [[ -z $p ]] || have[$p]=1; done < <(rt_list "${RT_CONF[$key]}")
  done
  file="$(rt_tmpdir)/apt-scan.yml"
  while IFS= read -r wf; do
    git -C "$dir" show "HEAD:$wf" >"$file" 2>/dev/null || continue
    grep -qF "$RT_MARKER" "$file" && continue
    missing=''
    while IFS= read -r p; do
      [[ -n $p && -z ${have[$p]+set} ]] && missing+="${missing:+ }$p"
    done < <(rt_workflow_apt_packages "$file")
    [[ -z $missing ]] || printf '%s\t%s\n' "${wf##*/}" "$missing"
  done < <(git -C "$dir" ls-tree -r --name-only HEAD -- .github/workflows | grep -E '\.ya?ml$' || true)
  return 0
}

# rt_dependabot_takeover CLONE GENERATED_FILE
# For --force on a hand-written dependabot.yml: writes what repo-tools.conf can
# express into it (and reloads the conf), and refuses (returns 1) if anything
# else would be dropped, unless --accept-loss. Sets RT_MIGRATED (KEY=VALUE),
# RT_LOST and RT_NOTES for the PR description.
rt_dependabot_takeover() {
  local dir=$1 file="$1/$RT_DEPENDABOT_FILE" plan l
  RT_MIGRATED=() RT_LOST=() RT_NOTES=()
  if ! plan=$(rt_migrate_dependabot "$file" "$2"); then
    if ((RT_ACCEPT_LOSS)); then
      warn "can't read $RT_DEPENDABOT_FILE (needs yq, or python3 + PyYAML), so none of its settings carry over; replacing it anyway (--accept-loss)"
      RT_LOST=("all of the hand-written file's settings (it couldn't be read)")
      return 0
    fi
    warn "can't read $RT_DEPENDABOT_FILE to carry its settings over: install yq, or python3 + PyYAML (or re-run with --accept-loss to replace it anyway)"
    return 1
  fi
  mapfile -t RT_LOST < <(jq -r '.lost[]' <<<"$plan")
  mapfile -t RT_NOTES < <(jq -r '.notes[]' <<<"$plan")
  if ((${#RT_LOST[@]})); then
    warn "replacing $RT_DEPENDABOT_FILE would drop settings $RT_CONF_FILE can't express:"
    for l in "${RT_LOST[@]}"; do warn "  - ${l//\`/}"; done
    if ((!RT_ACCEPT_LOSS)); then
      warn "leaving it alone; re-run with --accept-loss to replace it anyway"
      return 1
    fi
    warn "replacing it anyway (--accept-loss)"
  fi
  mapfile -t RT_MIGRATED < <(jq -r '.keys[] | "\(.key)\t\(.value)"' <<<"$plan" |
    rt_conf_append "$dir" "$RT_DEPENDABOT_FILE" "$(rt_dependabot_comments "$file")")
  if ((${#RT_MIGRATED[@]})); then
    rt_conf_load "$dir"
    for l in "${RT_MIGRATED[@]}"; do info "carried over to $RT_CONF_FILE: $l"; done
  fi
  for l in "${RT_NOTES[@]+"${RT_NOTES[@]}"}"; do info "note: ${l//\`/}"; done
  return 0
}
