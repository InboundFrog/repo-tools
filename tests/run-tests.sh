#!/usr/bin/env bash
# Offline tests for detection, config handling and rendering. No GitHub access
# needed. Uses actionlint and python3+PyYAML for extra validation when present.
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/detect.sh
source "$ROOT/lib/detect.sh"
# shellcheck source=lib/render.sh
source "$ROOT/lib/render.sh"
# shellcheck source=lib/gitops.sh
source "$ROOT/lib/gitops.sh"
# shellcheck source=lib/compare.sh
source "$ROOT/lib/compare.sh"

PASS=0 FAIL=0
pass() {
  PASS=$((PASS + 1))
  printf '  ok   %s\n' "$1"
}
fail() {
  FAIL=$((FAIL + 1))
  printf '  FAIL %s\n' "$1"
  [[ -z ${2:-} ]] || printf '%s\n' "$2" | sed 's/^/       /'
}
assert_eq() { # NAME EXPECTED ACTUAL
  if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1" "$(diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") || true)"; fi
}
assert_contains() { # NAME NEEDLE HAYSTACK
  if [[ $3 == *"$2"* ]]; then pass "$1"; else fail "$1" "missing: $2"; fi
}
assert_not_contains() {
  if [[ $3 != *"$2"* ]]; then pass "$1"; else fail "$1" "unexpected: $2"; fi
}

# new_repo -> path of an empty git repo; files added with mk + commit
new_repo() {
  local d
  d=$(mktemp -d "$(rt_tmpdir)/fixture.XXXXXX")
  git -C "$d" init -q -b main
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name test
  printf '%s\n' "$d"
}
mk() { # REPO PATH [CONTENT]
  mkdir -p "$(dirname "$1/$2")"
  printf '%s' "${3:-}" >"$1/$2"
}
commit() { git -C "$1" add -A && git -C "$1" commit -qm fixture --allow-empty; }

validate_yaml() { # NAME FILE
  if command -v python3 >/dev/null && python3 -c 'import yaml' 2>/dev/null; then
    if python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$2" 2>/dev/null; then
      pass "$1: valid YAML"
    else
      fail "$1: valid YAML" "$(python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$2" 2>&1)"
    fi
  fi
}

echo "Polyglot repo detection"
repo=$(new_repo)
mk "$repo" package.json '{}'
mk "$repo" packages/a/package.json '{}'                 # npm workspace member: folded into root
mk "$repo" node_modules/x/package.json '{}'             # ignored path
mk "$repo" tools/py/pyproject.toml '[project]'
mk "$repo" tools/py/uv.lock
mk "$repo" tools/py/main.py
mk "$repo" scripts/requirements.txt 'requests'
mk "$repo" crates/Cargo.toml
mk "$repo" crates/core/Cargo.toml                       # cargo workspace member
mk "$repo" jvm/settings.gradle.kts
mk "$repo" jvm/app/build.gradle.kts
mk "$repo" legacy/pom.xml
mk "$repo" infra/main.tf
mk "$repo" infra/modules/net/main.tf
mk "$repo" ansible/roles/web/tasks/main.yml
mk "$repo" deploy.sh 'echo'
mk "$repo" bin/tool $'#!/usr/bin/env bash\necho'
mk "$repo" bin/pytool $'#!/usr/bin/env python3\n'
mk "$repo" Dockerfile 'FROM scratch'
commit "$repo"

assert_eq "CI languages and directories" \
  "$(printf '%s\t%s\n' python scripts,tools/py node . rust crates gradle jvm maven legacy terraform . ansible ansible shell .)" \
  "$(rt_detect_langs "$repo")"
assert_eq "Dependabot ecosystems and directories" \
  "$(printf '%s\t%s\n' github-actions . npm . uv tools/py pip scripts cargo crates gradle jvm maven legacy \
    terraform infra,infra/modules/net docker .)" \
  "$(rt_detect_ecosystems "$repo")"
assert_eq "shell scripts found by extension and shebang" \
  "$(printf '%s\n' bin/tool deploy.sh)" "$(rt_shell_files "$repo" | sort)"

rt_conf_load "$repo"
ci=$(rt_render_ci "$repo" main)
dep=$(rt_render_dependabot "$repo")
assert_contains "CI calls reusable workflow at RT_REF" "uses: $RT_SOURCE_REPO/.github/workflows/python.yml@$RT_REF" "$ci"
assert_contains "CI matrix over python dirs" "dir: ['scripts', 'tools/py']" "$ci"
assert_contains "gradle job passes build-tool" "build-tool: gradle" "$ci"
assert_contains "aggregate job needs every language" \
  "needs: [python, node, rust, gradle, maven, terraform, ansible, shell]" "$ci"
assert_contains "aggregate job named for branch protection" "name: $RT_CI_CHECK_NAME" "$ci"
assert_contains "CI runs on pushes to the default branch" "branches: ['main']" "$ci"
assert_contains "dependabot lists terraform module dirs" "      - '/infra/modules/net'" "$dep"
assert_contains "dependabot groups minor/patch" "update-types: [minor, patch]" "$dep"
assert_contains "managed marker present (CI)" "$RT_MARKER" "$ci"
assert_contains "managed marker present (dependabot)" "$RT_MARKER" "$dep"

mkdir -p "$repo/.github/workflows"
printf '%s\n' "$ci" >"$repo/$RT_CI_FILE"
printf '%s\n' "$dep" >"$repo/$RT_DEPENDABOT_FILE"
validate_yaml "rendered CI" "$repo/$RT_CI_FILE"
validate_yaml "rendered dependabot.yml" "$repo/$RT_DEPENDABOT_FILE"
if command -v actionlint >/dev/null; then
  if out=$(cd "$repo" && actionlint "$RT_CI_FILE" 2>&1); then pass "rendered CI passes actionlint"; else fail "rendered CI passes actionlint" "$out"; fi
fi

echo
echo "Single-language repo (most ecosystems absent)"
repo=$(new_repo)
mk "$repo" Cargo.toml '[package]'
mk "$repo" src/main.rs
commit "$repo"
# Consumed via process substitution under set -e, as the renderers do: a
# helper returning non-zero for an absent ecosystem used to stop detection.
mapfile -t got < <(rt_detect_ecosystems "$repo")
assert_eq "ecosystems survive absent ones" "$(printf '%s\t%s\n' github-actions . cargo .)" "$(printf '%s\n' "${got[@]}")"
mapfile -t got < <(rt_detect_langs "$repo")
assert_eq "languages survive absent ones" "$(printf '%s\t%s' rust .)" "${got[*]}"
RT_CONF=()
assert_contains "rendered dependabot includes cargo" "package-ecosystem: cargo" "$(rt_render_dependabot "$repo")"

echo
echo "Comparing with an existing dependabot.yml"
mk "$repo" "$RT_DEPENDABOT_FILE" "version: 2
registries:
  crates: {type: cargo-registry, url: https://example.com}
updates:
  - package-ecosystem: cargo
    directory: /
    schedule: {interval: daily}
    open-pull-requests-limit: 2
    ignore:
      - dependency-name: rand
        update-types: [version-update:semver-major]
  - package-ecosystem: npm
    directory: /web
    schedule: {interval: weekly}
"
rt_render_dependabot "$repo" >"$(rt_tmpdir)/generated.yml"
if rt_yaml_to_json "$repo/$RT_DEPENDABOT_FILE" >/dev/null 2>&1; then
  report=$(rt_compare_dependabot "$repo/$RT_DEPENDABOT_FILE" "$(rt_tmpdir)/generated.yml")
  assert_contains "ecosystem only repo-tools covers" "+ github-actions  not covered" "$report"
  assert_contains "ecosystem only existing covers" "- npm  only in the existing config" "$report"
  assert_contains "shared directory" "= directories  /" "$report"
  assert_contains "interval difference" "~ interval     existing daily, repo-tools weekly" "$report"
  assert_contains "groups repo-tools adds" "+ groups       cargo-minor-patch" "$report"
  assert_contains "ignore rules would be lost" "- ignore       rand (major)" "$report"
  assert_contains "unknown keys would be lost" "- other keys   open-pull-requests-limit" "$report"
  assert_contains "top-level keys would be lost" "top-level keys only in existing: registries" "$report"
fi

echo
echo "Standalone Python scripts"
repo=$(new_repo)
mk "$repo" Cargo.toml '[package]'
mk "$repo" tools/gen_maps.py 'print()'
mk "$repo" tests/fixtures/x.py 'print()'                # fixtures are ignored
commit "$repo"
assert_eq "scripts without a project -> one python job at the root" \
  "$(printf '%s\t%s\n' python . rust .)" "$(rt_detect_langs "$repo")"
assert_eq "no pip ecosystem without a manifest" \
  "$(printf '%s\t%s\n' github-actions . cargo .)" "$(rt_detect_ecosystems "$repo")"
mk "$repo" svc/pyproject.toml '[project]'
commit "$repo"
assert_eq "a python project takes over from the root fallback" \
  "$(printf '%s\t%s\n' python svc rust .)" "$(rt_detect_langs "$repo")"
repo=$(new_repo)
mk "$repo" tests/fixtures/only.py 'print()'
commit "$repo"
assert_eq "only ignored .py files -> no python job" "" "$(rt_detect_langs "$repo")"

echo
echo "Config overrides (.github/repo-tools.conf)"
repo=$(new_repo)
mk "$repo" pyproject.toml '[project]'
mk "$repo" app.py
mk "$repo" web/package.json '{}'
mk "$repo" run.sh 'echo'
mk "$repo" "$RT_CONF_FILE" "# comment
LANGUAGES = python, node, rust
EXCLUDE=rust
PYTHON_VERSION=\"3.12\"
PYTHON_TEST=skip
PYTHON_LINT=ruff check src && echo 'it''s fine'
NODE_DIRS=web,admin
DEPENDABOT_EXCLUDE=pip
DEPENDABOT_INTERVAL=monthly
DEPENDABOT_COOLDOWN_DAYS=0   # trailing comment
QUOTED_HASH=\"keep # this\"
not a setting
"
commit "$repo"
rt_conf_load "$repo"
assert_eq "conf parsed (quotes stripped, spaces trimmed)" "3.12" "$(rt_conf PYTHON_VERSION)"
assert_eq "trailing comment dropped" "0" "$(rt_conf DEPENDABOT_COOLDOWN_DAYS)"
assert_eq "# inside quotes kept" "keep # this" "$(rt_conf QUOTED_HASH)"
assert_eq "LANGUAGES limits jobs; EXCLUDE removes; shell not listed" \
  "$(printf '%s\t%s\n' python . node web,admin)" "$(rt_ci_plan "$repo")"
ci=$(rt_render_ci "$repo" main)
dep=$(rt_render_dependabot "$repo")
assert_contains "version override" "python-version: '3.12'" "$ci"
assert_contains "skip passed through" "test-command: 'skip'" "$ci"
assert_contains "single quotes escaped" "lint-command: 'ruff check src && echo ''it''''s fine'''" "$ci"
assert_not_contains "excluded ecosystem dropped" "package-ecosystem: pip" "$dep"
assert_contains "interval override" "interval: monthly" "$dep"
assert_not_contains "cooldown 0 omits cooldown" "cooldown:" "$dep"
printf '%s\n' "$ci" >"$repo/ci.yml"
validate_yaml "rendered CI with overrides" "$repo/ci.yml"

echo
echo "System packages, Rust inputs and Dependabot ignore rules"
repo=$(new_repo)
mk "$repo" Cargo.toml '[package]'
mk "$repo" Cargo.lock
mk "$repo" tools/pyproject.toml '[project]'
mk "$repo" tools/x.py
mk "$repo" "$RT_CONF_FILE" "APT_PACKAGES=libudev-dev, pkg-config
PYTHON_APT_PACKAGES=libpq-dev
RUST_VERSION=1.96
RUST_AUDIT=skip
DEPENDABOT_IGNORE_CARGO=rand:minor+major windows-*
DEPENDABOT_IGNORE_GITHUB_ACTIONS=actions/checkout:major
"
commit "$repo"
rt_conf_load "$repo"
ci=$(rt_render_ci "$repo" main)
dep=$(rt_render_dependabot "$repo")
rust_job=$(sed -n '/^  rust:/,/^$/p' <<<"$ci")
python_job=$(sed -n '/^  python:/,/^$/p' <<<"$ci")
assert_contains "global APT_PACKAGES, space separated" "apt-packages: 'libudev-dev pkg-config'" "$rust_job"
assert_contains "per-language APT_PACKAGES wins" "apt-packages: 'libpq-dev'" "$python_job"
assert_contains "RUST_VERSION -> toolchain" "toolchain: '1.96'" "$rust_job"
assert_contains "RUST_AUDIT -> audit-command" "audit-command: 'skip'" "$rust_job"
assert_contains "ignore with update types" "- dependency-name: 'rand'
        update-types: ['version-update:semver-minor', 'version-update:semver-major']" "$dep"
assert_contains "ignore without update types" "- dependency-name: 'windows-*'" "$dep"
assert_contains "ignore key for hyphenated ecosystem" "- dependency-name: 'actions/checkout'" "$dep"
printf '%s\n' "$dep" >"$(rt_tmpdir)/ignore-dependabot.yml"
validate_yaml "dependabot.yml with ignore rules" "$(rt_tmpdir)/ignore-dependabot.yml"
mkdir -p "$repo/.github/workflows" && printf '%s\n' "$ci" >"$repo/$RT_CI_FILE"
if command -v actionlint >/dev/null; then
  if out=$(cd "$repo" && actionlint "$RT_CI_FILE" 2>&1); then pass "CI with extra inputs passes actionlint"; else fail "CI with extra inputs passes actionlint" "$out"; fi
fi
mk "$repo" "$RT_DEPENDABOT_FILE" "version: 2
updates:
  - package-ecosystem: cargo
    directory: /
    schedule: {interval: weekly}
    ignore:
      - dependency-name: rand
        update-types: [version-update:semver-major, version-update:semver-minor]
      - dependency-name: old-crate
"
if rt_yaml_to_json "$repo/$RT_DEPENDABOT_FILE" >/dev/null 2>&1; then
  report=$(rt_compare_dependabot "$repo/$RT_DEPENDABOT_FILE" "$(rt_tmpdir)/ignore-dependabot.yml")
  assert_contains "ignore rule on both sides (order-insensitive)" "= ignore       rand (major, minor)" "$report"
  assert_contains "ignore rule only in existing" "- ignore       old-crate" "$report"
  assert_contains "ignore rule only in repo-tools" "+ ignore       windows-*" "$report"
fi

echo
echo "Runner OS matrix, extra command and artifacts"
repo=$(new_repo)
mk "$repo" Cargo.toml '[package]'
mk "$repo" Cargo.lock
mk "$repo" tools/a.py 'print()'
mk "$repo" "$RT_CONF_FILE" "OS=ubuntu-latest, macos-latest
PYTHON_OS=ubuntu-latest
RUST_EXTRA=ci/smoke.sh
RUST_BUILD=cargo build --release --locked
RUST_ARTIFACTS=target/release/tvmap, tvmap-out/
"
commit "$repo"
rt_conf_load "$repo"
ci=$(rt_render_ci "$repo" main)
rust_job=$(sed -n '/^  rust:/,/^$/p' <<<"$ci")
python_job=$(sed -n '/^  python:/,/^$/p' <<<"$ci")
assert_contains "OS -> os matrix" "        os: ['ubuntu-latest', 'macos-latest']" "$rust_job"
assert_contains "os matrix feeds runs-on" "      runs-on: \${{ matrix.os }}" "$rust_job"
assert_contains "<LANG>_OS wins over OS" "        os: ['ubuntu-latest']" "$python_job"
assert_contains "RUST_EXTRA -> extra-command" "extra-command: 'ci/smoke.sh'" "$rust_job"
assert_contains "artifacts named after the language" "artifact-name: 'rust'" "$rust_job"
assert_contains "artifact paths space separated" "artifact-paths: 'target/release/tvmap tvmap-out/'" "$rust_job"
assert_not_contains "no artifacts unless configured" "artifact-" "$python_job"
mkdir -p "$repo/.github/workflows" && printf '%s\n' "$ci" >"$repo/$RT_CI_FILE"
validate_yaml "CI with OS matrix" "$repo/$RT_CI_FILE"
if command -v actionlint >/dev/null; then
  if out=$(cd "$repo" && actionlint "$RT_CI_FILE" 2>&1); then pass "CI with OS matrix passes actionlint"; else fail "CI with OS matrix passes actionlint" "$out"; fi
fi
out=$(rt_list_workflows "$repo" "$(rt_ci_plan "$repo")")
assert_contains "compare lists the runners" "      os: ubuntu-latest macos-latest" "$out"
assert_contains "compare lists the extra command" "      extra: ci/smoke.sh" "$out"
assert_contains "compare lists artifacts" "      artifacts: target/release/tvmap tvmap-out/" "$out"
RT_CONF=()
assert_not_contains "no os matrix by default" "os:" "$(rt_render_ci "$repo" main)"

# The "Prepare artifact" step is copied into every reusable workflow: check the
# copies match, then run one.
if command -v python3 >/dev/null && python3 -c 'import yaml' 2>/dev/null; then
  scripts=$(python3 - "$ROOT"/.github/workflows/{python,node,rust,jvm,terraform,ansible,shell}.yml <<'PY'
import sys, yaml
runs = set()
for f in sys.argv[1:]:
    steps = yaml.safe_load(open(f))["jobs"]["check"]["steps"]
    runs.update(s["run"] for s in steps if s.get("id") == "artifact")
print(len(runs))
print(next(iter(runs)), end="")
PY
  )
  assert_eq "Prepare artifact step identical in every workflow" "1" "$(head -n1 <<<"$scripts")"
  tail -n +2 <<<"$scripts" >"$(rt_tmpdir)/artifact.sh"
  out=$(GITHUB_OUTPUT="$(rt_tmpdir)/artifact.out" RUNNER_OS=macOS NAME=rust WORKDIR=./tools/cli/ \
    PATHS=$'target/release/x\ndist/*.tar.gz' bash -eo pipefail "$(rt_tmpdir)/artifact.sh" && cat "$(rt_tmpdir)/artifact.out")
  assert_eq "artifact paths prefixed with the working directory; name made unique" \
    "$(printf '%s\n' 'paths<<RT_EOF' tools/cli/target/release/x 'tools/cli/dist/*.tar.gz' RT_EOF name=rust-macos-tools-cli)" "$out"
  out=$(GITHUB_OUTPUT="$(rt_tmpdir)/artifact2.out" RUNNER_OS=Linux NAME='' WORKDIR=. PATHS='a b' \
    bash -eo pipefail "$(rt_tmpdir)/artifact.sh" && cat "$(rt_tmpdir)/artifact2.out")
  assert_eq "artifact at the repo root" "$(printf '%s\n' 'paths<<RT_EOF' a b RT_EOF name=build-linux)" "$out"
fi

echo
echo "Empty repo"
repo=$(new_repo)
mk "$repo" README.md '# hi'
commit "$repo"
RT_CONF=()
assert_eq "nothing detected" "" "$(rt_ci_plan "$repo")"
ci=$(rt_render_ci "$repo" main)
assert_contains "still renders the CI OK job" "name: $RT_CI_CHECK_NAME" "$ci"
assert_not_contains "no needs when there are no jobs" "needs:" "$ci"
assert_eq "dependabot covers only github-actions" \
  "$(printf '%s\t%s\n' github-actions .)" "$(rt_detect_ecosystems "$repo")"
mkdir -p "$repo/.github/workflows"
printf '%s\n' "$ci" >"$repo/$RT_CI_FILE"
if command -v actionlint >/dev/null; then
  if out=$(cd "$repo" && actionlint "$RT_CI_FILE" 2>&1); then pass "empty CI passes actionlint"; else fail "empty CI passes actionlint" "$out"; fi
fi

echo
echo "Managed file guard"
repo=$(new_repo)
mk "$repo" "$RT_DEPENDABOT_FILE" "version: 2  # hand written"
commit "$repo"
if rt_write_managed "$repo" "$RT_DEPENDABOT_FILE" <<<"new" 2>/dev/null; then rc=0; else rc=$?; fi
assert_eq "refuses to overwrite unmanaged file" "1 version: 2  # hand written" "$rc $(cat "$repo/$RT_DEPENDABOT_FILE")"
RT_FORCE=1 rt_write_managed "$repo" "$RT_DEPENDABOT_FILE" <<<"# $RT_MARKER v1" 2>/dev/null
assert_eq "--force overwrites" "# $RT_MARKER v1" "$(cat "$repo/$RT_DEPENDABOT_FILE")"
rt_write_managed "$repo" "$RT_DEPENDABOT_FILE" <<<"# $RT_MARKER v2"
assert_eq "managed file is updated without --force" "# $RT_MARKER v2" "$(cat "$repo/$RT_DEPENDABOT_FILE")"

echo
echo "PR publishing (dry run)"
repo=$(new_repo)
mk "$repo" README.md '# hi'
commit "$repo"
RT_DEFAULT_BRANCH=main RT_DRY_RUN=1
out=$(rt_publish_pr "$repo" repo-tools/x "t" "b" README.md 2>&1)
assert_contains "no change -> nothing to do" "already up to date" "$out"
mk "$repo" "$RT_CI_FILE" "# $RT_MARKER"
out=$(rt_publish_pr "$repo" repo-tools/x "t" "b" "$RT_CI_FILE" 2>&1)
assert_contains "change -> would open PR" "would open a PR from 'repo-tools/x'" "$out"
assert_contains "dry run shows the diff" "+# $RT_MARKER" "$out"
RT_DRY_RUN=0

echo
echo "Listing existing workflows next to the generated jobs"
repo=$(new_repo)
mk "$repo" run.sh 'echo'
commit "$repo"
RT_CONF=()
out=$(rt_list_workflows "$repo" "$(rt_ci_plan "$repo")")
assert_contains "no workflows yet" "  (none)" "$out"
assert_contains "bats reported as skipped without *.bats files" "test: bats (skipped: no *.bats files)" "$out"
mk "$repo" test/run.bats '@test "x" { true; }'
commit "$repo"
out=$(rt_list_workflows "$repo" "$(rt_ci_plan "$repo")")
assert_contains "bats reported when *.bats files exist" "      test: bats" "$out"
assert_not_contains "no skipped note with *.bats files" "skipped: no *.bats" "$out"

echo
echo "Renderer and reusable workflows agree on inputs"
if command -v python3 >/dev/null && python3 -c 'import yaml' 2>/dev/null; then
  for lang in "${RT_LANGS[@]}"; do
    wf="$ROOT/.github/workflows/${RT_WORKFLOW[$lang]}"
    want=(working-directory apt-packages lint-command test-command build-command
      extra-command runs-on artifact-name artifact-paths)
    for pair in ${RT_INPUT_KEYS[$lang]:-}; do want+=("${pair#*:}"); done
    case $lang in gradle | maven) want+=(build-tool) ;; esac
    # PyYAML reads the bare `on:` key as boolean True.
    missing=$(python3 - "$wf" "${want[@]}" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
on = doc.get("on", doc.get(True, {}))
inputs = (on.get("workflow_call") or {}).get("inputs") or {}
print(" ".join(i for i in sys.argv[2:] if i not in inputs))
PY
)
    assert_eq "$lang -> ${RT_WORKFLOW[$lang]} accepts every input the renderer emits" "" "$missing"
  done
fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
