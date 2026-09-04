# grubstake

grubstake pins the build tools an iOS repo depends on. It is a single script that lives in the repo
it serves.

Every tool is pinned to an exact version and an exact SHA256. grubstake verifies the bytes it
downloads against that pin, and confirms the archive contains the version it was pinned to, before
anything is installed.

The pin is the trust boundary and it is checked at download. The cache afterwards is an
optimisation: it lives in your home directory, anything that can write to it can write to all of
it, and grubstake does not pretend otherwise.

## Install

Fetch the script and adopt the repo.

```sh
curl -fsSL https://raw.githubusercontent.com/seriouslysean/grubstake/v1.1.2/grubstake.sh -o grubstake.sh
chmod +x grubstake.sh
./grubstake.sh version   # expect 1.1.2
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
repos can sit on different versions for as long as you like.

```sh
./grubstake.sh update          # newest release
./grubstake.sh update 0.3.1    # a specific release
```

The command rewrites `grubstake.sh` and stops, which leaves you a diff to review before committing.
If an update turns out to be wrong, `git revert` puts the old version back.

The `post-commit` hook tells you when a newer release exists. It only reports, and never changes
anything.

## Commands

```
install                   adopt this repo by wiring hooks, creating pins, and installing tools
update [<tag>]            replace this script with a newer release
ensure                    install and verify every pinned tool
check                     confirm every pinned tool is installed for this platform
add <tool>@<version>...   pin one or more tools by downloading, hashing, and recording them
path <tool>               print the absolute path to a pinned tool
doctor                    report the health of this install
clean                     remove the entire cache, read-only entries included
version                   print the version of this script
```

## Files

```
grubstake.sh      the engine, committed to the repo. Its version is the pin.
grubstake.tools   the pinned tools, one per line: name version sha256-darwin sha256-linux
.githooks/        the pre-commit and commit-msg spines, and the post-commit version notice
```

Binaries are cached in `~/Library/Caches/grubstake`, or under `$XDG_CACHE_HOME` on Linux, so nothing
downloaded ever lands in the repo. Set `GRUBSTAKE_CACHE` if you want them somewhere else.

Each entry is a directory named for the archive hash it was installed from, so changing a pin
installs alongside rather than over, and two repos pinning different hashes of the same version
coexist. Entries are made read-only after they are published, so clearing the cache by hand needs
write permission back first; `grubstake clean` does both steps and removes the whole cache root:

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
open. Either shape is refused in any casing, and every line is read, comment lines included: `-m`,
`-F`, and `--cleanup=verbatim` all publish them, so the spine cannot assume a cleanup will strip
one.

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

## Adopting it in an existing repo

The migration is in [ADOPTING.md](ADOPTING.md), which is written for an agent working through it.

## Contributing

The workflow is in [CONTRIBUTING.md](CONTRIBUTING.md), and the conventions the code holds itself to
are in [AGENTS.md](AGENTS.md).

## Stability

What a script or a person may rely on across releases is in [STABILITY.md](STABILITY.md).
