# Stability contract

What a script or a person may rely on across releases, and what may still change without notice.
Anything not listed here is an implementation detail.

## Versioning

A major release may break something this file promises. A minor release adds to it -- a command, a
pins-file key, a tool, an environment variable, or a hook behaviour -- without breaking what is
already promised. A patch release fixes behaviour without changing what is promised. A bare
`update` never crosses a major; `update <version>` is how to cross one deliberately.

## Commands

Argument grammar, frozen:

```
install                    adopt this repo: write config, wire hooks, install tools
update [<tag>]             fetch a newer grubstake, replace this script
ensure                     install and verify every pinned tool
check                      confirm every pinned tool is installed for this platform
add <tool>@<version>...   pin one or more tools: download, hash, record
path <tool>                print the absolute path to a pinned tool
doctor                     report install health
clean                      remove the cached tool entries, leaving the cache root and anything else in it alone
version                    print the version of this script
```

No arguments, or `-h`/`--help`/`help`, prints usage and exits 0.

## Machine-readable output

- `version` writes exactly the version string (e.g. `1.0.0`) to stdout, nothing else.
- `path <tool>` writes exactly one absolute path to stdout, nothing else. Diagnostics go to
  stderr.
- `doctor` prints every row regardless of what it finds, and exits non-zero if any row reports a
  problem.
- Every command exits 0 on success and non-zero on any documented failure class. The specific
  non-zero value is not part of the contract; only zero-vs-nonzero may be relied on.

## Environment

- `GRUBSTAKE_CACHE`: an absolute path; overrides the cache root.
- `GRUBSTAKE_OFFLINE`: non-empty means no tool is downloaded -- a missing one is refused instead of
  installed, and `add` refuses outright since it downloads by design. The shipped pre-commit hook
  sets it for the whole spine.
- `XDG_CACHE_HOME`: read on Linux only; a relative value is treated as unset.
- `HOME`: the cache root falls back to a path under it when `GRUBSTAKE_CACHE` (and, on Linux,
  `XDG_CACHE_HOME`) is not set.
- `TMPDIR`: scratch directories for downloads and staging are created under it, `/tmp` otherwise.
- `GRUBSTAKE_REPO`, `GRUBSTAKE_RAW`: override the repository and raw-content source `update`
  fetches releases from.

## The pins file

- Filename: `grubstake.tools`.
- Resolution: colocated with `grubstake.sh` itself, resolved from the running script's own path
  (symlinks followed), never from the working directory.

Two line grammars are accepted, and may coexist in the same file:

- Positional: `name version sha256-darwin sha256-linux`, one line per tool, `-` marking a
  platform with no build.
- Keyed: `name version key=sha256 [key=sha256 ...]`, one line per tool. `darwin` and `linux` are
  the keys read today. Every field from the third on matches `[a-z0-9_]+=[0-9a-f]{64}` -- one
  field failing that shape rejects the whole line -- and no key repeats on it; a key inside that
  shape but not read by name yet is accepted and ignored, so a new platform is an addition to this
  file, not a breaking change to it. A platform with no build is expressed by omitting its key,
  never by `-`, in the keyed form.
- A line is keyed exactly when its third field contains `=`.

Coexistence is across tools, not within one: a tool is pinned by exactly one line, positional or
keyed, and a second line for the same tool is rejected regardless of which form either line uses.

`add` writes the positional form today. A future minor release may switch it to the keyed form;
every reader described here already accepts both, so that switch would not break a consumer.

## Hooks

The pre-commit, commit-msg, and post-commit behaviour is a contract, not the hook files' bytes:

- pre-commit verifies pinned tools only when relevant files are staged, runs any repo-local gates
  in `.githooks/pre-commit.d/` in glob order, then lints staged Swift as those gates left it, and
  blocks the commit on failure. The order is part of the contract: a gate that formats staged Swift
  and re-stages it is linted on what it produced. Staged Swift that diverges from the working tree
  is refused rather than linted, since the lint reads the working tree and any verdict it returned
  would be about bytes that are not being committed.
- commit-msg refuses a message carrying an agent-session trailer or a transcript link, in any
  casing, on every line of the message, comment lines included, with one exception: text below
  git's own scissors line, and only when an editor actually produced it, since that is the only
  path on which git itself ever removes that text. It then runs any repo-local gates in
  `.githooks/commit-msg.d/` with the message file as their argument, and blocks the commit on
  failure.
- post-commit reports when a newer grubstake release exists in the same major version as the one
  running. It only reports, touches nothing but its own advisory cache inside `.git`, and never
  blocks a commit. That cache is stamped before the lookup starts and again once it returns, answer
  or not, so a lookup that hangs is never restarted by the next commit and one that fails is not
  repeated either.

The hook scripts themselves may be rewritten release to release; only this behaviour is promised.

## Dependencies

Standard POSIX utilities, plus `git`, `curl`, `unzip`, `tar` with `xz` support, `mktemp`,
`readlink`, and a sha256 tool (`shasum` or `sha256sum`).

## Not promised

Diagnostic text, specific non-zero exit codes, cache directory layout, the receipt file's
implementation, and the hook files' literal contents. Any of these may change in a patch release.
