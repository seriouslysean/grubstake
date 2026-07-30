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
curl -fsSL https://raw.githubusercontent.com/seriouslysean/grubstake/main/grubstake.sh -o grubstake.sh
chmod +x grubstake.sh
```

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

## Phase 2: resolve through grubstake

Change whatever invokes the tools so it asks grubstake for the path.

```sh
SWIFTLINT="$(./grubstake.sh path swiftlint)" || exit 1
"$SWIFTLINT" lint --strict "$@"
```

Resolve from the repository root, before anything changes directory. That is the failure this
exists to prevent: a tool manager that reads its manifest relative to the working directory drops
the pin when a script moves.

`path` verifies the binary before printing it, so a tampered cache fails here rather than later.

Run the repo's own lint and validation entry points and confirm the results are unchanged.

## Phase 3: cut over in one commit

Delete the old mechanism and its manifest in a single commit, together with any hand-copied hashes
in CI. Two version sources live at once is the drift this replaces, so do not leave the old manifest
in place "for now".

In CI, replace whatever downloads the tools with:

```sh
./grubstake.sh ensure
```

Cache the tool directory keyed on `grubstake.tools`, since that file is the version source and a
change to it should invalidate the cache. On Linux the cache lives under `$XDG_CACHE_HOME`, and on
macOS under `~/Library/Caches/grubstake`. Set `GRUBSTAKE_CACHE` to place it somewhere else.

Prove the gate still fails. Introduce a violation the linter must catch, confirm the failure, and
remove it. A gate that never fires looks exactly like one that passes, so a migration is not
finished until the new path has been shown to reject something.

## Phase 4: hooks, only if the repo wants them

`./grubstake.sh install` wires `core.hooksPath` to `.githooks` and installs a pre-commit spine and a
post-commit version notice. It refuses to run if another hooks directory is already configured, and
it leaves existing hook files alone.

A repo with its own pre-commit logic should keep it. Move repo-specific checks into
`.githooks/pre-commit.d/`, where the spine runs each one and fails the commit if any fails or has
lost its executable bit. Never edit the spine itself, because `update` replaces it wholesale.

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
