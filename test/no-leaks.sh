#!/bin/sh
# Refuse to publish anything that identifies a consuming repo, a person, or a machine.
#
# This repo is public and the repos that use it are not. The leak is prose, not code: the engine
# gets edited from inside a consumer, so a comment written in that context can carry a private
# repo name or an issue number into a public commit.
#
# It matches SHAPES, not names. A denylist of private repo names could not live here without
# being the leak it exists to prevent. For names, put one pattern per line in .leakwords, which
# is gitignored and never published.
#
#   test/no-leaks.sh          scan tracked files
#   test/no-leaks.sh --all    also scan every commit message in history

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
FOUND=0

report() { FOUND=1; printf '  %s\n' "$1"; }

scan() {
    _what="$1"; _re="$2"
    # Exclude this file and the suite: they contain the patterns by definition.
    _hits="$(git grep -nE "$_re" -- . ':!test/no-leaks.sh' ':!test/run.sh' 2>/dev/null)"
    [ -z "$_hits" ] && return 0
    printf '%s\n' "$_hits" | while IFS= read -r _l; do printf '  %s: %s\n' "$_what" "$_l"; done
    FOUND=1
    return 1
}

printf 'scanning tracked files\n'

scan "absolute home path" '/Users/[a-zA-Z0-9]|/home/[a-z]' || FOUND=1
scan "email address" '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' || FOUND=1
# owner/repo#123 pointing somewhere else is how one repo's issue history reaches a public commit.
scan "cross-repo issue reference" '[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+#[0-9]+' || FOUND=1

if [ -f .leakwords ]; then
    while IFS= read -r _w; do
        case "$_w" in ''|\#*) continue ;; esac
        _hits="$(git grep -inE "$_w" -- . ':!test/no-leaks.sh' 2>/dev/null)"
        [ -n "$_hits" ] && { printf '%s\n' "$_hits" | while IFS= read -r _l; do printf '  local denylist: %s\n' "$_l"; done; FOUND=1; }
    done < .leakwords
else
    printf '  note: no .leakwords file, so name matching is skipped\n'
fi

if [ "${1:-}" = "--all" ]; then
    printf 'scanning commit messages\n'
    _hits="$(git log --all --format='%H %s%n%b' | grep -nE '/Users/[a-zA-Z0-9]|/home/[a-z]|[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+#[0-9]+')"
    [ -n "$_hits" ] && { printf '%s\n' "$_hits" | head -20; FOUND=1; }
fi

if [ "$FOUND" -eq 0 ]; then
    printf 'clean\n'
    exit 0
fi
printf '\nrefusing: the above would be published.\n'
exit 1
