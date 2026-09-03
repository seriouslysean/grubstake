# Contributing

## Setup

Adopt this repo the way an adopting repo does, once per clone.

```sh
./grubstake.sh install
```

`hooks/` is the reviewable source that `install` copies into `.githooks/`, never this repo's own
hook directory, so nothing under `hooks/` runs here until `install` has been run. The leak scan
hangs off the same extension point every consumer uses, at `.githooks/pre-commit.d/scan-for-leaks`,
and `.githooks/commit-msg` gates the message itself, which a scan of tracked files cannot see.

## The rule that matters

**A fix ships with a test that fails without it.** Not a test that passes afterwards, which proves
nothing: a test you have watched fail on the unfixed code and pass on the fixed code.

This is a regression test in the ordinary sense, with the ordering made explicit: the test fails
before the fix is applied, and passes after.

This exists because three consecutive releases each contained a bug introduced by the previous
release's fix. Every fix had been verified, once, by hand, in a directory that was then deleted. So
nothing re-ran the earlier proofs and each fix was free to break an older one silently.

Run the suite before you push, and again before you tag.

```sh
test/run.sh              # offline, seconds
test/run.sh --network    # also downloads real artifacts
```

The default run is hermetic: no network, no shared state, every test in its own throwaway repo, so
a failure is about the code and not about the day. `--network` is the deliberately non-hermetic
tier, kept separate and run before a release, because a test that reaches the network cannot be
trusted to fail for the reason it names.

## Every change starts as an issue

Open an issue before writing code, even for a one-line fix, so the reason survives longer than the
diff. Record what the wrong behaviour actually was, ideally as the commands that produce it.

Branch from `main` and name the branch after the issue, as in `14-pins-resolve-from-cwd`. Open a
pull request that closes it with `Closes #14`. Merge with a merge commit rather than a squash, so
each commit on `main` stays individually revertable.

## Writing the test

Tests live in `test/run.sh`, grouped by area, and each one is named for the failure it prevents
rather than the function it calls. `pins resolve from the script, not the working directory` says
what breaks if it regresses; `test_pins_file` does not.

Most tests fabricate a cache entry with `fake_install` rather than downloading. That is a fake, not
a stub: a lightweight stand-in that behaves like a published cache entry, so a failure points at
logic rather than at GitHub being slow. Reach for `--network` tests only when the thing under test
is the download itself.

Before you write the fix, write the test and watch it fail. A test written afterwards tends to
assert what the code now does rather than what it should do.

## Nothing published may identify a consumer

This repo is public. The repos that use it are not, and the development model is to edit the engine
from inside one of them, so a comment written in that context can carry a private repo name or an
issue number into a public commit. Prose is the leak, not code.

`test/scan-for-leaks.sh` runs as part of the suite and, once `install` has been run, as a
repo-local gate in `.githooks/pre-commit.d/` and as `.githooks/commit-msg`. It refuses absolute
home paths, email addresses, cross-repo issue references, agent-session trailers, and agent-session
links. It matches shapes that point outside this repo.

**Issues and pull requests are published too, and no hook can gate them.** Before filing, read the
body back and remove anything that is not about this repository: which repo hit the bug, what its
schemes or targets are called, an issue number from somewhere else, a path from your machine.
Describe the failure, not the reporter. An adoption report becomes "an existing four-tool repo",
not its name.

The scan is a handful of hand-written regexes rather than gitleaks or git-secrets. What it refuses
are identifying references, not credentials, so a scanner's rule corpus and entropy scoring match
none of them, and pinning one would put a download in front of the first commit in a fresh clone
for rules this repo would have to author regardless.

## Releasing

1. `test/scan-for-leaks.sh --all` passes. The commit-msg hook reads one message at a time, so
   history as a whole is checked here or not at all.
2. `test/run.sh --network` passes.
3. Bump `GRUBSTAKE_VERSION` in `grubstake.sh`, and the version in the install snippets in
   `README.md` and `ADOPTING.md`.
4. Merge the pull request.
5. Confirm local `main` matches `origin/main`, and that the commit you are about to tag declares
   the version you are about to tag it as. A release was once cut from a stale local `main` and
   published a tag whose script identified as the previous version.
6. Tag `vX.Y.Z`, push the tag, publish a release naming the issues it closes.

Tags are annotated, so `git clone --branch vX.Y.Z` prints `refs/tags/... is not a commit!` and
then checks out the commit the tag points at. That is git dereferencing a tag object and is
expected; the checkout is correct.

Tags matching `v*` are protected against deletion, update, and force-push, so a published tag
cannot move silently. A release that may have been consumed is never corrected in place, and a
mistake there costs a patch version. Deleting and re-cutting through the admin bypass is reserved
for a release known to be unconsumed.

`main` is protected the same way, so a rewrite requires disabling the ruleset first.

## When a fix changes behaviour on upgrade

Say so in the release notes, in terms of what the user has to do. Cache verification landed without
mentioning that existing caches carried no digest, so the first `check` after upgrading refused
every commit until someone ran `ensure`.

## Rulesets

The active rulesets are committed under `.github/rulesets/` as importable JSON. GitHub does not read
that directory, so those files are a record rather than a mechanism, and they exist so the settings
are reviewable here and can be imported into another repository.

## Rules for the code itself

See [AGENTS.md](AGENTS.md).
