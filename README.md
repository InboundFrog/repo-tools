# repo-tools

Scripts to give GitHub repos a consistent baseline (Dependabot, CI on pull
requests, branch protection) without clicking through settings pages. Every
command is idempotent: run it again and it only changes what's out of date,
which is how updates get rolled out to repos you've already configured.

| Command | What it does |
|---|---|
| `bin/repo-dependabot` | Enables Dependabot alerts and security updates; opens a PR adding a generated `.github/dependabot.yml` |
| `bin/repo-ci` | Opens a PR adding `.github/workflows/repo-tools-ci.yml`, which runs lint, test and build for each detected language |
| `bin/repo-protect` | Turns on delete-branch-on-merge; on public repos, also secret scanning, push protection, private vulnerability reporting, CodeQL default setup and a default-branch ruleset |
| `bin/repo-apply` | Runs all three across one repo, a list, or `--all` of your repos |
| `bin/repo-detect` | Shows what would be detected and generated, from a local checkout or a repo. With `--compare`, sets it against the repo's existing `dependabot.yml` and workflows. Changes nothing |

## Requirements

- bash 4.4+ (macOS ships 3.2: `brew install bash`), git, jq
- [`gh`](https://cli.github.com/), logged in (`gh auth login`) with the `repo` scope

## Quick start

```bash
git clone https://github.com/InboundFrog/repo-tools && cd repo-tools

bin/repo-detect ~/src/my-project --render   # preview, no GitHub access needed
bin/repo-detect ~/src/my-project --compare  # vs the repo's existing dependabot.yml / workflows
bin/repo-apply --dry-run my-project          # show the API calls and diffs
bin/repo-apply my-project                    # do it
# merge the two PRs it opens, then:
bin/repo-protect my-project                  # now also requires the "CI OK" check
```

Repos are given as `owner/name`, or just `name` for your own. Bulk options:

```bash
bin/repo-apply --all                 # every non-archived, non-fork repo you own
bin/repo-apply --all --public        # public ones only
bin/repo-apply --file repos.txt      # one per line, # comments allowed
bin/repo-apply --all --only ci       # a subset of: dependabot, ci, protect
```

## How CI works

The generated `repo-tools-ci.yml` in each repo is a thin caller. The real work
lives in this repo's [reusable workflows](.github/workflows):

| Language | Workflow | Lint | Test | Build |
|---|---|---|---|---|
| Python | `python.yml` | ruff (+ `ruff format` if configured) | pytest | `uv build` |
| Node / TypeScript | `node.yml` | `lint`, `typecheck`, `format:check` scripts, or `tsc --noEmit` | `test` script | `build` script |
| Rust | `rust.yml` | `cargo fmt`, `clippy -D warnings` | `cargo test` (incl. doc tests), plus a `cargo audit` job | `cargo build` |
| Java / Kotlin (Gradle) | `jvm.yml` | `gradlew check -x test` | `gradlew test` | `gradlew assemble` |
| Java / Kotlin (Maven) | `jvm.yml` | none by default | `mvn test` | `mvn verify -DskipTests` |
| Terraform | `terraform.yml` | `terraform fmt`, tflint | `terraform test` | `init -backend=false` + `validate` per directory |
| Ansible | `ansible.yml` | ansible-lint | none by default | none by default |
| Shell | `shell.yml` | shellcheck | bats, if `*.bats` exist | none |

A repo with `.py` files but no Python project (`pyproject.toml`, `setup.py`,
requirements files, ...) still gets a Python job at the root, so helper scripts
are linted; with nothing to test or build, those steps pass.

Package managers and toolchain versions are picked up from the project (lockfiles,
`.python-version`, `.nvmrc`, `.java-version`, `rust-toolchain.toml`, `.terraform-version`, ...).
Every workflow can install Ubuntu packages first (`APT_PACKAGES`), for native
libraries the build links against. Each one can also run on other runners
(`OS=ubuntu-latest,macos-latest`), run an extra command after the standard steps
(`RUST_EXTRA=ci/smoke.sh`), and upload build output as an artifact
(`RUST_ARTIFACTS=target/release/mytool`). Rust builds use `--locked` when `Cargo.lock`
is committed, and save their cache only from the default branch.

Actions in these workflows are pinned to commit SHAs (with the version in a
comment), since they run in every repo. Dependabot updates the SHAs and comments.

Callers pin `@main`, so **a change merged here applies to every repo on its next
CI run**. To stage changes, set `RT_REF` (e.g. to a `v1` tag) when running
`repo-ci`. This repo's own Dependabot config keeps the actions in these
workflows current, and those bumps roll out the same way.

When a lint, test, build or extra step fails, its output (from the first
`error`/`warning` diagnostic, else the last 100 lines, colour codes and cargo
progress lines removed) is repeated as an error annotation. The failure can
then be read from the checks API, or by an agent fixing CI, without
downloading the log.

A final `CI OK` job passes only if every language job passed. It's the single
check branch protection requires, so the ruleset doesn't need to know which
languages a repo uses.

## Per-repo customisation

Generated files carry a `Managed by repo-tools` header and get overwritten.
Put overrides in `.github/repo-tools.conf` in the target repo instead, then
re-run `repo-ci` / `repo-dependabot`. See
[`examples/repo-tools.conf`](examples/repo-tools.conf) for every key. For example:

```ini
APT_PACKAGES=libudev-dev libusb-1.0-0-dev pkg-config
OS=ubuntu-latest,macos-latest
RUST_VERSION=1.96
RUST_EXTRA=ci/smoke.sh
RUST_ARTIFACTS=target/release/mytool
DEPENDABOT_IGNORE_CARGO=rand:major+minor
EXCLUDE=shell
PYTHON_VERSION=3.12
PYTHON_TEST=pytest -m "not slow"
GRADLE_LINT=./gradlew ktlintCheck detekt
NODE_BUILD=skip
DEPENDABOT_EXCLUDE=docker
```

Existing files without the header (e.g. a hand-written `dependabot.yml`) are
left alone with a warning. For `dependabot.yml`, `repo-dependabot` also prints
a per-ecosystem comparison: what repo-tools would add, and what would be lost
by replacing it (ignore rules, extra keys, ecosystems it didn't detect). Use
`--force` to replace them. The comparison needs `yq` or python3 with PyYAML;
without either it falls back to a plain diff. Existing workflows
like `ci.yml` aren't touched, so remove them yourself if they duplicate the
new one.

## Branch protection

`repo-protect` creates or updates a ruleset named `repo-tools: default branch`:

- no deleting or force-pushing the default branch
- changes go through a pull request (0 approvals by default, since you can't approve your own)
- `CI OK` must pass, once `repo-tools-ci.yml` exists on the default branch

Repo admins can bypass these rules on a PR (e.g. to merge with failing checks)
but can't push directly to the default branch. Tune this with environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `RT_APPROVALS` | `0` | Required approving reviews |
| `RT_BYPASS` | `pull_request` | Admin bypass: `pull_request`, `always` or `none` |
| `RT_CODEQL` | `1` | Enable CodeQL default setup on public repos (`0` to skip) |

CodeQL default setup needs no workflow file: GitHub picks the languages and keeps
the queries current. A repo that already runs its own CodeQL workflow (advanced
setup) keeps it; `repo-protect` warns and moves on. Delete that workflow first if
you'd rather switch.

**Free plan limits:** rulesets, secret scanning and CodeQL only work on public repos.
Private repos still get Dependabot, CI and delete-branch-on-merge, but CI isn't
*enforced*. With GitHub Pro, pass `--include-private` to apply rulesets there too.

## Development

```bash
tests/run-tests.sh        # offline tests: detection, config, rendering, file guards
shellcheck bin/* lib/*.sh tests/*.sh
actionlint
```

CI runs all three on every PR.

```
bin/        entry points (stable paths, safe to symlink onto $PATH)
lib/        common.sh, detect.sh, render.sh, gitops.sh
.github/    reusable workflows, plus this repo's own CI and Dependabot config
examples/   annotated repo-tools.conf
tests/      run-tests.sh
```

## Later: Terraform

GitHub has an official Terraform provider
([`integrations/github`](https://registry.terraform.io/providers/integrations/github/latest/docs))
covering repo settings, rulesets and file contents. The scripts keep each
concern separate, so they can be ported to resources one at a time if
drift detection becomes worth managing state for.
