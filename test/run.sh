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

# The count must not depend on the line actually landing. This file exits via [ "$FAIL" -eq 0 ],
# so if the count were gated on the printf's own success (printf ... && FAIL=$((FAIL + 1))), a
# printf that fails to write -- a full disk, a reader that closed the pipe early -- would turn a
# real failure into FAIL=0 and exit 0 on a run the release gates on. Counting first means that same
# broken printf still leaves FAIL nonzero: the run goes red with an unexplained count instead of
# green with a hidden one. Confusing-but-red beats silent-but-green.
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

# fake_install alone cannot reach the #30 wedge: it writes straight to the hash-named directory and
# never calls install_tool, so publish_dir never runs. This fabricates a swiftlint release that
# install_tool itself will accept -- a zip, hashed for the pin file, holding a stand-in binary that
# reports the pinned version -- and a curl shim that serves it for any URL. Prints the sha to pin;
# the shim lands at "$1/curl-shim/curl", a fixed path so callers need no second return value.
# $3, optional: an exit status the fixture binary reports after printing its version, for exercising
# reported_version's own exit-status handling. Omitted by every existing caller, so the binary just
# echoes and returns 0 as before.
fake_release() {
    _repo="$1"; _ver="$2"; _exit="${3:-}"
    command -v zip >/dev/null 2>&1 || fixture_die "no zip to build the fixture release"
    case "$(uname -s)" in
        Darwin) _member=swiftlint ;;
        Linux)  _member=swiftlint-static ;;
        *)      fixture_die "fake_release: no fixture member name for $(uname -s)" ;;
    esac
    _src="$_repo/release-src"
    mkdir -p "$_src" || fixture_die "cannot create $_src"
    printf '#!/bin/sh\necho %s\n' "$_ver" > "$_src/$_member" || fixture_die "cannot write the fixture release binary"
    [ -n "$_exit" ] && { printf 'exit %s\n' "$_exit" >> "$_src/$_member" || fixture_die "cannot append the exit status to the fixture release binary"; }
    chmod +x "$_src/$_member" || fixture_die "cannot make the fixture release binary executable"
    _zip="$_repo/release.zip"
    ( cd "$_src" && zip -q "$_zip" "$_member" ) || fixture_die "cannot zip the fixture release"
    if command -v shasum >/dev/null 2>&1; then
        _sha="$(shasum -a 256 "$_zip" | awk '{print $1}')"
    elif command -v sha256sum >/dev/null 2>&1; then
        _sha="$(sha256sum "$_zip" | awk '{print $1}')"
    else
        fixture_die "no shasum or sha256sum to hash the fixture release"
    fi
    # awk exits 0 on empty input, so a shasum/sha256sum failure upstream would otherwise fall
    # through as an empty _sha and surface as a confusing downstream pin-validation failure instead
    # of naming the actual fixture fault.
    [ -n "$_sha" ] || fixture_die "cannot hash fixture zip"
    _shim="$_repo/curl-shim"
    mkdir -p "$_shim" || fixture_die "cannot create the fixture curl shim dir"
    cat > "$_shim/curl" <<SHIM
#!/bin/sh
_out=""; _prev=""
for a in "\$@"; do
    [ "\$_prev" = "-o" ] && _out="\$a"
    _prev="\$a"
done
[ -n "\$_out" ] || exit 1
cp "$_zip" "\$_out"
SHIM
    chmod +x "$_shim/curl" || fixture_die "cannot make the fixture curl shim executable"
    echo "$_sha"
}

# A deterministic stand-in for hoping a real race lands: any mkdir call ending in ".lock" --
# with_lock's own lock acquisition is the only mkdir shaped this way anywhere in grubstake.sh --
# blocks until $3 exists, running "$1/plant" first if the caller wrote one there. That gives a test
# a fixed point to attach a second process to instead of a window it has to get lucky to hit. The
# real mkdir's path is resolved once, here, against the unshimmed PATH this helper itself runs
# under, and baked into the generated script as a literal -- never re-resolved at runtime, or a
# shim earlier on the shimmed PATH would find itself and recurse.
lock_pause_shim() {
    _lpdir="$1"; _lpreached="$2"; _lpgo="$3"
    mkdir -p "$_lpdir" || fixture_die "cannot create the lock-pause shim dir $_lpdir"
    _lpreal="$(command -v mkdir)" || fixture_die "no real mkdir on PATH to wrap"
    cat > "$_lpdir/mkdir" <<SHIM
#!/bin/sh
case "\$*" in
    *.lock)
        [ -x "$_lpdir/plant" ] && "$_lpdir/plant" "\$@"
        : > "$_lpreached"
        _lpw=0
        while [ ! -f "$_lpgo" ]; do
            _lpw=\$((_lpw + 1))
            [ "\$_lpw" -gt 300 ] && { echo "lock-pause shim: timed out waiting for the go flag" >&2; exit 1; }
            sleep 0.05 2>/dev/null || sleep 1
        done
        ;;
esac
exec "$_lpreal" "\$@"
SHIM
    chmod +x "$_lpdir/mkdir" || fixture_die "cannot make the lock-pause mkdir shim executable"
}

# For tests that cannot pin the same hash in both columns because they read a hash `add` wrote
# for real over the network: a hardcoded column asserts against a path only one platform installs to.
sha_column() {
    case "$(uname -s)" in
        Darwin) echo 3 ;;
        Linux)  echo 4 ;;
        *)      fixture_die "sha_column: no pin column for $(uname -s)" ;;
    esac
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
# The cut point is derived from log()'s own byte offset rather than a raw literal: a hardcoded count
# is incidental to the current header length and would silently drift onto a clean, complete
# boundary (an exit-0 prefix that defines functions but calls none) if that header ever changed.
# Landing one byte past the opening quote of log()'s own format string is an unterminated quote for
# any format string, so drift in what follows that quote cannot close the gap the way a fixed-length
# offset into the match could.
_trunc_lit="log()  { printf '"
_trunc_anchor=$(grep -bo "^$_trunc_lit" "$GS" | head -1 | cut -d: -f1)
case "$_trunc_anchor" in ''|*[!0-9]*) fixture_die "cannot find the truncation anchor in $GS" ;; esac
r=$(new_repo); head -c "$((_trunc_anchor + ${#_trunc_lit} + 1))" "$GS" > "$r/trunc.sh"; chmod +x "$r/trunc.sh"
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
# git grep, not a filesystem grep with --include filters: the shipped hooks and the workflow YAML
# have no *.sh/*.md extension and were invisible to an extension-filtered scan, and scoping to
# tracked files means an untracked local file (a scratch note, an agent's own memory directory)
# cannot trip this test either. git grep exits 0 (match), 1 (no match), or 2+ (it could not scan
# at all, e.g. not a repo) -- collapsing every non-zero rc into "clean" would trade one silent
# pass for another, so a real scan failure has to stop the run rather than read as ok.
git -C "$(dirname "$0")/.." grep -qiE "tamper" -- . ':!test/run.sh'; _tamper_rc=$?
case "$_tamper_rc" in
    0) fail "something still claims tamper detection" ;;
    1) pass ;;
    *) fixture_die "git grep could not scan the tree for tamper claims (rc $_tamper_rc)" ;;
esac

it "a missing binary fails"
r=$(new_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"; rm -f "$r/.cache/swiftlint/$SHA_A/swiftlint"
expect_fail "$r" check

it "an install does not verify when the archived binary itself exits nonzero"
# reported_version's pipeline (tool | head | sed | tr) returns tr's exit status, not the tool's own.
# A binary that prints the pinned version and then fails still satisfies the assertion inside
# install_tool, so a tool that cannot actually run is published and reported installed anyway. This
# is the check AGENTS.md rule 3 exists for: the hash proves what arrived, and this is supposed to
# prove it runs. fake_install cannot reach this: it writes straight into the hash-named cache
# directory and never calls install_tool, so reported_version never runs; fake_release drives the
# real download-hash-extract-publish path against a fixture that reports the pinned version and
# then exits 42, offline.
r=$(new_repo)
_sha=$(fake_release "$r" 0.63.2 42)
pins "$r" "swiftlint 0.63.2 $_sha $_sha"
_out=$( cd "$r" && PATH="$r/curl-shim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
if [ "$_rc" -eq 0 ]; then
    fail "ensure exited 0 even though the archived binary itself exits nonzero: $_out"
else
    pass
fi

it "a partial cache directory does not wedge ensure"
# publish_dir treats any existing destination as a finished, concurrent install and discards the
# freshly downloaded, hash-verified staging instead of publishing into it. An interrupted publish, a
# stray mkdir, or a cache layout change across versions all leave exactly this: a destination that
# exists but holds no binary. ensure is documented to repair that, and today it cannot -- it dies
# "install incomplete" and every retry repeats it. fake_install cannot exercise this: it writes the
# binary straight to the hash-named directory and never calls install_tool, so publish_dir never
# runs. fake_release is what makes install_tool's real download-hash-extract-publish path run
# offline, against a fixture instead of the network.
r=$(new_repo)
_sha=$(fake_release "$r" 0.63.2)
pins "$r" "swiftlint 0.63.2 $_sha $_sha"
mkdir -p "$r/.cache/swiftlint/$_sha"   # the wedge itself: present, but never published into
_out=$( cd "$r" && PATH="$r/curl-shim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
if [ "$_rc" -ne 0 ]; then
    fail "ensure did not repair the partial directory (rc $_rc): $_out"
elif [ ! -x "$r/.cache/swiftlint/$_sha/swiftlint" ]; then
    fail "ensure exited 0 but never installed the binary: $_out"
else
    _crc=$( cd "$r" && GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh check >/dev/null 2>&1; echo $? )
    [ "$_crc" -eq 0 ] && pass || fail "ensure repaired the binary, but check still fails (rc $_crc)"
fi

it "ensure makes check pass from any recoverable state"
# This used to loop over absent/partial and call check alone in each -- never ensure -- which is why
# it never noticed that the partial state stays broken forever (see "a partial cache directory does
# not wedge ensure" above). That is what shipped #30: the test named for ensure's recovery contract
# never invoked ensure. fake_release stands in for the network the same way it does there, since a
# repair has to actually install to be proven.
for _case in absent partial; do
    r=$(new_repo)
    _sha=$(fake_release "$r" 0.63.2)
    pins "$r" "swiftlint 0.63.2 $_sha $_sha"
    case "$_case" in
        absent)  : ;;
        partial) mkdir -p "$r/.cache/swiftlint/$_sha" ;;
    esac
    _out=$( cd "$r" && PATH="$r/curl-shim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
    if [ "$_rc" -ne 0 ]; then
        fail "state '$_case': ensure exited $_rc: $_out"; _bad=1; break
    fi
    _crc=$( cd "$r" && GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh check >/dev/null 2>&1; echo $? )
    if [ "$_crc" -ne 0 ]; then
        fail "state '$_case': ensure exited 0 but check still fails afterward"; _bad=1; break
    fi
done
[ "${_bad:-0}" = 0 ] && pass; _bad=0

it "a read-only published entry does not defeat cache removal"
# Published entries are hardened read-only (chmod -R a-w), so a bare `rm -rf` on the cache root
# fails partway and leaves a half-removed tree for a human to clean up by hand -- exactly the
# scenario test/run.sh's own trap already works around. There is no `clean` command yet.
r=$(new_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"
chmod -R a-w "$r/.cache/swiftlint/$SHA_A"
# A no-op chmod (root, or a filesystem that ignores it) would let a naive rm -rf succeed and prove
# nothing about the hard case, the same trap "published entries are read-only" already guards
# against for the network add tests.
{ printf x >> "$r/.cache/swiftlint/$SHA_A/swiftlint"; } 2>/dev/null \
    && fixture_die "chmod -R a-w did not make $r/.cache/swiftlint/$SHA_A/swiftlint read-only (running as root?)"
_out=$(gs "$r" clean); _rc=$?
if [ "$_rc" -ne 0 ]; then
    fail "clean exited $_rc: $_out"
elif [ -d "$r/.cache" ]; then
    if [ -e "$r/.cache/swiftlint" ]; then
        fail "the cache root was left behind, read-only entry and all: $_out"
    else
        fail "the cache root still exists (though the read-only entry is gone): $_out"
    fi
else
    pass
fi

it "an unremovable partial directory fails loudly instead of nesting the staging"
# publish_dir's debris-clearing branch chmods the destination writable before removing it, but
# chmod cannot restore search (execute) permission it was never asked to add: chmod -R u+w on a
# subdirectory with no execute bit changes that subdirectory's own mode but still cannot descend
# into it, so whatever is inside stays exactly as unreachable as before. rm -rf then fails the same
# way, for the same reason. Pre-fix, rm -rf's exit status does not survive the `if "$@"` inside
# with_lock (see with_lock's own comment on that), the failure is swallowed, the destination still
# exists, and `mv staging dest` -- which nests rather than errors when dest is an existing directory,
# since there is no mv -T on macOS -- buries the freshly downloaded, hash-verified staging inside the
# debris instead of the install ever failing loudly.
r=$(new_repo)
_sha=$(fake_release "$r" 0.63.2)
pins "$r" "swiftlint 0.63.2 $_sha $_sha"
_dest="$r/.cache/swiftlint/$_sha"
mkdir -p "$_dest/debris"
printf 'x' > "$_dest/debris/file"
chmod 000 "$_dest/debris"   # no execute bit: chmod -R u+w cannot descend into it, and neither can rm -rf
_out=$( cd "$r" && PATH="$r/curl-shim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
# u+rwx, not just u+w: the suite's own EXIT trap only restores u+w, which is not enough to enter a
# directory that was never given execute permission in the first place, and would leave this debris
# behind forever otherwise.
chmod -R u+rwx "$_dest" 2>/dev/null
if [ "$_rc" -eq 0 ]; then
    fail "ensure exited 0 over a destination it could not clear: $_out"
elif find "$_dest" -mindepth 1 -maxdepth 1 -name '*staging*' 2>/dev/null | grep -q .; then
    fail "the staging directory was nested inside the debris instead of the install failing loudly: $_out"
else
    case "$_out" in
        *"$_dest"*) pass ;;
        *) fail "died without naming the directory to remove by hand: $_out" ;;
    esac
fi

it "a version-mismatch install does not leave a staging directory in the cache"
# The EXIT trap in install_tool covers $_tmp only, while staging is created outside it at
# $_dest.staging.$$. A version-mismatch die -- the pinned hash matches what arrived, but the
# archive's own binary reports a different version than the one pinned -- leaves the staging
# directory behind in the cache. The existing "no staging directories are left in the cache" test
# only exercises the success path. fake_release's binary reports 0.63.2; pinning it under a
# different version number gets the hash check to pass and the version check to fail.
r=$(new_repo)
_sha=$(fake_release "$r" 0.63.2)
pins "$r" "swiftlint 0.65.0 $_sha $_sha"
_out=$( cd "$r" && PATH="$r/curl-shim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
n=$(find "$r/.cache" -name '*.staging.*' 2>/dev/null | wc -l | tr -d ' ')
if [ "$_rc" -eq 0 ]; then
    fail "ensure exited 0 despite a version mismatch: $_out"
elif [ "$n" != "0" ]; then
    fail "$n staging directories left behind after the version-mismatch die: $_out"
else
    case "$_out" in
        *"pinned 0.65.0"*) pass ;;
        *) fail "died for an unexpected reason, not the version mismatch: $_out" ;;
    esac
fi

it "a space in the cache path does not break the cleanup trap"
# Contrast case for the single-quote test below: a trap string is shell source, re-parsed when it
# fires, so any value embedded in it has to survive that second parse regardless of what characters
# it holds. A plain space is not one of the characters that can break it, so this must stay green.
# Same version-mismatch shape as the "does not leave a staging directory" test above; only the
# cache path differs.
r=$(new_repo)
_sha=$(fake_release "$r" 0.63.2)
pins "$r" "swiftlint 0.65.0 $_sha $_sha"
_cache="$r/space cache"
mkdir -p "$_cache"
_out=$( cd "$r" && PATH="$r/curl-shim:$PATH" GRUBSTAKE_CACHE="$_cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
n=$(find "$_cache" -name '*.staging.*' 2>/dev/null | wc -l | tr -d ' ')
if [ "$_rc" -eq 0 ]; then
    fail "ensure exited 0 despite a version mismatch: $_out"
elif [ "$n" != "0" ]; then
    fail "$n staging directories left behind after the version-mismatch die (spaced cache path): $_out"
else
    case "$_out" in
        *"pinned 0.65.0"*) pass ;;
        *) fail "died for an unexpected reason, not the version mismatch: $_out" ;;
    esac
fi

it "a single quote in the cache path does not break the cleanup trap or leak the staging directory"
# A trap string is shell source, expanded once when the trap is set and re-parsed when it fires, so
# a value embedded in it has to survive that second parse regardless of what characters it holds
# (grubstake.sh's `sq` helper exists to guarantee that). A GRUBSTAKE_CACHE containing a literal ' is
# the minimal case that breaks a naive quoting scheme: it ends the quoting early, so the trap string
# the shell evaluates at EXIT is no longer valid syntax, and it errors instead of running rm -rf --
# the staging directory, holding the rejected binary, is never removed. Same version-mismatch shape
# as the "does not leave a staging directory" test above; only the cache path differs. A broken trap
# reports this as "Syntax error: Unterminated quoted string" under dash, or "unexpected EOF while
# looking for matching `''" under bash-as-sh (what /bin/sh resolves to on this machine) -- both
# patterns are checked, since either shell can run this script. The space-only case just above stays
# green: it is the quote character itself that breaks a naive scheme, not the space. This test only
# proves the trap does not error on the character; it does not prove no command runs -- see the
# compound-injection test below for that.
r=$(new_repo)
_sha=$(fake_release "$r" 0.63.2)
pins "$r" "swiftlint 0.65.0 $_sha $_sha"
_cache="$r/cache's dir"
mkdir -p "$_cache"
_out=$( cd "$r" && PATH="$r/curl-shim:$PATH" GRUBSTAKE_CACHE="$_cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
n=$(find "$_cache" -name '*.staging.*' 2>/dev/null | wc -l | tr -d ' ')
if [ "$_rc" -eq 0 ]; then
    fail "ensure exited 0 despite a version mismatch: $_out"
else
    case "$_out" in
        *"Unterminated quoted string"*|*"unexpected EOF"*|*"syntax error"*|*"Syntax error"*)
            fail "the cleanup trap itself errored on the quoted cache path: $_out" ;;
        *)
            if [ "$n" != "0" ]; then
                fail "$n staging directories left behind after the version-mismatch die (quoted cache path): $_out"
            else
                case "$_out" in
                    *"pinned 0.65.0"*) pass ;;
                    *) fail "died for an unexpected reason, not the version mismatch: $_out" ;;
                esac
            fi
            ;;
    esac
fi

it "a hostile GRUBSTAKE_CACHE cannot inject commands into install's cleanup trap"
# Apostrophe-survival (above) proves the trap does not error on a quote; it does not prove no
# command runs, since a scheme that merely tolerates the character without properly closing and
# reopening the quoting can still be broken by a value that goes further. This is the same
# version-mismatch die as the tests above, but GRUBSTAKE_CACHE is crafted the way an attacker would
# craft it: close the quote, add a command, reopen a quote, so the staging directory's own path
# carries the payload. If the trap ever re-parses this as more than a single quoted argument to
# rm -rf, SENTINEL gets created; sq() (grubstake.sh) exists to prevent exactly that.
r=$(new_repo)
_sha=$(fake_release "$r" 0.63.2)
pins "$r" "swiftlint 0.65.0 $_sha $_sha"
_sentinel="$r/SENTINEL"
_cache="$r/cache'; touch \"$_sentinel\"; echo '"
mkdir -p "$_cache"
_out=$( cd "$r" && PATH="$r/curl-shim:$PATH" GRUBSTAKE_CACHE="$_cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
n=$(find "$_cache" -name '*.staging.*' 2>/dev/null | wc -l | tr -d ' ')
if [ -e "$_sentinel" ]; then
    fail "the injected command ran: SENTINEL was created via install's cleanup trap"
elif [ "$_rc" -eq 0 ]; then
    fail "ensure exited 0 despite a version mismatch: $_out"
elif [ "$n" != "0" ]; then
    fail "$n staging directories left behind after the version-mismatch die (injection-payload cache path): $_out"
else
    case "$_out" in
        *"pinned 0.65.0"*) pass ;;
        *) fail "died for an unexpected reason, not the version mismatch: $_out" ;;
    esac
fi

it "clean refuses a symlinked cache root rather than lying about removal"
# rm -rf on a symlink unlinks the link itself and leaves whatever it points at completely untouched,
# while still reporting success -- so a `clean` built on a bare `rm -rf "$GRUBSTAKE_CACHE"` would
# exit 0 and claim the cache was removed while every published entry survives at the real path.
r=$(new_repo)
_real="$r/real-cache"
mkdir -p "$_real/swiftlint/$SHA_A"
printf '#!/bin/sh\necho 0.63.2\n' > "$_real/swiftlint/$SHA_A/swiftlint"
chmod +x "$_real/swiftlint/$SHA_A/swiftlint"
_link="$r/.cache-link"
ln -s "$_real" "$_link"
_out=$( cd "$r" && GRUBSTAKE_CACHE="$_link" ./grubstake.sh clean 2>&1 ); _rc=$?
if [ "$_rc" -eq 0 ]; then
    fail "clean exited 0 on a symlinked cache root: $_out"
elif [ ! -x "$_real/swiftlint/$SHA_A/swiftlint" ]; then
    fail "the symlink's target was touched even though clean refused: $_out"
else
    case "$_out" in
        *"$_link"*) pass ;;
        *) fail "refused without naming the symlink: $_out" ;;
    esac
fi

it "clean refuses a degenerate cache root"
# GRUBSTAKE_CACHE is used verbatim, so a value that is neither empty nor literally "/" but still
# resolves to the filesystem root -- ".." above root is root again, so "/.." does -- has to be caught
# by the same guard that already refuses "" and "/", or clean reaches chmod -R and rm -rf on the
# entire filesystem. Both are shimmed to record their invocation instead of running for real: even
# wrapped in `|| true`, a real chmod -R u+w / is itself destructive and slow, so trusting a live rm's
# exit status alone is not enough -- a real rm can also fail non-zero for an unrelated permission
# reason and look like a refusal that never happened. The assertion is that neither command was ever
# reached, not that whichever one ran happened to fail.
r=$(new_repo)
_shim="$r/danger-shim"; mkdir -p "$_shim"
_record="$r/danger.invoked"
cat > "$_shim/chmod" <<SHIM
#!/bin/sh
printf 'chmod %s\n' "\$*" >> "$_record"
exit 0
SHIM
cat > "$_shim/rm" <<SHIM
#!/bin/sh
printf 'rm %s\n' "\$*" >> "$_record"
exit 0
SHIM
chmod +x "$_shim/chmod" "$_shim/rm"
_out=$( cd "$r" && PATH="$_shim:$PATH" GRUBSTAKE_CACHE="/.." ./grubstake.sh clean 2>&1 ); _rc=$?
if [ "$_rc" -eq 0 ]; then
    fail "clean exited 0 for GRUBSTAKE_CACHE=/..: $_out"
elif [ -f "$_record" ]; then
    fail "the guard let a destructive command run before refusing: $(cat "$_record")"
else
    pass
fi

it "clean racing a concurrent ensure fails fast with the real cause, not a five-second stale-lock stall"
# #56: clean renames the cache root aside mid-install (see the comment on the mv above), and
# with_lock's mkdir cannot tell its own ENOENT (the parent just vanished) apart from EEXIST (a real
# lock held by another run) -- both just fail the mkdir. Pre-fix it spins the full 50-iteration,
# five-second retry budget and then dies blaming a stale lock that was never there. A legacy
# (receiptless) entry reaches with_lock the cheapest way: no download, no staging, just
# install_tool's own write_receipt call, so lock_pause_shim's mkdir pause lands exactly at the
# mkdir that matters without needing a real download race to get there.
r=$(new_repo)
pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"
_shim="$r/mkdir-shim"; _reached="$r/reached"; _go="$r/go"
lock_pause_shim "$_shim" "$_reached" "$_go"
( cd "$r" && PATH="$_shim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure >"$r/out" 2>&1; echo $? > "$r/rc" ) &
_bgpid=$!
_w=0
while [ ! -f "$_reached" ]; do
    _w=$((_w + 1))
    [ "$_w" -gt 300 ] && fixture_die "ensure never reached the lock point"
    sleep 0.05 2>/dev/null || sleep 1
done
_cleanout=$( cd "$r" && GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh clean 2>&1 ); _cleanrc=$?
[ "$_cleanrc" -eq 0 ] || fixture_die "clean itself failed while racing ensure: $_cleanout"
[ -e "$r/.cache" ] && fixture_die "clean did not actually remove the cache root; the race window is not real"
_t0=$(date +%s)
: > "$_go"
wait "$_bgpid" 2>/dev/null
_t1=$(date +%s)
[ -f "$r/rc" ] || fixture_die "the backgrounded ensure never recorded an exit status"
_rc="$(cat "$r/rc")"
_elapsed=$((_t1 - _t0))
_out="$(cat "$r/out" 2>/dev/null)"
if [ "$_rc" -eq 0 ]; then
    fail "ensure exited 0 racing clean: $_out"
elif [ "$_elapsed" -ge 3 ]; then
    fail "ensure spun ${_elapsed}s instead of failing fast when its cache root vanished mid-lock: $_out"
elif printf '%s' "$_out" | grep -qi "stale? rmdir it"; then
    fail "misdiagnosed a vanished cache root as another run's stale lock: $_out"
elif printf '%s' "$_out" | grep -qi "archive contains"; then
    fail "misdiagnosed a vanished cache root as a corrupt archive: $_out"
elif ! printf '%s' "$_out" | grep -Eqi "cache|root|gone|removed|disappear"; then
    fail "failed fast without naming the real cause: $_out"
else
    pass
fi

# ---------------------------------------------------------------------------- cache integrity: receipts
#
# #47: publish_dir's winner branch is "[ -x dest/tool ]" alone, so a corrupted-but-executable dest
# is trusted without ever re-reading what arrived. These tests are written against the receipt
# design in #47/#2 before it exists: a three-line .grubstake-receipt ("receipt 1" / binary-sha256 /
# version) staged before publish so it rides the atomic mv and is hardened read-only with the rest
# of the entry.
#
# Design correction: the first receipt design repaired a mismatched or receiptless entry by
# destroying it in place (rm -rf, then republish), which an antagonist pass showed briefly removes
# the hash-named path -- a second repo sharing the same machine-wide cache and executing that path
# saw ENOENT partway through, 9/40 iterations. publish_dir now only ever clears an entry with no
# executable at all (debris, exactly as before receipts existed); a mismatch is install_tool's
# refusal to make, never publish_dir's repair to attempt, and a legacy or skewed-format receipt is
# written beside the existing binary in place, offline, never by destroying and redownloading it.

printf '\ncache integrity: receipts\n'

# Independent of grubstake.sh's own sha256_file, so a fixture never leans on the code under test to
# build its own expectations.
sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        fixture_die "no shasum or sha256sum to hash $1"
    fi
}

# A well-formed receipt beside a binary a test has already placed at $1/$2: "receipt 1", that
# binary's own sha256, then the given version. fake_install builds the receiptless shape a
# pre-receipt release leaves behind; this is what the same layout looks like once a receipt has
# been written beside it.
fake_receipt() {
    _dir="$1"; _tool="$2"; _ver="$3"
    printf 'receipt 1\nbinary-sha256 %s\nversion %s\n' "$(sha256_of "$_dir/$_tool")" "$_ver" > "$_dir/.grubstake-receipt"
}

# Sourcing the script would run main and exit, so pull the functions under test out by name. The
# sed ranges are keyed to exact brace formatting: move an opening brace to the next line and the
# extraction silently yields nothing, the generated script exits 127 without ever calling the
# function, and a test that only checks for the absence of a lock directory reports ok. An empty
# or truncated extraction is a harness fault, not a result, so it stops the run.
#
# publish_dir consults neither entry_verified nor a receipt: its winner rule is bare executable
# existence, deliberately, after three antagonist rounds fought over exactly this -- a mismatch is
# surfaced by install_tool's own deeper pass before publish_dir is ever reached, never repaired by
# publish_dir itself, so a live binary is never cleared out from under a concurrent reader. That
# keeps with_lock and publish_dir the whole call graph; neither reaches sha256_file, receipt_file,
# or entry_verified, so extracting those would carry dead weight into the generated script. Defined
# here, ahead of every caller in the file (the update section's included), since the earliest of
# those callers is the receipt tests just below.
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

it "ensure refuses a binary that no longer matches its receipt, rather than reinstalling over it"
# The original design repaired a mismatch by reinstalling over the existing entry: rm -rf the
# destination, then mv a freshly downloaded copy into place. A second repo already resolved to that
# path and executing it in a loop saw ENOENT in the gap between the two (an antagonist pass
# reproduced it 9/40 iterations; see "two repos sharing one cache: a legacy upgrade must not break a
# concurrent exec" below). Since the cache is machine-wide and another repo may be running this
# exact binary right now, ensure now refuses and tells the human what to do instead of touching it.
# fake_install cannot reach this: it never leaves a genuine receipt to mismatch, so fake_release
# seeds a real one via a real (offline) install first.
r=$(new_repo)
_sha=$(fake_release "$r" 0.63.2)
pins "$r" "swiftlint 0.63.2 $_sha $_sha"
_out=$( cd "$r" && PATH="$r/curl-shim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
[ "$_rc" -eq 0 ] || fixture_die "cannot seed a clean install to tamper with (rc $_rc): $_out"
_d="$r/.cache/swiftlint/$_sha"
_bin="$_d/swiftlint"
_receipt="$_d/.grubstake-receipt"
chmod u+w "$_bin"
printf '#!/bin/sh\necho tampered\n' > "$_bin"
chmod +x "$_bin"
_bin_before="$(cat "$_bin")"
_inode_before="$(ls -i "$_bin" | awk '{print $1}')"
_receipt_before="$(cat "$_receipt")"
_out=$( cd "$r" && PATH="$r/curl-shim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
_bin_after="$(cat "$_bin" 2>/dev/null)"
_inode_after="$(ls -i "$_bin" 2>/dev/null | awk '{print $1}')"
_receipt_after="$(cat "$_receipt" 2>/dev/null)"
if [ "$_rc" -eq 0 ]; then
    fail "ensure exited 0 over a binary that no longer matches its receipt: $_out"
elif ! printf '%s' "$_out" | grep -q "does not match its receipt"; then
    fail "refused, but without a receipt-mismatch warning: $_out"
elif ! printf '%s' "$_out" | grep -F -q "$_d"; then
    fail "refused, but did not name the entry's directory: $_out"
elif ! printf '%s' "$_out" | grep -Eqi "clean|remove"; then
    fail "refused, but did not tell the user how to recover (expected 'clean' or 'remove'): $_out"
elif [ "$_bin_after" != "$_bin_before" ]; then
    fail "the binary's bytes changed even though ensure refused: $_out"
elif [ "$_inode_after" != "$_inode_before" ]; then
    fail "the binary was unlinked and rebuilt (inode changed) even though ensure refused -- this is the destroy-in-place hazard: $_out"
elif [ "$_receipt_after" != "$_receipt_before" ]; then
    fail "the receipt itself was rewritten even though ensure refused to touch the entry: $_out"
else
    pass
fi

it "a legacy entry is upgraded to a receipt without ceremony"
# The receipt is written beside the existing binary in place, offline: no download, no destroy.
# AGENTS.md 2 already covers what arrived over the network; this only records the hash of what is
# already trusted on disk, for next time -- there is nothing left here for fake_release's real
# (if offline) install cycle to exercise, so fake_install's plain receiptless entry is enough. A
# curl that always fails is put on PATH deliberately, not curl's mere absence, so a version that
# quietly reaches the real network to "reinstall" fails loudly here instead of leaving this test
# green by accident.
r=$(new_repo)
pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"   # receiptless: exactly what a pre-receipt release left behind
_bin="$r/.cache/swiftlint/$SHA_A/swiftlint"
_bin_before="$(cat "$_bin")"
_inode_before="$(ls -i "$_bin" | awk '{print $1}')"
_shims="$(mktemp -d "$ROOT/legacy-no-net.XXXXXX")" || fixture_die "cannot create a scratch dir for the network shim"
printf '#!/bin/sh\necho "curl: network blocked in test" >&2\nexit 6\n' > "$_shims/curl"
chmod +x "$_shims/curl"
_out=$( cd "$r" && PATH="$_shims:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
_receipt="$r/.cache/swiftlint/$SHA_A/.grubstake-receipt"
_bin_after="$(cat "$_bin" 2>/dev/null)"
_inode_after="$(ls -i "$_bin" 2>/dev/null | awk '{print $1}')"
if [ "$_rc" -ne 0 ]; then
    fail "ensure refused a legacy entry that merely predates receipts, even with no network reachable (rc $_rc): $_out"
elif [ ! -f "$_receipt" ]; then
    fail "ensure did not write a receipt for the legacy entry: $_out"
elif printf '%s' "$_out" | grep -q "does not match its receipt"; then
    fail "a legacy entry with no receipt was reported as receipt-mismatched, not upgraded: $_out"
elif [ "$(awk '/^binary-sha256/{print $2}' "$_receipt" 2>/dev/null)" != "$(sha256_of "$_bin")" ]; then
    fail "the receipt does not record the on-disk binary's own hash: $(cat "$_receipt" 2>/dev/null)"
elif [ "$_bin_after" != "$_bin_before" ]; then
    fail "the binary's bytes changed even though nothing should have reinstalled it: $_out"
elif [ "$_inode_after" != "$_inode_before" ]; then
    fail "the binary was replaced (inode changed) even though the receipt was supposed to be written in place: $_out"
elif find "$r/.cache/swiftlint/$SHA_A" -maxdepth 1 -name '.grubstake-receipt.tmp.*' 2>/dev/null | grep -q .; then
    fail "a temp receipt file from the atomic write was left behind: $_out"
else
    pass
fi

it "check is not blocked by an entry that predates receipts"
# The incident guard from CONTRIBUTING.md's "When a fix changes behaviour on upgrade": cache
# verification once landed without accounting for existing caches carrying no digest, and the first
# check after upgrading refused every commit until someone ran ensure. verify_tool/check stay
# existence-only on purpose, so a receiptless legacy entry must pass check the moment this design
# lands, not just after ensure re-touches it. This passes today; see the scratch proof in this
# dispatch's report that a version requiring a receipt inside verify_tool makes it fail, per
# AGENTS.md rule 14.
r=$(new_repo)
pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"   # no receipt: exactly what a pre-receipt release left behind
expect_ok "$r" check

it "publish_dir never clears an entry whose binary exists"
# Inverted after the design correction above: publish_dir no longer repairs a mismatched-receipt
# winner in place -- that destroy-then-republish is exactly what opened the ENOENT window for a
# concurrent repo (see "two repos sharing one cache: a legacy upgrade must not break a concurrent
# exec" below). The winner rule is executable-presence alone now, same as before receipts existed; a
# mismatch is install_tool's refusal to make (see "ensure refuses a binary that no longer matches its
# receipt, rather than reinstalling over it" above), never publish_dir's to touch.
r=$(new_repo)
_d="$r/dest"; _st="$r/dest.staging.333"
mkdir -p "$_st"; printf 'staged-bytes' > "$_st/swiftlint"; chmod +x "$_st/swiftlint"
mkdir -p "$_d"; printf 'original-bytes' > "$_d/swiftlint"; chmod +x "$_d/swiftlint"
fake_receipt "$_d" swiftlint 0.63.2
printf 'corrupted-bytes' > "$_d/swiftlint"   # mismatched: bytes no longer match the receipt beside them
{ extract_fns; echo 'die() { echo "$1" >&2; exit 1; }'; echo 'warn() { echo "WARN: $1" >&2; }'; echo 'publish_dir "$1" "$2" "$3"'; } > "$r/t.sh"
_out=$( cd "$r" && sh "$r/t.sh" "$_st" "$_d" swiftlint 2>&1 ); _rc=$?
_after="$(cat "$_d/swiftlint" 2>/dev/null)"
if [ "$_rc" -ne 0 ]; then
    fail "the generated script exited $_rc, so publish_dir did not run: $_out"
elif [ -e "$_st" ]; then
    fail "the staging directory was not discarded: $_st still exists"
elif [ "$_after" != "corrupted-bytes" ]; then
    fail "the existing binary was replaced even though it still exists at the hash-named path: $_out"
elif printf '%s' "$_out" | grep -q "does not match its receipt"; then
    fail "publish_dir still warns about (and by implication repairs) a mismatched receipt: $_out"
else
    pass
fi
chmod -R u+w "$r" 2>/dev/null

it "the receipt rides publish and is read-only"
r=$(new_repo)
_sha=$(fake_release "$r" 0.63.2)
pins "$r" "swiftlint 0.63.2 $_sha $_sha"
_out=$( cd "$r" && PATH="$r/curl-shim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
_d="$r/.cache/swiftlint/$_sha"
_receipt="$_d/.grubstake-receipt"
if [ "$_rc" -ne 0 ]; then
    fail "ensure did not even install cleanly (rc $_rc): $_out"
elif [ ! -f "$_receipt" ]; then
    fail "no receipt was written beside the published binary: $_out"
elif [ "$(sed -n 1p "$_receipt")" != "receipt 1" ]; then
    fail "the receipt's first line was not 'receipt 1': $(cat "$_receipt" 2>/dev/null)"
elif [ "$(awk '/^binary-sha256/{print $2}' "$_receipt")" != "$(sha256_of "$_d/swiftlint")" ]; then
    fail "the receipt's sha does not match the published binary: $(cat "$_receipt" 2>/dev/null)"
else
    # A no-op chmod (root, or a filesystem that ignores it) would let a naive append succeed and
    # prove nothing, the same trap "a read-only published entry does not defeat cache removal" above
    # already guards against for the binary itself.
    { printf x >> "$_receipt"; } 2>/dev/null \
        && fixture_die "chmod -R a-w did not make $_receipt read-only (running as root?)"
    pass
fi

it "editing a pin's version does not relabel a binary that never reported it"
# AGENTS.md 3: a tool has to report the version it was pinned to, since the hash only proves what
# arrived. Relabeling a receipt straight from the pin, with no check against the binary, would let
# grubstake claim a version the installed binary has never been shown to have -- exactly the
# scenario "a version-only receipt edit is corrected in place, not re-fetched" below must NOT also
# accept: there, the binary genuinely reports the newly pinned version, so the receipt's line is
# what was stale. Here, only the pin changed underneath an unchanged hash and an unchanged binary,
# so the binary still reports the OLD version, and the entry must be refused, not relabeled. No curl
# is reachable, so a refusal reached without ever attempting a download is what proves this is
# install_tool's own reported_version assertion firing, not a network failure standing in for it.
r=$(new_repo)
_sha=$(fake_release "$r" 0.63.2)
pins "$r" "swiftlint 0.63.2 $_sha $_sha"
_out=$( cd "$r" && PATH="$r/curl-shim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
[ "$_rc" -eq 0 ] || fixture_die "cannot seed a clean install to edit the pin against (rc $_rc): $_out"
_d="$r/.cache/swiftlint/$_sha"
_bin="$_d/swiftlint"
_receipt="$_d/.grubstake-receipt"
_bin_before="$(cat "$_bin")"
_inode_before="$(ls -i "$_bin" | awk '{print $1}')"
_receipt_before="$(cat "$_receipt")"
pins "$r" "swiftlint 0.65.0 $_sha $_sha"   # same hash, edited version: the binary never became 0.65.0
_shims="$(mktemp -d "$ROOT/no-net-version-refuse.XXXXXX")" || fixture_die "cannot create a scratch dir for the network shim"
printf '#!/bin/sh\necho "curl: network blocked in test" >&2\nexit 6\n' > "$_shims/curl"
chmod +x "$_shims/curl"
_out=$( cd "$r" && PATH="$_shims:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
_bin_after="$(cat "$_bin" 2>/dev/null)"
_inode_after="$(ls -i "$_bin" 2>/dev/null | awk '{print $1}')"
_receipt_after="$(cat "$_receipt" 2>/dev/null)"
if [ "$_rc" -eq 0 ]; then
    fail "ensure exited 0 after the pin's version changed under an unchanged hash: a binary the pin never verified was relabeled: $_out"
elif ! printf '%s' "$_out" | grep -q "0.63.2"; then
    fail "refused, but did not name the version the binary actually reports: $_out"
elif ! printf '%s' "$_out" | grep -q "0.65.0"; then
    fail "refused, but did not name the newly pinned version: $_out"
elif [ "$_receipt_after" != "$_receipt_before" ]; then
    fail "the receipt was relabeled even though the binary never reported the newly pinned version: $(cat "$_receipt" 2>/dev/null)"
elif [ "$_bin_after" != "$_bin_before" ]; then
    fail "the binary's bytes changed even though nothing should have been re-fetched: $_out"
elif [ "$_inode_after" != "$_inode_before" ]; then
    fail "the binary was replaced (inode changed) even though ensure refused: $_out"
else
    pass
fi

it "a version-only receipt edit is corrected in place, not re-fetched"
# The version-mismatch path used to warn and "reinstall": a real download, verified, staged, and
# handed to publish_dir -- which discards that fresh staging outright, since the existing binary at
# this hash-named path already makes it the winner (see "publish_dir never clears an entry whose
# binary exists" above). The wrong version line could therefore never actually be corrected; the
# download and the warning would repeat, forever, on every single ensure. Now, when the binary still
# matches its receipt and only the version line disagrees with the pin, the receipt is rewritten in
# place instead -- no download at all, so no curl shim is put on PATH for the corrective run: any
# attempt to reach one fails hard rather than silently reaching this sandbox's real network.
r=$(new_repo)
_sha=$(fake_release "$r" 0.63.2)
pins "$r" "swiftlint 0.63.2 $_sha $_sha"
_out=$( cd "$r" && PATH="$r/curl-shim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
[ "$_rc" -eq 0 ] || fixture_die "cannot seed a clean install to edit the receipt against (rc $_rc): $_out"
_d="$r/.cache/swiftlint/$_sha"
_bin="$_d/swiftlint"
_receipt="$_d/.grubstake-receipt"
_bin_before="$(cat "$_bin")"
_inode_before="$(ls -i "$_bin" | awk '{print $1}')"
chmod u+w "$_d" 2>/dev/null
# Tamper only the receipt's version line, not the pin and not the binary: the pin still correctly
# says 0.63.2, and the binary still hashes to what the receipt's own binary-sha256 line records.
sed 's/^version .*/version 0.60.0/' "$_receipt" > "$_receipt.tmp" && mv "$_receipt.tmp" "$_receipt"
_shims="$(mktemp -d "$ROOT/no-net-version-fix.XXXXXX")" || fixture_die "cannot create a scratch dir for the network shim"
printf '#!/bin/sh\necho "curl: network blocked in test" >&2\nexit 6\n' > "$_shims/curl"
chmod +x "$_shims/curl"
_out=$( cd "$r" && PATH="$_shims:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
_bin_after="$(cat "$_bin" 2>/dev/null)"
_inode_after="$(ls -i "$_bin" 2>/dev/null | awk '{print $1}')"
_rver="$(awk '/^version/{print $2}' "$_receipt" 2>/dev/null)"
if [ "$_rc" -ne 0 ]; then
    fail "ensure did not correct a version-only receipt edit with no network reachable (rc $_rc): $_out"
elif [ "$_rver" != "0.63.2" ]; then
    fail "the receipt's version line was not corrected to the pinned version: $(cat "$_receipt" 2>/dev/null)"
elif [ "$_bin_after" != "$_bin_before" ]; then
    fail "the binary's bytes changed even though nothing should have been re-fetched: $_out"
elif [ "$_inode_after" != "$_inode_before" ]; then
    fail "the binary was replaced (inode changed) instead of the receipt being rewritten in place: $_out"
else
    _out2=$( cd "$r" && PATH="$_shims:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc2=$?
    if [ "$_rc2" -ne 0 ]; then
        fail "a second ensure over the now-corrected entry failed (rc $_rc2): $_out2"
    elif printf '%s' "$_out2" | grep -qE "updated the receipt to pinned|entry records version"; then
        fail "the version-mismatch warning repeated on a second ensure over an already-corrected entry: $_out2"
    else
        pass
    fi
fi

it "an unknown receipt format is skew, not tampering"
# A receipt in a format this version does not recognize is not evidence the bytes changed, so it now
# takes the same offline, in-place path as a legacy receiptless entry (see "a legacy entry is
# upgraded to a receipt without ceremony" above) -- rewritten beside the existing binary, never a
# reason to reinstall -- rather than the refusal a genuine hash mismatch gets.
r=$(new_repo)
pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"
_d="$r/.cache/swiftlint/$SHA_A"
_bin="$_d/swiftlint"
fake_receipt "$_d" swiftlint 0.63.2
sed 's/^receipt 1/receipt 2/' "$_d/.grubstake-receipt" > "$_d/.grubstake-receipt.tmp" \
    && mv "$_d/.grubstake-receipt.tmp" "$_d/.grubstake-receipt"
_bin_before="$(cat "$_bin")"
_inode_before="$(ls -i "$_bin" | awk '{print $1}')"
_shims="$(mktemp -d "$ROOT/skew-no-net.XXXXXX")" || fixture_die "cannot create a scratch dir for the network shim"
printf '#!/bin/sh\necho "curl: network blocked in test" >&2\nexit 6\n' > "$_shims/curl"
chmod +x "$_shims/curl"
_out=$( cd "$r" && PATH="$_shims:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
_bin_after="$(cat "$_bin" 2>/dev/null)"
_inode_after="$(ls -i "$_bin" 2>/dev/null | awk '{print $1}')"
if [ "$_rc" -ne 0 ]; then
    fail "ensure refused an unrecognized receipt format, even with no network reachable (rc $_rc): $_out"
elif printf '%s' "$_out" | grep -q "does not match its receipt"; then
    fail "an unrecognized receipt format was reported as a receipt mismatch, not skew: $_out"
elif [ "$(sed -n 1p "$_d/.grubstake-receipt" 2>/dev/null)" != "receipt 1" ]; then
    fail "ensure did not record a format-1 receipt over the skewed one: $(cat "$_d/.grubstake-receipt" 2>/dev/null)"
elif [ "$_bin_after" != "$_bin_before" ]; then
    fail "the binary's bytes changed even though nothing should have reinstalled it: $_out"
elif [ "$_inode_after" != "$_inode_before" ]; then
    fail "the binary was replaced (inode changed) instead of the receipt being rewritten in place: $_out"
elif find "$_d" -maxdepth 1 -name '.grubstake-receipt.tmp.*' 2>/dev/null | grep -q .; then
    fail "a temp receipt file from the atomic write was left behind: $_out"
else
    pass
fi

it "an interrupted or failed backfill leaves no half-written receipt"
# The backfill write is atomic: the hash is computed and validated as 64 hex first, then written to
# a .tmp.$$ path inside the entry and mv'd over -- so a hash tool that fails mid-backfill has to
# leave the entry exactly as it was, never a receipt recording an empty or partial hash that the next
# run reads as a mismatch and refuses forever (see "ensure refuses a binary that no longer matches
# its receipt, rather than reinstalling over it" above -- a self-inflicted version of that same
# wedge). Shadowing shasum and sha256sum with a stub that exits 1 keeps sha256_file's own
# `command -v` checks satisfied, so it takes its normal branch instead of dying outright, while the
# actual hash still comes out empty: a pipeline reports its last command's exit status, not the
# shadowed tool's, the same gotcha reported_version's own comment documents.
r=$(new_repo)
pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"   # receiptless: legacy, exactly what triggers a backfill
_d="$r/.cache/swiftlint/$SHA_A"
_bin="$_d/swiftlint"
_receipt="$_d/.grubstake-receipt"
_shims="$(mktemp -d "$ROOT/no-hash-tools.XXXXXX")" || fixture_die "cannot create a scratch dir for the hash-tool shims"
printf '#!/bin/sh\nexit 1\n' > "$_shims/shasum"
printf '#!/bin/sh\nexit 1\n' > "$_shims/sha256sum"
chmod +x "$_shims/shasum" "$_shims/sha256sum"
_out=$( cd "$r" && PATH="$_shims:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
_leftover=$(find "$_d" -maxdepth 1 -name '.grubstake-receipt.tmp.*' 2>/dev/null | wc -l | tr -d ' ')
if [ "$_rc" -ne 0 ]; then
    fail "ensure exited $_rc when the hash tool merely failed, instead of leaving the entry alone: $_out"
elif [ -f "$_receipt" ]; then
    fail "a receipt was written from a failed hash: $(cat "$_receipt" 2>/dev/null)"
elif [ "$_leftover" != "0" ]; then
    fail "a temp receipt file from the failed backfill was left behind: $_out"
elif ! printf '%s' "$_out" | grep -q "swiftlint"; then
    fail "the failed hash said nothing about which entry it could not record for: $_out"
else
    # The important part: the entry is still usable, not permanently wedged, once hashing works again.
    _out2=$( cd "$r" && GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc2=$?
    if [ "$_rc2" -ne 0 ]; then
        fail "a second ensure with hashing restored still failed (rc $_rc2) -- the failed hash wedged the entry: $_out2"
    elif [ ! -f "$_receipt" ]; then
        fail "a second ensure with hashing restored exited 0 but still never recorded a receipt: $_out2"
    else
        pass
    fi
fi

it "a receipt mismatch on one tool does not stop ensure from verifying the rest"
# Go's "go mod verify" model: report every failure, exit non-zero once, rather than stopping at the
# first. A mismatch now warns naming the entry and continues to the remaining pinned tools; ensure
# only exits non-zero once everything has been attempted. swiftlint is pinned first and tampered
# after a real (offline) install, so it has a genuine receipt to mismatch; swiftformat is pinned
# second as a plain receiptless legacy entry, which converges with no download needed, so its receipt
# appearing is unambiguous evidence ensure reached it rather than stopping at swiftlint. pinned_tools
# reads grubstake.tools in file order and pins() here writes exactly what it is given, so swiftlint
# has to be first in the fixture or a healthy second tool being processed proves nothing about
# continuation.
r=$(new_repo)
_sha=$(fake_release "$r" 0.63.2)
# swiftformat is not pinned yet for this first, seeding install: pinning it alongside swiftlint here
# would send ensure's loop to actually try downloading it too, and the curl shim always serves the
# swiftlint fixture zip regardless of URL, which does not hash to swiftformat's arbitrary SHA_B.
pins "$r" "swiftlint 0.63.2 $_sha $_sha"
_out=$( cd "$r" && PATH="$r/curl-shim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
[ "$_rc" -eq 0 ] || fixture_die "cannot seed a clean swiftlint install to tamper with (rc $_rc): $_out"
_lint_d="$r/.cache/swiftlint/$_sha"
chmod u+w "$_lint_d/swiftlint"
printf '#!/bin/sh\necho tampered\n' > "$_lint_d/swiftlint"
chmod +x "$_lint_d/swiftlint"
fake_install "$r" swiftformat 0.61.1 "$SHA_B"   # receiptless legacy entry: converges offline, no curl needed
pins "$r" "swiftlint 0.63.2 $_sha $_sha
swiftformat 0.61.1 $SHA_B $SHA_B"
_fmt_receipt="$r/.cache/swiftformat/$SHA_B/.grubstake-receipt"
_out=$( cd "$r" && GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
if [ "$_rc" -eq 0 ]; then
    fail "ensure exited 0 despite a tampered swiftlint entry: $_out"
elif ! printf '%s' "$_out" | grep -F -q "$_lint_d"; then
    fail "the mismatch was reported without naming swiftlint's entry: $_out"
elif [ ! -f "$_fmt_receipt" ]; then
    fail "ensure stopped at swiftlint's mismatch instead of continuing: swiftformat was never reached, no receipt recorded: $_out"
else
    pass
fi

# ---------------------------------------------------------------------------- cache integrity: shared cache
#
# Deliberately breaks the suite's own isolation model: every other test gets its own repo AND its
# own cache (new_repo), which is exactly why this class of bug survived two prior fix cycles here --
# no single-repo fixture can observe one repo's write racing another repo's read against a cache both
# share, which is the real deployment shape this design targets (one machine-wide cache, many
# repos). This is the one place in the suite two repos are pointed at the same GRUBSTAKE_CACHE on
# purpose.

printf '\ncache integrity: shared cache\n'

it "two repos sharing one cache: a legacy upgrade must not break a concurrent exec"
# Reproduces the antagonist's finding directly: the design this replaces repaired a legacy entry by
# destroying it (rm -rf) and republishing a freshly downloaded copy (mv), leaving the hash-named
# path briefly absent. A second repo already resolved to that path and executing it in a loop saw
# ENOENT partway through -- 9 of 40 iterations in the antagonist's run. The corrected design writes
# the receipt beside the existing binary without ever unlinking it, so the path never goes missing.
# Repo A's exec loop runs in the background for the whole span of repo B's ensure call (not just one
# instant), so every iteration that lands inside that call has a chance to catch a destructive
# window if one exists; a warm-up wait before B starts is what keeps a loop that has not gotten going
# yet from proving nothing.
#
# The loop also runs a fixed minimum number of iterations regardless of how long repo B's ensure
# call takes, so the sample size the pass/fail decision is based on is guaranteed by construction
# rather than by how much wall clock a busy machine happened to grant it. The verdict is still a
# check of the same failure-log file as before -- it is not a different kind of signal -- but the
# loop makes that check on itself the instant it stops and hands the answer back through wait's
# exit status, rather than leaving a separate process to re-open the file later at whatever moment
# it happens to get scheduled.
#
# The catch is probabilistic, not guaranteed, per AGENTS.md 15: a single green run here does not
# prove the window is closed, only that this run did not hit it. Reconstructing the design this
# replaces and looping this fixture against it caught the destroy-in-place window 10/20 runs; the
# same loop against the corrected design caught nothing in 15/15. A future regression back to
# destroy-in-place is therefore likely, not certain, to show red on any given run.
a=$(new_repo); b=$(new_repo)
_shared="$ROOT/shared-cache.$$"
mkdir -p "$_shared" || fixture_die "cannot create the shared cache dir"
# fake_release, not an arbitrary hash: a real (if offline) reinstall is what actually exercises the
# rm-then-mv window in the implementation this test is written to catch regressing back to: an
# arbitrary sha would only die on a sha256 mismatch long before ever reaching publish_dir. The fixed
# implementation needs no download for a legacy entry at all, so the curl shim just sits unused.
_sha=$(fake_release "$a" 0.63.2)
_entry="$_shared/swiftlint/$_sha"
mkdir -p "$_entry" || fixture_die "cannot create the shared legacy entry"
printf '#!/bin/sh\necho 0.63.2\n' > "$_entry/swiftlint" || fixture_die "cannot write the shared legacy binary"
chmod +x "$_entry/swiftlint" || fixture_die "cannot make the shared legacy binary executable"
pins "$a" "swiftlint 0.63.2 $_sha $_sha"
pins "$b" "swiftlint 0.63.2 $_sha $_sha"

_bin=$( cd "$a" && GRUBSTAKE_CACHE="$_shared" ./grubstake.sh path swiftlint 2>/dev/null )
[ -x "$_bin" ] || fixture_die "repo A could not resolve the shared entry's path"

_execlog="$ROOT/execlog.$$"
_faillog="$ROOT/execlog.$$.fail"
_stop="$ROOT/stop.$$"
: > "$_execlog"
(
    _i=0
    # 20 is a floor, not a target: the loop keeps going past it until told to stop, so it still
    # spans the whole of repo B's ensure call on a fast machine. The floor exists so a slow one
    # cannot shrink the sample to a handful of iterations and call that a clean run -- the exit
    # status below is what decides pass/fail, not how many of these ran.
    while [ "$_i" -lt 20 ] || [ ! -f "$_stop" ]; do
        _i=$((_i + 1))
        # The append is the one remaining record of a real exec failure; if it silently cannot be
        # written (a full disk, the temp dir vanishing under it), a real failure would read back as
        # a clean faillog and this test would pass on exactly the regression it exists to catch.
        # fixture_die instead of a swallowed error, same as every other fixture write in this file.
        "$_bin" >/dev/null 2>&1 || echo "$_i" >> "$_faillog" || fixture_die "cannot record repo A's exec failure to $_faillog"
        echo "$_i" > "$_execlog"
    done
    [ -s "$_faillog" ] && exit 1
    exit 0
) &
_aloop=$!

# Wait for repo A's loop to demonstrably be running before repo B starts, so the window B is about
# to open actually overlaps a live reader instead of a loop that has not started yet. The empty file
# : > "$_execlog" created above reads back as an empty string, not "0", until the background loop's
# first write lands, so that has to be normalized before the numeric compare or dash reports
# "integer expression expected" on every poll before the loop gets going. The budget below is
# generous on purpose: this poll, unlike the pass/fail decision itself, still runs under a load
# assumption, and firing fixture_die early would abort the whole suite over scheduling noise
# rather than over anything the test exists to catch. 300 * 0.05s is 15s in practice; it only
# reaches the full 300s on a shell without fractional sleep, which none of the suite's supported
# shells are.
_w=0
while :; do
    _seen="$(cat "$_execlog" 2>/dev/null)"
    case "$_seen" in ''|*[!0-9]*) _seen=0 ;; esac
    [ "$_seen" -ge 5 ] && break
    _w=$((_w + 1))
    [ "$_w" -gt 300 ] && fixture_die "repo A's exec loop never got going"
    sleep 0.05 2>/dev/null || sleep 1
done

_out=$( cd "$b" && PATH="$a/curl-shim:$PATH" GRUBSTAKE_CACHE="$_shared" ./grubstake.sh ensure 2>&1 ); _rc=$?

# A little longer past B's ensure, so a window opening right at the end is still caught, before
# repo A's loop is told to stop.
sleep 0.2 2>/dev/null || sleep 1
: > "$_stop"
wait "$_aloop"; _lrc=$?

_iterations="$(cat "$_execlog" 2>/dev/null)"
case "$_iterations" in ''|*[!0-9]*) _iterations=0 ;; esac
_failures=0
[ -f "$_faillog" ] && _failures=$(wc -l < "$_faillog" | tr -d ' ')

if [ "$_rc" -ne 0 ]; then
    fail "repo B's ensure over the shared legacy entry exited $_rc: $_out"
elif [ "$_lrc" -ne 0 ] || [ "$_failures" != "0" ]; then
    fail "repo A's binary failed to exec $_failures/$_iterations times while repo B ran ensure against the shared cache (iterations: $(tr '\n' ' ' < "$_faillog" 2>/dev/null))"
else
    pass
fi
rm -f "$_stop" "$_execlog" "$_faillog"

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

it "path rejects a tool name that known_tools' regex check would silently let through"
# known_tools | grep -qw "$1" treats the name as a basic regular expression, so a "." in
# "swift.int" matches any character and passes the guard meant to reject it. Nothing must be
# pinned under a name grep -qw would also match against "swift.int" (that includes "swiftlint"
# itself, since pin_field's own lookup is grep -E "^$1[[:space:]]"), or path finds a pin, calls
# tool_url, and dies there instead -- accidentally closing over the guard's own job with the
# wrong evidence. periphery is pinned instead so path's guard is what has to reject this alone.
r=$(new_repo); pins "$r" "periphery 3.7.4 $SHA_A $SHA_A"
_out=$(gs "$r" path swift.int); _rc=$?
if [ "$_rc" -eq 0 ]; then
    fail "path exited 0 for 'swift.int': $_out"
else
    case "$_out" in
        *"unknown tool"*) pass ;;
        *) fail "refused, but not with 'unknown tool' from the guard: $_out" ;;
    esac
fi

it "check names the pins-file line when a regex-matched tool name should be an outright rejection"
# validate_pins carries its own tool-name guard, a call site neither the path test above nor add
# can reach. Pinning "swift.int" directly and running check exercises it: today the guard lets
# the line through, and the tool name is instead rejected several frames downstream inside
# tool_url, whose bare die propagates out through set -e (see cmd_doctor's "assign, do not test"
# comment) and prints a message with no grubstake.tools:N prefix at all -- so the file and line
# responsible for the bad pin is never named.
r=$(new_repo); pins "$r" "swift.int 1.0.0 $SHA_A $SHA_A"
_out=$(gs "$r" check); _rc=$?
if [ "$_rc" -eq 0 ]; then
    fail "check exited 0 for a pin named 'swift.int': $_out"
else
    case "$_out" in
        *"grubstake.tools:"*) pass ;;
        *) fail "refused, but without naming the pins-file line responsible: $_out" ;;
    esac
fi

it "a tool with no artifact on this platform is skipped, not failed, by check"
r=$(new_repo); pins "$r" "periphery 3.7.4 $SHA_A -"
sed 's/        Darwin) echo darwin ;;/        Darwin) echo linux ;;/' "$GS" > "$r/grubstake.sh"
chmod +x "$r/grubstake.sh"; expect_ok "$r" check

# ---------------------------------------------------------------------------- update

printf '\nupdate\n'

it "a release below the supported floor is refused"
r=$(new_repo); expect_fail "$r" update 0.1.4

it "a hostile TMPDIR cannot inject commands into update's cleanup trap"
# cmd_update's only trap wraps $_tmp, sourced from mktemp under TMPDIR. Refusing a release below the
# supported floor dies immediately and offline, so that trap is still the one active at EXIT -- the
# same injection shape as install's and add's traps above, applied to update's one and only site.
r=$(new_repo)
_sentinel="$r/SENTINEL"
_tmpdir="$r/tmp'; touch \"$_sentinel\"; echo '"
mkdir -p "$_tmpdir"
_out=$( cd "$r" && TMPDIR="$_tmpdir" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh update 0.1.4 2>&1 ); _rc=$?
if [ -e "$_sentinel" ]; then
    fail "the injected command ran: SENTINEL was created via update's cleanup trap"
elif [ "$_rc" -eq 0 ]; then
    fail "update exited 0 for a release below the supported floor: $_out"
else
    case "$_out" in
        *"below the supported floor"*) pass ;;
        *) fail "died for an unexpected reason: $_out" ;;
    esac
fi

it "the legacy handoff verb still answers, for clients that only speak it"
# Removing it stranded every existing adopter: it is a protocol only OLD versions speak, so it is
# the one thing that cannot be fixed forward. It stays as compatibility, not as a live path.
r=$(new_repo)
cp "$GS" "$r/target.sh"
sed -i.bak 's/^GRUBSTAKE_VERSION=.*/GRUBSTAKE_VERSION="0.0.1"/' "$r/target.sh" && rm -f "$r/target.sh.bak"
( cd "$r" && ./grubstake.sh __replace-self "$r/target.sh" 9.9.9 ) >/dev/null 2>&1
_v=$( "$r/target.sh" version 2>/dev/null )
[ "$_v" = "$(gs "$(new_repo)" version)" ] && pass || fail "the shim did not replace the target (got '$_v')"

it "the legacy handoff verb replaces the script and stops, without running the replacement"
# cmd_legacy_replace copies the running script onto the target and, in the code this test exists
# to catch, immediately execs "$_installed" ensure -- the same defect just fixed in cmd_update
# above, running bytes before anyone has reviewed the diff. The replacement is a copy of $0 rather
# than a fetch, so the marker has to live in the invoking script itself, gated on an "ensure"
# argument: cmd_legacy_replace is called directly with (target, version), the way extract_fns'
# callers do below, so that argument is never present on the first run -- only the auto-ensure
# this test is watching for would supply it. log/die/cmd_legacy_replace come from $GS via sed, the
# same technique extract_fns uses, so the real function body runs rather than a reimplementation.
r=$(new_repo)
_fn="$(sed -n '/^cmd_legacy_replace() {/,/^}/p' "$GS")"
printf '%s\n' "$_fn" | grep -q '^cmd_legacy_replace() {$' \
    || fixture_die "extract cmd_legacy_replace: no line-anchored '{' in $GS (reformatted?)"
_closes="$(printf '%s\n' "$_fn" | grep -c '^}$' | tr -d ' ')"
[ "$_closes" = 1 ] || fixture_die "extract cmd_legacy_replace: $_closes closing braces, expected 1 (truncated)"
_helpers="$(grep -E '^(log|die)\(\)' "$GS")"
[ -n "$_helpers" ] || fixture_die "extract log/die: neither found in $GS"
{
    printf '#!/bin/sh\nset -eu\n'
    printf '[ "${1:-}" = ensure ] && { [ -n "${GST_TEST_MARKER:-}" ] && touch "$GST_TEST_MARKER"; exit 0; }\n'
    printf '%s\n' "$_helpers"
    printf '%s\n' "$_fn"
    printf 'cmd_legacy_replace "$@"\n'
} > "$r/t.sh"
chmod +x "$r/t.sh"
_marker="$r/EXECUTED"
_out=$( cd "$r" && GST_TEST_MARKER="$_marker" "$r/t.sh" "$r/target.sh" 9.9.9 2>&1 ); _rc=$?
# cmp, not the marker alone: a fixture that dies before ever reaching cmd_legacy_replace (a bad
# extraction, a broken mktemp) also leaves no marker, and that must read as a harness failure, not
# as proof the auto-ensure is gone.
if ! cmp -s "$r/t.sh" "$r/target.sh" 2>/dev/null; then
    fail "the shim did not replace the target, so cmd_legacy_replace never ran (rc $_rc): $_out"
elif [ -f "$_marker" ]; then
    fail "the replaced script executed before any diff existed to review: $_out"
else
    pass
fi

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
    # The named default is the source of truth; a plain literal assignment is the fallback shape.
    _repo="$(sed -n 's/^GRUBSTAKE_REPO_DEFAULT="\(.*\)"$/\1/p' "$GS")"
    [ -n "$_repo" ] || _repo="$(sed -n 's/^GRUBSTAKE_REPO="\(.*\)"$/\1/p' "$GS")"
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

it "a race loser cleans up after itself"
# Two installs of one cold pin. The loser must discard its own staging, or a shared cache
# accumulates litter that a normal rm cannot remove.
#
# publish_dir's winner branch is bare executable existence, "[ -x "$2/$3" ]", full stop: a live
# binary is never cleared, whatever its receipt does or does not say -- a mismatch is install_tool's
# refusal to make, before publish_dir is ever reached (see "ensure refuses a binary that no longer
# matches its receipt, rather than reinstalling over it" above), never publish_dir's to repair. The
# tool name is still what tells a real winner (dest holds the executable) apart from debris (dest
# exists but does not). This generated script has no `set -u`, so calling publish_dir with only two
# arguments leaves $3 empty rather than erroring, and "$2/$3" degrades to "$2/" -- ordinary
# directory search permission, true for any plain directory -- so the winner branch would fire
# unconditionally regardless of what dest actually holds. Passing the tool name, and giving dest a
# genuine executable to be a genuine winner, is what makes this assertion mean anything again; see
# "publish_dir publishes a staging directory into a destination that lacks the executable" below for
# the debris branch this would otherwise never distinguish from, and "publish_dir never clears an
# entry whose binary exists" above for the same invariant proven directly against a receipt that
# does not match.
r=$(new_repo)
_d="$r/dest"; _st="$r/dest.staging.111"
mkdir -p "$_st"; printf 'x' > "$_st/f"; chmod -R a-w "$_st"
mkdir -p "$_d"; printf '#!/bin/sh\necho 0.63.2\n' > "$_d/swiftlint"; chmod +x "$_d/swiftlint"
_before="$(cat "$_d/swiftlint")"
{ extract_fns; echo 'die() { echo "$1" >&2; exit 1; }'; echo 'warn() { echo "WARN: $1" >&2; }'; echo 'publish_dir "$1" "$2" "$3"'; } > "$r/t.sh"
( cd "$r" && sh "$r/t.sh" "$_st" "$_d" swiftlint ) >/dev/null 2>&1; _rc=$?
# The status is checked rather than discarded: 127 is publish_dir never running, which leaves no
# staging behind either and so read as a pass.
if [ "$_rc" -ne 0 ]; then fail "the generated script exited $_rc, so publish_dir did not run"
elif [ -e "$_st" ]; then fail "the loser could not remove its own read-only staging"
elif [ "$(cat "$_d/swiftlint" 2>/dev/null)" != "$_before" ]; then fail "the winner's own executable was disturbed"
else pass; fi
chmod -R u+w "$r" 2>/dev/null

it "a race loser's staging cleanup that rm cannot finish is reported in grubstake's voice, not raw rm stderr"
# #56: install_tool's own "with_lock ... publish_dir ..." call (the real call site, not the
# fabricated one above) is bare -- no "|| die". cmd_ensure calls install_tool as
# "install_tool ... || _bad=1", and a shell function called on the left of "||" runs with errexit
# suspended for its whole body (POSIX 2.8.1 / bash's documented -e behavior for compound commands),
# so the bare call's nonzero return does not stop the script at all: execution falls through to
# install_tool's own "[ -x "$_bin" ]" completeness check, which passes because the winner's binary
# is right there, and the run finishes by logging a false "installed". The user is left with rm's
# unprefixed complaint sandwiched between two ordinary "[grubstake]" log lines, exit 0, and an
# orphaned, half-removed staging directory still sitting in the cache. publish_dir's winner branch
# has no error handling at all around its "rm -rf $1": unlike the debris branch a few lines below
# it, which at least warns before returning 1, a cleanup failure here never gets a "[grubstake]"
# line of its own. Reaching this needs a genuine race through the real call site: install_tool's
# early "already installed" check means a fresh download only ever calls publish_dir once the binary
# is confirmed absent, so the winner branch is unreachable except when a second install actually
# wins in between. lock_pause_shim pauses the loser (B) at with_lock's own mkdir, right after B has
# built and verified its staging but before it takes the lock, which is exactly the window a real
# winner (A) needs to publish first; the plant script then makes B's own staging partially
# unremovable the same way "an unremovable partial directory fails loudly instead of nesting the
# staging" above does to a destination, before B is released to find A already there.
r=$(new_repo)
_sha=$(fake_release "$r" 0.63.2)
pins "$r" "swiftlint 0.63.2 $_sha $_sha"
_dest="$r/.cache/swiftlint/$_sha"
_shim="$r/mkdir-shim"; _reached="$r/reached"; _go="$r/go"
lock_pause_shim "$_shim" "$_reached" "$_go"
cat > "$_shim/plant" <<'PLANT'
#!/bin/sh
_pd="${1%.lock}"
for _psd in "$_pd".staging.*; do
    [ -d "$_psd" ] || continue
    mkdir -p "$_psd/locked" 2>/dev/null
    printf x > "$_psd/locked/f" 2>/dev/null
    chmod 000 "$_psd/locked" 2>/dev/null
done
PLANT
chmod +x "$_shim/plant" || fixture_die "cannot make the plant script executable"
# B (the eventual loser): staged and paused at the lock, staging deliberately half-unremovable.
( cd "$r" && PATH="$r/curl-shim:$_shim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure >"$r/b.out" 2>&1; echo $? > "$r/b.rc" ) &
_bpid=$!
_w=0
while [ ! -f "$_reached" ]; do
    _w=$((_w + 1))
    [ "$_w" -gt 300 ] && fixture_die "the loser never reached the lock point"
    sleep 0.05 2>/dev/null || sleep 1
done
_stB=$(printf '%s\n' "$_dest".staging.* 2>/dev/null | head -1)
[ -d "$_stB/locked" ] || fixture_die "the plant script did not create the unremovable subdirectory"
{ [ -r "$_stB/locked" ] || [ -x "$_stB/locked" ]; } && fixture_die "chmod 000 did not block $_stB/locked (running as root?)"
# A (the winner): a plain, unshimmed, fully offline install of the same cold pin, run to completion
# while B sits paused above.
_outA=$( cd "$r" && PATH="$r/curl-shim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rcA=$?
[ "$_rcA" -eq 0 ] || fixture_die "the winning install failed while the loser was paused: $_outA"
[ -x "$_dest/swiftlint" ] || fixture_die "the winner did not actually publish: $_outA"
: > "$_go"
wait "$_bpid" 2>/dev/null
[ -f "$r/b.rc" ] || fixture_die "the backgrounded loser never recorded an exit status"
_rcB="$(cat "$r/b.rc")"
_outB="$(cat "$r/b.out" 2>/dev/null)"
chmod -R u+rwx "$_stB" 2>/dev/null
if [ "$_rcB" -eq 0 ]; then
    fail "the losing install exited 0 despite an unremovable staging directory: $_outB"
elif ! printf '%s\n' "$_outB" | grep -q '^rm:'; then
    fail "did not actually hit rm's own failure -- the fixture did not reach the real defect: $_outB"
else
    _last=$(printf '%s\n' "$_outB" | tail -1)
    case "$_last" in
        "[grubstake]"*) pass ;;
        *) fail "the cleanup failure was left in rm's raw voice, not grubstake's: $_outB" ;;
    esac
fi

it "publish_dir publishes a staging directory into a destination that lacks the executable"
# The other half of the branch above: a destination that exists but does not hold the tool's
# executable is debris, not a winner -- an interrupted publish, a stray mkdir, a cache layout change
# across versions -- and the freshly built staging must land there rather than being discarded. Unit
# coverage of publish_dir itself, at the same level "a race loser cleans up after itself" covers the
# winner branch; "a partial cache directory does not wedge ensure" already covers this branch
# end-to-end through the whole ensure pipeline, but nothing previously exercised publish_dir alone.
r=$(new_repo)
_d="$r/dest"; _st="$r/dest.staging.222"
mkdir -p "$_st"; printf 'bin' > "$_st/swiftlint"; chmod +x "$_st/swiftlint"
mkdir -p "$_d"   # exists, but nothing named swiftlint inside it: debris, not a winner
{ extract_fns; echo 'die() { echo "$1" >&2; exit 1; }'; echo 'publish_dir "$1" "$2" "$3"'; } > "$r/t.sh"
( cd "$r" && sh "$r/t.sh" "$_st" "$_d" swiftlint ) >/dev/null 2>&1; _rc=$?
if [ "$_rc" -ne 0 ]; then fail "the generated script exited $_rc, so publish_dir did not run"
elif [ -e "$_st" ]; then fail "the staging directory was not moved: $_st still exists"
elif [ ! -x "$_d/swiftlint" ]; then fail "debris was cleared, but the staging was never published into $_d"
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

# A local stand-in for GRUBSTAKE_REPO/GRUBSTAKE_RAW: a bare repo carrying one annotated release tag,
# plus a raw-fetch tree laid out the same way raw.githubusercontent.com is (v<version>/grubstake.sh).
# gpgsign is disabled for both the commit and the tag, for the same reason new_hook_repo disables it
# for commits: a globally configured signing key would block the tag too, and a fixture that cannot
# be built is not a test result.
new_update_fixture() {
    _uf="$(mktemp -d "$ROOT/update-fixture.XXXXXX")" || fixture_die "cannot create an update fixture dir"
    git init -q --bare "$_uf/repo.git" || fixture_die "cannot init the fixture release repo"
    _uw="$(mktemp -d "$ROOT/update-fixture-work.XXXXXX")" || fixture_die "cannot create a work dir for the fixture release"
    ( cd "$_uw" \
      && git init -q . \
      && git config user.email test@example.invalid \
      && git config user.name "grubstake suite" \
      && git config commit.gpgsign false \
      && git config tag.gpgSign false \
      && printf 'fixture release\n' > README.md \
      && git add README.md \
      && git commit -q -m release \
      && git tag -a v9.9.9 -m "fixture release 9.9.9" \
      && git push -q "$_uf/repo.git" HEAD:refs/heads/main --tags ) \
        || fixture_die "cannot seed the fixture release repo in $_uf"
    mkdir -p "$_uf/raw/v9.9.9" || fixture_die "cannot create the fixture raw tree in $_uf"
    # Declares the version fetch_release's grep demands, and marks its own execution unconditionally
    # -- on any argument, including "ensure", the argument an auto-run handoff would supply -- so
    # the test can tell replaced-but-not-run apart from replaced-and-run.
    printf '#!/bin/sh\nGRUBSTAKE_VERSION="9.9.9"\n[ -n "${GST_TEST_MARKER:-}" ] && touch "$GST_TEST_MARKER"\nexit 0\n' \
        > "$_uf/raw/v9.9.9/grubstake.sh" || fixture_die "cannot write the fixture release script"
    echo "$_uf"
}

it "update replaces the script and stops, without running the fetched code"
# GRUBSTAKE_REPO and GRUBSTAKE_RAW are env-overridable so update can be pointed at a local
# fixture instead of the real grubstake repo.
#
# curl and git are shimmed to allow only file:// targets and to fail everything else outright,
# rather than trusting this sandbox's real reachability. That keeps the test offline and fast
# whether or not the override lands: unfixed, the hardcoded https:// targets get refused by the
# shim instead of making a live call (or hanging, on a sandbox with no egress at all) before
# release_tags gives up and update dies -- never reaching the fixture, let alone running it.
_realcurl="$(command -v curl)" || fixture_die "no curl on PATH"
_realgit="$(command -v git)" || fixture_die "no git on PATH"
_shims="$(mktemp -d "$ROOT/update-shims.XXXXXX")" || fixture_die "cannot create a scratch dir for the network shims"
cat > "$_shims/curl" <<SHIM
#!/bin/sh
for a in "\$@"; do
    case "\$a" in
        file://*) exec "$_realcurl" "\$@" ;;
    esac
done
echo "curl: network blocked in test" >&2
exit 6
SHIM
cat > "$_shims/git" <<SHIM
#!/bin/sh
if [ "\${1:-}" = "ls-remote" ]; then
    _ok=1
    for a in "\$@"; do
        case "\$a" in file://*) _ok=0 ;; esac
    done
    if [ "\$_ok" = 1 ]; then
        echo "git: network blocked in test" >&2
        exit 128
    fi
fi
exec "$_realgit" "\$@"
SHIM
chmod +x "$_shims/curl" "$_shims/git"

f=$(new_update_fixture)
r=$(new_repo)
_marker="$r/EXECUTED"
_out=$( cd "$r" && PATH="$_shims:$PATH" \
    GRUBSTAKE_CACHE="$r/.cache" GST_TEST_MARKER="$_marker" \
    GRUBSTAKE_REPO="file://$f/repo.git" GRUBSTAKE_RAW="file://$f/raw" \
    ./grubstake.sh update 2>&1 )

if ! grep -q '^GRUBSTAKE_VERSION="9.9.9"' "$r/grubstake.sh" 2>/dev/null; then
    fail "update did not replace the script with the fetched release: $_out"
elif [ -f "$_marker" ]; then
    fail "the fetched script executed before any diff existed to review: $_out"
else
    case "$_out" in
        *ensure*) pass ;;
        *) fail "did not tell the user to run ensure: $_out" ;;
    esac
fi

# ---------------------------------------------------------------------------- install

printf '\ninstall\n'

it "install refuses a foreign hooksPath without writing anything first"
r=$(new_repo); ( cd "$r" && git config core.hooksPath .other-hooks )
gs_rc "$r" install
if [ -d "$r/.githooks" ]; then fail "left .githooks behind after refusing"; else pass; fi

# The gst-embedded-hook-begin/end: <name> marker lines are the extraction interface this test and
# grubstake.sh's own install share, so renaming or reformatting either side breaks both silently.
# grubstake.sh must strip both marker lines when it writes the installed hook: if they reach
# .githooks/pre-commit, the installed file no longer matches hooks/pre-commit byte for byte, and
# the drift test below would then flag every clean install as drifted forever.
extract_embedded_hook() {
    sed -n "/^# gst-embedded-hook-begin: $1\$/,/^# gst-embedded-hook-end: $1\$/p" "$GS" | sed '1d;$d'
}

it "the embedded copy of each hook in grubstake.sh cannot drift from hooks/"
# hooks/ is the reviewable source; grubstake.sh must ship its own verbatim copy so install needs no
# network. Two copies of the same ~105 lines is exactly how they silently diverge, which is what
# this test would catch. Unlike extract_fns below, an empty extraction here is not a harness
# fault: a hook missing from grubstake.sh must fail this test, not abort the run, since a missing
# embedded copy is exactly the drift this test exists to catch.
#
# cmp, not a $(...) string compare: command substitution strips trailing newlines from both sides,
# which would let an embedded copy missing (or carrying an extra) trailing newline compare equal
# and pass a test named for byte identity.
_bad=""
for _hook in pre-commit post-commit; do
    _got="$(mktemp "$ROOT/embedded.XXXXXX")" || fixture_die "cannot create a scratch file for $_hook extraction"
    extract_embedded_hook "$_hook" > "$_got"
    cmp -s "$_got" "$HOOKS/$_hook" || _bad="$_bad $_hook"
done
[ -z "$_bad" ] && pass || fail "embedded copy differs from (or is missing for) hooks/:$_bad"

it "install adopts a repo with no network access"
# Shadowing curl, rather than trusting this sandbox's real reachability (which has open egress to
# GitHub -- v0.3.2/hooks/pre-commit already resolves there), is what makes this test fail today for
# the right reason instead of passing by accident. A curl that always fails forces install down
# exactly the path a genuinely offline developer takes.
r=$(new_repo)
_shims="$(mktemp -d "$ROOT/no-net.XXXXXX")" || fixture_die "cannot create a scratch dir for the network shim"
printf '#!/bin/sh\necho "curl: network blocked in test" >&2\nexit 6\n' > "$_shims/curl"
chmod +x "$_shims/curl"
_out=$( cd "$r" && PATH="$_shims:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh install 2>&1 ); _rc=$?
_hp=$( cd "$r" && git config core.hooksPath 2>/dev/null )
if [ "$_rc" -ne 0 ]; then
    fail "install failed with no network (rc $_rc): $_out"
elif [ ! -x "$r/.githooks/pre-commit" ] || [ ! -x "$r/.githooks/post-commit" ]; then
    fail "a hook is missing or not executable after an offline install: $_out"
elif [ "$_hp" != ".githooks" ]; then
    fail "core.hooksPath was not set to .githooks (got '$_hp'): $_out"
else
    pass
fi

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

# Write a file and stage it; the staged paths are all the pre-commit spine looks at. "--" before the
# path so a dash-prefixed name (#29) stages instead of git parsing it as an option itself.
stage() {
    printf '%s\n' "$3" > "$1/$2" || fixture_die "cannot write $1/$2"
    ( cd "$1" && git add -- "$2" ) || fixture_die "cannot stage $2 in $1"
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

# A stubbed swiftlint that decides its own output from real argv rather than a canned per-run
# script: whether a staged path survives to the linter as a path at all (#29's dash defect) and
# whether a path is even present when the linter runs (#29's AD/MD defect) both depend on what the
# linter was actually handed and what it can see, which stub_linter's invocation-numbered scripting
# cannot express. Argument parsing mirrors SwiftLint's own: "lint" and anything starting with "-"
# is an option and is consumed, until a bare "--" is seen, after which every remaining argument is a
# path even if it also starts with "-". A path that does not exist is noted as missing; a path that
# exists and contains the marker gets a fake violation. A violation for one co-staged path is always
# reported even when another path in the same invocation is missing -- only when nothing at all was
# lintable does the run collapse to 0.63.2's own "No lintable files found" message alone, at exit 1.
# Otherwise a real violation still exits 2. Callers pin SHA_A in both columns, so the stub sits where
# either platform looks for it.
stub_linter_mechanical() {
    _sd="$1/.cache/swiftlint/$SHA_A"
    mkdir -p "$_sd" || fixture_die "cannot create $_sd"
    printf "#!/bin/sh\nR='%s'\n" "$1" > "$_sd/swiftlint" \
        || fixture_die "cannot write the mechanical stub linter"
    cat >> "$_sd/swiftlint" <<'STUB'
n=$(cat "$R/lint.runs" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$R/lint.runs"
{ echo "$0"; for a in "$@"; do echo "$a"; done; } > "$R/lint.argv.$n"
cd "$R" || exit 99
missing=""
violations=""
seen_dashdash=0
for a in "$@"; do
    if [ "$seen_dashdash" -eq 0 ]; then
        case "$a" in
            lint) continue ;;
            --) seen_dashdash=1; continue ;;
            -*) continue ;;
        esac
    fi
    if [ ! -e "$a" ]; then
        missing="$missing '$a'"
    elif grep -q -- VIOLATION_MARKER "$a" 2>/dev/null; then
        violations="$violations
$a:1:1: error: Fake Violation (fake_rule)"
    fi
done
out=""
[ -n "$violations" ] && out="$violations"
if [ -n "$missing" ]; then
    _miss_msg="Error: No lintable files found at paths:$missing"
    if [ -n "$out" ]; then out="$out
$_miss_msg"; else out="$_miss_msg"; fi
fi
if [ -n "$violations" ]; then rc=2
elif [ -n "$missing" ]; then rc=1
else rc=0
fi
[ -n "$out" ] && printf '%s\n' "$out"
exit "$rc"
STUB
    chmod +x "$_sd/swiftlint" || fixture_die "cannot make the mechanical stub linter executable"
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

it "a staged path beginning with a dash is linted as a path, not consumed as a linter option"
# #29's unqualified reproduction: a name that is simultaneously a valid staged Swift path and a
# valid swiftlint option (no "--" separates paths from options) gets consumed as the option, and the
# violation inside it is never seen.
r=$(new_hook_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
stub_linter_mechanical "$r"
stage "$r" '--config=clean.yml.swift' 'let x = 1 // VIOLATION_MARKER'
_out=$(hook_commit "$r"); _rc=$?
if [ ! -f "$r/lint.argv.1" ]; then
    fail "the linter never ran, so this proves nothing about the dash: $_out"
elif [ "$_rc" -eq 0 ]; then
    fail "the commit went through with the violation hidden behind the dash-prefixed name: $_out"
elif [ "$(commits "$r")" != 1 ]; then
    fail "refused, and committed anyway"
else
    case "$_out" in
        *"Fake Violation"*) pass ;;
        *) fail "blocked without reporting what the linter said: $_out" ;;
    esac
fi

it "a staged file missing from the working tree does not commit unlinted (AD, MD)"
# SwiftLint cannot read a path that is staged but gone from the working tree: it exits 1 and says
# "No lintable files found", a message the hook also (wrongly) treats as "every staged path is
# excluded by config, nothing to report". AD is that state fresh: staged as new, then removed. MD
# reaches the same state from a tracked file: modified in the index, then removed. Neither case means
# the linter looked and found nothing wrong; both mean it never looked at all, which the pre-commit
# gate must not read as a pass, and must not pass through in silence either.
r=$(new_hook_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
stub_linter_mechanical "$r"
_bad=""

_n0=$(cat "$r/lint.runs" 2>/dev/null || echo 0)
_c0=$(commits "$r")
stage "$r" Violating.swift 'let x = 1 // VIOLATION_MARKER'
rm -f "$r/Violating.swift"
_out=$(hook_commit "$r"); _rc=$?
_n1=$(cat "$r/lint.runs" 2>/dev/null || echo 0)
_c1=$(commits "$r")
if [ "$_n1" = "$_n0" ]; then
    _bad="$_bad AD(the linter never ran: $_out)"
elif [ "$_rc" -eq 0 ]; then
    _bad="$_bad AD(exited 0 and committed silently: $_out)"
elif [ "$_c1" != "$_c0" ]; then
    _bad="$_bad AD(refused with rc $_rc, but the commit count still moved from $_c0 to $_c1)"
elif ! printf '%s' "$_out" | grep -q "Violating.swift"; then
    _bad="$_bad AD(blocked in silence, without naming the file: $_out)"
fi

# A correct refusal never touches the index, so Violating.swift is still staged (AD) here. Clear it
# before seeding the tracked baseline below, or that commit is refused for the same AD reason and
# never becomes the tracked file the MD sub-case needs to modify. The worktree copy is already gone,
# so this reset only drops the stage; it does not resurrect the file.
( cd "$r" && git reset -q -- Violating.swift ) || fixture_die "cannot unstage Violating.swift in $r"

# A tracked baseline, so the next removal is a genuine MD rather than a second AD.
_cseed=$(commits "$r")
stage "$r" Tracked.swift 'let ok = 1'
hook_commit "$r" >/dev/null 2>&1
[ "$(commits "$r")" = "$((_cseed + 1))" ] \
    || fixture_die "could not seed a tracked baseline commit for MD in $r"

_n2=$(cat "$r/lint.runs" 2>/dev/null || echo 0)
_c2=$(commits "$r")
printf 'let x = 1 // VIOLATION_MARKER\n' > "$r/Tracked.swift"
( cd "$r" && git add Tracked.swift ) || fixture_die "cannot re-stage Tracked.swift in $r"
rm -f "$r/Tracked.swift"
_out=$(hook_commit "$r"); _rc=$?
_n3=$(cat "$r/lint.runs" 2>/dev/null || echo 0)
_c3=$(commits "$r")
if [ "$_n3" = "$_n2" ]; then
    _bad="$_bad MD(the linter never ran: $_out)"
elif [ "$_rc" -eq 0 ]; then
    _bad="$_bad MD(exited 0 and committed silently: $_out)"
elif [ "$_c3" != "$_c2" ]; then
    _bad="$_bad MD(refused with rc $_rc, but the commit count still moved from $_c2 to $_c3)"
elif ! printf '%s' "$_out" | grep -q "Tracked.swift"; then
    _bad="$_bad MD(blocked in silence, without naming the file: $_out)"
fi

[ -z "$_bad" ] && pass || fail "$_bad"

it "a staged file with a legitimate unstaged edit still commits, with only a warning"
# AM and MM mean the linter read different content than what is staged, which is normal under
# `git add -p`; refusing there would break a workflow people rely on. This has to keep working once
# AD/MD above start refusing, since both are reached through the same lint-the-working-tree
# limitation and a fix that is not narrow could sweep this case in too.
r=$(new_hook_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
stub_linter_mechanical "$r"
stage "$r" Tracked.swift 'let a = 1'
hook_commit "$r" >/dev/null 2>&1
printf 'let a = 2\n' > "$r/Tracked.swift"
( cd "$r" && git add Tracked.swift ) || fixture_die "cannot re-stage Tracked.swift in $r"
printf 'let a = 3\n' > "$r/Tracked.swift"
_out=$(hook_commit "$r"); _rc=$?
if [ "$_rc" -ne 0 ]; then
    fail "a legitimate unstaged edit (MM) was refused, not just warned about: $_out"
elif [ "$(commits "$r")" != 3 ]; then
    fail "exited 0 without committing"
elif ! printf '%s' "$_out" | grep -q "unstaged edits"; then
    fail "committed with no warning about the divergence: $_out"
else
    pass
fi

it "a staged rename with an unstaged edit still warns"
# The divergence warning narrowed from "^[ACMR]M" to "^[AM]M " when AD/MD split off into a refusal.
# A rename reports "R" in the index column, which that narrower pattern does not match, so `git mv`
# followed by an unstaged edit -- lint-clean content, so this must still commit -- says nothing about
# reading working-tree bytes that differ from what is staged.
r=$(new_hook_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
stub_linter_mechanical "$r"
stage "$r" Old.swift 'let a = 1'
hook_commit "$r" >/dev/null 2>&1
( cd "$r" && git mv Old.swift New.swift ) || fixture_die "cannot rename Old.swift to New.swift in $r"
printf 'let a = 1\nlet b = 2\n' > "$r/New.swift"
_out=$(hook_commit "$r"); _rc=$?
if [ ! -f "$r/lint.argv.2" ]; then
    fail "the linter never ran: $_out"
elif [ "$_rc" -ne 0 ]; then
    fail "a lint-clean rename with an unstaged edit was refused, not just warned about: $_out"
elif [ "$(commits "$r")" != 3 ]; then
    fail "exited 0 without committing"
elif ! printf '%s' "$_out" | grep -q "unstaged edits"; then
    fail "committed with no warning about the divergence: $_out"
else
    pass
fi

it "a co-staged violation is reported alongside a missing-file refusal"
# The refusal for a staged-but-gone file is computed straight from git status, independent of what
# the linter said, so it fires correctly. But $OUT -- where a violation in some other file the
# linter *did* still read would show up -- is never printed on that path. A developer who fixes the
# missing file and retries only then learns their other file had a violation the whole time.
r=$(new_hook_repo); pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
stub_linter_mechanical "$r"
stage "$r" File1.swift 'let x = 1 // VIOLATION_MARKER'
stage "$r" File2.swift 'let y = 2'
rm -f "$r/File2.swift"
_out=$(hook_commit "$r"); _rc=$?
if [ ! -f "$r/lint.argv.1" ]; then
    fail "the linter never ran, so this proves nothing: $_out"
elif [ "$_rc" -eq 0 ]; then
    fail "the commit went through even though File2.swift is staged but missing: $_out"
elif ! printf '%s' "$_out" | grep -q "File2.swift"; then
    fail "did not refuse for the missing file: $_out"
elif ! printf '%s' "$_out" | grep -q "Fake Violation"; then
    fail "refused for the missing file, but swallowed File1's violation: $_out"
else
    pass
fi

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

it "doctor reports a hook that has drifted from grubstake's copy"
# ADOPTING says install writes hooks once and leaves them alone, so a fix landing in hooks/ (like
# #29) never reaches an already-adopted repo through update. doctor is the only place left that can
# surface the gap. new_hook_repo is used here rather than `grubstake.sh install`: unshimmed,
# install reaches the real network in this sandbox, and shimmed (as in the offline-install test
# above) it dies before writing anything -- neither seeds a hook to corrupt. Copying hooks/ by hand,
# the way new_hook_repo already does for the rest of this section, is the offline equivalent.
#
# Compares clean output against drifted output rather than grepping the drifted output alone for
# "pre-commit": doctor prints a status line per hook, so a healthy repo's own "pre-commit  ok" line
# would satisfy a bare substring match and pass whether or not drift detection actually works.
# Diffing against a known-clean baseline is what makes this specific to the corruption.
r=$(new_hook_repo)
_clean=$(gs "$r" doctor)
printf '# corrupted for test\n' >> "$r/.githooks/pre-commit"
_drift=$(gs "$r" doctor)
if [ "$_clean" = "$_drift" ]; then
    fail "doctor's output did not change at all once pre-commit was corrupted: $_drift"
elif ! printf '%s\n' "$_drift" | grep -q "pre-commit"; then
    fail "doctor's output changed, but never named pre-commit: $_drift"
elif [ "$(printf '%s\n' "$_clean" | grep post-commit)" != "$(printf '%s\n' "$_drift" | grep post-commit)" ]; then
    fail "corrupting pre-commit also changed what doctor said about post-commit: $_drift"
else
    pass
fi

# ---------------------------------------------------------------------------- add

printf '\nadd\n'

it "add rejects an unknown tool"
r=$(new_repo); expect_fail "$r" add notatool@1.0.0

it "add rejects a spec with no version"
r=$(new_repo); expect_fail "$r" add swiftlint

it "add refuses to write over a pins file with unresolved conflict markers"
# add is the only command that writes grubstake.tools and, pre-fix, the only one that never calls
# validate_pins: it exits 0 reporting success while LC_ALL=C sort relocates the conflict markers
# away from the lines they delimited, so whoever resolves the conflict is reading a file whose
# structure has been rearranged underneath them. fake_release's curl shim keeps this offline: add
# still has to hash a real artifact for every platform before it ever reaches the pins file.
r=$(new_repo)
pins "$r" "<<<<<<< HEAD
======="
_before=$(cat "$r/grubstake.tools")
fake_release "$r" 0.63.2 >/dev/null
_out=$( cd "$r" && PATH="$r/curl-shim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh add swiftlint@0.63.2 2>&1 ); _rc=$?
_after=$(cat "$r/grubstake.tools")
if [ "$_rc" -eq 0 ]; then
    fail "add exited 0 over a pins file with unresolved conflict markers: $_out"
elif [ "$_after" != "$_before" ]; then
    fail "add refused, but rewrote grubstake.tools first: $_out"
else
    case "$_out" in
        *"conflict"*) pass ;;
        *) fail "refused, but without naming the conflict markers: $_out" ;;
    esac
fi

it "conflict markers introduced while add is still fetching are not merged into the rewrite"
# cmd_add calls validate_pins exactly once, before add_one ever fetches. add_one then downloads
# both platform artifacts -- up to --max-time 300 each -- before it ever takes the pins lock and
# rewrites grubstake.tools. Conflict markers landing in that window -- the same window a real
# `git pull` mid-add would land in -- are validated by nothing: add_one's grep/sort/mv rewrite runs
# over whatever is on disk when the lock is finally taken. The curl shim wraps fake_release's own
# shim (rather than reimplementing its -o argv parsing) and, on its first call only, mutates
# grubstake.tools and snapshots it to pins-mid-add at that instant -- so the assertion below is a
# byte-for-byte compare against what the shim actually wrote, never a hand-maintained copy of it.
r=$(new_repo)
_pins_path="$r/grubstake.tools"
pins "$r" "periphery 3.7.4 $SHA_A $SHA_A"
fake_release "$r" 0.63.2 >/dev/null
mv "$r/curl-shim/curl" "$r/curl-shim/curl-real"
cat > "$r/curl-shim/curl" <<SHIM
#!/bin/sh
if ! grep -q '<<<<<<<' "$_pins_path" 2>/dev/null; then
    printf '%s\n' '<<<<<<< HEAD' 'swiftformat 0.61.1 $SHA_B $SHA_B' '=======' 'swiftformat 0.65.0 $SHA_A $SHA_A' '>>>>>>> incoming' >> "$_pins_path"
    cp "$_pins_path" "$r/pins-mid-add"
fi
exec "$r/curl-shim/curl-real" "\$@"
SHIM
chmod +x "$r/curl-shim/curl"
_out=$( cd "$r" && PATH="$r/curl-shim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh add swiftlint@0.63.2 2>&1 ); _rc=$?
if [ ! -f "$r/pins-mid-add" ]; then
    fail "fixture never mutated grubstake.tools mid-add; the curl shim did not run as expected"
elif [ "$_rc" -eq 0 ]; then
    fail "add exited 0 over conflict markers introduced mid-fetch. pins file now:
$(cat "$_pins_path" 2>/dev/null)"
elif ! cmp -s "$_pins_path" "$r/pins-mid-add"; then
    fail "add refused, but the pins file was rewritten anyway. diff (mid-add snapshot vs after):
$(diff "$r/pins-mid-add" "$_pins_path" 2>&1)"
elif [ -e "$_pins_path.lock" ]; then
    fail "add refused, but left the pins lock behind: $_pins_path.lock"
else
    case "$_out" in
        *"conflict"*) pass ;;
        *) fail "refused, but without naming the conflict markers: $_out" ;;
    esac
fi

it "a hostile TMPDIR cannot inject commands into add's post-lock cleanup trap"
# add_one's second trap runs after the pins lock is taken, wrapping $_tmp/$_pt/$_lock together. The
# conflict-marker curl shim above forces a deterministic die inside that window (validate_pins, now
# called right after the lock is taken and the trap replaced). TMPDIR flows into $_tmp via mktemp,
# so a hostile TMPDIR is the attacker-controlled value that reaches this specific trap, the same way
# a hostile GRUBSTAKE_CACHE reaches install's (above).
r=$(new_repo)
_pins_path="$r/grubstake.tools"
pins "$r" "periphery 3.7.4 $SHA_A $SHA_A"
fake_release "$r" 0.63.2 >/dev/null
mv "$r/curl-shim/curl" "$r/curl-shim/curl-real"
cat > "$r/curl-shim/curl" <<SHIM
#!/bin/sh
if ! grep -q '<<<<<<<' "$_pins_path" 2>/dev/null; then
    printf '%s\n' '<<<<<<< HEAD' 'swiftformat 0.61.1 $SHA_B $SHA_B' '=======' 'swiftformat 0.65.0 $SHA_A $SHA_A' '>>>>>>> incoming' >> "$_pins_path"
fi
exec "$r/curl-shim/curl-real" "\$@"
SHIM
chmod +x "$r/curl-shim/curl"
_sentinel="$r/SENTINEL"
_tmpdir="$r/tmp'; touch \"$_sentinel\"; echo '"
mkdir -p "$_tmpdir"
_out=$( cd "$r" && PATH="$r/curl-shim:$PATH" TMPDIR="$_tmpdir" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh add swiftlint@0.63.2 2>&1 ); _rc=$?
if [ -e "$_sentinel" ]; then
    fail "the injected command ran: SENTINEL was created via add's post-lock cleanup trap"
elif [ "$_rc" -eq 0 ]; then
    fail "add exited 0 despite conflict markers introduced mid-fetch: $_out"
elif [ -e "$_pins_path.lock" ]; then
    fail "add refused, but left the pins lock behind: $_pins_path.lock"
else
    case "$_out" in
        *"conflict"*) pass ;;
        *) fail "refused, but not for the conflict markers: $_out" ;;
    esac
fi

# add's half of the regex defect is not observable at the CLI: tool_url's literal case dies with
# the same message either way, so the check test above covers the discriminating call site.

if [ "$NETWORK" = 1 ]; then
    printf '\nadd, network\n'

    it "add pins every argument, not just the first"
    # It once read only $1 while accepting any number, so a batched call pinned one and exited 0.
    r=$(new_repo)
    gs_rc "$r" add swiftlint@0.63.2 swiftformat@0.61.1
    n=$(grep -cvE '^[[:space:]]*(#|$)' "$r/grubstake.tools" 2>/dev/null || echo 0)
    [ "$n" = "2" ] && pass || fail "pinned $n tools, expected 2"

    it "add records a hash for every platform the tool publishes"
    # gs_rc's own exit status used to be discarded here entirely (test/run.sh runs under set -u
    # alone), and when add writes nothing at all, both awk fields read from a missing grep match
    # are empty, and `case "$d$l" in *-*)` cannot match an empty string -- so a complete failure of
    # add fell through to pass. Existence guarded before anything about the columns is asserted,
    # the same shape #37 already added to this test's two siblings.
    r=$(new_repo)
    if ! gs_rc "$r" add swiftlint@0.63.2; then
        fail "add exited non-zero"
    else
        line=$(grep '^swiftlint' "$r/grubstake.tools" 2>/dev/null)
        if [ -z "$line" ]; then
            fail "add exited 0 but grubstake.tools has no swiftlint pin line"
        else
            d=$(echo "$line" | awk '{print $3}'); l=$(echo "$line" | awk '{print $4}')
            case "$d$l" in *-*) fail "a platform hash is missing: $line" ;; *) pass ;; esac
        fi
    fi

    it "a real install passes check, and the path it prints runs at the pinned version"
    r=$(new_repo); gs_rc "$r" add swiftlint@0.63.2
    _p="$(gs "$r" path swiftlint)"
    if gs_rc "$r" check && [ "$("$_p" version 2>/dev/null)" = "0.63.2" ]; then pass
    else fail "install did not verify, or the path does not run"; fi

    it "a real install lands under the pinned archive hash"
    # The path is the validity, so it must be the hash from grubstake.tools and nothing else.
    r=$(new_repo); gs_rc "$r" add swiftlint@0.63.2
    _sha=$(awk -v c="$(sha_column)" '/^swiftlint/{print $c}' "$r/grubstake.tools")
    _bin="$r/.cache/swiftlint/$_sha/swiftlint"
    [ -x "$_bin" ] && pass || fail "not installed at $_bin (column $(sha_column), sha $_sha)"

    it "published entries are read-only"
    r=$(new_repo); gs_rc "$r" add swiftlint@0.63.2
    _sha=$(awk -v c="$(sha_column)" '/^swiftlint/{print $c}' "$r/grubstake.tools")
    _bin="$r/.cache/swiftlint/$_sha/swiftlint"
    # An append refused because the path is wrong reads identically to one refused because the
    # file is read-only, so writability is only provable against an entry that exists.
    if [ ! -x "$_bin" ]; then
        fail "not installed at $_bin (column $(sha_column), sha $_sha), so writability was never tested"
    elif { printf 'x' >> "$_bin"; } 2>/dev/null; then
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

# ---------------------------------------------------------------------------- development gates

printf '\ndevelopment gates\n'

it "the antagonist and receipt hooks block what they must and pass what they may"
if "$(dirname "$0")/gates.sh" >/dev/null 2>&1; then pass; else fail "$("$(dirname "$0")/gates.sh" 2>&1 | tail -5)"; fi

# ---------------------------------------------------------------------------- publication safety

printf '\npublication safety\n'

it "nothing tracked identifies a consumer, a person, or a machine"
if "$(dirname "$0")/no-leaks.sh" >/dev/null 2>&1; then pass; else fail "$("$(dirname "$0")/no-leaks.sh" 2>&1 | tail -3)"; fi

# The test above only proves no-leaks.sh's exit code against this repo's own, already-clean tree --
# it cannot prove either scan path below actually fires, and a no-op regression in either one would
# leave it green. A throwaway repo with a known-dirty shape closes that.
leaks_repo() {
    _lr="$(new_repo)"
    # A CI runner has no global identity, so a fixture that commits has to carry its own.
    ( cd "$_lr" \
      && git config user.email test@example.invalid \
      && git config user.name "grubstake suite" \
      && git config commit.gpgsign false ) || fixture_die "cannot configure $_lr"
    mkdir -p "$_lr/test" || fixture_die "cannot create $_lr/test"
    cp "$(dirname "$0")/no-leaks.sh" "$_lr/test/no-leaks.sh" || fixture_die "cannot copy no-leaks.sh into $_lr"
    chmod +x "$_lr/test/no-leaks.sh" || fixture_die "cannot make no-leaks.sh executable in $_lr"
    echo "$_lr"
}

it "no-leaks flags a leaky filename even when its content is clean"
r=$(leaks_repo)
: > "$r/notes-admin@example.com.txt" || fixture_die "cannot write the filename fixture in $r"
( cd "$r" && git add -A && git commit -q -m fixture ) || fixture_die "cannot commit the filename fixture in $r"
if ( cd "$r" && ./test/no-leaks.sh ) >/dev/null 2>&1; then
    fail "a leaky filename with clean content was not flagged"
else
    pass
fi

it "no-leaks flags a capitalized home path a lowercase-only pattern would miss"
r=$(leaks_repo)
printf 'built at /home/Jenkins/workspace/app\n' > "$r/deploy-log.txt" || fixture_die "cannot write the home-path fixture in $r"
( cd "$r" && git add -A && git commit -q -m fixture ) || fixture_die "cannot commit the home-path fixture in $r"
if ( cd "$r" && ./test/no-leaks.sh ) >/dev/null 2>&1; then
    fail "a capitalized home path was not flagged"
else
    pass
fi

# ---------------------------------------------------------------------------- result

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
