#!/bin/sh
# SubagentStop hook, and the only writer of the antagonist receipt. An antagonist names
# itself on its first line, so the receipt can only come from a completed pass rather than
# from prose claiming one happened. Also enforces output discipline: no empty returns, and
# finding-producing agents return their rule ids or the exact string "No findings.".
#
#   antagonist-receipt.sh --skip "reason"
#
# records an advisory skip for the current state instead, because an unavailable antagonist
# must be recorded rather than silently waved through.

set -u

. "$(dirname "$0")/gate-lib.sh"

GITDIR=$(git rev-parse --git-dir 2>/dev/null) || exit 0
MARKER="$GITDIR/grubstake-antagonist"
BLOCKS="$GITDIR/grubstake-antagonist-blocks"
LOG="$GITDIR/grubstake-antagonist-log"

if [ "${1:-}" = "--skip" ]; then
    reason="${2:-unspecified}"
    printf 'skip\n-\n%s\n%s\n' "$(changed_digest)" "$reason" > "$MARKER"
    printf 'skip-recorded %s %s\n' "$(date +%s)" "$reason" >> "$LOG"
    echo "advisory skip recorded for the current change footprint"
    exit 0
fi

INPUT=$(cat)

block() { printf '{"decision":"block","reason":"%s"}\n' "$1"; exit 0; }
msg_has() { printf '%s' "$INPUT" | grep -qF "$1"; }

# An empty return is not a completed dispatch, whatever the agent was.
if ! msg_has '"last_assistant_message"' \
    || printf '%s' "$INPUT" | grep -qE '"last_assistant_message"[[:space:]]*:[[:space:]]*""'; then
    block "Return the work product: the result was empty."
fi

# The orchestrator deduplicates on rule ids, so output without them cannot be merged.
check() { msg_has "$2" || msg_has "No findings." || block "$1 must return findings carrying its rule ids, or exactly: No findings."; }

mint=0
if msg_has "Antagonist: gst-shell-critic."; then check gst-shell-critic "critic-"; mint=1; fi
if msg_has "Antagonist: gst-leak-auditor."; then check gst-leak-auditor "leak-"; mint=1; fi
if msg_has "Reviewer: gst-shell-reviewer."; then check gst-shell-reviewer "shell-"; fi

if [ "$mint" -eq 1 ]; then
    session=$(printf '%s' "$INPUT" | json_field session_id)
    printf 'pass\n%s\n%s\n' "${session:--}" "$(changed_digest)" > "$MARKER"
    rm -f "$BLOCKS"
fi
exit 0
