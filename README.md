# grubstake

grubstake pins the build tools an iOS repo depends on. It is a single script that lives in the repo
it serves.

Every tool is pinned to an exact version and an exact SHA256. grubstake verifies the bytes it
downloads against that pin, and confirms the archive contains the version it was pinned to, before
anything is installed.

The pin is the trust boundary and it is checked at download. The cache afterwards is an
optimisation: it lives in your home directory, anything that can write to it can write to all of
it, and grubstake does not pretend otherwise.

`path` and `check` confirm a pinned entry exists without re-hashing it, so the commit path stays
fast; `path` downloads a missing entry unless `GRUBSTAKE_OFFLINE` is set, which the pre-commit spine
does. `ensure` re-hashes each binary and compares it against the receipt recorded at install; a
receipt that is removed, or rewritten to match a rewritten binary, passes that comparison too, so
the cache still is not a trust boundary -- only the pin checked at download is.

## Install

Fetch the script and adopt the repo.

```sh
curl -fsSL https://raw.githubusercontent.com/seriouslysean/grubstake/v1.3.0/grubstake.sh -o grubstake.sh
chmod +x grubstake.sh
./grubstake.sh version   # expect 1.3.0
./grubstake.sh install
```

Install from a release tag, never from `main`. `main` is a moving target, and a tool about
pinning should not adopt itself from an unpinned ref. The current release is on the
[releases page](https://github.com/seriouslysean/grubstake/releases/latest).

Then pin whichever tools the repo needs.

```sh
./grubstake.sh add swiftlint@0.63.2
```

Commit `grubstake.sh`, `grubstake.tools`, and `.githooks/` when you are happy with the result.

## Update

Updates are always manual. A repo stays on the version it has until you update it there, so two
repos can sit on different versions for as long as you like. A bare `update` stays within the
running major; `update <version>` is how to cross one deliberately.

```sh
./grubstake.sh update              # newest release in the running major
./grubstake.sh update <version>    # a specific release
./grubstake.sh install             # pick up whatever hook or config change it brought
```

The command rewrites `grubstake.sh` and stops, which leaves you a diff to review before committing.
If an update turns out to be wrong, `git revert` puts the old version back.

The `post-commit` hook tells you when a newer release exists in the major you are on. It only
reports, and never changes anything.

## Commands

```
./grubstake.sh install                  adopt this repo: write config, wire hooks, install tools
./grubstake.sh update [<tag>]           fetch a newer grubstake, replace this script, leave the diff
./grubstake.sh ensure                   install and verify every pinned tool
./grubstake.sh check                    confirm every pinned tool is installed for this platform
./grubstake.sh add <tool>@<version>...  pin one or more tools: download, hash, record
./grubstake.sh path <tool>              absolute path to a pinned tool
./grubstake.sh doctor                   report install health
./grubstake.sh clean                    remove the cached tool entries, read-only entries included
./grubstake.sh version                  print the version of this script
```

## Files

```
grubstake.sh      the engine, committed to the repo. Its version is the pin.
grubstake.tools   the pinned tools, one per line: name version sha256-darwin sha256-linux
.githooks/        the pre-commit and commit-msg spines, and the post-commit version notice
```

`.githooks/` is committed, but wiring it is not: `core.hooksPath` is local git config and is never
cloned with the repo. Run `./grubstake.sh install` once in every fresh clone; `./grubstake.sh
doctor` reports hooks `not wired` until you do.

Binaries are cached in `~/Library/Caches/grubstake`, or under `$XDG_CACHE_HOME` on Linux, so nothing
downloaded ever lands in the repo. Set `GRUBSTAKE_CACHE` if you want them somewhere else. Set
`GRUBSTAKE_OFFLINE` to a non-empty value to stop any tool from being downloaded: a missing one is
refused instead of installed wherever that would happen, and `add` refuses outright since it exists
to download. The pre-commit spine sets it for you, so a clean cache racing a commit never puts curl
on the commit path.

Each entry is a directory named for the archive hash it was installed from, so changing a pin
installs alongside rather than over, and two repos pinning different hashes of the same version
coexist. Entries are made read-only after they are published, so clearing the cache by hand needs
write permission back first; `./grubstake.sh clean` does both steps and removes the cached tool
entries, leaving the cache root and anything else in it alone:

```sh
./grubstake.sh clean
```

Checks that belong to one repo go in `.githooks/pre-commit.d/`, and checks on the commit message
itself go in `.githooks/commit-msg.d/`, where the spine that owns each directory will find and run
them. A gate that has lost its executable bit fails the commit rather than being skipped. Do not
edit either spine.

A pre-commit gate runs before the spine's own staged-Swift lint, so a gate that formats and
re-stages is linted on what it left behind rather than refused for what it was about to fix.

The commit-msg spine refuses a message carrying an agent-session trailer or a transcript link on
its own: both name something outside the repository that no reader of the published history can
open. Either shape is refused in any casing, on every line, comment lines included. Text below
git's own scissors line is skipped only when an editor produced the message, since that is the one
path on which git itself ever removes it; `-m` and `-F` publish everything below it too, and the
spine reads it in full there.

`update` replaces `grubstake.sh` and nothing else, so run `install` after it: `install` writes a
hook a release has added, refreshes one it recognises as its own earlier copy, and leaves anything
else alone. A hook carrying edits it does not recognise is left alone with a warning, and one
without its marker is never touched. The test is the bytes, not the intent: a hook reverted to an
earlier published copy is recognised, and refreshed.

The pre-commit lint reads the working tree rather than the staged blobs, so it checks the current
contents of files whose paths are staged. Linting a copy would break SwiftLint's config resolution,
and stashing the unstaged remainder is what strands work in the tools that do it, so a staged Swift
file carrying unstaged edits is refused by name instead. Stage the rest, or stash it with
`git stash push --keep-index` and pop it after the commit; a plain `git stash` would take the
staged hunk with it. CI lints the committed tree.

## Tools

grubstake knows how to install `swiftlint`, `swiftformat`, `xcbeautify`, and `periphery`.

`periphery` publishes no Linux build, so grubstake skips it there rather than failing the run.

## Operating

**Unadopt.** Run `./grubstake.sh clean` if the cached binaries should go. Move anything repo-owned
out of `.githooks/` (the `pre-commit.d/` and `commit-msg.d/` gates, and any hook without
grubstake's marker), then delete `grubstake.sh`, `grubstake.tools`, grubstake's three hooks and
`.git/grubstake-latest`, and run `git config --unset core.hooksPath`, the only git config grubstake
writes.

**Platforms.** macOS on arm64 or x86_64, and Linux on x86_64. Any other platform, or any other
Linux architecture, is refused.

**CI.** One job: check out the repo, cache `GRUBSTAKE_CACHE` at an explicit path keyed on
`grubstake.tools` and `grubstake.sh`, run `./grubstake.sh ensure`, then resolve each tool with
`./grubstake.sh path <tool>` to run it.

```yaml
- run: echo "GRUBSTAKE_CACHE=$HOME/.cache/grubstake" >>"$GITHUB_ENV"
- uses: actions/cache@<pinned sha>
  with:
    path: ${{ env.GRUBSTAKE_CACHE }}
    key: grubstake-${{ runner.os }}-${{ hashFiles('grubstake.tools', 'grubstake.sh') }}
- run: ./grubstake.sh ensure
- run: '"$(./grubstake.sh path swiftlint)" lint --strict'
```

**Linked worktrees.** `core.hooksPath` is shared config across every worktree of a repository, but
git resolves a relative value against each worktree's own root while an absolute one is the same
literal path everywhere. Once linked worktrees exist, `install` refuses an absolute value, even one
naming this repo's own `.githooks`; the relative `.githooks` it writes resolves in every worktree.

## Adopting it in an existing repo

The migration is in [ADOPTING.md](ADOPTING.md), which is written for an agent working through it.

## Contributing

The workflow is in [CONTRIBUTING.md](CONTRIBUTING.md), and the conventions the code holds itself to
are in [AGENTS.md](AGENTS.md).

## Stability

What a script or a person may rely on across releases is in [STABILITY.md](STABILITY.md).
