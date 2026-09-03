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
#   test/scan-for-leaks.sh          scan tracked files
#   test/scan-for-leaks.sh --all    also scan every commit message in history

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
FOUND=0

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

printf 'scanning tracked files\n'

scan "absolute home path" '/Users/[a-zA-Z0-9]|/home/[a-zA-Z]' || FOUND=1
scan "email address" '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' || FOUND=1
# owner/repo#123 pointing somewhere else is how one repo's issue history reaches a public commit.
scan "cross-repo issue reference" '[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+#[0-9]+' || FOUND=1
# A session trailer or link names an agent transcript outside this repo, which no reader can open.
scan "agent-session trailer" 'Claude-Session:' || FOUND=1
scan "agent-session link" 'claude\.ai/code/session' || FOUND=1

if [ "${1:-}" = "--all" ]; then
    printf 'scanning commit messages\n'
    _hits="$(git log --all --format='%H %s%n%b' | grep -nE '/Users/[a-zA-Z0-9]|/home/[a-zA-Z]|[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+#[0-9]+')"
    [ -n "$_hits" ] && { printf '%s\n' "$_hits" | head -20; FOUND=1; }
fi

if [ "$FOUND" -eq 0 ]; then
    printf 'clean\n'
    exit 0
fi
printf '\nrefusing: the above would be published.\n'
exit 1
