#!/bin/sh
# Prove the development gates fail on known-bad input, per AGENTS.md 14: a gate that never
# fires looks exactly like one that passes. Runs the Stop and SubagentStop hooks from
# .claude/hooks against a throwaway repo, so no marker or counter touches this one.
#
#   test/gates.sh    offline, seconds

set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/grubstake-gates.XXXXXX")" || {
    printf 'FATAL  no scratch directory under %s\n' "${TMPDIR:-/tmp}" >&2
    exit 2
}
trap 'rm -rf "$ROOT"' EXIT
trap 'rm -rf "$ROOT"; exit 2' HUP INT TERM

R="$ROOT/repo"
mkdir -p "$R/.claude/hooks"
( cd "$R" && git init -q . )
cp "$SRC/grubstake.sh" "$R/"
cp "$SRC/.claude/hooks/gate-lib.sh" "$SRC/.claude/hooks/antagonist-gate.sh" \
   "$SRC/.claude/hooks/antagonist-receipt.sh" "$R/.claude/hooks/"
( cd "$R" && git add -A && git -c user.email=t@t -c user.name=t commit -qm init )

GATE="$R/.claude/hooks/antagonist-gate.sh"
RCPT="$R/.claude/hooks/antagonist-receipt.sh"
MARKER="$R/.git/grubstake-antagonist"
BLOCKS="$R/.git/grubstake-antagonist-blocks"
LOG="$R/.git/grubstake-antagonist-log"

PASS=0
FAIL=0
CURRENT=""

it()   { CURRENT="$1"; }
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n         %s\n' "$CURRENT" "$1"; }

# Feed the Stop hook the payload Claude Code sends it; the transcript path is the only variable.
gate() {
    printf '{"session_id":"s1","transcript_path":"%s","hook_event_name":"Stop"}' "${1:-/nonexistent}" \
        | ( cd "$R" && "$GATE" )
}
receipt() {
    printf '{"session_id":"s1","hook_event_name":"SubagentStop","last_assistant_message":"%s"}' "$1" \
        | ( cd "$R" && "$RCPT" )
}

it "an out-of-scope turn passes untouched"
out=$(gate); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass; else fail "rc=$rc out=$out"; fi

it "a shell change blocks until an antagonist has run"
echo "# poke" >> "$R/grubstake.sh"
out=$(gate)
case "$out" in
    *'"decision":"block"'*gst-shell-critic*) pass ;;
    *) fail "got: $out" ;;
esac

it "the fourth block on the same state passes and records the override"
gate >/dev/null; gate >/dev/null
out=$(gate); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ] && grep -q '^gate-override' "$LOG"; then pass
else fail "rc=$rc out=$out"; fi

it "a completed antagonist pass mints the receipt"
rm -f "$MARKER" "$BLOCKS"
receipt 'Antagonist: gst-shell-critic.\n\nNo findings.' >/dev/null
if [ -f "$MARKER" ]; then pass; else fail "no marker written"; fi

it "the gate passes on a fresh matching receipt"
out=$(gate); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass; else fail "rc=$rc out=$out"; fi

it "a stale receipt does not cover edits made after the pass"
echo "# poke2" >> "$R/grubstake.sh"
out=$(gate)
case "$out" in
    *'"decision":"block"'*) pass ;;
    *) fail "the gate accepted a receipt minted for an earlier state" ;;
esac

it "an empty subagent return is rejected"
out=$(receipt "")
case "$out" in
    *'"decision":"block"'*empty*) pass ;;
    *) fail "got: $out" ;;
esac

it "antagonist output without rule ids is rejected and mints nothing"
rm -f "$MARKER"
out=$(receipt 'Antagonist: gst-shell-critic.\nLooks good to me!')
case "$out" in
    *'"decision":"block"'*)
        if [ ! -f "$MARKER" ]; then pass; else fail "a receipt was minted"; fi ;;
    *) fail "got: $out" ;;
esac

it "an unavailable antagonist records an advisory skip rather than passing silently"
rm -f "$BLOCKS"
( cd "$R" && "$RCPT" --skip "none available" ) >/dev/null
out=$(gate); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ] && grep -q '^advisory-skip' "$LOG"; then pass
else fail "rc=$rc out=$out"; fi

it "publishing an issue demands the leak auditor"
( cd "$R" && git checkout -q grubstake.sh )
rm -f "$MARKER" "$BLOCKS"
T="$ROOT/transcript.jsonl"
printf '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"gh issue create"}}]}}\n' > "$T"
out=$(gate "$T")
case "$out" in
    *'"decision":"block"'*gst-leak-auditor*) pass ;;
    *) fail "got: $out" ;;
esac

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
