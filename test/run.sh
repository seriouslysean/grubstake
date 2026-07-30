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
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/grubstake-test.XXXXXX")"
NETWORK=0
[ "${1:-}" = "--network" ] && NETWORK=1

PASS=0
FAIL=0
CURRENT=""

# Published cache entries are read-only, as Go's module cache is, so they need write back first.
trap 'chmod -R u+w "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT HUP INT TERM

# ---------------------------------------------------------------------------- harness

it() { CURRENT="$1"; }

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n         %s\n' "$CURRENT" "$1"; }

# A fresh repo with its own cache. Every test gets one, so no test can depend on another.
new_repo() {
    _r="$ROOT/$(date +%s)-$$-$PASS$FAIL-$(od -An -N2 -tu2 < /dev/urandom | tr -d ' ')"
    mkdir -p "$_r"
    _r="$(cd "$_r" && pwd)"
    ( cd "$_r" && git init -q . )
    cp "$GS" "$_r/grubstake.sh"
    mkdir -p "$_r/.cache"
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
r=$(new_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_B"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"; expect_ok "$r" check

it "editing a pin sends the lookup to a different path, so the old install is not served"
# Content addressing replaces invalidation logic: a corrected hash is a cache miss by construction.
r=$(new_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_B"
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
r=$(new_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_B"
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
r=$(new_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_B"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"; rm -f "$r/.cache/swiftlint/$SHA_A/swiftlint"
expect_fail "$r" check

it "ensure makes check pass from any recoverable state"
# The invariant that replaces the stamp-healing matrix: absent or present, nothing in between.
for _case in absent partial; do
    r=$(new_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_B"
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
pins "$a" "swiftlint 0.63.2 $SHA_A $SHA_B"; fake_install "$a" swiftlint 0.63.2 "$SHA_A"
pins "$b" "swiftlint 0.63.2 $SHA_B $SHA_B"; fake_install "$b" swiftlint 0.63.2 "$SHA_B"
out=$( cd "$b" && GRUBSTAKE_CACHE="$a/.cache" "$a/grubstake.sh" path swiftlint 2>&1 )
case "$out" in
    *"$SHA_A"*) pass ;;
    *) fail "served the other repo's pin: $out" ;;
esac

it "invocation through a symlink resolves the real script's pins"
r=$(new_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_B"
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
if [ "$NETWORK" = 1 ]; then
    r=$(new_repo)
    _prev=$( (cd "$ROOT/.." 2>/dev/null; git -C "$(dirname "$GS")" tag --list 'v*' \
        | sed 's/^v//' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
        | LC_ALL=C sort -t. -k1,1nr -k2,2nr -k3,3nr | sed -n 2p) )
    if [ -n "$_prev" ] && curl -fsSL "https://raw.githubusercontent.com/seriouslysean/grubstake/v$_prev/grubstake.sh" -o "$r/grubstake.sh" 2>/dev/null; then
        chmod +x "$r/grubstake.sh"
        _now="$(gs "$r" version)"
        gs_rc "$r" update
        _after="$(gs "$r" version)"
        [ "$_after" != "$_now" ] && pass || fail "update from $_now did not move it (still $_after)"
    else
        fail "could not fetch the previous release to test the upgrade path"
    fi
else
    pass   # network required
fi

# Sourcing the script would run main and exit, so pull the functions under test out by name.
extract_fns() {
    sed -n '/^with_lock() {/,/^}/p;/^publish_dir() {/,/^}/p' "$GS"
}

it "a race loser cleans up after itself"
# Two installs of one cold pin. The loser must discard its own staging, or a shared cache
# accumulates litter that a normal rm cannot remove.
r=$(new_repo)
_d="$r/dest"; _st="$r/dest.staging.111"
mkdir -p "$_st"; printf 'x' > "$_st/f"; chmod -R a-w "$_st"
mkdir -p "$_d"
{ extract_fns; echo 'publish_dir "$1" "$2"'; } > "$r/t.sh"
( cd "$r" && sh "$r/t.sh" "$_st" "$_d" ) >/dev/null 2>&1
if [ -e "$_st" ]; then fail "the loser could not remove its own read-only staging"; else pass; fi
chmod -R u+w "$r" 2>/dev/null

it "a lock is released even when the locked command fails"
r=$(new_repo)
{ extract_fns; cat <<'INNER'
die() { echo "$1" >&2; exit 1; }
fails() { return 1; }
with_lock "$1" fails
INNER
} > "$r/t.sh"
( cd "$r" && sh -eu "$r/t.sh" "$r/t.lock" ) >/dev/null 2>&1
if [ -d "$r/t.lock" ]; then fail "the lock survived a failing command"; else pass; fi

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
