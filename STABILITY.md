# Stability contract

What a script or a person may rely on across releases, and what may still change without notice.
Anything not listed here is an implementation detail.

## Commands

Argument grammar, frozen:

```
install                    adopt this repo: write config, wire hooks, install tools
update [<tag>]             fetch a newer grubstake, replace this script
ensure                     install and verify every pinned tool
check                      confirm every pinned tool is installed for this platform
add <tool>@<version> ...   pin one or more tools: download, hash, record
path <tool>                print the absolute path to a pinned tool
doctor                     report install health
clean                      remove the entire cache
version                    print the version of this script
```

No arguments, or `-h`/`--help`/`help`, prints usage and exits 0.

## Machine-readable output

- `version` writes exactly the version string (e.g. `1.0.0`) to stdout, nothing else.
- `path <tool>` writes exactly one absolute path to stdout, nothing else. Diagnostics go to
  stderr.
- Every command exits 0 on success and non-zero on any documented failure class. The specific
  non-zero value is not part of the contract; only zero-vs-nonzero may be relied on.

## The pins file

- Filename: `grubstake.tools`.
- Resolution: colocated with `grubstake.sh` itself, resolved from the running script's own path
  (symlinks followed), never from the working directory.

Two line grammars are accepted, and may coexist in the same file:

- Positional: `name version sha256-darwin sha256-linux`, one line per tool, `-` marking a
  platform with no build.
- Keyed: `name version key=sha256 [key=sha256 ...]`, one line per tool. `darwin` and `linux` are
  the keys read today. An unrecognized key is accepted and ignored, so a new platform is an
  addition to this file, not a breaking change to it. A platform with no build is expressed by
  omitting its key, never by `-`, in the keyed form.
- A line is keyed exactly when its third field contains `=`.

Coexistence is across tools, not within one: a tool is pinned by exactly one line, positional or
keyed, and a second line for the same tool is rejected regardless of which form either line uses.

`add` writes the positional form today. A future minor release may switch it to the keyed form;
every reader described here already accepts both, so that switch would not break a consumer.

## Hooks

The pre-commit and post-commit behaviour is a contract, not the hook files' bytes:

- pre-commit verifies pinned tools and lints staged Swift only when relevant files are staged,
  runs any repo-local gates in `.githooks/pre-commit.d/`, and blocks the commit on failure.
- post-commit reports when a newer grubstake release exists. It only reports, and never changes
  anything, and never blocks a commit.

The hook scripts themselves may be rewritten release to release; only this behaviour is promised.

## Dependencies

`unzip`, `tar` with `xz` support, a sha256 tool (`shasum` or `sha256sum`), `git`, and `curl`.

## Not promised

Diagnostic text, specific non-zero exit codes, cache directory layout, the receipt file's
implementation, and the hook files' literal contents. Any of these may change in a patch release.
