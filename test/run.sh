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

trap 'rm -rf "$ROOT"' EXIT HUP INT TERM

# ---------------------------------------------------------------------------- harness

it() { CURRENT="$1"; }

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n         %s\n' "$CURRENT" "$1"; }

# A fresh repo with its own cache. Every test gets one, so no test can depend on another.
new_repo() {
    _r="$ROOT/$(date +%s)-$$-$PASS$FAIL-$(od -An -N2 -tu2 < /dev/urandom | tr -d ' ')"
    mkdir -p "$_r"
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

# A cache entry that looks exactly like a real install: a binary reporting the pinned version,
# and a stamp holding the binary digest and the pin it came from. No network.
fake_install() {
    _repo="$1"; _tool="$2"; _ver="$3"; _pinsha="$4"
    _d="$_repo/.cache/$_tool/$_ver"
    mkdir -p "$_d"
    printf '#!/bin/sh\necho %s\n' "$_ver" > "$_d/$_tool"
    chmod +x "$_d/$_tool"
    _bin_sha=$(shasum -a 256 "$_d/$_tool" | cut -d' ' -f1)
    printf '%s\n%s\n' "$_bin_sha" "$_pinsha" > "$_d/.grubstake-sha256"
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

it "a binary replaced by one reporting the right version fails"
# The whole threat model: the cache is shared and mutable, so a version string is not proof.
r=$(new_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_B"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"
printf '#!/bin/sh\necho 0.63.2\necho pwned\n' > "$r/.cache/swiftlint/0.63.2/swiftlint"
chmod +x "$r/.cache/swiftlint/0.63.2/swiftlint"
expect_fail "$r" check

it "path refuses a poisoned binary as well as check"
r=$(new_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_B"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"
printf '#!/bin/sh\necho 0.63.2\n#x\n' > "$r/.cache/swiftlint/0.63.2/swiftlint"
chmod +x "$r/.cache/swiftlint/0.63.2/swiftlint"
expect_fail "$r" path swiftlint

it "editing a pin sha invalidates the install it produced"
# The stamp binds an install to the pin that made it, so correcting a hash cannot leave the old
# binary being served.
r=$(new_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_B"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"
pins "$r" "swiftlint 0.63.2 $SHA_B $SHA_B"
expect_fail "$r" check

it "an install with no digest recorded fails rather than being trusted"
r=$(new_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_B"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"; rm -f "$r/.cache/swiftlint/0.63.2/.grubstake-sha256"
expect_fail "$r" check

it "a missing binary fails"
r=$(new_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_B"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"; rm -f "$r/.cache/swiftlint/0.63.2/swiftlint"
expect_fail "$r" check

# ---------------------------------------------------------------------------- resolution

printf '\nresolution\n'

it "pins resolve from the script, not the working directory"
# This is the failure grubstake exists to prevent, and it was once present in grubstake: running
# one repo's script from inside another served the other repo's pins.
a=$(new_repo); b=$(new_repo)
pins "$a" "swiftlint 0.63.2 $SHA_A $SHA_B"; fake_install "$a" swiftlint 0.63.2 "$SHA_A"
pins "$b" "swiftlint 0.65.0 $SHA_A $SHA_B"; fake_install "$b" swiftlint 0.65.0 "$SHA_A"
out=$( cd "$b" && GRUBSTAKE_CACHE="$a/.cache" "$a/grubstake.sh" path swiftlint 2>&1 )
case "$out" in
    */0.63.2/*) pass ;;
    *) fail "served the wrong repo's pin: $out" ;;
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

it "a target that is not a release version is rejected"
r=$(new_repo); expect_fail "$r" update ../main

it "an already-current version is a no-op"
r=$(new_repo); v=$(gs "$r" version); expect_says "already on $v" "$r" update "$v"

it "replacing the script in place does not truncate it"
# A script that overwrites the file it is being read from stops silently. The replacement must
# be a rename, and the replacement here is deliberately longer than the original.
r=$(new_repo)
sed 's/^GRUBSTAKE_VERSION=.*/GRUBSTAKE_VERSION="0.0.9"/' "$GS" > "$r/installed.sh"
{ cat "$GS"; printf '# pad\n%.0s' 1 2 3 4 5 6 7 8 9 10; } > "$r/new.sh"
chmod +x "$r/installed.sh" "$r/new.sh"
( cd "$r" && ./new.sh __replace-self "$r/installed.sh" 9.9.9 >/dev/null 2>&1 )
if sh -n "$r/installed.sh" 2>/dev/null && [ "$(wc -c < "$r/installed.sh")" -ge "$(wc -c < "$GS")" ]; then
    pass
else
    fail "installed script was truncated or is not valid shell"
fi

it "replacing the script re-verifies the cache it inherits"
# The self-heal once resolved pins from the temp copy it was running as, so it silently skipped
# and left a repo whose next commit would be refused.
r=$(new_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_B"
mkdir -p "$r/.cache/swiftlint/0.63.2"
printf '#!/bin/sh\necho 0.63.2\n' > "$r/.cache/swiftlint/0.63.2/swiftlint"
chmod +x "$r/.cache/swiftlint/0.63.2/swiftlint"   # no stamp: an older install
cp "$GS" "$r/new.sh"; chmod +x "$r/new.sh"
out=$( cd "$r" && GRUBSTAKE_CACHE="$r/.cache" ./new.sh __replace-self "$r/grubstake.sh" 9.9.9 2>&1 )
case "$out" in
    *"re-verifying"*) pass ;;
    *) fail "self-heal did not run: $out" ;;
esac

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

    it "a real install passes check and reports its pinned version"
    r=$(new_repo); gs_rc "$r" add swiftlint@0.63.2
    if gs_rc "$r" check && [ "$(gs "$r" path swiftlint | xargs -I{} {} version)" = "0.63.2" ]; then
        pass
    else
        fail "install did not verify"
    fi

    it "ensure reinstalls an install that carries no digest"
    r=$(new_repo); gs_rc "$r" add swiftlint@0.63.2
    rm -f "$r/.cache/swiftlint/0.63.2/.grubstake-sha256"
    gs_rc "$r" ensure
    [ -f "$r/.cache/swiftlint/0.63.2/.grubstake-sha256" ] && pass || fail "digest not recorded"

    it "no staging directories are left in the cache"
    r=$(new_repo); gs_rc "$r" add swiftlint@0.63.2
    n=$(find "$r/.cache" -name '*.staging.*' | wc -l | tr -d ' ')
    [ "$n" = "0" ] && pass || fail "$n staging directories left behind"
else
    printf '\nadd, network  (skipped: pass --network to run)\n'
fi

# ---------------------------------------------------------------------------- result

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
