<!-- Pull requests are published too, and no hook can gate this body. Nothing here may name a
consuming repository, a person, a machine, a scheme, a target, or an issue number from somewhere
else. Redact paths before pasting output. -->

## Closes

Closes #

<!-- Every change starts as an issue, so this line is not optional.

The closing keyword registers only from this body or from a commit message, never from the pull
request title. Each issue needs its own keyword: `Closes #<first>, closes #<second>` closes both,
while `Closes #<first>, #<second>` closes only the first and silently leaves the second open. -->

## What was wrong

<!-- The behaviour that was wrong, ideally as the commands that produced it, so the reason survives
longer than the diff. -->

## The test that fails without this

<!-- A fix ships with a test that fails without it. Not a test that passes afterwards, which proves
nothing: a test you have watched fail on the unfixed code and pass on the fixed code.

Name the test, and say how you watched it fail: what you reverted to unfix the code, and what it
printed when you did. -->

- [ ] I watched this test fail on the unfixed code and pass on the fixed code.
- [ ] `test/run.sh` passes.
