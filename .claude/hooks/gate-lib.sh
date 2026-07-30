# Shared by the antagonist gate and receipt hooks, and sourced rather than executed.
# These are Claude Code hooks: hooks/ at the repo root is shipped product for consuming
# repos, and this directory is development policy for this one. Keep them apart.

# Field extraction good enough for the flat hook payload, whose values carry no quotes.
json_field() { sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1; }

# Mirror grubstake.sh's own fallback chain; cksum is POSIX, and this digest is identity, not security.
sha_any() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
    elif command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
    else cksum | tr ' \t' '--'
    fi
}

# The turn's footprint: uncommitted paths plus any commits the upstream has not seen.
changed_paths() {
    git status --porcelain 2>/dev/null | cut -c4-
    git log --format= --name-only '@{u}..HEAD' 2>/dev/null
}

# Digest the changed state, not just the path list, or an edit made after the antagonist ran
# would hide under the receipt minted for the state it reviewed.
changed_digest() {
    {
        git status --porcelain 2>/dev/null
        git diff HEAD 2>/dev/null
        git log --format=%H '@{u}..HEAD' 2>/dev/null
        git ls-files --others --exclude-standard 2>/dev/null | while IFS= read -r _f; do
            [ -f "$_f" ] && sha_any < "$_f"
        done
    } | sha_any
}
