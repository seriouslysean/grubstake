#!/bin/sh
# grubstake regression suite.
#
# Every test here exists because something shipped broken. The name says what it prevents.
# Run before every release: this suite is the reason a fix cannot silently break an earlier fix.
#
#   test/run.sh              offline tests only (fast, no network)
#   test/run.sh --network    also the tests that download real artifacts
#
# Most tests fabricate a cache entry rather than downloading, so a failure points at logic
# rather than at GitHub being slow.

set -u

GS="$(cd "$(dirname "$0")/.." && pwd)/grubstake.sh"
HOOKS="$(cd "$(dirname "$0")/.." && pwd)/hooks"
SUITE_PID=$$
NETWORK=0
[ "${1:-}" = "--network" ] && NETWORK=1

PASS=0
FAIL=0
CURRENT=""

# Unchecked, this failed silently under an unwritable TMPDIR and every later test ran against a
# path that did not exist, which turned "grubstake could not start" into a column of passes.
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/grubstake-test.XXXXXX")" || {
    printf 'FATAL  no scratch directory under %s\n' "${TMPDIR:-/tmp}" >&2
    exit 2
}

# Published cache entries are read-only, as Go's module cache is, so they need write back first.
cleanup() { chmod -R u+w "$ROOT" 2>/dev/null; rm -rf "$ROOT"; }
trap cleanup EXIT
trap 'cleanup; exit 2' HUP INT TERM

# ---------------------------------------------------------------------------- harness

it() { CURRENT="$1"; }

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n         %s\n' "$CURRENT" "$1"; }

# A fixture that could not be built is not a test result. new_repo runs inside $(...), which is a
# subshell, so exiting here would end only that subshell and hand the caller an empty path: every
# expect_fail after it then passes because grubstake.sh could not run at all. Signal the suite
# instead, so a broken fixture stops the run rather than inflating it.
fixture_die() {
    printf '\nFATAL  fixture: %s\n' "$1" >&2
    kill -TERM "$SUITE_PID" 2>/dev/null
    exit 2
}

# A fresh repo with its own cache. Every test gets one, so no test can depend on another.
new_repo() {
    _r="$ROOT/$(date +%s)-$$-$PASS$FAIL-$(od -An -N2 -tu2 < /dev/urandom | tr -d ' ')"
    mkdir -p "$_r" || fixture_die "cannot create $_r"
    _r="$(cd "$_r" && pwd)" || fixture_die "cannot enter $_r"
    ( cd "$_r" && git init -q . ) || fixture_die "git init failed in $_r"
    cp "$GS" "$_r/grubstake.sh" || fixture_die "cannot copy grubstake.sh into $_r"
    mkdir -p "$_r/.cache" || fixture_die "cannot create $_r/.cache"
    # Backstop for whatever the per-step checks above do not enumerate.
    [ -d "$_r/.git" ] && [ -x "$_r/grubstake.sh" ] && [ -d "$_r/.cache" ] \
        || fixture_die "incomplete repo at $_r"
    echo "$_r"
}

# Run grubstake in a repo with that repo's own cache.
gs() {
    _repo="$1"; shift
    ( cd "$_repo" && GRUBSTAKE_CACHE="$_repo/.cache" ./grubstake.sh "$@" 2>&1 )
}
gs_rc() {
    _repo="$1"; shift
    ( cd "$_repo" && GRUBSTAKE_CACHE="$_repo/.cache" ./grubstake.sh "$@" >/dev/null 2>&1 )
}

pins() { printf '# grubstake pins: name version sha256-darwin sha256-linux\n%s\n' "$2" > "$1/grubstake.tools"; }

# A cache entry as install_tool publishes one: a directory named by the pinned archive hash,
# holding a binary that reports the pinned version. Nothing else; the path is the validity.
fake_install() {
    _repo="$1"; _tool="$2"; _ver="$3"; _pinsha="$4"
    _d="$_repo/.cache/$_tool/$_pinsha"
    mkdir -p "$_d"
    printf '#!/bin/sh\necho %s\n' "$_ver" > "$_d/$_tool"
    chmod +x "$_d/$_tool"
}

# A test that fabricates an entry and then runs grubstake pins the SAME hash in both columns.
# pin_sha reads the column for the running platform, so pinning darwin and linux differently puts
# the entry at a path only one platform ever looks in, and the test asserts nothing on the other.
# That is how three tests came to pass only on darwin. Pin the columns differently only when the
# difference is the thing under test.
SHA_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SHA_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

expect_fail() {
    if gs_rc "$@"; then fail "expected non-zero exit, got 0"; else pass; fi
}
expect_ok() {
    if gs_rc "$@"; then pass; else fail "expected exit 0, got non-zero"; fi
}
expect_says() {
    _want="$1"; shift
    _out="$(gs "$@")"
    case "$_out" in
        *"$_want"*) pass ;;
        *) fail "output did not contain '$_want'. Got: $_out" ;;
    esac
}

# ---------------------------------------------------------------------------- basics

printf '\nbasics\n'

it "version prints the embedded version"
r=$(new_repo); v=$(gs "$r" version)
case "$v" in [0-9]*.[0-9]*.[0-9]*) pass ;; *) fail "got '$v'" ;; esac

it "no arguments prints usage and exits 0"
expect_ok "$(new_repo)"

it "an unknown verb fails"
expect_fail "$(new_repo)" notaverb

it "runs under dash, not just bash"
if dash -n "$GS" 2>/dev/null; then pass; else fail "dash -n rejected the script"; fi

it "the script is wrapped so a truncated copy is inert"
# A shell reads scripts incrementally, so without main() at the end a partial file executes its
# valid prefix. A syntax error on stderr is the correct outcome. What must not happen is a command running:
# no version, no log line, non-zero exit.
r=$(new_repo); head -c 900 "$GS" > "$r/trunc.sh"; chmod +x "$r/trunc.sh"
out=$(sh "$r/trunc.sh" version 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
    fail "truncated script exited 0"
else
    case "$out" in
        *"[grubstake]"*|*[0-9].[0-9].[0-9]*) fail "truncated script executed something: $out" ;;
        *) pass ;;
    esac
fi

# ---------------------------------------------------------------------------- pins validation

printf '\npins file validation\n'

it "a duplicate tool line fails"
r=$(new_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_B
swiftlint 0.65.0 $SHA_A $SHA_B"; expect_fail "$r" check

it "a line with the wrong field count fails"
r=$(new_repo); pins "$r" "swiftlint 0.63.2 $SHA_A"; expect_fail "$r" check

it "a sha that is not 64 hex characters fails"
r=$(new_repo); pins "$r" "swiftlint 0.63.2 nothex $SHA_B"; expect_fail "$r" check

it "an unknown tool name fails"
r=$(new_repo); pins "$r" "notatool 1.0.0 $SHA_A $SHA_B"; expect_fail "$r" check

it "an unresolved conflict marker fails"
r=$(new_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_B
<<<<<<< HEAD"; expect_fail "$r" check

it "CRLF line endings fail"
r=$(new_repo); printf '# h\r\nswiftlint 0.63.2 %s %s\r\n' "$SHA_A" "$SHA_B" > "$r/grubstake.tools"
expect_fail "$r" check

it "an indented pin line fails"
r=$(new_repo); pins "$r" "  swiftlint 0.63.2 $SHA_A $SHA_B"; expect_fail "$r" check

it "an unterminated final line is still validated"
r=$(new_repo); printf '# h\nswiftlint 0.63.2 %s' "$SHA_A" > "$r/grubstake.tools"
expect_fail "$r" check

it "a malformed pin fails check, not just ensure"
# check is what the pre-commit hook calls. It once passed on a malformed file because a die
# inside a command substitution killed only the subshell.
r=$(new_repo); pins "$r" "garbage 1.0.0 $SHA_A $SHA_B"; expect_fail "$r" check

it "a malformed pin fails doctor too"
r=$(new_repo); pins "$r" "garbage 1.0.0 $SHA_A $SHA_B"; expect_fail "$r" doctor

# ---------------------------------------------------------------------------- cache integrity

printf '\ncache integrity\n'

it "a clean install passes check"
r=$(new_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"; expect_ok "$r" check

it "editing a pin sends the lookup to a different path, so the old install is not served"
# Content addressing replaces invalidation logic: a corrected hash is a cache miss by construction.
r=$(new_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"
pins "$r" "swiftlint 0.63.2 $SHA_B $SHA_B"
expect_fail "$r" check

it "two pins of the same version at different hashes coexist"
# Two repos correcting a hash at different times must not fight over one directory.
r=$(new_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_B"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"
fake_install "$r" swiftlint 0.63.2 "$SHA_B"
if [ -x "$r/.cache/swiftlint/$SHA_A/swiftlint" ] && [ -x "$r/.cache/swiftlint/$SHA_B/swiftlint" ]; then
    pass
else
    fail "one install displaced the other"
fi

it "a poisoned cache IS served, and nothing claims otherwise"
# Honest boundary: the pin checked at download is the trust root. A local cache writable by the
# same user is not defensible, and no cited tool claims it is. This test exists so the claim
# cannot quietly come back.
r=$(new_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"
printf '#!/bin/sh\necho 0.63.2\n' > "$r/.cache/swiftlint/$SHA_A/swiftlint"
chmod +x "$r/.cache/swiftlint/$SHA_A/swiftlint"
expect_ok "$r" check

it "no source file claims to detect tampering"
if grep -rniE "tamper" "$(dirname "$0")/.." --include='*.sh' --include='*.md' \
    --exclude=run.sh >/dev/null 2>&1; then
    fail "something still claims tamper detection"
else
    pass
fi

it "a missing binary fails"
r=$(new_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"; rm -f "$r/.cache/swiftlint/$SHA_A/swiftlint"
expect_fail "$r" check

it "ensure makes check pass from any recoverable state"
# The invariant that replaces the stamp-healing matrix: absent or present, nothing in between.
for _case in absent partial; do
    r=$(new_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
    case "$_case" in
        absent)  : ;;
        partial) mkdir -p "$r/.cache/swiftlint/$SHA_A" ;;
    esac
    gs_rc "$r" check && { fail "state '$_case' passed check without an install"; _bad=1; break; }
done
[ "${_bad:-0}" = 0 ] && pass; _bad=0

# ---------------------------------------------------------------------------- resolution

printf '\nresolution\n'

it "pins resolve from the script, not the working directory"
# This is the failure grubstake exists to prevent, and it was once present in grubstake: running
# one repo's script from inside another served the other repo's pins.
a=$(new_repo); b=$(new_repo)
pins "$a" "swiftlint 0.63.2 $SHA_A $SHA_A"; fake_install "$a" swiftlint 0.63.2 "$SHA_A"
pins "$b" "swiftlint 0.63.2 $SHA_B $SHA_B"; fake_install "$b" swiftlint 0.63.2 "$SHA_B"
out=$( cd "$b" && GRUBSTAKE_CACHE="$a/.cache" "$a/grubstake.sh" path swiftlint 2>&1 )
case "$out" in
    *"$SHA_A"*) pass ;;
    *) fail "served the other repo's pin: $out" ;;
esac

it "invocation through a symlink resolves the real script's pins"
r=$(new_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"
mkdir -p "$r/bin" && ln -s "$r/grubstake.sh" "$r/bin/grubstake"
other=$(new_repo)
out=$( cd "$other" && GRUBSTAKE_CACHE="$r/.cache" "$r/bin/grubstake" doctor 2>&1 | grep '^pins' )
case "$out" in
    *"$r/grubstake.tools"*) pass ;;
    *) fail "symlink resolved pins elsewhere: $out" ;;
esac

it "path fails for a tool that is not pinned"
r=$(new_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_B"; expect_fail "$r" path periphery

it "path fails for a tool with no artifact on this platform"
# It used to print a cache path that did not exist and exit 0, which after a cutover hands CI
# a path to nothing instead of an error.
r=$(new_repo)
sed 's/        Darwin) echo darwin ;;/        Darwin) echo linux ;;/' "$GS" > "$r/grubstake.sh"
chmod +x "$r/grubstake.sh"
pins "$r" "periphery 3.7.4 $SHA_A -"
expect_fail "$r" path periphery

it "path rejects a tool name that is not a known tool"
r=$(new_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_B"
expect_fail "$r" path 'swiftlint|x'

it "a tool with no artifact on this platform is skipped, not failed, by check"
r=$(new_repo); pins "$r" "periphery 3.7.4 $SHA_A -"
sed 's/        Darwin) echo darwin ;;/        Darwin) echo linux ;;/' "$GS" > "$r/grubstake.sh"
chmod +x "$r/grubstake.sh"; expect_ok "$r" check

# ---------------------------------------------------------------------------- update

printf '\nupdate\n'

it "a release below the supported floor is refused"
r=$(new_repo); expect_fail "$r" update 0.1.4

it "the legacy handoff verb still answers, for clients that only speak it"
# Removing it stranded every existing adopter: it is a protocol only OLD versions speak, so it is
# the one thing that cannot be fixed forward. It stays as compatibility, not as a live path.
r=$(new_repo)
cp "$GS" "$r/target.sh"
sed -i.bak 's/^GRUBSTAKE_VERSION=.*/GRUBSTAKE_VERSION="0.0.1"/' "$r/target.sh" && rm -f "$r/target.sh.bak"
( cd "$r" && ./grubstake.sh __replace-self "$r/target.sh" 9.9.9 ) >/dev/null 2>&1
_v=$( "$r/target.sh" version 2>/dev/null )
[ "$_v" = "$(gs "$(new_repo)" version)" ] && pass || fail "the shim did not replace the target (got '$_v')"

it "a target that is not a release version is rejected"
r=$(new_repo); expect_fail "$r" update ../main

it "an already-current version is a no-op"
r=$(new_repo); v=$(gs "$r" version); expect_says "already on $v" "$r" update "$v"

it "update renames over the script rather than handing off to a temp copy"
# The handoff avoided a hazard rename never had, and cost a $0 that lied about which repo it was
# in. Renaming from within keeps the running interpreter on the old inode. The verb survives only
# to answer old clients; nothing in this version's own update path may exec it.
if sed -n '/^cmd_update() {/,/^}/p' "$GS" | grep -q '__replace-self'; then
    fail "update still hands off to a temp copy"
else
    pass
fi

it "the previous release can update to this one"
# The suite asserted the destination and never the journey: it checked that the internal replace
# verb was gone, while every older client still called it. Removing a verb only old versions speak
# is the one change that cannot be fixed forward.
#
# Resolved from the remote, not from local tags: a shallow clone by tag has one tag, which made
# this report a failure when the real cause was "nothing to compare against". A test that cannot
# tell "I could not run" from "the thing is broken" gets ignored the first time it goes red.
if [ "$NETWORK" = 1 ]; then
    _repo="$(sed -n 's/^GRUBSTAKE_REPO="\(.*\)"/\1/p' "$GS")"
    _prev=$(git ls-remote --tags --refs "$_repo" 'v*' 2>/dev/null \
        | awk '{print $2}' | sed 's|refs/tags/v||' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
        | LC_ALL=C sort -t. -k1,1nr -k2,2nr -k3,3nr | sed -n 2p)
    if [ -z "$_prev" ]; then
        printf '  skip  %s\n' "$CURRENT (fewer than two releases published)"
    else
        r=$(new_repo)
        if curl -fsSL "https://raw.githubusercontent.com/seriouslysean/grubstake/v$_prev/grubstake.sh" \
             -o "$r/grubstake.sh" 2>/dev/null; then
            chmod +x "$r/grubstake.sh"
            _now="$(gs "$r" version)"
            gs_rc "$r" update
            _after="$(gs "$r" version)"
            if [ "$_after" != "$_now" ]; then pass; else fail "update from $_now did not move it (still $_after)"; fi
        else
            fail "v$_prev is published but could not be fetched"
        fi
    fi
else
    printf '  skip  %s (network)\n' "$CURRENT"
fi

# Sourcing the script would run main and exit, so pull the functions under test out by name. The
# sed ranges are keyed to exact brace formatting: move an opening brace to the next line and the
# extraction silently yields nothing, the generated script exits 127 without ever calling the
# function, and a test that only checks for the absence of a lock directory reports ok. An empty
# or truncated extraction is a harness fault, not a result, so it stops the run.
extract_fns() {
    _fns="$(sed -n '/^with_lock() {/,/^}/p;/^publish_dir() {/,/^}/p' "$GS")"
    for _f in with_lock publish_dir; do
        printf '%s\n' "$_fns" | grep -q "^$_f() {$" \
            || fixture_die "extract_fns: no '$_f() {' line in $GS (reformatted?)"
    done
    # Neither function nests a line-anchored brace, so anything but one close each means a range ran on.
    _closes="$(printf '%s\n' "$_fns" | grep -c '^}$' | tr -d ' ')"
    [ "$_closes" = 2 ] || fixture_die "extract_fns: $_closes closing braces, expected 2 (truncated)"
    printf '%s\n' "$_fns"
}

it "a race loser cleans up after itself"
# Two installs of one cold pin. The loser must discard its own staging, or a shared cache
# accumulates litter that a normal rm cannot remove.
r=$(new_repo)
_d="$r/dest"; _st="$r/dest.staging.111"
mkdir -p "$_st"; printf 'x' > "$_st/f"; chmod -R a-w "$_st"
mkdir -p "$_d"
{ extract_fns; echo 'publish_dir "$1" "$2"'; } > "$r/t.sh"
( cd "$r" && sh "$r/t.sh" "$_st" "$_d" ) >/dev/null 2>&1; _rc=$?
# The status is checked rather than discarded: 127 is publish_dir never running, which leaves no
# staging behind either and so read as a pass.
if [ "$_rc" -ne 0 ]; then fail "the generated script exited $_rc, so publish_dir did not run"
elif [ -e "$_st" ]; then fail "the loser could not remove its own read-only staging"
else pass; fi
chmod -R u+w "$r" 2>/dev/null

it "a lock is released even when the locked command fails"
r=$(new_repo)
{ extract_fns; cat <<'INNER'
die() { echo "$1" >&2; exit 1; }
fails() { return 1; }
with_lock "$1" fails
INNER
} > "$r/t.sh"
( cd "$r" && sh -eu "$r/t.sh" "$r/t.lock" ) >/dev/null 2>&1; _rc=$?
# 1 is the locked command's own status arriving back through with_lock. 127 is with_lock never
# running, which leaves no lock directory either and so read as a pass.
if [ "$_rc" -ne 1 ]; then fail "the generated script exited $_rc, expected the locked command's 1"
elif [ -d "$r/t.lock" ]; then fail "the lock survived a failing command"
else pass; fi

it "release versions sort newest first"
# A trailing -r is ignored when per-key flags are present, which once made update install the
# oldest release every time.
top=$(printf '0.2.0\n0.10.0\n0.9.9\n' | LC_ALL=C sort -t. -k1,1nr -k2,2nr -k3,3nr | head -1)
[ "$top" = "0.10.0" ] && pass || fail "sorted to $top, expected 0.10.0"

# ---------------------------------------------------------------------------- install

printf '\ninstall\n'

it "install refuses a foreign hooksPath without writing anything first"
r=$(new_repo); ( cd "$r" && git config core.hooksPath .other-hooks )
gs_rc "$r" install
if [ -d "$r/.githooks" ]; then fail "left .githooks behind after refusing"; else pass; fi

# ---------------------------------------------------------------------------- hooks
#
# Nothing here ran either shipped hook before: the suite tested what grubstake does when the suite
# calls it, never what happens inside a commit. These fixtures install the hooks the way
# `grubstake install` does and drive them through a real `git commit`.

# A repo with the shipped hooks installed and one commit of history. The baseline commit is made
# before core.hooksPath is set, so building the fixture never runs the hooks under test.
new_hook_repo() {
    _hr="$(new_repo)"
    printf 'fixture\n' > "$_hr/README.md" || fixture_die "cannot write $_hr/README.md"
    # gpgsign off explicitly: a signing key configured globally would block every commit below.
    ( cd "$_hr" \
      && git config user.email test@example.invalid \
      && git config user.name "grubstake suite" \
      && git config commit.gpgsign false \
      && git add README.md \
      && git commit -q -m baseline ) || fixture_die "cannot seed a commit in $_hr"
    mkdir -p "$_hr/.githooks" || fixture_die "cannot create $_hr/.githooks"
    cp "$HOOKS/pre-commit" "$HOOKS/post-commit" "$_hr/.githooks/" \
        || fixture_die "cannot copy hooks into $_hr"
    chmod +x "$_hr/.githooks/pre-commit" "$_hr/.githooks/post-commit" \
        || fixture_die "cannot make the hooks executable in $_hr"
    ( cd "$_hr" && git config core.hooksPath .githooks ) \
        || fixture_die "cannot set core.hooksPath in $_hr"
    echo "$_hr"
}

# Commit in a hook fixture, returning git's status and printing everything the hooks said.
#
# GRUBSTAKE_CACHE has to be exported into the git invocation itself. The hook is a child of git,
# not of this function, so a cache set only in this shell would leave the hook resolving against
# the developer's real cache: the tests would still go green, for a reason the fixture never
# controlled. GIT_ALLOW_PROTOCOL keeps post-commit's backgrounded refresh off the network, since
# git then refuses the transport outright instead of dialling out.
hook_commit() {
    _hcr="$1"
    ( cd "$_hcr" \
      && GRUBSTAKE_CACHE="$_hcr/.cache" GIT_ALLOW_PROTOCOL=file \
         git commit -q -m change 2>&1 )
}

commits() { ( cd "$1" && git rev-list --count HEAD 2>/dev/null || echo 0 ); }

# Write a file and stage it; the staged paths are all the pre-commit spine looks at.
stage() {
    printf '%s\n' "$3" > "$1/$2" || fixture_die "cannot write $1/$2"
    ( cd "$1" && git add "$2" ) || fixture_die "cannot stage $2 in $1"
}

# A stubbed swiftlint at the pinned cache path, so `grubstake path swiftlint` resolves to it. It
# records the binary it was invoked as and every argument it received, and takes its output and
# status from files numbered by invocation, so a test can script the first run and the second
# differently. verify_tool only checks that the path exists, so nothing else runs this. Its callers
# pin SHA_A in both columns, so the stub sits where either platform looks for it.
stub_linter() {
    _sd="$1/.cache/swiftlint/$SHA_A"
    mkdir -p "$_sd" || fixture_die "cannot create $_sd"
    printf "#!/bin/sh\nR='%s'\n" "$1" > "$_sd/swiftlint" || fixture_die "cannot write the stub linter"
    cat >> "$_sd/swiftlint" <<'STUB'
n=$(cat "$R/lint.runs" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$R/lint.runs"
{ echo "$0"; for a in "$@"; do echo "$a"; done; } > "$R/lint.argv.$n"
[ -f "$R/lint.out.$n" ] && cat "$R/lint.out.$n"
exit "$(cat "$R/lint.rc.$n" 2>/dev/null || echo 0)"
STUB
    chmod +x "$_sd/swiftlint" || fixture_die "cannot make the stub linter executable"
}

# What the stub does on its Nth invocation: repo, n, exit status, output.
lint_run() {
    printf '%s\n' "$3" > "$1/lint.rc.$2" || fixture_die "cannot script lint run $2"
    printf '%s' "$4" > "$1/lint.out.$2" || fixture_die "cannot script lint run $2"
}

# A repo-local gate, which is where repo-specific checks live rather than in the shared spine.
gate() {
    mkdir -p "$1/.githooks/pre-commit.d" || fixture_die "cannot create $1/.githooks/pre-commit.d"
    printf '#!/bin/sh\nexit %s\n' "$3" > "$1/.githooks/pre-commit.d/$2" \
        || fixture_die "cannot write gate $2"
    chmod +x "$1/.githooks/pre-commit.d/$2" || fixture_die "cannot make gate $2 executable"
}

# The answer post-commit reads, inside .git so it needs no gitignore entry. Stamped now, so the
# TTL has not expired and nothing tries to refresh it. An empty version is refused rather than
# written: post-commit says nothing when line 2 is blank, which would make silence prove nothing.
latest_cache() {
    [ -n "$2" ] || fixture_die "no version to cache as the latest release"
    printf '%s\n%s\n' "$(date +%s)" "$2" > "$1/.git/grubstake-latest" \
        || fixture_die "cannot write the latest cache in $1"
}

printf '\nhooks\n'

it "the hook lints with the pinned binary from this repo's cache"
# The hook is a child of git, so a cache exported only into this shell never reaches it, and every
# test below would then be measuring the developer's real cache instead of the fixture's.
r=$(new_hook_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
stub_linter "$r"; lint_run "$r" 1 0 ""
stage "$r" A.swift "struct A {}"
hook_commit "$r" >/dev/null 2>&1
_bin=$(sed -n 1p "$r/lint.argv.1" 2>/dev/null)
if [ "$_bin" != "$r/.cache/swiftlint/$SHA_A/swiftlint" ]; then
    fail "the hook ran '$_bin', not this repo's pinned linter"
elif ! grep -qx lint "$r/lint.argv.1"; then
    fail "the linter was not asked to lint: $(tr '\n' ' ' < "$r/lint.argv.1")"
elif ! grep -qx A.swift "$r/lint.argv.1"; then
    fail "the staged path never reached the linter: $(tr '\n' ' ' < "$r/lint.argv.1")"
else
    pass
fi

it "a lint failure blocks the commit"
# The linter's own output has to reach the developer, or a refusal for any other reason -- a tool
# that was never installed, say -- looks identical to a refusal the linter asked for.
r=$(new_hook_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
stub_linter "$r"; lint_run "$r" 1 2 "A.swift:1:1: error: Force Cast Violation (force_cast)"
stage "$r" A.swift "struct A {}"
_out=$(hook_commit "$r"); _rc=$?
if [ "$_rc" -eq 0 ]; then fail "the commit went through: $_out"
elif [ "$(commits "$r")" != 1 ]; then fail "refused, and committed anyway"
else
    case "$_out" in
        *"Force Cast Violation"*) pass ;;
        *) fail "blocked without reporting what the linter said: $_out" ;;
    esac
fi

it "a clean lint lets the commit through"
# A gate that never passes gets bypassed, and then it gates nothing at all.
r=$(new_hook_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
stub_linter "$r"; lint_run "$r" 1 0 ""
stage "$r" A.swift "struct A {}"
_out=$(hook_commit "$r"); _rc=$?
if [ "$_rc" -ne 0 ]; then fail "a clean lint was blocked (rc $_rc): $_out"
elif [ "$(commits "$r")" != 2 ]; then fail "exited 0 without committing"
else pass; fi

it "a blocked commit goes through once the lint passes"
# The retry loop the spine is built around: the hook refuses, the developer fixes and re-stages,
# and the second attempt has to lint again rather than replay the first verdict.
r=$(new_hook_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
stub_linter "$r"
lint_run "$r" 1 2 "A.swift:1:1: error: Force Cast Violation (force_cast)"
lint_run "$r" 2 0 ""
stage "$r" A.swift "struct A {}"
hook_commit "$r" >/dev/null 2>&1
stage "$r" A.swift "struct A { let a = 1 }"
_out=$(hook_commit "$r"); _rc=$?
if [ "$_rc" -ne 0 ]; then fail "the retry was still blocked (rc $_rc): $_out"
elif [ ! -f "$r/lint.argv.2" ]; then fail "the retry never re-ran the linter"
elif [ "$(commits "$r")" != 2 ]; then fail "exited 0 without committing"
else pass; fi

it "a commit with no Swift files does not need the tools installed"
# A cold cache must not refuse a docs-only commit: nothing this spine gates is staged, so there is
# nothing to verify and no reason to reach for a binary that has not been fetched yet.
r=$(new_hook_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
stage "$r" NOTES.md "notes"
_out=$(hook_commit "$r"); _rc=$?
if [ "$_rc" -ne 0 ]; then fail "a cold cache blocked a non-Swift commit (rc $_rc): $_out"
elif [ "$(commits "$r")" != 2 ]; then fail "exited 0 without committing"
else pass; fi

it "a failing pre-commit.d gate blocks the commit"
r=$(new_hook_repo); gate "$r" 10-gate 1
stage "$r" NOTES.md "notes"
_out=$(hook_commit "$r"); _rc=$?
if [ "$_rc" -eq 0 ]; then fail "the commit went through: $_out"
elif [ "$(commits "$r")" != 1 ]; then fail "refused, and committed anyway"
else
    case "$_out" in
        *"gate failed: 10-gate"*) pass ;;
        *) fail "blocked without naming the gate: $_out" ;;
    esac
fi

it "a pre-commit.d gate that lost its exec bit blocks the commit"
# A gate that cannot run must not look like one that passed; the silent skip is the whole failure.
r=$(new_hook_repo); gate "$r" 20-gate 0
chmod -x "$r/.githooks/pre-commit.d/20-gate"
stage "$r" NOTES.md "notes"
_out=$(hook_commit "$r"); _rc=$?
if [ "$_rc" -eq 0 ]; then fail "an unrunnable gate was skipped: $_out"
elif [ "$(commits "$r")" != 1 ]; then fail "refused, and committed anyway"
else
    case "$_out" in
        *"gate not executable"*) pass ;;
        *) fail "blocked without saying why: $_out" ;;
    esac
fi

it "a repo with no pre-commit.d directory still commits"
# An unmatched glob expands to itself, so the loop has to skip a path that is not there instead of
# trying to run it. Most adopters never add a repo-local gate.
r=$(new_hook_repo)
stage "$r" NOTES.md "notes"
_out=$(hook_commit "$r"); _rc=$?
if [ "$_rc" -ne 0 ]; then fail "blocked with no gates present (rc $_rc): $_out"
elif [ "$(commits "$r")" != 2 ]; then fail "exited 0 without committing"
else pass; fi

it "post-commit reports a release newer than the one running"
r=$(new_hook_repo); latest_cache "$r" 99.9.9
stage "$r" NOTES.md "notes"
_out=$(hook_commit "$r")
case "$_out" in
    *"99.9.9 available"*) pass ;;
    *) fail "said nothing about a newer release: $_out" ;;
esac

it "post-commit stays quiet when the cached latest is the version already running"
# A line on every commit is noise that gets filtered, and then the one that mattered is filtered too.
r=$(new_hook_repo); latest_cache "$r" "$(gs "$r" version)"
stage "$r" NOTES.md "notes"
_out=$(hook_commit "$r")
case "$_out" in
    *"[grubstake]"*) fail "spoke with nothing to report: $_out" ;;
    *) pass ;;
esac

it "post-commit stays quiet with no cache and no network"
# Being offline is a reason to say nothing, not to fail a commit. The refresh is backgrounded, so
# the commit must neither wait on it nor print a half-answer.
r=$(new_hook_repo)
stage "$r" NOTES.md "notes"
_out=$(hook_commit "$r"); _rc=$?
if [ "$_rc" -ne 0 ]; then fail "an offline post-commit failed the commit (rc $_rc): $_out"
else
    case "$_out" in
        *"[grubstake]"*) fail "spoke with no cached answer: $_out" ;;
        *) pass ;;
    esac
fi

# ---------------------------------------------------------------------------- add

printf '\nadd\n'

it "add rejects an unknown tool"
r=$(new_repo); expect_fail "$r" add notatool@1.0.0

it "add rejects a spec with no version"
r=$(new_repo); expect_fail "$r" add swiftlint

if [ "$NETWORK" = 1 ]; then
    printf '\nadd, network\n'

    it "add pins every argument, not just the first"
    # It once read only $1 while accepting any number, so a batched call pinned one and exited 0.
    r=$(new_repo)
    gs_rc "$r" add swiftlint@0.63.2 swiftformat@0.61.1
    n=$(grep -cvE '^[[:space:]]*(#|$)' "$r/grubstake.tools" 2>/dev/null || echo 0)
    [ "$n" = "2" ] && pass || fail "pinned $n tools, expected 2"

    it "add records a hash for every platform the tool publishes"
    r=$(new_repo); gs_rc "$r" add swiftlint@0.63.2
    line=$(grep '^swiftlint' "$r/grubstake.tools")
    d=$(echo "$line" | awk '{print $3}'); l=$(echo "$line" | awk '{print $4}')
    case "$d$l" in *-*) fail "a platform hash is missing: $line" ;; *) pass ;; esac

    it "a real install passes check, and the path it prints runs at the pinned version"
    r=$(new_repo); gs_rc "$r" add swiftlint@0.63.2
    _p="$(gs "$r" path swiftlint)"
    if gs_rc "$r" check && [ "$("$_p" version 2>/dev/null)" = "0.63.2" ]; then pass
    else fail "install did not verify, or the path does not run"; fi

    it "a real install lands under the pinned archive hash"
    # The path is the validity, so it must be the hash from grubstake.tools and nothing else.
    r=$(new_repo); gs_rc "$r" add swiftlint@0.63.2
    _sha=$(awk '/^swiftlint/{print $3}' "$r/grubstake.tools")
    [ -x "$r/.cache/swiftlint/$_sha/swiftlint" ] && pass || fail "not installed under $_sha"

    it "published entries are read-only"
    r=$(new_repo); gs_rc "$r" add swiftlint@0.63.2
    _sha=$(awk '/^swiftlint/{print $3}' "$r/grubstake.tools")
    if { printf 'x' >> "$r/.cache/swiftlint/$_sha/swiftlint"; } 2>/dev/null; then
        fail "a published binary was writable"
    else
        pass
    fi

    it "no staging directories are left in the cache"
    r=$(new_repo); gs_rc "$r" add swiftlint@0.63.2
    n=$(find "$r/.cache" -name '*.staging.*' | wc -l | tr -d ' ')
    [ "$n" = "0" ] && pass || fail "$n staging directories left behind"
else
    printf '\nadd, network  (skipped: pass --network to run)\n'
fi

# ---------------------------------------------------------------------------- publication safety

printf '\npublication safety\n'

it "nothing tracked identifies a consumer, a person, or a machine"
if "$(dirname "$0")/no-leaks.sh" >/dev/null 2>&1; then pass; else fail "$("$(dirname "$0")/no-leaks.sh" 2>&1 | tail -3)"; fi

# ---------------------------------------------------------------------------- result

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
