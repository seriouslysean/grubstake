# grubstake

grubstake pins the build tools an iOS repo depends on. It is a single script that lives in the repo
it serves.

Every tool is pinned to an exact version and an exact SHA256. grubstake downloads the tool, verifies
the bytes it received, confirms the binary reports the version it was pinned to, and refuses to hand it
over if anything disagrees.

## Install

Fetch the script and adopt the repo.

```sh
curl -fsSL https://raw.githubusercontent.com/seriouslysean/grubstake/main/grubstake.sh -o grubstake.sh
chmod +x grubstake.sh
./grubstake.sh install
```

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
them. Do not edit the spine itself, because `update` replaces it wholesale.

## Tools

grubstake knows how to install `swiftlint`, `swiftformat`, `xcbeautify`, and `periphery`.

`periphery` publishes no Linux build, so grubstake skips it there rather than failing the run.

## Contributing

The workflow is in [CONTRIBUTING.md](CONTRIBUTING.md), and the conventions the code holds itself to
are in [AGENTS.md](AGENTS.md).
