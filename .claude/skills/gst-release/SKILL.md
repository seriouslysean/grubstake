---
name: gst-release
description: "Cut a release by running CONTRIBUTING's procedure as commands with shown output: preflight sync, network suite, three-file version bump, notes with the upgrade-behaviour question answered, leak audit, annotated tag, and post-release proof."
argument-hint: "<X.Y.Z>"
disable-model-invocation: true
allowed-tools: Read, Grep, Glob, Bash, Agent
---

# Release

Runs the release procedure as checks rather than recall. Every step shows its output, and a failed step stops the release. Tags are protected and cannot be corrected in place, so each gate here is cheaper than the patch version a mistake costs.

## 1. Preflight

```sh
git checkout main && git fetch origin
git status --porcelain
git rev-parse main origin/main
```

A dirty tree or diverged SHAs stops here. A release was once cut from a stale local `main`, so this step runs before anything else and again after the merge.

## 2. Prove the candidate locally

```sh
test/run.sh --network
```

Paste the result verbatim. Red stops the release. This is the cheap early signal; it proves the
working tree, not the commit that gets tagged, which cannot exist yet because the bump has not
happened. The run that gates the tag is step 6, after the merge.

## 3. Bump

Raise the version in all three places: `GRUBSTAKE_VERSION` in `grubstake.sh`, and the install snippets in `README.md` and `ADOPTING.md`. Then prove they agree:

```sh
grep -n 'GRUBSTAKE_VERSION="\|grubstake/v' grubstake.sh README.md ADOPTING.md
```

All three must declare the target, because `fetch_release` skips a tag whose bytes disagree with its name, and the mismatched release becomes a silent dud that cost a version number.

## 4. Land it

The bump goes through the normal cycle: issue, branch named after it, pull request, merge commit. Nothing about a release skips review.

## 5. Re-verify after the merge

Repeat step 1, then confirm the commit about to be tagged declares the version about to be tagged:

```sh
grep '^GRUBSTAKE_VERSION=' grubstake.sh
git rev-parse HEAD
```

Keep that SHA. It is the one thing the next step has to match, and the only commit this release is
allowed to tag.

## 6. Gate the tag on the commit being tagged

The network tier runs on tags too, but that run reports after publication and cannot stop anything.
This one can, because it happens first and names its own commit:

```sh
gh workflow run network.yml --ref main
gh run list --workflow=network.yml --event=workflow_dispatch --limit 1 --json databaseId,headSha,status,url
gh run watch <databaseId> --exit-status
gh run view <databaseId> --json headSha,conclusion
```

Filter by event and read the run's own id: a bare `--limit 1` can hand back a previous release's
tag-triggered run while the dispatch is still registering, and a green row for the wrong run is the
same failure this step exists to prevent.

Two things stop the release here: a conclusion that is not `success`, and a `headSha` that is not
the SHA from step 5. If `main` moved while this ran, the release is against a different commit than
the one proven, and the fix is to start again from step 5 rather than to tag anyway.

## 7. Notes

Draft the notes naming the issues the release closes. Answer explicitly, never skip: does any fix change behaviour on upgrade, and what must the user do? A verification change once shipped without that sentence and refused every commit until users ran `ensure`. Dispatch `gst-leak-auditor` with the full text, then show the notes for approval before publishing.

## 8. Tag and publish

Confirm before each command, since both are irreversible.

Tag the SHA from step 5 by name, not whatever `HEAD` happens to be now: notes approval is a
wall-clock gap, and an unpinned tag would quietly point somewhere the gate never proved.

```sh
git rev-parse HEAD
git tag -a "vX.Y.Z" -m "vX.Y.Z" <the SHA from step 5>
git push origin "vX.Y.Z"
gh release create "vX.Y.Z" --title "vX.Y.Z" --notes "<approved notes>"
```

If `HEAD` no longer matches that SHA, something landed during approval and the release is against a
commit the gate never saw: go back to step 5.

## 9. Prove the release is discoverable

```sh
git ls-remote --tags origin "vX.Y.Z"
curl -fsSL "https://raw.githubusercontent.com/seriouslysean/grubstake/vX.Y.Z/grubstake.sh" | grep '^GRUBSTAKE_VERSION='
```

The second command is the assertion the update path makes when consumers discover releases; passing it here means the release is reachable, not just tagged.

## 10. Report

The tag, the release URL, and the verbatim output of steps 6 and 9: the commit the gate
proved, and the proof that the tag serves it. Nothing else.
