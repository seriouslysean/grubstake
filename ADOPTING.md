# Adopting grubstake

Instructions for an agent adding grubstake to an existing iOS repo that already pins tools some
other way. Work through the phases in order and stop at the end of each one.

## Before you start

Read `README.md` and `AGENTS.md` in this repository. Read the existing tool setup in the repo you
are changing: its `Mintfile` or equivalent, `scripts/lint.sh`, `.githooks/`, and the CI workflow.

Do not invent versions. Every version you pin must come from what the repo already declares. The
point of this migration is to change the mechanism, not the versions.

## Phase 1: pin the tools, change nothing else

```sh
curl -fsSL https://raw.githubusercontent.com/seriouslysean/grubstake/v0.2.2/grubstake.sh -o grubstake.sh
chmod +x grubstake.sh
./grubstake.sh version   # confirm it matches the tag you asked for
```

Fetch a release tag, never `main`. Check the
[releases page](https://github.com/seriouslysean/grubstake/releases/latest) for the current one,
and confirm the version before continuing: a tool about pinning must not adopt itself from a
moving ref.

Add each tool at the version the repo already uses, taken from its existing manifest.

```sh
./grubstake.sh add swiftlint@<version-from-existing-manifest>
```

`add` downloads the artifact for both platforms, records the hashes, and installs. A tool with no
build for a platform records `-` for that column and is skipped there.

Verify before going further.

```sh
./grubstake.sh check
./grubstake.sh doctor
```

Then confirm every resolved binary reports the same version the old manifest declares. If any
disagree, stop and report it rather than adjusting a pin to make the check pass.

Commit `grubstake.sh` and `grubstake.tools`. Nothing else changes in this phase, so the old
mechanism keeps working and the repo now has a second opinion about the same versions.

## Phase 2: resolve through grubstake, without removing what works

Add grubstake as the **first** branch of whatever resolver the repo already has. Do not replace the
chain yet. CI is still installing tools the old way at this point, and a repo whose lint script
resolves from a directory CI populates will go red the moment that branch disappears.

```sh
if _gs=$(./grubstake.sh path swiftlint 2>/dev/null); then
    echo "$_gs"
elif [ -x "./tools/swiftlint" ]; then
    echo "./tools/swiftlint"
elif command -v swiftlint >/dev/null 2>&1; then
    command -v swiftlint
fi
```

Resolve from the repository root, before anything changes directory. That is the failure this
exists to prevent: a tool manager that reads its manifest relative to the working directory drops
the pin when a script moves, and installs whatever is newest without saying so.

`path` verifies the binary before printing it, so a tampered cache fails here rather than later. It
also installs the tool if it is missing, which is what lets this phase work before CI knows about
grubstake. That means a call to `path` can reach the network. The shipped pre-commit hook runs
`check` first, which fails with an instruction to run `ensure` rather than downloading mid-commit,
so keep that ordering in any hook of your own.

Run the repo's lint and validation entry points and confirm the results are unchanged. Every commit
from here to the end of phase 3 should be pushable and green.

## Phase 3: cut over in one commit

Now delete the old mechanism: its manifest, every invocation of it, the remaining branches of the
resolver chain, and any hand-copied hashes in CI. Two version sources live at once is the drift this
replaces, so do not leave the old manifest in place "for now".

Search without extension filters. Hook files have no extension, so `--include='*.sh'` will miss
them, and a stale reference in a hook is one nobody notices.

In CI, replace whatever downloads the tools with:

```sh
./grubstake.sh ensure
```

Cache the tool directory keyed on `grubstake.tools`, since that file is the version source and a
change to it should invalidate the cache. `ensure` re-verifies on a cache hit, so a poisoned cache
fails at install rather than during lint, and the conditional "only install on cache miss" step can
go.

If you add `ensure` to an existing bootstrap script, put it after anything that does not need the
network. Under `set -e` a failed download aborts every later step, and a fresh clone can end up
half-configured in a way the repo's own validation then reports as drift.

**Prove the gate still fails, per tool.** Inject a violation, confirm the failure, revert. Do it
once for each tool, not once overall: a whitespace violation may be owned by the formatter and
ignored by the linter, which proves nothing about the linter while looking like proof. Pick a rule
you have confirmed that repo's config actually enforces. Line length is a good default, since it is
almost always on and trivially injected.

## Phase 4: hooks, only if the repo wants them

`./grubstake.sh install` wires `core.hooksPath` to `.githooks` and installs a pre-commit spine and a
post-commit version notice. It refuses to run if another hooks directory is already configured, and
it leaves existing hook files alone.

A repo with its own pre-commit logic should keep it. Move repo-specific checks into
`.githooks/pre-commit.d/`, where the spine runs each one and fails the commit if any fails or has
lost its executable bit. Never edit the spine itself.

`update` replaces `grubstake.sh` only. Hooks are written once by `install` and left alone after
that, so a fix to the spine reaches this repo only when you delete the hook file and re-run
`install`. Check the release notes before assuming a hook fix arrived with an update.

## What to know before you hit it

The pre-commit lint reads the working tree, not the staged blobs, so it checks the current contents
of files whose paths are staged. It warns when the two diverge. This is deliberate and documented;
do not try to fix it locally.

`periphery` publishes no Linux build, so it is skipped there rather than failing.

Updates are manual and per repo. Run `./grubstake.sh update` in a repo when you want that repo on a
newer version, review the diff, and commit it. Repos are expected to sit on different versions.

Every open issue is in this repository. Read them before reporting something as new.

## Report back

Say which versions were pinned and where they came from, what the old mechanism was and that it is
gone, what you ran to prove the gate still fails, and anything that did not match.
