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
  [rust]="lint: cargo fmt --check, clippy --workspace --all-targets -D warnings | build: cargo build --workspace --all-targets | test: cargo test --workspace (incl. doc tests) | audit: cargo audit (separate job) | --locked when Cargo.lock is committed; cache saved from the default branch only"
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

# rt_list_workflows CLONE PLAN
# Lists existing workflows (jobs, actions and commands), then the jobs the
# generated CI would run, so the two can be compared by eye.
rt_list_workflows() {
  local dir=$1 plan=$2 wf json lang dirs kind val steps
  local -a files=()
  mapfile -t files < <(cd "$dir" && git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml')
  echo "Existing:"
  for wf in "${files[@]+"${files[@]}"}"; do
    if grep -qF "$RT_MARKER" "$dir/$wf"; then
      echo "  ${wf##*/}  (managed by repo-tools; would be regenerated)"
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
    steps=${RT_DEFAULT_STEPS[$lang]}
    for kind in lint test build audit; do
      val=$(rt_conf "${lang^^}_${kind^^}")
      [[ -z $val ]] || steps=$(sed -E "s#${kind}: [^|]*#${kind}: ${val//#/\\#} (override) #" <<<"$steps")
    done
    # bats only runs when there are tests to run.
    if [[ $lang == shell && -z $(rt_conf SHELL_TEST) && -z $(git -C "$dir" ls-files '*.bats') ]]; then
      steps=${steps/test: bats/test: bats (skipped: no *.bats files)}
    fi
    echo "    job $lang  (dirs: $dirs)"
    val=$(rt_conf "${lang^^}_APT_PACKAGES" "$(rt_conf APT_PACKAGES)")
    [[ -z $val ]] || echo "      apt: $val"
    for pair in ${RT_INPUT_KEYS[$lang]:-}; do
      [[ ${pair#*:} == *-command ]] && continue
      val=$(rt_conf "${pair%%:*}")
      [[ -z $val ]] || echo "      ${pair#*:}: $val"
    done
    tr '|' '\n' <<<"$steps" | sed -E 's/^ +//; s/ +$//; s/^/      /'
  done <<<"$plan"
  echo "    job ci-ok \"$RT_CI_CHECK_NAME\"  (the check branch protection requires)"
}
