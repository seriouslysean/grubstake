# Contributing

## Every change starts as an issue

Open an issue before writing code, even a small one, so the reason for a change survives longer than
the diff that made it. Then branch from `main` and name the branch after the issue, as in `12-fail-
closed-on-bad-pins`.

Open a pull request that closes the issue, using `Closes #12` in the description so the link is
recorded on both sides. Merge with a merge commit rather than a squash, which keeps each commit on
`main` individually revertable.

## Prove the gate before you trust it

A change to a gate is not done until it has been shown to fail on input it should reject. This
repository exists because a version pin can be silently wrong, and a check that never fires looks
exactly like one that passes.

Put the evidence in the pull request. Show the bad input, the failure, and the exit code.

## Releasing

Bump `GRUBSTAKE_VERSION` in `grubstake.sh`, tag the merge commit as `vX.Y.Z`, and publish a release
pointing at the issues it closes.

Tags matching `v*` are protected against deletion, update, and force-push, because a version pin is
only meaningful if the tag it names cannot move. A release cannot be corrected in place, so a
mistake costs a patch version rather than a retag. That is deliberate.

`main` is protected the same way, so a rewrite requires disabling the ruleset first.

## Rulesets

The active rulesets are committed under `.github/rulesets/` as importable JSON. GitHub does not read
that directory, so the files are a record rather than a mechanism, and they exist so the settings
are reviewable in the repository and can be imported into another one.

## Rules for the code itself

See [AGENTS.md](AGENTS.md).
