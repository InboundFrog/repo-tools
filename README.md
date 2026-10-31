# repo-tools

Scripts to give GitHub repos a consistent baseline (Dependabot, CI on pull
requests, branch protection) without clicking through settings pages. Every
command is idempotent: run it again and it only changes what's out of date,
which is how updates get rolled out to repos you've already configured.

| Command | What it does |
|---|---|
| `bin/repo-dependabot` | Enables Dependabot alerts and security updates; opens a PR adding a generated `.github/dependabot.yml` |
| `bin/repo-ci` | Opens a PR adding `.github/workflows/repo-tools-ci.yml`, which runs lint, test and build for each detected language |
| `bin/repo-protect` | Turns on delete-branch-on-merge, makes the Actions token read-only by default and stops Actions approving PRs; on public repos, also secret scanning, push protection, private vulnerability reporting, CodeQL default setup and a default-branch ruleset |
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
| Rust | `rust.yml` | `cargo fmt`, `clippy -D warnings` | `cargo test` (incl. doc tests), plus `cargo audit` and MSRV jobs | `cargo build` |
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
is committed, and save their cache only from the default branch. A crate that
declares `rust-version` is also checked (`cargo check`) on that toolchain;
`RUST_MSRV=skip` turns that off.

Actions in these workflows are pinned to commit SHAs (with the version in a
comment), since they run in every repo. Dependabot updates the SHAs and comments.
Tools the workflows install themselves (uv, ruff, poetry, pytest, corepack,
cargo-audit, ansible-lint, Terraform, tflint) are pinned too, in each workflow's
top-level `env:` (`RT_*_VERSION`). Dependabot can't see those, so bump them by hand.
A project's own tool versions still win: ruff or pytest from its dependencies,
Terraform from `.terraform-version`.

Callers are **pinned to a release**: `repo-ci` writes
`uses: InboundFrog/repo-tools/.github/workflows/<lang>.yml@<commit SHA> # vX.Y.Z`,
using the newest `vX.Y.Z` tag here. A change merged to `main` reaches no one
until it's released. Each caller's Dependabot then opens a PR to move to the
new release, after its cooldown (`DEPENDABOT_COOLDOWN_DAYS`, 3 by default).
So one bad release shows up as a failing Dependabot PR in each repo rather
than as broken CI everywhere. To follow `main` anyway, or to pin a SHA
yourself, set `RT_REF` when running `repo-ci`.

### Releasing

```bash
git checkout main && git pull
git tag -a v1.2.0 -m "v1.2.0"   # semver: major for breaking changes to inputs or config
git push origin v1.2.0
```

Tags are only an index: callers pin the SHA, so a tag moved later doesn't change
what they run. Without any `vX.Y.Z` tag, `repo-ci` stops and asks for one (or for `RT_REF`).

This repo's own Dependabot config keeps the actions in these workflows current;
those bumps ship in the next release.

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
by replacing it (ignore rules, extra keys, ecosystems it didn't detect). The
comparison needs `yq` or python3 with PyYAML; without either it falls back to a
plain diff.

`--force` replaces a hand-written `dependabot.yml` **without losing what it did**.
Its ignore rules, interval and cooldown are written into `repo-tools.conf`, in
the same PR, together with the comments that explained them. If the old file
has anything the config can't express, such as labels, registries, `versions`
ranges, extra directories or ecosystems repo-tools doesn't detect,
`repo-dependabot` lists it and leaves the file alone. Add `--accept-loss` to
replace it anyway; the PR description then lists what was dropped. Settings
already in `repo-tools.conf` always win.

Existing workflows like `ci.yml` aren't touched unless listed in
`REPLACE_WORKFLOWS` (`REPLACE_WORKFLOWS=ci.yml`), in which case `repo-ci`
removes them in the same PR. It warns about unlisted workflows that also run on
push or pull requests. It also checks two things a replaced workflow may have
been doing, and adds them to the terminal output and the PR description:

- **Required checks.** If a ruleset or branch protection still requires a check
  from a workflow the PR removes (e.g. `build & test`), the PR would wait for it
  forever. Change that rule to require `CI OK` before merging.
- **System packages.** Packages a hand-written workflow installs with
  `apt-get install`, which no `APT_PACKAGES` / `<LANGUAGE>_APT_PACKAGES` setting
  covers. Native crates like `hidapi` fail to build without them.
  `repo-detect --compare` lists these too.

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

On every repo, `repo-protect` also restricts GitHub Actions:

- **The `GITHUB_TOKEN` is read-only by default.** A workflow that needs more
  says so in its own `permissions:` block, so whoever writes it takes on the
  extra access deliberately. Before the default changes, `repo-protect` lists
  the workflows on the default branch that don't declare `permissions:` for
  every job; any that write (push tags, publish releases, comment) need a block
  adding.
- **Workflows can't create or approve pull requests**, so a token approval
  can't satisfy a required review.

**Free plan limits:** rulesets, secret scanning and CodeQL only work on public repos.
Private repos still get Dependabot, CI and delete-branch-on-merge, but CI isn't
*enforced*. With GitHub Pro, pass `--include-private` to apply rulesets there too.

## Security model

- **Target repos are untrusted input.** Their files and `.github/repo-tools.conf`
  are read as data: config values are never evaluated by the scripts, and
  repo-tools refuses to read, write or delete through a symlink in a target
  repo (`.github` itself included), even with `--force`.
- **No `${{ }}` in config.** Values end up in the generated workflow, where
  GitHub would evaluate expressions before the reusable workflow runs them as
  commands. Use environment variables (`$GITHUB_HEAD_REF`, ...) in commands instead.
- **Branches and PRs.** `repo-tools/*` branches are force-pushed whenever their
  tree differs from what repo-tools would commit, so nothing else can ride along
  in a repo-tools PR. PRs from forks are never mistaken for the repo-tools PR.
- **Releases are the trust boundary.** Callers run a pinned commit and move
  only through a Dependabot PR, so a bad merge here stays here until it's
  tagged. Keep this repo's default branch protected
  (`bin/repo-protect InboundFrog/repo-tools`), and look at what changed since
  the last tag before releasing. `RT_REF=main` gives up that boundary for the
  repos it's used on.
- **CI checks are not a security gate.** `pull_request` runs use the PR's own
  copy of the workflow, so `CI OK` guards against mistakes, not against someone
  with write access. Use `RT_APPROVALS` (and CODEOWNERS) for that.

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
