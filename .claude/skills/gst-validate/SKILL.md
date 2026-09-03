---
name: gst-validate
description: "Run the adversarial validation panel over shell changes and anything about to be published: gst-shell-reviewer, then gst-shell-critic on its findings, plus the suite. Use before reporting work done, opening a pull request, or filing an issue."
argument-hint: "[<path> | prose | (default: working tree changes)]"
allowed-tools: Read, Grep, Glob, Bash, Agent
---

# Validate

The panel behind the antagonist gate. Completing the critic or auditor pass mints the receipt the Stop hook in `.claude/settings.json` waits for.

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

Deduplicate findings on rule id. Present survivors as `[SEVERITY] rule-id — sentence, citation`, worst first, and say which reviewer findings the critic killed and why. `No findings.` from both ends the panel.

## 4. Published prose

When the turn writes an issue, pull request, release, or commit message, dispatch `gst-leak-auditor` with the exact text about to be published. Its findings block publication until a human clears them, because it is the only gate on bodies that `test/scan-for-leaks.sh` cannot read.

## 5. Report

Suite result verbatim, surviving findings by rule id, and what was escalated to the user. Nothing else.
