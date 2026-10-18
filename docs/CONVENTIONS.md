# Conventions

How an iOS repository that uses grubstake lays out what sits around it: its scripts, hooks, CI, and
lint configuration. Written for an agent working in such a repository.

`./grubstake.sh doctor` checks the rules here that a script can check exactly, and reports each as
a row in its conventions section. Run it in the repository to see where it stands. The checks ship
in `grubstake.sh`, so they change when the repository updates grubstake and at no other time.

`doctor` reports those rows without failing on them. What it promises about that is in
[STABILITY.md](STABILITY.md). Everything else in this file is advisory. Getting grubstake into a
repository in the first place is [ADOPTING.md](ADOPTING.md).

## What doctor checks

| Row | Holds when |
|---|---|
| `scripts/bootstrap.sh`, `scripts/lint.sh`, `scripts/validate.sh`, `.githooks/pre-push` | The file exists and is executable. |
| `.swift-version` | The file exists. |
| `.xcode-version` | The file holds one version number. |
| `.swiftlint.yml` | The file exists and can be read. |
| `.swiftformat` | The file exists, can be read, and does not set the Swift version, as `--swiftversion` or `--swift-version`. |
| `node version` | There is no node version file, or it is `.nvmrc` holding an exact `x.y.z`. |
| `workflow actions` | Every `uses:` under `.github/workflows/` that names an action in another repository ends in a 40-character commit SHA. |
| `.claude/skills` | It is a symlink to `../.agents/skills`, and that directory exists. |
| `.codex/agents` | The repository's own ignore rules cover it, and nothing in it is tracked. |

The last two rows print only where `.agents/` exists. The rest of this file is prose only: `doctor`
does not read what a script does, how the CI job is laid out, or the lint and format baselines.

## Root files

Each version has one source.

| File | What it is the source for |
|---|---|
| `grubstake.sh`, `grubstake.tools` | Every pinned tool's version and hash. No script or workflow repeats one. |
| `.swift-version` | The Swift language version. SwiftFormat reads it, so `.swiftformat` carries no `--swiftversion`. |
| `.xcode-version` | The oldest Xcode the repository builds with. A floor, not an exact build. |
| `.nvmrc` | The exact node version, only in a repository that has node-based gates. |
| `.swiftlint.yml`, `.swiftformat` | Lint and format rules, and the lint scope. |

`scripts/validate.sh` refuses an Xcode older than `.xcode-version` before it builds anything. A
newer Xcode passes, so an Xcode release never blocks a push by itself.

A gate that runs node refuses any version other than the one in `.nvmrc`. CI installs that version
from the same file.

## scripts/bootstrap.sh

What a fresh clone runs once. It is idempotent, it runs from the repository root, and its last
step is `./grubstake.sh install`.

```sh
#!/bin/sh
# Fresh-clone bootstrap. Idempotent.
set -e

cd "$(git rev-parse --show-toplevel)"

# Steps that need no network go here.

# Last: under set -e a failed download would abort every step after it.
./grubstake.sh install
```

`install` wires `core.hooksPath`, writes or refreshes grubstake's hooks, and installs every pinned
tool. `ensure` alone installs the tools and leaves the hooks unwired, so a clone bootstrapped that
way commits ungated, and never picks up a hook a later grubstake release changed.

## scripts/lint.sh

The one place SwiftLint and SwiftFormat are invoked from, apart from grubstake's own pre-commit
hook. Hooks, `scripts/validate.sh`, and CI all call it.

```
scripts/lint.sh lint [files...]   SwiftLint, strict, over the project or over the given files
scripts/lint.sh format-check      SwiftFormat in lint mode over the project; changes nothing
scripts/lint.sh format <files>    format the given files in place
```

```sh
#!/bin/sh
set -e

cd "$(git rev-parse --show-toplevel)"

# SwiftFormat takes its scope on the command line. Keep this equal to `included:` in .swiftlint.yml.
FORMAT_TARGETS="Sources Tests"

mode="${1:-}"
[ "$#" -gt 0 ] && shift

case "$mode" in
    lint)
        SWIFTLINT=$(./grubstake.sh path swiftlint) || exit 1
        "$SWIFTLINT" lint --strict --quiet -- "$@"
        ;;
    format-check)
        SWIFTFORMAT=$(./grubstake.sh path swiftformat) || exit 1
        set -- --lint
        [ -z "${GITHUB_ACTIONS:-}" ] || set -- "$@" --verbose
        # shellcheck disable=SC2086 # the targets split into separate paths on purpose
        "$SWIFTFORMAT" $FORMAT_TARGETS "$@"
        ;;
    format)
        [ "$#" -gt 0 ] || {
            echo "[lint] format needs file arguments" >&2
            exit 1
        }
        SWIFTFORMAT=$(./grubstake.sh path swiftformat) || exit 1
        "$SWIFTFORMAT" "$@"
        ;;
    *)
        echo "Usage: scripts/lint.sh {lint [files...] | format-check | format <files>}" >&2
        exit 1
        ;;
esac
```

- **Tools resolve through grubstake, from the repository root, and a failure is fatal.** There is
  no fallback to a binary on `PATH`.
- **`included:` in `.swiftlint.yml` is the one lint scope.** `lint` with no arguments passes
  SwiftLint no paths. SwiftLint ignores a directory given on the command line when `included` is
  set, so a directory list in the script is a second list that changes nothing.
- **A `lint` run that finds no files fails.** SwiftLint's own exit status stands, so a run that
  checked nothing cannot read as a clean one. Leave `allow_zero_lintable_files` at its default.
- **File arguments are relative to the repository root**, where the script changes directory
  before it runs anything. `--` ends option parsing, so a path that starts with `-` is linted as a
  path.
- **`format-check` adds `--verbose` under `GITHUB_ACTIONS`.** SwiftFormat checks files concurrently
  unless that flag is given, and the time it allows each rule on a file is wall clock.
  Repositories that hit that timeout on small Linux runners stopped hitting it once the check ran
  serially.
- **`format` rewrites files and is run by hand.** No hook calls it.

## CI

One Linux job on pull requests, which installs the pinned tools and runs the two lint commands.
What needs Xcode runs locally through `scripts/validate.sh`. A repository adds further Linux jobs
for checks of its own.

```yaml
on:
  pull_request:

permissions:
  contents: read

concurrency:
  group: ci-${{ github.head_ref || github.run_id }}
  cancel-in-progress: true

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<pinned sha>
      - run: echo "GRUBSTAKE_CACHE=$HOME/.cache/grubstake" >>"$GITHUB_ENV"
      - uses: actions/cache@<pinned sha>
        with:
          path: ${{ env.GRUBSTAKE_CACHE }}
          key: grubstake-${{ runner.os }}-${{ hashFiles('grubstake.tools', 'grubstake.sh') }}
      - run: ./grubstake.sh ensure
      - run: ./grubstake.sh doctor
      - run: scripts/lint.sh lint
      - run: scripts/lint.sh format-check
```

- **Actions are pinned to a commit SHA.** A tag can be moved.
- **`GRUBSTAKE_CACHE` is set explicitly**, and the cache step reads the same variable, so the path
  that is cached is the path grubstake uses.
- **The cache key covers `grubstake.tools` and `grubstake.sh`, with no `restore-keys`.**
  [ADOPTING.md](ADOPTING.md) says why.
- **`ensure` runs on every run**, a cache hit included.
- **`doctor` runs after `ensure`**, and prints the conventions rows into the job's log.
- **A repository with node-based gates** adds `actions/setup-node` with
  `node-version-file: .nvmrc`.

## Hooks

`pre-commit`, `commit-msg`, and `post-commit` are grubstake's. Do not edit them. A repository's own
checks go in `.githooks/pre-commit.d/` and `.githooks/commit-msg.d/`, one executable file per
gate, named for what it checks.

A gate:

- exits 0 at once when nothing it covers is staged;
- fails when the checker it calls is missing, since a check that did not run must not look like
  one that passed;
- does not reach the network. The pre-commit and commit-msg hooks export `GRUBSTAKE_OFFLINE` for
  every gate they run.

**The formatting gate checks and refuses.** It never rewrites a file and never runs `git add`:
re-adding a formatted file stages all of its working-tree content, which folds an unstaged hunk
into the commit.

```sh
#!/bin/sh
# Pre-commit gate: the project passes the SwiftFormat check whenever Swift is staged.

git diff --cached --quiet --diff-filter=ACMRT -- '*.swift' && exit 0

scripts/lint.sh format-check || {
    echo "[pre-commit] swiftformat check failed: scripts/lint.sh format <file>, re-stage, retry." >&2
    exit 1
}
```

**`pre-push` belongs to the repository.** grubstake ships none. It routes on how the checked-out
branch differs from the default branch, and anything it cannot classify gets the full gate. It
reads the working tree, not the refs being pushed, so push the branch that is checked out, from a
clean tree.

```sh
#!/bin/sh
set -e

BASE=$(git merge-base HEAD origin/main 2>/dev/null || echo "")
[ -n "$BASE" ] || exec scripts/validate.sh

# --no-renames lists both ends of a move, so moving a gate away still counts as changing it.
CHANGED=$(git diff --name-only --no-renames "$BASE"..HEAD)

# Gate inputs come first, so no later route lets a change to the gates through unvalidated. A lint
# or format configuration counts at any depth.
if printf '%s\n' "$CHANGED" | grep -Eq '^(scripts/|\.githooks/|\.github/workflows/|grubstake\.(sh|tools)$|\.swift-version$|\.xcode-version$|\.nvmrc$)|(^|/)\.swift(lint\.yml|format)$'; then
    exec scripts/validate.sh
fi

# Documentation only: nothing to build.
printf '%s\n' "$CHANGED" | grep -qvE '\.md$' || exit 0

exec scripts/validate.sh
```

A repository adds narrower routes between those two for diffs it can classify, such as a change
confined to one package running that package's tests alone.

## scripts/validate.sh

The one full local gate: what `pre-push` calls, and what "validated" means in the repository. A
separate test script, where a repository has one, is a stage of it.

- **Cheap stages first:** `./grubstake.sh doctor`, the Xcode floor, `scripts/lint.sh lint`,
  `scripts/lint.sh format-check`, then the build, the tests, and any scans.
- **Tools resolve at the repository root, before anything changes directory.**
- **It builds into `.derivedData-local`**, which git ignores and both lint configurations exclude.

## Lint and format baseline

A repository starts from these and adds to them.

`.swiftlint.yml`:

```yaml
excluded:
  - .build
  - DerivedData
  - .derivedData
  - .derivedData-local

identifier_name:
  excluded: [i, x, y, dx, dy, id]

line_length:
  warning: 120
  error: 200
type_body_length:
  warning: 400
  error: 600
file_length:
  warning: 500
  error: 700
  ignore_comment_only_lines: true

opt_in_rules:
  - redundant_self
  - empty_count
  - implicit_return
  - redundant_type_annotation
  - accessibility_label_for_image
  - accessibility_trait_for_button
  - force_unwrapping
  - force_cast
  - force_try
  - overridden_super_call
  - identical_operands
  - unowned_variable_capture
  - fatal_error_message
  - shorthand_optional_binding
  - direct_return
  - reduce_into
  - modifier_order
  - async_without_await
  - unhandled_throwing_task
  - weak_delegate
  - first_where
  - contains_over_filter_count
  - toggle_bool
  - explicit_init
  - prohibited_super_call
  - private_swiftui_state
  - array_init
  - empty_string
  - empty_collection_literal
  - last_where
  - collection_alignment
  - convenience_type
  - pattern_matching_keywords
  - redundant_nil_coalescing
  - unneeded_parentheses_in_closure_argument

custom_rules:
  no_print_statements:
    name: "No print() in production code"
    regex: "\\bprint\\s*\\("
    message: "Use os_log or Logger instead of print()."
    severity: warning
    match_kinds:
      - identifier

reporter: xcode
```

`.swiftformat`:

```
--maxwidth 120
--exclude .build,DerivedData,.derivedData,.derivedData-local
--commas inline
--disable wrapMultilineStatementBraces
--disable modifierOrder
--test-case-name-format preserve
--suite-name-format preserve
--enable organizeDeclarations
--sort-swiftui-properties first-appearance-sort
--struct-threshold 60
--class-threshold 60
--enum-threshold 60
--extension-threshold 60
--enable privateStateVariables
--enable extensionAccessControl
```

There is no `--swiftversion` line. SwiftFormat takes the version from `.swift-version` when the
option is absent, and ignores that file when it is present, which makes a second copy that can
disagree with the first.

## Agent layer

For a repository that keeps agent definitions. One that has none skips this section.

- **`.agents/` is the one source** for agents, skills, and tools. `.claude/` holds symlinks into
  it, never copies: `.claude/skills` points at `../.agents/skills`.
- **Generated Codex adapters are not committed.** `.codex/agents/` is in `.gitignore` and is
  regenerated from `.agents/`, never edited by hand.
- **Model and effort pins on an agent are optional.**
- **A reviewer agent has no write or edit tool.** It keeps a shell only where it runs checks.
- **Claude Code and Codex are the tools covered.**
- **MCP servers are pinned to a version.**

## What each repository fills in

The shapes above are the same everywhere. These are the values a repository owns:

- **Scope:** `included:` in `.swiftlint.yml`, the matching `FORMAT_TARGETS` in `scripts/lint.sh`,
  and `deployment_target` in `.swiftlint.yml`.
- **Pins:** the tools and versions in `grubstake.tools`, and the values in `.swift-version`,
  `.xcode-version`, and `.nvmrc`.
- **Domain gates:** the files in `.githooks/pre-commit.d/` beyond the formatting gate.
- **Domain lint rules:** further `custom_rules`. A repository that keeps its logic in a Swift
  package bans platform-framework imports from that package's sources with one.
- **Validation stages:** what `scripts/validate.sh` builds, tests, and scans.
- **Push routes:** the narrower routes in `pre-push`.
