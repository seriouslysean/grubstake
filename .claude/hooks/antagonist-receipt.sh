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
    tmp="$MARKER.$$.tmp"
    printf 'skip\n-\n%s\n%s\n' "$(changed_digest)" "$reason" > "$tmp" && mv -f "$tmp" "$MARKER" || rm -f "$tmp"
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

digest=$(changed_digest)

# Read once: a writer interleaving between separate reads of digest and kinds could relabel a stale kind under the current digest.
marker=""
[ -f "$MARKER" ] && marker=$(cat "$MARKER")

# Kinds accumulate across receipts for the same digest, so a fresh mint does not erase what an earlier receipt already proved.
kinds=""
if [ "$(printf '%s\n' "$marker" | sed -n 1p)" = pass ] \
    && [ "$(printf '%s\n' "$marker" | sed -n 3p)" = "$digest" ]; then
    kinds=$(printf '%s\n' "$marker" | sed -n 4p)
fi
add_kind() {
    case " $kinds " in
        *" $1 "*) ;;
        *) kinds="${kinds:+$kinds }$1" ;;
    esac
}

mint=0
if msg_has "Antagonist: gst-shell-critic."; then check gst-shell-critic "critic-"; mint=1; add_kind "$(reviewer_kind gst-shell-critic)"; fi
if msg_has "Antagonist: gst-leak-auditor."; then check gst-leak-auditor "leak-"; mint=1; add_kind "$(reviewer_kind gst-leak-auditor)"; fi
if msg_has "Reviewer: gst-shell-reviewer."; then check gst-shell-reviewer "shell-"; fi

if [ "$mint" -eq 1 ]; then
    session=$(printf '%s' "$INPUT" | json_field session_id)
    # Still read-modify-write across two receipts racing the same digest: accepted, since a later receipt unions the kinds and the gate's block-limit override prevents a wedge.
    tmp="$MARKER.$$.tmp"
    printf 'pass\n%s\n%s\n%s\n' "${session:--}" "$digest" "$kinds" > "$tmp" && mv -f "$tmp" "$MARKER" || rm -f "$tmp"
    rm -f "$BLOCKS"
fi
exit 0
