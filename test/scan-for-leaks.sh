#!/bin/sh
# Refuse to publish anything that identifies a consuming repo, a person, or a machine.
#
# This repo is public and the repos that use it are not. The leak is prose, not code: the engine
# gets edited from inside a consumer, so a comment written in that context can carry a private
# repo name or an issue number into a public commit.
#
# It matches shapes: paths, addresses, and references that point outside this repo.
#
# A bare owner/repo mention with no issue number is beyond this scanner: the pattern that would
# catch it matches every path fragment in the tree, and a deny-list tracked here would itself
# carry the names it protects. The semantic audit gates that shape in published bodies; in
# tracked files it has no mechanical gate at all and rests on review of the diff.
#
# The message tier drops comment lines because git's default cleanup does. Under
# --cleanup=verbatim they survive into the published message, and this scan will have missed them.
#
#   test/scan-for-leaks.sh                  scan tracked files
#   test/scan-for-leaks.sh --all            also scan every commit message in history
#   test/scan-for-leaks.sh --message FILE   scan one commit message, for the commit-msg hook

set -u

# Resolved before the cd below, because a hook is handed a path relative to wherever git ran it.
MSG=""
if [ "${1:-}" = "--message" ]; then
    [ "$#" -eq 2 ] || { printf 'usage: scan-for-leaks.sh --message <file>\n' >&2; exit 2; }
    case "$2" in /*) MSG="$2" ;; *) MSG="$PWD/$2" ;; esac
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
FOUND=0

# One list, and every tier reads it. Keeping a second copy for commit messages is how that tier
# came to miss both agent-session shapes, which are the ones rule 28 exists to refuse.
RE_HOME='/Users/[a-zA-Z0-9]|/home/[a-zA-Z]'
RE_EMAIL='[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'
# owner/repo#123 pointing somewhere else is how one repo's issue history reaches a public commit.
RE_ISSUE='[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+#[0-9]+'
# A session trailer or link names an agent transcript outside this repo, which no reader can open.
RE_TRAILER='Claude-Session:'
RE_LINK='claude\.ai/code/session'
RE_ANY="$RE_HOME|$RE_EMAIL|$RE_ISSUE|$RE_TRAILER|$RE_LINK"

report() { FOUND=1; printf '  %s\n' "$1"; }

scan() {
    _what="$1"; _re="$2"
    # Exclude this file and the suite: they contain the patterns by definition.
    _hits="$(git grep -nE "$_re" -- . ':!test/scan-for-leaks.sh' ':!test/run.sh' 2>/dev/null)"
    [ -n "$_hits" ] && printf '%s\n' "$_hits" | while IFS= read -r _l; do printf '  %s: %s\n' "$_what" "$_l"; done
    # A leak can live entirely in a tracked filename with clean content, invisible to git grep above.
    _names="$(git ls-files -- . ':!test/scan-for-leaks.sh' ':!test/run.sh' | grep -E "$_re" 2>/dev/null)"
    [ -n "$_names" ] && printf '%s\n' "$_names" | while IFS= read -r _n; do printf '  %s (filename): %s\n' "$_what" "$_n"; done
    [ -z "$_hits" ] && [ -z "$_names" ]
}

# git has not stripped comments or a --verbose diff yet, so read only what becomes the message.
scan_message() {
    _text="$(sed -e '/^#.*>8/,$d' -e '/^#/d' "$1")" || return 2
    _hits="$(printf '%s\n' "$_text" | grep -nE "$RE_ANY")"
    [ -z "$_hits" ] && return 0
    printf '%s\n' "$_hits" | while IFS= read -r _l; do printf '  commit message: %s\n' "$_l"; done
    return 1
}

if [ -n "$MSG" ]; then
    printf 'scanning the commit message\n'
    # A message that cannot be read is refused, never skipped: an unread gate has not passed.
    [ -r "$MSG" ] || { printf '  cannot read %s\n\nrefusing: the commit message was not scanned.\n' "$MSG"; exit 2; }
    scan_message "$MSG" || { printf '\nrefusing: the above would be published.\n'; exit 1; }
    printf 'clean\n'
    exit 0
fi

printf 'scanning tracked files\n'

scan "absolute home path" "$RE_HOME" || FOUND=1
scan "email address" "$RE_EMAIL" || FOUND=1
scan "cross-repo issue reference" "$RE_ISSUE" || FOUND=1
scan "agent-session trailer" "$RE_TRAILER" || FOUND=1
scan "agent-session link" "$RE_LINK" || FOUND=1

if [ "${1:-}" = "--all" ]; then
    printf 'scanning commit messages\n'
    _hits="$(git log --all --format='%H %s%n%b' | grep -nE "$RE_ANY")"
    [ -n "$_hits" ] && { printf '%s\n' "$_hits" | head -20; FOUND=1; }
fi

if [ "$FOUND" -eq 0 ]; then
    printf 'clean\n'
    exit 0
fi
printf '\nrefusing: the above would be published.\n'
exit 1
