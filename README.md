# grubstake

grubstake pins the build tools an iOS repo depends on. It is a single script that lives in the repo
it serves.

Every tool is pinned to an exact version and an exact SHA256. grubstake downloads the tool, verifies
the bytes it received, confirms the binary reports the version it was pinned to, and refuses to hand it
over if anything disagrees.

## Install

Fetch the script and adopt the repo.

```sh
curl -fsSL https://raw.githubusercontent.com/seriouslysean/grubstake/v0.2.1/grubstake.sh -o grubstake.sh
chmod +x grubstake.sh
./grubstake.sh version   # expect 0.2.1
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
install            adopt this repo by wiring hooks, creating pins, and installing tools
update [<tag>]     replace this script with a newer release
ensure             install and verify every pinned tool
check              re-verify installed tools against their pins
add <tool>@<ver>   pin a tool by downloading it, hashing both platforms, and recording it
path <tool>        print the absolute path to a pinned tool
doctor             report the health of this install
version            print the version of this script
```

## Files

```
grubstake.sh      the engine, committed to the repo. Its version is the pin.
grubstake.tools   the pinned tools, one per line: name version sha256-darwin sha256-linux
.githooks/        the pre-commit spine and the post-commit version notice
```

Binaries are cached in `~/Library/Caches/grubstake`, or under `$XDG_CACHE_HOME` on Linux, so nothing
downloaded ever lands in the repo. Set `GRUBSTAKE_CACHE` if you want them somewhere else.

Checks that belong to one repo go in `.githooks/pre-commit.d/`, where the spine will find and run
them. Do not edit the spine itself.

`update` replaces `grubstake.sh` and nothing else. Hooks are written once by `install`, which
leaves an existing hook file alone, so a spine fix reaches a repo only when you delete its hook
and re-run `install`. Release notes say when that is worth doing.

The pre-commit lint reads the working tree rather than the staged blobs, so it checks the current
contents of files whose paths are staged. Linting a copy would break SwiftLint's config resolution,
and stashing the unstaged remainder is what strands work in the tools that do it, so the hook warns
when the two diverge instead and leaves the committed tree to CI.

## Tools

grubstake knows how to install `swiftlint`, `swiftformat`, `xcbeautify`, and `periphery`.

`periphery` publishes no Linux build, so grubstake skips it there rather than failing the run.

## Adopting it in an existing repo

The migration is in [ADOPTING.md](ADOPTING.md), which is written for an agent working through it.

## Contributing

The workflow is in [CONTRIBUTING.md](CONTRIBUTING.md), and the conventions the code holds itself to
are in [AGENTS.md](AGENTS.md).
