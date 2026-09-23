#!/bin/sh
# Prove the development gates fail on known-bad input, per AGENTS.md 14: a gate that never
# fires looks exactly like one that passes. Runs the Stop hook and the PostToolUse receipt from
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
(cd "$R" && git init -q .)
cp "$SRC/grubstake.sh" "$R/"
cp "$SRC/.claude/hooks/gate-lib.sh" "$SRC/.claude/hooks/antagonist-gate.sh" \
    "$SRC/.claude/hooks/antagonist-receipt.sh" "$R/.claude/hooks/"
(cd "$R" && git add -A && git -c user.email=t@t -c user.name=t commit -qm init)

GATE="$R/.claude/hooks/antagonist-gate.sh"
RCPT="$R/.claude/hooks/antagonist-receipt.sh"
MARKER="$R/.git/grubstake-antagonist"
BLOCKS="$R/.git/grubstake-antagonist-blocks"
LOG="$R/.git/grubstake-antagonist-log"

PASS=0
FAIL=0
CURRENT=""

it() { CURRENT="$1"; }
pass() {
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$CURRENT"
}
fail() {
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n         %s\n' "$CURRENT" "$1"
}

# Feed the Stop hook the payload Claude Code sends it; the transcript path is the only variable.
gate() {
    printf '{"session_id":"s1","transcript_path":"%s","hook_event_name":"Stop"}' "${1:-/nonexistent}" \
        | (cd "$R" && "$GATE")
}
# SubagentStop's last_assistant_message is closing text, not the report; the report is the
# SubagentHandback tool call's own tool_input.message, read here via PostToolUse's payload shape.
receipt() {
    printf '{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"SubagentHandback","agent_type":"%s","tool_input":{"message":"%s"},"tool_response":{"success":true,"message":"Report delivered to your caller."}}' "$1" "$2" \
        | (cd "$R" && "$RCPT")
}

it "an out-of-scope turn passes untouched"
out=$(gate)
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass; else fail "rc=$rc out=$out"; fi

it "a shell change blocks until an antagonist has run"
echo "# poke" >>"$R/grubstake.sh"
out=$(gate)
case "$out" in
    *'"decision":"block"'*gst-shell-critic*) pass ;;
    *) fail "got: $out" ;;
esac

it "the fourth block on the same state passes and records the override"
# Self-contained: reset the block count and the log rather than relying on state a preceding test
# leaves behind, so inserting or reordering a test here cannot silently miscount to a wrong total,
# or pass because an earlier test already wrote a gate-override line this one never earned.
rm -f "$BLOCKS" "$LOG"
gate >/dev/null
gate >/dev/null
gate >/dev/null
out=$(gate)
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ] && grep -q '^gate-override' "$LOG"; then
    pass
else fail "rc=$rc out=$out"; fi

it "a completed antagonist pass mints the receipt"
rm -f "$MARKER" "$BLOCKS"
receipt gst-shell-critic 'Antagonist: gst-shell-critic.\n\nNo findings.' >/dev/null
# pass and skip are not equivalent: skip bypasses the gate's session check, so a genuine mint
# mislabeled skip is strictly more permissive than a correct pass and must not read as ok here.
if [ -f "$MARKER" ] && [ "$(sed -n 1p "$MARKER")" = pass ]; then
    pass
else fail "marker missing or not labeled pass: $(cat "$MARKER" 2>/dev/null)"; fi

it "the gate passes on a fresh matching receipt"
out=$(gate)
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass; else fail "rc=$rc out=$out"; fi

it "a stale receipt does not cover edits made after the pass"
echo "# poke2" >>"$R/grubstake.sh"
out=$(gate)
case "$out" in
    *'"decision":"block"'*) pass ;;
    *) fail "the gate accepted a receipt minted for an earlier state" ;;
esac

it "an empty subagent return is rejected"
out=$(receipt "" "")
case "$out" in
    *'"decision":"block"'*empty*) pass ;;
    *) fail "got: $out" ;;
esac

it "antagonist output without rule ids is rejected and mints nothing"
rm -f "$MARKER"
out=$(receipt gst-shell-critic 'Antagonist: gst-shell-critic.\nLooks good to me!')
case "$out" in
    *'"decision":"block"'*)
        if [ ! -f "$MARKER" ]; then pass; else fail "a receipt was minted"; fi
        ;;
    *) fail "got: $out" ;;
esac

it "an unavailable antagonist records an advisory skip rather than passing silently"
rm -f "$BLOCKS"
(cd "$R" && "$RCPT" --skip "none available") >/dev/null
out=$(gate)
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ] && grep -q '^advisory-skip' "$LOG"; then
    pass
else fail "rc=$rc out=$out"; fi

it "publishing an issue demands the leak auditor"
(cd "$R" && git checkout -q grubstake.sh)
rm -f "$MARKER" "$BLOCKS"
T="$ROOT/transcript.jsonl"
printf '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"gh issue create"}}]}}\n' >"$T"
out=$(gate "$T")
case "$out" in
    *'"decision":"block"'*gst-leak-auditor*) pass ;;
    *) fail "got: $out" ;;
esac

it "a shell-critic receipt does not satisfy a leak-auditor requirement"
# F13/#137: the marker carried no reviewer kind, so any receipt on a matching digest and session cleared the gate whatever it had actually reviewed.
rm -f "$MARKER" "$BLOCKS"
receipt gst-shell-critic 'Antagonist: gst-shell-critic.\n\nNo findings.' >/dev/null
out=$(gate "$T")
case "$out" in
    *'"decision":"block"'*gst-leak-auditor*) pass ;;
    *) fail "a shell-critic receipt satisfied a requirement only gst-leak-auditor can cover: $out" ;;
esac

it "shell-critic and leak-auditor receipts on the same state together satisfy both requirements"
rm -f "$MARKER" "$BLOCKS"
echo "# poke3" >>"$R/grubstake.sh"
out1=$(gate "$T")
receipt gst-shell-critic 'Antagonist: gst-shell-critic.\n\nNo findings.' >/dev/null
out2=$(gate "$T")
receipt gst-leak-auditor 'Antagonist: gst-leak-auditor.\n\nNo findings.' >/dev/null
out3=$(gate "$T")
rc3=$?
if printf '%s' "$out1" | grep -q '"decision":"block"' \
    && printf '%s' "$out2" | grep -q '"decision":"block"' \
    && [ "$rc3" -eq 0 ] && [ -z "$out3" ]; then
    pass
else
    fail "out1=$out1 out2=$out2 rc3=$rc3 out3=$out3"
fi

it "a receipt whose agent_type does not match its own header mints nothing"
# #152: the header text alone used to be enough; a subagent could name any antagonist it liked.
rm -f "$MARKER" "$BLOCKS"
out=$(receipt gst-shell-critic 'Antagonist: gst-leak-auditor.\n\nNo findings.')
if [ ! -f "$MARKER" ]; then pass; else fail "agent_type/header mismatch minted anyway: $(cat "$MARKER")"; fi

it "a header buried past the first line mints nothing"
rm -f "$MARKER" "$BLOCKS"
out=$(receipt gst-shell-critic 'No findings.\n\nAntagonist: gst-shell-critic.')
if [ ! -f "$MARKER" ]; then pass; else fail "a non-leading header minted anyway: $(cat "$MARKER")"; fi

it "a first-line header with nothing else still reaches the output-discipline check rather than passing silently"
# The header alone can never satisfy check()'s rule-id requirement; this proves check() actually runs for it rather than first_line_header silently skipping the whole block.
rm -f "$MARKER" "$BLOCKS"
out=$(receipt gst-shell-critic 'Antagonist: gst-shell-critic.')
case "$out" in
    *'"decision":"block"'*'must return findings'*) pass ;;
    *) fail "a bare first-line header did not reach the output-discipline check: out=$out" ;;
esac

it "stop_hook_active true exits quietly instead of re-blocking, and logs the pass"
rm -f "$MARKER" "$BLOCKS" "$LOG"
echo "# pokeStop" >>"$R/grubstake.sh"
out=$(printf '{"session_id":"s1","transcript_path":"/nonexistent","hook_event_name":"Stop","stop_hook_active":true}' \
    | (cd "$R" && "$GATE"))
rc=$?
(cd "$R" && git checkout -q grubstake.sh)
if [ "$rc" -eq 0 ] && [ -z "$out" ] && grep -q '^stop-hook-active-pass' "$LOG"; then
    pass
else fail "rc=$rc out=$out log=$(cat "$LOG" 2>/dev/null)"; fi

it "an empty session_id does not desynchronize the block counter's fields"
rm -f "$MARKER" "$BLOCKS" "$LOG"
echo "# pokeEmptySession" >>"$R/grubstake.sh"
i=0
while [ "$i" -lt 4 ]; do
    out=$(printf '{"session_id":"","transcript_path":"/nonexistent","hook_event_name":"Stop"}' | (cd "$R" && "$GATE") )
    rc=$?
    i=$((i + 1))
done
(cd "$R" && git checkout -q grubstake.sh)
if [ "$rc" -eq 0 ] && [ -z "$out" ] && grep -q '^gate-override' "$LOG"; then
    pass
else fail "rc=$rc out=$out blocks=$(cat "$BLOCKS" 2>/dev/null)"; fi

it "CLAUDE_PROJECT_DIR lets the gate see a shell change from an unrelated cwd"
rm -f "$MARKER" "$BLOCKS"
echo "# pokeProjectDir" >>"$R/grubstake.sh"
out=$(printf '{"session_id":"s1","transcript_path":"/nonexistent","hook_event_name":"Stop"}' \
    | (cd "$ROOT" && CLAUDE_PROJECT_DIR="$R" "$GATE"))
(cd "$R" && git checkout -q grubstake.sh)
case "$out" in
    *'"decision":"block"'*gst-shell-critic*) pass ;;
    *) fail "got: $out" ;;
esac

it "the untracked-file digest resolves against CLAUDE_PROJECT_DIR, not an unrelated cwd"
(cd "$R" && git checkout -q . && git clean -fdq)
GLIB="$R/.claude/hooks/gate-lib.sh"
PROBE="$ROOT/digest-probe.sh"
printf '. "%s"\nchanged_digest\n' "$GLIB" >"$PROBE"
printf 'one\n' >"$R/untracked-probe.txt"
d1=$(cd "$ROOT" && CLAUDE_PROJECT_DIR="$R" sh "$PROBE")
printf 'two\n' >"$R/untracked-probe.txt"
d2=$(cd "$ROOT" && CLAUDE_PROJECT_DIR="$R" sh "$PROBE")
rm -f "$R/untracked-probe.txt"
if [ -n "$d1" ] && [ "$d1" != "$d2" ]; then pass; else fail "d1=$d1 d2=$d2"; fi

it "the merge-base fallback sees a committed shell change when the branch has no upstream"
# #152: @{u} has nothing to resolve on a fresh branch, so a committed-but-unpushed shell change was invisible to the scope check.
F="$ROOT/fallback-repo"
mkdir -p "$F/.claude/hooks"
(cd "$F" && git init -q .)
cp "$SRC/grubstake.sh" "$F/"
cp "$SRC/.claude/hooks/gate-lib.sh" "$SRC/.claude/hooks/antagonist-gate.sh" \
    "$SRC/.claude/hooks/antagonist-receipt.sh" "$F/.claude/hooks/"
(cd "$F" && git add -A && git -c user.email=t@t -c user.name=t commit -qm init)
(cd "$F" && git update-ref refs/remotes/origin/main HEAD)
(cd "$F" && git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main)
(cd "$F" && git checkout -q -b feature)
echo "# fallback poke" >>"$F/grubstake.sh"
(cd "$F" && git add -A && git -c user.email=t@t -c user.name=t commit -qm "shell change")
out=$(printf '{"session_id":"s1","transcript_path":"/nonexistent","hook_event_name":"Stop"}' \
    | (cd "$F" && "$F/.claude/hooks/antagonist-gate.sh"))
case "$out" in
    *'"decision":"block"'*gst-shell-critic*) pass ;;
    *) fail "got: $out" ;;
esac

it "a change under .claude/hooks/ requires the shell critic too"
rm -f "$MARKER" "$BLOCKS"
echo "# pokeDotClaude" >>"$R/.claude/hooks/gate-lib.sh"
out=$(gate)
(cd "$R" && git checkout -q .claude/hooks/gate-lib.sh)
case "$out" in
    *'"decision":"block"'*gst-shell-critic*) pass ;;
    *) fail "got: $out" ;;
esac

it "a change under .githooks/ requires the shell critic too"
rm -f "$MARKER" "$BLOCKS"
mkdir -p "$R/.githooks"
printf '#!/bin/sh\n' >"$R/.githooks/pre-commit"
out=$(gate)
rm -rf "$R/.githooks"
case "$out" in
    *'"decision":"block"'*gst-shell-critic*) pass ;;
    *) fail "got: $out" ;;
esac

it "a change under test/ ending in .sh requires the shell critic too"
# A brand-new directory's first file is collapsed to just the directory name by plain git status; stage it so the individual path is what the scope check sees.
rm -f "$MARKER" "$BLOCKS"
mkdir -p "$R/test"
printf '#!/bin/sh\n' >"$R/test/newcheck.sh"
(cd "$R" && git add test/newcheck.sh)
out=$(gate)
(cd "$R" && git reset -q -- test/newcheck.sh)
rm -rf "$R/test"
case "$out" in
    *'"decision":"block"'*gst-shell-critic*) pass ;;
    *) fail "got: $out" ;;
esac

it "a shell path needing quoting still trips the scope check"
# A path git must quote (a literal space) breaks an anchor that expects the raw path at column 0.
rm -f "$MARKER" "$BLOCKS"
mkdir -p "$R/hooks"
printf 'x\n' >"$R/hooks/new hook.sh"
(cd "$R" && git add "hooks/new hook.sh")
out=$(gate)
(cd "$R" && git reset -q -- "hooks/new hook.sh")
rm -rf "$R/hooks"
case "$out" in
    *'"decision":"block"'*gst-shell-critic*) pass ;;
    *) fail "got: $out" ;;
esac

it "an unrelated path with a space in its name still passes untouched"
rm -f "$MARKER" "$BLOCKS"
mkdir -p "$R/docs"
printf 'x\n' >"$R/docs/release notes.md"
out=$(gate)
rc=$?
rm -rf "$R/docs"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass; else fail "rc=$rc out=$out"; fi

it "settings.json wires the receipt to PostToolUse on SubagentHandback, not SubagentStop"
# The receipt reads tool_input.message, which only PostToolUse on the handback call carries;
# SubagentStop's payload has no tool_input, so wiring it there would block every subagent stop.
SETTINGS="$SRC/.claude/settings.json"
if grep -q '"SubagentStop"' "$SETTINGS"; then
    fail "settings.json still wires SubagentStop, which the receipt no longer reads"
elif ! grep -q '"PostToolUse"' "$SETTINGS"; then
    fail "settings.json does not wire PostToolUse"
elif ! grep -q '"SubagentHandback"' "$SETTINGS"; then
    fail "settings.json's PostToolUse entry does not match SubagentHandback"
elif ! grep -q 'antagonist-receipt.sh' "$SETTINGS"; then
    fail "settings.json does not run antagonist-receipt.sh"
else
    pass
fi

it "settings.json is valid JSON"
if command -v python3 >/dev/null 2>&1; then
    if python3 -m json.tool <"$SRC/.claude/settings.json" >/dev/null 2>&1; then
        pass
    else
        fail "settings.json failed to parse"
    fi
else
    pass
fi

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
