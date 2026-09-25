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
curl -fsSL https://raw.githubusercontent.com/seriouslysean/grubstake/v1.3.1/grubstake.sh -o grubstake.sh
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
if [ -x ./grubstake.sh ] && [ -f grubstake.tools ]; then
    ./grubstake.sh path swiftlint || exit 1      # a real failure stays fatal
elif [ -x "./tools/swiftlint" ]; then
    echo "./tools/swiftlint"
elif command -v swiftlint >/dev/null 2>&1; then
    command -v swiftlint
fi
```

Branch on whether grubstake is **set up**, never on whether it **succeeded**. Suppressing its exit
status falls through to an unpinned binary on exactly the failures it exists to raise: a hash
mismatch, a malformed pins file, an unreachable download. A machine with the tool on `PATH` will
then lint with whatever version it happens to have, and exit 0. A half-migrated repo is the unsafe
state, so delete the remaining branches the moment phase 3 lands.

Resolve from the repository root, before anything changes directory. That is the failure this
exists to prevent: a tool manager that reads its manifest relative to the working directory drops
the pin when a script moves, and installs whatever is newest without saying so.

`path` installs the tool if it is missing, which is what lets this phase work before CI knows about
grubstake. That means a call to `path` can reach the network. The shipped pre-commit hook sets
`GRUBSTAKE_OFFLINE` for its whole run, so inside a commit `path` refuses a missing tool with an
instruction to run `ensure` rather than downloading; set it in any hook of your own that calls `path`.

The download is checked against the pin, and the cache is keyed by that hash, so editing a pin is a
cache miss rather than something that has to be detected. `path` and `check` then confirm the
pinned entry exists, no hashing, so the commit path stays fast and offline. `ensure` goes further:
it re-hashes each binary and compares it against a receipt recorded at install -- an entry from
before receipts existed gets one written in place, offline, against whatever is already there --
and an entry that no longer matches its receipt is reported rather than replaced, since nothing
here will delete a binary another repo might be executing. A receipt that is removed, or rewritten
to match a rewritten binary, passes that comparison too: the cache is not a trust boundary, only the
pin checked at download is. What the cache cannot do is defend itself: it lives in your home directory and
anything able to write to it can write to all of it.

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

Cache the tool directory keyed on **both** `grubstake.tools` and `grubstake.sh`:

```yaml
key: grubstake-${{ runner.os }}-${{ hashFiles('grubstake.tools', 'grubstake.sh') }}
```

The pins decide which versions; the script decides the cache layout. Keying on pins alone means a
grubstake upgrade that changes the layout restores an unchanged key, misses every lookup,
re-downloads everything, and then saves nothing because the key already existed. The job stays
green and pays that cost on every run until someone happens to edit a pin.

Avoid a `restore-keys` prefix, or expect the cache to grow: entries are never unlinked, so a prefix
hit restores the old layout and saves it alongside the new one. `ensure` re-hashes each binary on a
cache hit and compares it against the receipt recorded at install, so a binary poisoned on its own
fails at install rather than surfacing later during lint, and the conditional "only install on cache
miss" step can go. A receipt that is removed, or rewritten to match a rewritten binary, passes that
comparison too: the cache is not a trust boundary, the pin checked at download is.

If you add `ensure` to an existing bootstrap script, put it after anything that does not need the
network. Under `set -e` a failed download aborts every later step, and a fresh clone can end up
half-configured in a way the repo's own validation then reports as drift.

**Prove the gate still fails, once per gate.** Inject a violation, confirm the failure, revert. Do
it separately for each tool that can reject input, not once overall: a whitespace violation may be
owned by the formatter and ignored by the linter, which proves nothing about the linter while
looking like proof. Pick a rule you have confirmed that repo's config actually enforces. Line
length is a good default, since it is almost always on and trivially injected.

Some pinned tools reject nothing. An output formatter has no gate to prove, and no wording makes
one provable. Report a pinned tool that nothing invokes, or that no gate depends on, as a finding
rather than as a gap in the proof: it is being downloaded on every cold cache for no reason.

## Phase 4: hooks, only if the repo wants them

`./grubstake.sh install` wires `core.hooksPath` to `.githooks` and installs a pre-commit spine, a
commit-msg spine, and a post-commit version notice. It refuses to run if another hooks directory is
already configured, or if `.git/hooks` holds an executable hook that wiring `.githooks` would
silence; move that hook under `.githooks/` first. A value that already resolves to this repo's own
hooks directory -- an absolute path to it, say -- is accepted and left exactly as written, unless
the repository has linked worktrees, where only the relative `.githooks` is accepted. Once
installed, it writes any hook that is missing, refreshes one whose bytes match an earlier published
copy of itself, and otherwise leaves it alone -- with a warning for one it does not recognise,
silently for one carrying no marker.

The commit-msg spine refuses a commit message carrying an agent-session trailer or a transcript
link. Both name a transcript outside the repository, which nobody reading the history later can
open, and no scan of tracked files can see a message that has not been written yet. Either shape is
refused in any casing, on every line, comment lines included. Text below git's own scissors line is
skipped only when an editor produced the message, since that is the one path on which git itself
ever removes it; `-m` and `-F` publish everything below it too, and the spine reads it in full
there.

A repo with its own pre-commit logic should keep it. Move repo-specific checks into
`.githooks/pre-commit.d/`, and checks on the commit message into `.githooks/commit-msg.d/`, where
the spine that owns each directory runs every gate in it and fails the commit if any gate fails or
has lost its executable bit. A message gate is handed the message file as its argument. Never edit
either spine.

A pre-commit gate runs before the spine's own staged-Swift lint, in glob order, so a gate that
formats staged files and re-stages them is linted on what it produced rather than refused for what
it was about to fix. The spine re-reads the staged paths once the gates are done, so Swift a gate
staged is linted too. A gate that fails refuses the commit there and then, before any lint runs.

A repo that already has a `commit-msg` hook of its own keeps it: `install` never touches a hook
without grubstake's marker, so that repo gains no message gate until its own hook moves into
`.githooks/commit-msg.d/`.

`update` replaces `grubstake.sh` only, so follow it with `install`: that is what delivers a spine
fix, or a hook a release has added. `install` refreshes a hook whose bytes match one of grubstake's
own earlier copies, warns and leaves alone one that carries edits it cannot recognise, and never
touches a hook without its marker. The test is the bytes rather than the intent, so a hook
deliberately held at an earlier published copy is recognised as one of grubstake's own and
refreshed; to keep a hook out of that path, change it in a way grubstake has never published, or
drop the marker line.

## What to know before you hit it

The pre-commit lint reads the working tree, not the staged blobs, so it checks the current contents
of files whose paths are staged. When the two diverge it refuses the commit and names the paths, so
`git add -p` over a Swift file means stashing the remainder before committing. Stage the rest, or
`git stash push --keep-index` and pop after the commit -- a plain `git stash` takes the staged hunk
with it and leaves the retry committing nothing. This is deliberate and documented; do not try to
fix it locally.

`periphery` publishes no Linux build, so it is skipped there rather than failing.

Updates are manual and per repo. Run `./grubstake.sh update` in a repo when you want that repo on a
newer version, then `./grubstake.sh install` to pick up whatever hook or config change it brought,
review the diff, and commit it. Repos are expected to sit on different versions.

Every open issue is in this repository. Read them before reporting something as new.

## Report back

Say which versions were pinned and where they came from, what the old mechanism was and that it is
gone, what you ran to prove the gate still fails, and anything that did not match.
