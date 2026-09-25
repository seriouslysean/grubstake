#!/bin/sh
# PostToolUse hook on SubagentHandback, and the only writer of the antagonist receipt.
# SubagentStop's last_assistant_message is the subagent's closing text, not its report -- the
# report is the SubagentHandback call's own tool_input.message, which is what this reads. An
# antagonist names itself on its first line there, so the receipt can only come from a completed
# pass rather than from prose claiming one happened. Also enforces output discipline: no empty
# returns, and finding-producing agents return their rule ids or the exact string "No findings.".
#
#   antagonist-receipt.sh --skip "reason"
#
# records an advisory skip for the current state instead, because an unavailable antagonist
# must be recorded rather than silently waved through.

set -u

. "$(dirname "$0")/gate-lib.sh"

# --absolute-git-dir, not --git-dir: git -C prints the latter relative to the -C target, which is wrong once cwd differs from it.
GITDIR=$(git_run rev-parse --absolute-git-dir 2>/dev/null) || exit 0
MARKER="$GITDIR/grubstake-antagonist"
BLOCKS="$GITDIR/grubstake-antagonist-blocks"
LOG="$GITDIR/grubstake-antagonist-log"

if [ "${1:-}" = "--skip" ]; then
    reason="${2:-unspecified}"
    tmp="$MARKER.$$.tmp"
    # rm only reaches here on a failed write or failed mv; a successful mv already made $tmp disappear.
    # shellcheck disable=SC2015
    printf 'skip\n-\n%s\n%s\n' "$(changed_digest)" "$reason" >"$tmp" && mv -f "$tmp" "$MARKER" || rm -f "$tmp"
    printf 'skip-recorded %s %s\n' "$(date +%s)" "$reason" >>"$LOG"
    echo "advisory skip recorded for the current change footprint"
    exit 0
fi

INPUT=$(cat)

block() {
    printf '{"decision":"block","reason":"%s"}\n' "$1"
    exit 0
}

# tool_response carries its own "message" key ("Report delivered..."), so a bare "message" search
# would always be true; anchoring past tool_input's opening brace is what tells the two apart.
TOOL_MSG='"tool_input"[[:space:]]*:[[:space:]]*{[[:space:]]*"message"[[:space:]]*:[[:space:]]*"'
tool_msg() { printf '%s' "$INPUT" | sed -n "s/.*$TOOL_MSG\\([^\"]*\\).*/\\1/p"; }
MSG="$(tool_msg)"

msg_has() {
    case "$MSG" in
        *"$1"*) return 0 ;;
    esac
    return 1
}

# An empty return is not a completed dispatch, whatever the agent was; this also catches a
# malformed payload carrying no tool_input.message at all, which reads the same as empty.
[ -z "$MSG" ] && block "Return the work product: the result was empty."

# The orchestrator deduplicates on rule ids, so output without them cannot be merged. A finding
# line is "[SEVERITY] rule-id -- ..."; "] id-" anchors on that bracket, since the bare id is also
# a loose substring of the header itself (e.g. "gst-leak-auditor." contains "leak-").
check() { msg_has "] $2" || msg_has "No findings." || block "$1 must return findings carrying its rule ids, or exactly: No findings."; }

# The header must open the message: a name only present mid-prose is a mention, not a completed
# pass. The trailing \n is the literal two-byte JSON escape for a newline, not a real one.
first_line_header() {
    case "$MSG" in
        "Antagonist: $1." | "Antagonist: $1."\\n*) return 0 ;;
    esac
    return 1
}

agent_type=$(printf '%s' "$INPUT" | json_field agent_type)

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
if [ "$agent_type" = gst-shell-critic ] && first_line_header gst-shell-critic; then
    check gst-shell-critic "critic-"
    mint=1
    add_kind "$(reviewer_kind gst-shell-critic)"
fi
if [ "$agent_type" = gst-leak-auditor ] && first_line_header gst-leak-auditor; then
    check gst-leak-auditor "leak-"
    mint=1
    add_kind "$(reviewer_kind gst-leak-auditor)"
fi
if [ "$agent_type" = gst-shell-reviewer ] && msg_has "Reviewer: gst-shell-reviewer."; then check gst-shell-reviewer "shell-"; fi

if [ "$mint" -eq 1 ]; then
    session=$(printf '%s' "$INPUT" | json_field session_id)
    # Still read-modify-write across two receipts racing the same digest: accepted, since a later receipt unions the kinds and the gate's block-limit override prevents a wedge.
    tmp="$MARKER.$$.tmp"
    # rm only reaches here on a failed write or failed mv; a successful mv already made $tmp disappear.
    # shellcheck disable=SC2015
    printf 'pass\n%s\n%s\n%s\n' "${session:--}" "$digest" "$kinds" >"$tmp" && mv -f "$tmp" "$MARKER" || rm -f "$tmp"
    rm -f "$BLOCKS"
fi
exit 0
