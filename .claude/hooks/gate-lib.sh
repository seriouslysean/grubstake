# Shared by the antagonist gate and receipt hooks, and sourced rather than executed.
# These are Claude Code hooks for developing this repo; the git hooks grubstake ships are embedded in grubstake.sh.

# Field extraction good enough for the flat hook payload, whose values carry no quotes.
json_field() { sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1; }

# Mirror grubstake.sh's own fallback chain; cksum is POSIX, and this digest is identity, not security.
sha_any() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | cut -d' ' -f1
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    else
        cksum | tr ' \t' '--'
    fi
}

# A hook's cwd is whatever launched it, not necessarily the project; $CLAUDE_PROJECT_DIR is the one root Claude Code guarantees.
git_run() {
    if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
        git -C "$CLAUDE_PROJECT_DIR" "$@"
    else
        git "$@"
    fi
}

# A branch with no upstream (a new branch, a detached HEAD) has no @{u}; fall back to where it forked from origin/HEAD so a committed shell change is still seen.
turn_base() {
    if git_run rev-parse -q --verify '@{u}' >/dev/null 2>&1; then
        printf '@{u}\n'
        return
    fi
    git_run merge-base HEAD origin/HEAD 2>/dev/null
}

# The turn's footprint: uncommitted paths plus any commits the upstream has not seen. -z and
# --no-renames keep every path raw and single-field, so a later anchor can trust column 0.
changed_paths() {
    git_run status --porcelain -z --no-renames 2>/dev/null | tr '\0' '\n' | cut -c4-
    _base=$(turn_base)
    [ -n "$_base" ] && git_run log --format= --name-only "$_base..HEAD" 2>/dev/null
}

# Digest the changed state, not just the path list, or an edit made after the antagonist ran
# would hide under the receipt minted for the state it reviewed.
changed_digest() {
    _base=$(turn_base)
    {
        git_run status --porcelain 2>/dev/null
        git_run diff HEAD 2>/dev/null
        [ -n "$_base" ] && git_run log --format=%H "$_base..HEAD" 2>/dev/null
        # ls-files paths are project-relative, not cwd-relative, so a caller elsewhere needs the same root prefixed back on.
        git_run ls-files --others --exclude-standard 2>/dev/null | while IFS= read -r _f; do
            _p="${CLAUDE_PROJECT_DIR:+$CLAUDE_PROJECT_DIR/}$_f"
            [ -f "$_p" ] && sha_any <"$_p"
        done
    } | sha_any
}

# One registry for the gate and the receipt, so a third reviewer that mints a kind is one edit here; gst-shell-reviewer mints no receipt, so it carries no kind.
reviewer_kind() {
    case "$1" in
        gst-shell-critic) echo shell ;;
        gst-leak-auditor) echo leak ;;
        *) return 1 ;;
    esac
}
