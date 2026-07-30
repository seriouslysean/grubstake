#!/bin/sh
# Stop hook: the antagonist gate. Blocks the turn from ending until an adversarial pass has
# run over what the turn touched, per AGENTS.md 26.
#
# Scope is mechanical rather than semantic, because a script cannot judge what a change meant:
# touching grubstake.sh or hooks/ needs gst-shell-critic, a gh issue/pr/release write in the
# transcript needs gst-leak-auditor, and anything else passes untouched.
#
# The receipt is minted only by antagonist-receipt.sh when an antagonist subagent finishes,
# and lives under .git/ so it needs no gitignore entry. After 3 blocks on the same state the
# gate passes and records the override, because a wedged session is worse than a missed review.

set -u

. "$(dirname "$0")/gate-lib.sh"

GITDIR=$(git rev-parse --git-dir 2>/dev/null) || exit 0
MARKER="$GITDIR/grubstake-antagonist"
BLOCKS="$GITDIR/grubstake-antagonist-blocks"
LOG="$GITDIR/grubstake-antagonist-log"
LIMIT=3

INPUT=$(cat)
session=$(printf '%s' "$INPUT" | json_field session_id)
transcript=$(printf '%s' "$INPUT" | json_field transcript_path)

need=""
if changed_paths | grep -qE '(^|-> )(grubstake\.sh$|hooks/)'; then
    need="gst-shell-critic over the shell changes"
fi
if [ -n "$transcript" ] && [ -f "$transcript" ] \
    && grep -qE '"command"[^{}]*gh (issue|pr|release) (create|comment|edit)' "$transcript" 2>/dev/null; then
    need="${need:+$need, and }gst-leak-auditor over the published prose"
fi
[ -z "$need" ] && exit 0

digest=$(changed_digest)

if [ -f "$MARKER" ]; then
    m_status=$(sed -n 1p "$MARKER"); m_session=$(sed -n 2p "$MARKER"); m_digest=$(sed -n 3p "$MARKER")
    if [ "$m_digest" = "$digest" ]; then
        case "$m_status" in
            pass)
                # Accept an unknown session on either side; the digest is the freshness proof.
                if [ "$m_session" = "$session" ] || [ "$m_session" = "-" ] || [ -z "$session" ]; then
                    exit 0
                fi ;;
            skip)
                printf 'advisory-skip %s %s %s\n' "$(date +%s)" "$digest" "$(sed -n 4p "$MARKER")" >> "$LOG"
                exit 0 ;;
        esac
    fi
fi

b_session=""; b_digest=""; b_count=0
[ -f "$BLOCKS" ] && read -r b_session b_digest b_count < "$BLOCKS" 2>/dev/null
case "$b_count" in ''|*[!0-9]*) b_count=0 ;; esac
count=1
[ "$b_session" = "$session" ] && [ "$b_digest" = "$digest" ] && count=$((b_count + 1))
printf '%s %s %s\n' "$session" "$digest" "$count" > "$BLOCKS"

if [ "$count" -gt "$LIMIT" ]; then
    printf 'gate-override %s %s %s after-%s-blocks\n' "$(date +%s)" "$session" "$digest" "$LIMIT" >> "$LOG"
    exit 0
fi

printf '{"decision":"block","reason":"Antagonist gate (%s/%s): dispatch %s and let it finish; its completion mints the receipt. If no antagonist can run, record that instead: sh .claude/hooks/antagonist-receipt.sh --skip <reason>."}\n' \
    "$count" "$LIMIT" "$need"
exit 0
