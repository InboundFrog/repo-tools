# repo-tools

Reusable GitHub Actions workflows that lint, test and build a repo for each
language in it, sample callers to copy into a repo, and one script that puts
the same security baseline on every repo you own.

| Part | What it is |
|---|---|
| `.github/workflows/<lang>.yml` | Reusable workflows: Python, Node, Rust, JVM, Terraform, Ansible, shell |
| `examples/workflows/` | Caller workflows to copy into a repo as `.github/workflows/ci.yml` |
| `examples/dependabot.yml` | Dependabot config to copy, covering every ecosystem the workflows know |
| `bin/repo-protect` | Repo settings, idempotently: Dependabot alerts and security updates, delete-branch-on-merge, merge commits only (no squash or rebase), a read-only Actions token; on public repos also secret scanning, private vulnerability reporting, CodeQL and a default-branch ruleset requiring `CI OK` |

## Quick start

In the target repo:

1. Copy the caller for its language from [`examples/workflows`](examples/workflows)
   to `.github/workflows/ci.yml`; `polyglot.yml` shows several languages,
   directories and runners. Edit the `with:` block (inputs below) and the
   default branch name.
2. Copy [`examples/dependabot.yml`](examples/dependabot.yml) to
   `.github/dependabot.yml` and delete the ecosystems the repo doesn't use.
3. Merge, then run `repo-protect` (needs bash 4.4+, `jq`, and
   [`gh`](https://cli.github.com/) logged in with the `repo` scope):

```bash
git clone https://github.com/InboundFrog/repo-tools && cd repo-tools
bin/repo-protect my-project              # "name" means a repo you own; or owner/name
bin/repo-protect --dry-run my-project    # show the API calls instead
bin/repo-protect --all                   # every non-archived, non-fork repo you own
bin/repo-protect --all --public          # public ones only
bin/repo-protect --file repos.txt        # one per line, # comments allowed
bin/repo-protect --prune my-project      # also delete older rulesets on the default branch
```

Re-run it whenever you like: it only changes what is out of date. Run it again
after the CI PR merges, so the ruleset starts requiring `CI OK`.

Repos set up by the old generator (`repo-tools-ci.yml` and `dependabot.yml`
with a `Managed by repo-tools` header) keep working: they are ordinary callers.
Edit them by hand from now on; the header no longer means anything.

## How CI works

The caller in each repo is a few lines per language, each a `uses:` of a
reusable workflow here, plus a final `CI OK` job:

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

Package managers and toolchain versions are picked up from the project
(lockfiles, `.python-version`, `.nvmrc`, `.java-version`, `rust-toolchain.toml`,
`.terraform-version`, ...). Rust builds use `--locked` when `Cargo.lock` is
committed, and save their cache only from the default branch. A crate that
declares `rust-version` is also checked (`cargo check`) on that toolchain.

### Inputs

Every workflow takes these (`with:` in the caller):

| Input | Default | Meaning |
|---|---|---|
| `working-directory` | `.` | Directory the job runs in. For several, use a `matrix` (see `polyglot.yml`) |
| `runs-on` | `ubuntu-latest` | Runner; a `matrix` gives several. System packages are only installed on Linux |
| `apt-packages` | | Ubuntu packages to install first, space separated (`libudev-dev pkg-config`) |
| `lint-command`, `test-command`, `build-command` | | Replace a step's default command; `skip` disables the step |
| `extra-command` | | Runs after lint, test and build (`ci/smoke.sh`) |
| `artifact-paths`, `artifact-name` | | Files or globs to upload once the job passes, relative to the working directory; the artifact is named `<name>-<os>[-<dir>]` |

Per language:

| Workflow | Inputs |
|---|---|
| `python.yml` | `python-version` (else `.python-version`, else 3.13) |
| `node.yml` | `node-version` (else `.nvmrc` / `.node-version`, else the latest LTS) |
| `rust.yml` | `toolchain` (else `rust-toolchain(.toml)`, else stable); `audit-command` and `msrv-command` replace or `skip` those jobs |
| `jvm.yml` | `build-tool` (`gradle` or `maven`; else detected), `java-version` (else `.java-version` / `.sdkmanrc`, else 21), `java-distribution` |
| `terraform.yml` | `terraform-version` (else `.terraform-version`), `tflint` (boolean) |
| `ansible.yml` | `python-version`, `ansible-lint-version` |
| `shell.yml` | none |

Commands run in the job's working directory, the way a `run:` step would.
Don't put `${{ }}` expressions in them: GitHub evaluates those before the
command runs, so a PR title or branch name would be spliced into it. Use the
environment instead (`$GITHUB_HEAD_REF`, ...).

### What the workflows pin

Actions are pinned to commit SHAs (version in a comment), since they run in
every repo; Dependabot keeps them current here, and those bumps ship in the
next release. Tools the workflows install themselves (uv, ruff, poetry,
pytest, corepack, cargo-audit, ansible-lint, Terraform, tflint) are pinned in
each workflow's top-level `env:` (`RT_*_VERSION`); Dependabot can't see those,
so bump them by hand. A project's own tool versions still win: ruff or pytest
from its dependencies, Terraform from `.terraform-version`.

### Failures and the `CI OK` check

When a lint, test, build or extra step fails, its output (from the first
`error`/`warning` diagnostic, else the last 100 lines, colour codes and cargo
progress lines removed) is repeated as an error annotation, so the failure can
be read from the checks API, or by an agent fixing CI, without the log.

The caller's final `CI OK` job passes only if every language job passed. It's
the single check branch protection requires, so the ruleset doesn't need to
know which languages a repo uses.

## Releases

Callers pin a release: `uses: InboundFrog/repo-tools/.github/workflows/<lang>.yml@<commit SHA> # vX.Y.Z`.
A change merged to `main` reaches no one until it's tagged. Each caller's
Dependabot then proposes the new release (the sample config waits 3 days
first), so one bad release shows up as a failing Dependabot PR in each repo
rather than as broken CI everywhere.

```bash
git checkout main && git pull
git tag -a v1.2.0 -m "v1.2.0"   # semver: major for breaking changes to inputs
git push origin v1.2.0
# then a PR that points examples/workflows at the new tag's commit
```

Tags are only an index: callers pin the SHA, so a tag moved later doesn't
change what they run. The tests check that the examples pin a release's
commit, and say so when a newer release exists.

## Branch protection

`repo-protect` creates or updates a ruleset named `repo-tools: default branch`:

- no deleting or force-pushing the default branch
- changes go through a pull request (0 approvals by default, since you can't approve your own),
  merged with a merge commit; squash and rebase are refused
- review conversations must be resolved before merging
- CodeQL alerts block merging (security alerts of medium severity or higher,
  and errors and warnings), on repos where CodeQL default setup is on
- `CI OK` must pass on a branch that is up to date with the default branch, once
  a workflow on the default branch has a job of that name

Repo admins can bypass these rules on a PR (e.g. to merge with failing checks)
but can't push directly to the default branch. Tune this with environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `RT_APPROVALS` | `0` | Required approving reviews |
| `RT_BYPASS` | `pull_request` | Admin bypass: `pull_request`, `always` or `none` |
| `RT_CODEQL` | `1` | Enable CodeQL default setup on public repos, and gate merges on it (`0` skips both) |
| `RT_MERGE_METHODS` | `merge` | Merge methods allowed, comma separated: `merge`, `squash`, `rebase` |

The merge methods are also set in the repo's own settings (Settings > General),
on every repo, private ones included: the other buttons disappear from PRs, and
on the Free plan that is the only thing stopping a squash merge on a private repo.

**Other rulesets.** When several rulesets cover a branch, all of them apply:
the strictest setting wins, and a bypass only lifts the ruleset that grants it.
So a ruleset made by hand before `repo-protect` can still decide what happens
on the default branch, for instance by allowing no bypass at all. `repo-protect`
lists every other ruleset that covers the default branch, disabled ones
included; once `repo-tools: default branch` does what you need, `--prune`
deletes them. Rulesets for other branches or for tags are left alone.

On the repo hosting the reusable workflows (`RT_SOURCE_REPO`, this one by
default) it adds a second ruleset, `repo-tools: release tags`: only repo admins
can create, move or delete `v*` tags. Callers pin the commit behind the newest
`vX.Y.Z` tag, so a tag there is a release, and write access alone must not be
enough to cut one.

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
Private repos still get Dependabot, the token restriction, delete-branch-on-merge and
the merge-method setting, but CI isn't *enforced*, and force-pushes aren't blocked. With GitHub Pro, pass `--include-private` to apply rulesets there too.

## Security model

- **Callers run a pinned commit.** The `uses:` line names a commit SHA, so what
  runs in a repo changes only through a Dependabot PR in that repo.
- **Releases are the trust boundary.** A bad merge here stays here until it's
  tagged. Run `bin/repo-protect InboundFrog/repo-tools` here: it protects the
  default branch and makes `v*` tags admin-only, so write access alone can't
  cut a release. Look at what changed since the last tag before releasing.
- **Inputs are code.** `*-command` inputs are run by the reusable workflow
  like a `run:` step, with the caller's read-only token and no secrets. That
  is the same access an edit to the caller workflow would have.
- **CI checks are not a security gate.** `pull_request` runs use the PR's own
  copy of the workflow, a fork's PR included, so a PR can swap in a workflow
  whose `CI OK` always passes. `CI OK` guards against mistakes, not against
  whoever opened the PR; a human review does, so set `RT_APPROVALS` (and
  CODEOWNERS) where that matters.
- **`repo-protect` reads only GitHub's API.** It clones nothing and runs
  nothing from the repos it configures. Workflow files it reads (to find the
  `CI OK` job and warn about missing `permissions:`) are parsed as data, with
  control characters stripped before anything reaches the terminal.

## Development

```bash
tests/run-tests.sh        # offline: examples, embedded scripts, repo-protect helpers
shellcheck bin/* lib/*.sh tests/*.sh
actionlint
```

CI runs all three on every PR.

```
bin/repo-protect   the one command (stable path, safe to symlink onto $PATH)
lib/common.sh      helpers it shares with the tests
.github/           reusable workflows, plus this repo's own CI and Dependabot config
examples/          caller workflows and dependabot.yml to copy
tests/             run-tests.sh
```

## Later: Terraform

GitHub has an official Terraform provider
([`integrations/github`](https://registry.terraform.io/providers/integrations/github/latest/docs))
covering repo settings, rulesets and file contents. `repo-protect` keeps each
setting separate, so it can be ported to resources one at a time if drift
detection becomes worth managing state for.
