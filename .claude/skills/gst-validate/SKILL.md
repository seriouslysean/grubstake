---
name: gst-validate
description: "Run the adversarial validation panel over shell changes and anything about to be published: gst-shell-reviewer, then gst-shell-critic on its findings, plus the suite. Use before reporting work done, opening a pull request, or filing an issue."
argument-hint: "[<path> | prose | (default: working tree changes)]"
allowed-tools: Read, Grep, Glob, Bash, Agent
---

# Validate

The panel behind the antagonist gate. A completed critic or auditor pass mints the receipt the Stop hook in `.claude/settings.json` waits for, and that receipt proves only that an antagonist of that kind finished while this checkout's change footprint had that digest. It records neither the scope the dispatch named nor changes in other worktrees (#191), so a green receipt is not proof of what was reviewed: the pull request body records each reviewer's actual outcome and the ref and scope it reviewed. `antagonist-receipt.sh --skip <reason>` records that no pass ran for the current footprint and why; it never represents a review that ran.

## 1. Resolve scope

- No argument: every changed path in the working tree, plus commits the upstream has not seen.
- `<path>`: that file or directory.
- `prose`: skip the shell panel and run only step 4 over the issue, pull request, release, or commit text about to be published.

## 2. Run the suite first

```sh
test/run.sh
```

A red suite blocks the panel: fix the regression before spending review on it. The suite proves past failures stay fixed; the panel covers what it cannot.

## 3. Shell panel

Dispatch in order, since the critic optionally takes the reviewer's output as its second-pass input:

1. `gst-shell-reviewer` with the scope and changed paths.
2. `gst-shell-critic` with the same scope and the reviewer's findings.

Deduplicate findings on rule id. Present survivors as `[SEVERITY] rule-id — sentence, citation`, worst first, and say which reviewer findings the critic killed and why. One pass per change. It is done when the change's acceptance criteria and required checks hold and each material in-scope objection is fixed or answered with a citation. An objection is material when it shows a causal path or trust-boundary exposure to a failure in supported use; it needs no past incident. A credible bug outside the change is logged, reusing an existing issue, not fixed here; an accepted limitation is recorded once in the pull request body; speculation is rejected, not filed. A fixup gets a focused critic pass over the correction and the behavior it affects, which mints the receipt for the fixed state.

## 4. Published prose

When the turn writes an issue, pull request, release, or commit message, dispatch `gst-leak-auditor` with the exact text about to be published. Its findings block publication until a human clears them, because it is the only gate on bodies that `test/scan-for-leaks.sh` cannot read.

## 5. Report

Suite result verbatim, surviving findings by rule id, what was escalated to the user, and the review record for the pull request body: each reviewer, its outcome, and the ref and scope it reviewed. Nothing else.
