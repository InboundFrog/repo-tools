#!/usr/bin/env bash
# Offline tests: the sample callers, the scripts embedded in the reusable
# workflows, and the helpers repo-protect relies on. No GitHub access needed;
# python3 + PyYAML, actionlint and shellcheck add checks when present.
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

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
yesno() { if "$@"; then echo yes; else echo no; fi; }

have_yaml=0
if python3 -c 'import yaml' 2>/dev/null; then have_yaml=1; fi
validate_yaml() { # NAME FILE
  ((have_yaml)) || return 0
  if python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$2" 2>/dev/null; then
    pass "$1: valid YAML"
  else
    fail "$1: valid YAML" "$(python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$2" 2>&1)"
  fi
}

WORKFLOWS=("$ROOT"/.github/workflows/{python,node,rust,jvm,terraform,ansible,shell}.yml)
EXAMPLES=("$ROOT"/examples/workflows/*.yml)

echo "Sample callers (examples/workflows)"
mapfile -t uses_lines < <(grep -hE '^[[:space:]]+uses: ' "${EXAMPLES[@]}")
assert_eq "every uses: is a repo-tools workflow pinned to a 40-character SHA, tag in a comment" "" \
  "$(printf '%s\n' "${uses_lines[@]}" |
    grep -vE "^[[:space:]]+uses: $RT_SOURCE_REPO/\.github/workflows/[a-z]+\.yml@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$" || true)"
pins=$(printf '%s\n' "${uses_lines[@]}" | sed -E 's#^.*@##' | sort -u)
assert_eq "all examples pin the same release" "1" "$(grep -c . <<<"$pins")"
sha=${pins%% *} tag=${pins##* }
for wf in $(printf '%s\n' "${uses_lines[@]}" | sed -E 's#^.*/\.github/workflows/##; s#@.*##' | sort -u); do
  assert_eq "called workflow exists: $wf" yes "$(yesno test -f "$ROOT/.github/workflows/$wf")"
done
if tags=$(git -C "$ROOT" ls-remote --tags origin 'v*' 2>/dev/null); then
  release=$(awk -v s="$sha" -v t="refs/tags/$tag" '$1 == s && ($2 == t || $2 == t "^{}")' <<<"$tags")
  assert_eq "pinned SHA is the commit of release $tag" yes "$(yesno test -n "$release")"
  newest=$(sed -nE 's#^[0-9a-f]{40}[[:space:]]+refs/tags/v([0-9]+\.[0-9]+\.[0-9]+)$#\1#p' <<<"$tags" |
    sort -t. -k1,1n -k2,2n -k3,3n | tail -n1)
  [[ v$newest == "$tag" ]] || echo "  note: the newest release is v$newest but the examples pin $tag; bump them"
else
  echo "  (no network: the pin isn't checked against the release tags)"
fi
for f in "${EXAMPLES[@]}"; do
  name=${f##*/}
  validate_yaml "$name" "$f"
  assert_eq "$name declares permissions" no "$(yesno rt_workflow_lacks_permissions "$f")"
  assert_eq "$name ends in a '$RT_CI_CHECK_NAME' job" yes "$(yesno rt_workflow_has_job "$f" "$RT_CI_CHECK_NAME")"
done
if ((have_yaml)); then
  out=$(python3 - "$ROOT" "${EXAMPLES[@]}" <<'PY'
import re, sys, yaml
root, files = sys.argv[1], sys.argv[2:]
inputs = {}
def wf_inputs(path):
    if path not in inputs:
        doc = yaml.safe_load(open(f"{root}/.github/workflows/{path}"))
        on = doc.get("on", doc.get(True, {}))  # PyYAML reads the bare `on:` key as True
        inputs[path] = set((on.get("workflow_call") or {}).get("inputs") or {})
    return inputs[path]
problems = []
for f in files:
    text = open(f).read()
    referenced = set()
    for job_id, job in yaml.safe_load(text)["jobs"].items():
        if "uses" not in job:
            continue
        path = job["uses"].split("@")[0].split("/.github/workflows/")[1]
        referenced.add(path)
        for key in (job.get("with") or {}):
            if key not in wf_inputs(path):
                problems.append(f"{f}: job {job_id}: {key} is not an input of {path}")
    allowed = set().union(*(wf_inputs(p) for p in referenced))
    for key in re.findall(r"^\s+# ([a-z][a-z-]*): ", text, re.M):
        if key not in allowed:
            problems.append(f"{f}: commented input {key} is not an input of {', '.join(sorted(referenced))}")
print("\n".join(problems))
PY
  )
  assert_eq "every with: input, commented suggestions included, exists in the workflow it calls" "" "$out"
fi
if command -v actionlint >/dev/null; then
  d=$(mktemp -d "$(rt_tmpdir)/examples.XXXXXX")
  git init -q "$d" && mkdir -p "$d/.github/workflows" && cp "${EXAMPLES[@]}" "$d/.github/workflows/" # actionlint wants a project root
  if out=$(cd "$d" && actionlint 2>&1); then pass "examples pass actionlint"; else fail "examples pass actionlint" "$out"; fi
fi

echo
echo "Sample dependabot.yml"
validate_yaml "examples/dependabot.yml" "$ROOT/examples/dependabot.yml"
if json=$(rt_yaml_to_json "$ROOT/examples/dependabot.yml" 2>/dev/null); then
  assert_eq "version 2, github-actions first" "2 github-actions" \
    "$(jq -r '"\(.version) \(.updates[0]["package-ecosystem"])"' <<<"$json")"
  assert_eq "every entry has directories, a schedule and a group" "" \
    "$(jq -r '.updates[] | select((.directories | length) == 0 or .schedule.interval == null or (.groups | length) == 0)
      | .["package-ecosystem"]' <<<"$json")"
fi

echo
echo "Steps shared by the reusable workflows"
# The "Prepare artifact" and "Install system packages" steps are copied into
# every reusable workflow: check the copies match, then run the artifact one.
if ((have_yaml)); then
  scripts=$(python3 - "${WORKFLOWS[@]}" <<'PY'
import sys, yaml
runs, apt = set(), set()
for f in sys.argv[1:]:
    for job in yaml.safe_load(open(f))["jobs"].values():
        for s in job.get("steps", []):
            if s.get("id") == "artifact": runs.add(s["run"])
            if s.get("name") == "Install system packages": apt.add(s["run"])
print(len(runs), len(apt))
print(next(iter(runs)), end="")
PY
  )
  assert_eq "Prepare artifact and Install system packages steps identical in every workflow" "1 1" "$(head -n1 <<<"$scripts")"
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
echo "Tools installed by the reusable workflows are pinned"
# Each pattern is an install of the latest release of something.
for unpinned in 'uvx ruff ' 'uvx poetry ' 'install pytest$' 'install -g corepack$' 'tool: cargo-audit$' 'v=latest'; do
  hits=$(grep -nE -- "$unpinned" "${WORKFLOWS[@]}" || true)
  assert_eq "no unpinned install: $unpinned" "" "$hits"
done
all_wfs=$(cat "${WORKFLOWS[@]}")
for var in RT_UV_VERSION RT_RUFF_VERSION RT_POETRY_VERSION RT_PYTEST_VERSION RT_COREPACK_VERSION \
  RT_CARGO_AUDIT_VERSION RT_TERRAFORM_VERSION RT_TFLINT_VERSION; do
  # Defined once (top-level env, a version) and used at least once.
  defs=$(grep -cE -- "^  ${var}: v?[0-9]" <<<"$all_wfs" || true)
  uses=$(grep -c -- "${var}[^:]" <<<"$all_wfs" || true)
  assert_eq "$var defined once and used" "1 yes" "$defs $([[ $uses -ge 1 ]] && echo yes || echo no)"
done
assert_contains "ansible-lint pinned by default" "default: 26." "$(sed -n '/ansible-lint-version:/,/default:/p' "$ROOT/.github/workflows/ansible.yml")"

echo
echo "Failure annotations (rt-run step shell)"
if ((have_yaml)); then
  wrapped="$(rt_tmpdir)/wrapped"
  mkdir -p "$wrapped"
  # Writes each workflow's rt-run script and every step run through it; prints
  # how many distinct rt-run scripts there are, then any job missing the setup.
  out=$(python3 - "$wrapped" "${WORKFLOWS[@]}" <<'PY'
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
if ((have_yaml)); then
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

echo
echo "Reading workflows for repo-protect"
wf="$(rt_tmpdir)/wf.yml"
lacks() { # YAML -> yes if a job is left on the default token permissions
  printf '%s\n' "$1" >"$wf"
  yesno rt_workflow_lacks_permissions "$wf"
}
assert_eq "no permissions anywhere -> lacks" yes \
  "$(lacks $'on: push\njobs:\n  a:\n    runs-on: x\n    steps: [{run: "true"}]')"
assert_eq "top-level permissions -> declares" no \
  "$(lacks $'on: push\npermissions:\n  contents: read\njobs:\n  a:\n    runs-on: x')"
assert_eq "every job declares its own -> declares" no \
  "$(lacks $'on: push\njobs:\n  a:\n    permissions: {}\n  b:\n    permissions:\n      contents: write')"
assert_eq "one job without -> lacks" yes \
  "$(lacks $'on: push\njobs:\n  a:\n    permissions: {}\n  b:\n    runs-on: x')"
has_ci_ok() { # YAML -> yes if a job is named CI OK
  printf '%s\n' "$1" >"$wf"
  yesno rt_workflow_has_job "$wf" "$RT_CI_CHECK_NAME"
}
assert_eq "job named CI OK found" yes "$(has_ci_ok $'on: push\njobs:\n  ci-ok:\n    name: CI OK\n    runs-on: x')"
assert_eq "a job key alone isn't the check name" no "$(has_ci_ok $'on: push\njobs:\n  ci-ok:\n    runs-on: x')"
assert_eq "other names don't count" no "$(has_ci_ok $'on: push\njobs:\n  a:\n    name: CI\n    runs-on: x')"
assert_eq "no jobs" no "$(has_ci_ok $'on: push\njobs: {}')"
own="$ROOT/.github/workflows/repo-tools-ci.yml"
assert_eq "this repo's own CI declares permissions and has a CI OK job" "no yes" \
  "$(yesno rt_workflow_lacks_permissions "$own") $(yesno rt_workflow_has_job "$own" "$RT_CI_CHECK_NAME")"

cat >"$(rt_tmpdir)/hostile.yml" <<'YAML'
"true":
  push:
jobs:
  a:
    name: "x\u001b]0;pwned\u0007y"
YAML
if json=$(rt_yaml_to_json "$(rt_tmpdir)/hostile.yml" 2>/dev/null); then
  assert_eq "a 'true' top-level key (PyYAML's reading of 'on') is renamed" '["jobs","on"]' "$(jq -c keys <<<"$json")"
  assert_eq "control characters stripped from parsed strings" 'x]0;pwnedy' "$(jq -r '.jobs.a.name' <<<"$json")"
  printf 'jobs: [\n' >"$(rt_tmpdir)/broken.yml"
  assert_eq "unparseable YAML fails cleanly" no "$(yesno rt_yaml_to_json "$(rt_tmpdir)/broken.yml" 2>/dev/null)"
else
  echo "  (no YAML parser: rt_yaml_to_json not tested)"
fi

echo
echo "Repository names"
for bad in --force -h 'a/b/c' '../x' 'https://github.com/a/b' ''; do
  if (rt_resolve_repo "$bad") 2>/dev/null; then rc=0; else rc=$?; fi
  assert_eq "repo name '$bad' refused" "1" "$rc"
done
assert_eq "owner/name accepted" "octo/my.repo-1" "$(rt_resolve_repo octo/my.repo-1)"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
