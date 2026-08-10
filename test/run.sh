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
REPO="$(cd "$(dirname "$0")/.." && pwd)"
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

# Mirrors new_repo()'s own construction, but nests the repo one level under a "gate" directory this
# suite controls, so that directory -- never $ROOT itself, which every other fixture shares -- can
# be made untraversable (chmod 000) without disturbing anything else running concurrently. Echoes
# the repo path, same as new_repo(); the caller derives the gate to chmod via "$(dirname "$repo")".
new_gated_repo() {
    _gbase="$ROOT/gated-repo.$$.$(od -An -N2 -tu2 < /dev/urandom | tr -d ' ')"
    mkdir -p "$_gbase/gate/repo" || fixture_die "cannot create $_gbase/gate/repo"
    _gr="$(cd "$_gbase/gate/repo" && pwd)" || fixture_die "cannot enter $_gbase/gate/repo"
    ( cd "$_gr" && git init -q . ) || fixture_die "git init failed in $_gr"
    cp "$GS" "$_gr/grubstake.sh" || fixture_die "cannot copy grubstake.sh into $_gr"
    mkdir -p "$_gr/.cache" || fixture_die "cannot create $_gr/.cache"
    [ -d "$_gr/.git" ] && [ -x "$_gr/grubstake.sh" ] && [ -d "$_gr/.cache" ] \
        || fixture_die "incomplete repo at $_gr"
    echo "$_gr"
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

# Pauses "mv" only when its destination (mv's own last argument) exactly matches $4, so it does not
# also catch an unrelated mv on the same run -- install_tool renames the archived member into place
# inside staging before ever publishing, and on Linux (where swiftlint's member is named
# "swiftlint-static", not "swiftlint") that lands at a different destination than either the
# receipt's own tmp-to-real rename or the final staging-to-dest publish, so gating on exact
# destination rather than "any mv" is what keeps this pointed at the one call site under test. The
# pid file is written before the reached flag, the same ordering lock_pause_shim's plant uses, so a
# poller that wakes on the flag never reads the pid file before it exists.
mv_pause_shim() {
    _mvdir="$1"; _mvreached="$2"; _mvgo="$3"; _mvdest="$4"
    mkdir -p "$_mvdir" || fixture_die "cannot create the mv-pause shim dir $_mvdir"
    _mvreal="$(command -v mv)" || fixture_die "no real mv on PATH to wrap"
    cat > "$_mvdir/mv" <<SHIM
#!/bin/sh
for _a in "\$@"; do _mvlast="\$_a"; done
if [ "\$_mvlast" = "$_mvdest" ]; then
    echo "\$\$" > "$_mvreached.pid"
    : > "$_mvreached"
    _mvw=0
    while [ ! -f "$_mvgo" ]; do
        _mvw=\$((_mvw + 1))
        [ "\$_mvw" -gt 300 ] && { echo "mv-pause shim: timed out waiting for the go flag" >&2; exit 1; }
        sleep 0.05 2>/dev/null || sleep 1
    done
fi
exec "$_mvreal" "\$@"
SHIM
    chmod +x "$_mvdir/mv" || fixture_die "cannot make the mv-pause shim executable"
}

# Mirrors mv_pause_shim, matched on the SOURCE (mv's own first argument) rather than the
# destination: cmd_clean's detach-and-verify race needs the pause to land before anything is
# grabbed off disk, but its destination is a mktemp'd trash directory, unpredictable by design, so
# there is no exact destination a caller could match the way mv_pause_shim's own callers do.
mv_source_pause_shim() {
    _mvsdir="$1"; _mvsreached="$2"; _mvsgo="$3"; _mvssrc="$4"
    mkdir -p "$_mvsdir" || fixture_die "cannot create the mv-source-pause shim dir $_mvsdir"
    _mvsreal="$(command -v mv)" || fixture_die "no real mv on PATH to wrap"
    cat > "$_mvsdir/mv" <<SHIM
#!/bin/sh
if [ "\$1" = "$_mvssrc" ]; then
    echo "\$\$" > "$_mvsreached.pid"
    : > "$_mvsreached"
    _mvsw=0
    while [ ! -f "$_mvsgo" ]; do
        _mvsw=\$((_mvsw + 1))
        [ "\$_mvsw" -gt 300 ] && { echo "mv-source-pause shim: timed out waiting for the go flag" >&2; exit 1; }
        sleep 0.05 2>/dev/null || sleep 1
    done
fi
exec "$_mvsreal" "\$@"
SHIM
    chmod +x "$_mvsdir/mv" || fixture_die "cannot make the mv-source-pause shim executable"
}

# Pauses "sed" only when its last argument (the file it reads) falls under $4, a known prefix --
# cmd_clean's own post-detach window needs the pause to land after the rename but before
# sentinel_verified decides anything, and sentinel_verified's own "[ -f ]" existence check is a
# builtin, not interceptable; its first and only external command is this sed read. Matched by
# prefix rather than an exact path because the trash directory's own name is mktemp'd and
# unpredictable by design, the same reason mv_source_pause_shim matches on source rather than
# destination. Safe against collision with the OTHER "sed -n 1p" reads this script has (receipts):
# in a clean-only run, nothing else ever reads a path under this prefix.
sed_pause_shim() {
    _spdir="$1"; _spreached="$2"; _spgo="$3"; _spprefix="$4"
    mkdir -p "$_spdir" || fixture_die "cannot create the sed-pause shim dir $_spdir"
    _spreal="$(command -v sed)" || fixture_die "no real sed on PATH to wrap"
    cat > "$_spdir/sed" <<SHIM
#!/bin/sh
for _a in "\$@"; do _splast="\$_a"; done
case "\$_splast" in
    "$_spprefix"*)
        echo "\$\$" > "$_spreached.pid"
        : > "$_spreached"
        _spw=0
        while [ ! -f "$_spgo" ]; do
            _spw=\$((_spw + 1))
            [ "\$_spw" -gt 300 ] && { echo "sed-pause shim: timed out waiting for the go flag" >&2; exit 1; }
            sleep 0.05 2>/dev/null || sleep 1
        done
        ;;
esac
exec "$_spreal" "\$@"
SHIM
    chmod +x "$_spdir/sed" || fixture_die "cannot make the sed-pause shim executable"
}

# Pauses "chmod" only on an argument list containing "u+w" -- cmd_clean's own read-only-clearing
# step ("chmod -R u+w $_trash") before it rm -rf's the detached trash directory. Unambiguous in a
# clean-only run: publish_dir's own "u+w" chmod never executes on that path, so nothing else on the
# way to clean can trip this match. Same pid-file-before-flag ordering as mv_pause_shim, for the
# same reason: a signal sent straight to this recorded pid kills the paused child outright, no need
# to ever release the go flag to make the kill land.
chmod_pause_shim() {
    _cpdir="$1"; _cpreached="$2"; _cpgo="$3"
    mkdir -p "$_cpdir" || fixture_die "cannot create the chmod-pause shim dir $_cpdir"
    _cpreal="$(command -v chmod)" || fixture_die "no real chmod on PATH to wrap"
    cat > "$_cpdir/chmod" <<SHIM
#!/bin/sh
case "\$*" in
    *u+w*)
        echo "\$\$" > "$_cpreached.pid"
        : > "$_cpreached"
        _cpw=0
        while [ ! -f "$_cpgo" ]; do
            _cpw=\$((_cpw + 1))
            [ "\$_cpw" -gt 300 ] && { echo "chmod-pause shim: timed out waiting for the go flag" >&2; exit 1; }
            sleep 0.05 2>/dev/null || sleep 1
        done
        ;;
esac
exec "$_cpreal" "\$@"
SHIM
    chmod +x "$_cpdir/chmod" || fixture_die "cannot make the chmod-pause shim executable"
}

# Pauses "git" only on cmd_install's own hooksPath write ("git -C <root> config core.hooksPath
# .githooks", five arguments exactly), never the read earlier in the same command ("git -C <root>
# config core.hooksPath", four arguments, no value) -- pausing that one too would strand the caller
# before it ever reaches the call under test. Each paused invocation writes "$_reached.$GST_LABEL",
# a label the caller sets per racer (GST_LABEL=1, GST_LABEL=2), not a pid: measured directly against
# git's own lock (not through a full "install"), a poll-with-sleep handshake on either side of the
# release only landed the two racers on top of each other 3-5 times in 15-20 tries -- enough slack
# for one side to slip through git's lock window before the other arrives. A tight, sleep-free
# busy-wait on a plain "[ -f ]" test on both sides (no external `find`/`wc` call standing between a
# racer finishing and the poll noticing) raised that to 12-16 in 15-20. This is still a real race,
# not a guarantee: a clean run on this half proves nothing beyond itself, the same as every other
# probabilistic catch in this suite, but a red one is real, and it now fires often enough to trust
# watching it fail once as real evidence rather than a fluke.
git_pause_shim() {
    _gpdir="$1"; _gpreached="$2"; _gpgo="$3"
    mkdir -p "$_gpdir" || fixture_die "cannot create the git-pause shim dir $_gpdir"
    _gpreal="$(command -v git)" || fixture_die "no real git on PATH to wrap"
    cat > "$_gpdir/git" <<SHIM
#!/bin/sh
if [ "\$#" -eq 5 ] && [ "\$1" = "-C" ] && [ "\$3" = "config" ] && [ "\$4" = "core.hooksPath" ] && [ "\$5" = ".githooks" ]; then
    : > "$_gpreached.\${GST_LABEL:-x}"
    while [ ! -f "$_gpgo" ]; do :; done
fi
exec "$_gpreal" "\$@"
SHIM
    chmod +x "$_gpdir/git" || fixture_die "cannot make the git-pause git shim executable"
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

# ---------------------------------------------------------------------------- platform

printf '\nplatform\n'

it "a non-x86_64 Linux is refused by name, not silently installed as amd64"
# platform()'s Linux branch dies "unsupported arch: $(uname -m)" when uname -m is not x86_64. Nothing
# proved that guard fires: delete it and every existing test still passes, since none of them run on
# anything but this sandbox's own real uname. A uname shim reporting Linux/aarch64 exercises it without
# needing real aarch64 hardware. A curl that always fails keeps this offline and, more importantly,
# keeps the discrimination copy below from quietly reaching this sandbox's real network egress to
# GitHub once the guard is stripped.
#
# rc alone does not discriminate: `ensure` exits non-zero either way (a stripped guard still fails,
# just later, when the real amd64 URL's download is blocked). Two properties depend on nothing but the
# guard, so those are what is asserted: die() writes "unsupported arch: aarch64" to stderr
# unconditionally, before anything downstream can lose track of its exit status; and tool_url never
# returns a real linux URL, so "downloading" -- install_tool's own log line printed right before curl
# ever runs -- never appears.
#
# Both are needed because platform() is always called nested inside another command substitution
# (tool_url's own "$(platform)" argument), which discards its exit status: the actual reason the script
# ends up non-zero here is tool_url separately dying on the resulting empty platform argument ("unknown
# tool: swiftlint"), not platform()'s own die propagating directly. That coupling is a real, separate
# defect (reported alongside this dispatch), not this test's to fix -- so this asserts only the two
# guard-only properties above, never the incidental "unknown tool" line, message ordering, or how many
# times "aarch64" happens to appear.
r=$(new_repo)
pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
_unameshim="$r/uname-shim"; mkdir -p "$_unameshim" || fixture_die "cannot create the uname shim dir"
cat > "$_unameshim/uname" <<'SHIM'
#!/bin/sh
case "$1" in
    -s) echo Linux ;;
    -m) echo aarch64 ;;
    *)  echo Linux ;;
esac
SHIM
chmod +x "$_unameshim/uname" || fixture_die "cannot make the uname shim executable"
_curlshim="$r/curl-blocked"; mkdir -p "$_curlshim" || fixture_die "cannot create the blocked-curl shim dir"
printf '#!/bin/sh\necho "curl: network blocked in test" >&2\nexit 6\n' > "$_curlshim/curl"
chmod +x "$_curlshim/curl" || fixture_die "cannot make the blocked curl shim executable"
_out=$( cd "$r" && PATH="$_unameshim:$_curlshim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
if [ "$_rc" -eq 0 ]; then
    fail "ensure exited 0 on a non-x86_64 Linux instead of refusing: $_out"
elif ! printf '%s' "$_out" | grep -q "aarch64"; then
    fail "refused, but never named the actual arch (aarch64): $_out"
elif printf '%s' "$_out" | grep -q "downloading"; then
    fail "attempted to download an artifact for the wrong arch instead of refusing outright: $_out"
else
    pass
fi

it "ensure on an unsupported arch fails with the guard's own error, not an empty-platform skip"
# #70: install_tool's own "_plat=\"\$(platform)\"" (grubstake.sh:295) is a bare assignment, and
# install_tool runs with errexit suspended for its whole body under cmd_ensure's own
# "install_tool ... || _bad=1" (the same rule the arch-guard test above already relies on for
# install_tool's callers) -- so platform()'s die is printed but its status is discarded there, $_plat
# lands empty, and install_tool falls through to tool_url returning empty for "swiftlint:" (no such
# case) and logs "swiftlint: not published for , skipping" as if this were a legitimate skip (the same
# shape periphery's genuine linux gap uses) rather than a refusal. ensure still ends up non-zero today,
# but only because cmd_check's own independent, later pass over the same tool fails separately (#67) --
# a second, unrelated symptom, not this one being fixed. This fixture pins only swiftlint, so "not
# published for" cannot be the legitimate periphery-on-linux message; widening the fixture to include a
# tool with a genuine platform gap would make that assertion ambiguous.
r=$(new_repo)
pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
_unameshim="$r/uname-shim"; mkdir -p "$_unameshim" || fixture_die "cannot create the uname shim dir"
cat > "$_unameshim/uname" <<'SHIM'
#!/bin/sh
case "$1" in
    -s) echo Linux ;;
    -m) echo aarch64 ;;
    *)  echo Linux ;;
esac
SHIM
chmod +x "$_unameshim/uname" || fixture_die "cannot make the uname shim executable"
_curlshim="$r/curl-blocked"; mkdir -p "$_curlshim" || fixture_die "cannot create the blocked-curl shim dir"
printf '#!/bin/sh\necho "curl: network blocked in test" >&2\nexit 6\n' > "$_curlshim/curl"
chmod +x "$_curlshim/curl" || fixture_die "cannot make the blocked curl shim executable"
_out=$( cd "$r" && PATH="$_unameshim:$_curlshim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
if [ "$_rc" -eq 0 ]; then
    fail "ensure exited 0 on a non-x86_64 Linux: $_out"
elif printf '%s' "$_out" | grep -q "not published for"; then
    fail "install_tool ran on an empty platform and logged a misleading per-tool skip: $_out"
elif printf '%s' "$_out" | grep -q "unknown tool"; then
    fail "the guard's failure was masked by tool_url dying on an empty platform argument: $_out"
elif ! printf '%s' "$_out" | grep -q "unsupported arch: aarch64"; then
    fail "refused, but not with the guard's own message: $_out"
else
    pass
fi

# Shared by every remaining #70 site test below: the same uname stand-in as the two tests above,
# factored out because three more call sites now need it. Not backported into those two: they are
# already reviewed and passing, and this section's rule is add coverage, not churn proven tests.
uname_arch_shim() {
    mkdir -p "$1" || fixture_die "cannot create the uname shim dir"
    cat > "$1/uname" <<'SHIM'
#!/bin/sh
case "$1" in
    -s) echo Linux ;;
    -m) echo aarch64 ;;
    *)  echo Linux ;;
esac
SHIM
    chmod +x "$1/uname" || fixture_die "cannot make the uname shim executable"
}

it "check on an unsupported arch resolves the guard's own message, not an unrelated tool_url death"
# #70's remaining survey item at verify_tool: it now captures "_plat=\"\$(platform)\"" and checks it
# directly, before ever calling tool_url -- unlike the #67-era shape (still in this branch's own git
# history) that called tool_url with platform() nested as its own argument and only caught tool_url's
# resulting "unknown tool" death after the fact. That earlier shape already turned check non-zero and
# already printed "could not resolve for this platform", so a test asserting only those two properties
# would have passed on the #67 shape too, proving nothing about whether tool_url's masking death still
# fires alongside it. Discrimination proof (scratch copy of this repo's own committed HEAD, the #67-era
# verify_tool, spliced in): watched failing -- see this dispatch's report.
r=$(new_repo)
pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
_unameshim="$r/uname-shim"; uname_arch_shim "$_unameshim"
_curlshim="$r/curl-blocked"; mkdir -p "$_curlshim" || fixture_die "cannot create the blocked-curl shim dir"
printf '#!/bin/sh\necho "curl: network blocked in test" >&2\nexit 6\n' > "$_curlshim/curl"
chmod +x "$_curlshim/curl" || fixture_die "cannot make the blocked curl shim executable"
_out=$( cd "$r" && PATH="$_unameshim:$_curlshim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh check 2>&1 ); _rc=$?
if [ "$_rc" -eq 0 ]; then
    fail "check exited 0 on a non-x86_64 Linux: $_out"
elif printf '%s' "$_out" | grep -q "unknown tool"; then
    fail "the guard's failure was masked by tool_url dying on an empty platform argument: $_out"
elif ! printf '%s' "$_out" | grep -q "could not resolve for this platform"; then
    fail "refused, but not with verify_tool's own platform-resolution message: $_out"
else
    pass
fi

it "path on an unsupported arch fails with the guard's own message and prints no path"
# #70's remaining survey item at cmd_path: "_url=\"\$(tool_url \"\$1\" \"\$_ver\" \"\$(platform)\")\""
# nested platform() as tool_url's own argument, unguarded -- the same shape install_tool had before its
# own fix, and the one shape in this file with no catch at all. A refusal that still reaches
# tool_url's own "unknown tool" death is only accidentally non-zero; cmd_path's normal success path
# ends in "echo \"\$_bin\"" on stdout, so a refusal that got there anyway would print a path alongside
# whatever it died on. Discrimination proof (scratch copy of this repo's own committed HEAD, the
# unfixed cmd_path, spliced in): watched failing -- see this dispatch's report.
r=$(new_repo)
pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
_unameshim="$r/uname-shim"; uname_arch_shim "$_unameshim"
_curlshim="$r/curl-blocked"; mkdir -p "$_curlshim" || fixture_die "cannot create the blocked-curl shim dir"
printf '#!/bin/sh\necho "curl: network blocked in test" >&2\nexit 6\n' > "$_curlshim/curl"
chmod +x "$_curlshim/curl" || fixture_die "cannot make the blocked curl shim executable"
_out=$( cd "$r" && PATH="$_unameshim:$_curlshim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh path swiftlint 2>&1 ); _rc=$?
_stdout=$( cd "$r" && PATH="$_unameshim:$_curlshim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh path swiftlint 2>/dev/null )
if [ "$_rc" -eq 0 ]; then
    fail "path exited 0 on a non-x86_64 Linux: $_out"
elif printf '%s' "$_out" | grep -q "unknown tool"; then
    fail "the guard's failure was masked by tool_url dying on an empty platform argument: $_out"
elif ! printf '%s' "$_out" | grep -q "unsupported arch: aarch64"; then
    fail "refused, but not with the guard's own message: $_out"
elif [ -n "$_stdout" ]; then
    fail "printed something on stdout despite refusing: $_stdout"
else
    pass
fi

it "doctor on an unsupported arch stays advisory, without a stray guard message leaking past its report"
# #70's remaining survey item at cmd_doctor covers two nestings. The header's own capture
# ("_plat=\"\$(platform 2>&1)\"") redirects platform()'s stderr into the captured value, so a failure
# there renders cleanly inside doctor's own "platform   ..." line instead of a blank field, and the
# per-tool loop reuses that same captured value rather than re-embedding "$(platform)" per tool, so a
# tool row reads "unsupported platform" instead of silently trying "n/a on " with an empty platform
# name. Neither call site is reached with GRUBSTAKE_CACHE set (every other test in this file sets it),
# so this test deliberately leaves it unset and points HOME at a scratch directory instead: only that
# reaches cache_root's own "$(platform)" nesting -- doctor's sixth and last site, inside
# "elif [ \"\$(platform)\" = darwin ]" -- which is a tested condition, so a failure there is swallowed
# for control-flow purposes (cache_root quietly takes the linux branch) but platform()'s own die() still
# writes to stderr unconditionally, unredirected, leaking a duplicate "[grubstake] unsupported arch"
# line the header's own clean capture does not have. doctor is advisory (confirmed against its own rc
# semantics: a MISSING tool or a drifted hook already reports without failing doctor itself), so this
# asserts exit 0 throughout, not a refusal.
#
# This was watched failing directly against this branch's real grubstake.sh before cache_root's own
# nesting was fixed here (a stray "[grubstake] unsupported arch" line leaking past doctor's clean
# report) -- see this dispatch's report for that verbatim output. cache_root's fix landed on this same
# branch while this dispatch was in progress, so this test is not proven via a scratch-copy mutation
# the way the sibling test below is: the watched failure above already is that proof.
r=$(new_repo)
pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
_unameshim="$r/uname-shim"; uname_arch_shim "$_unameshim"
_fakehome="$r/fake-home"; mkdir -p "$_fakehome" || fixture_die "cannot create the fake HOME dir"
_out=$( cd "$r" && PATH="$_unameshim:$PATH" HOME="$_fakehome" ./grubstake.sh doctor 2>/dev/null ); _rc=$?
_err=$( cd "$r" && PATH="$_unameshim:$PATH" HOME="$_fakehome" ./grubstake.sh doctor 2>&1 1>/dev/null )
if [ "$_rc" -ne 0 ]; then
    fail "doctor exited $_rc on an unsupported arch; doctor is advisory and must still report, not fail: $_out"
elif ! printf '%s\n' "$_out" | grep -q '^platform.*unsupported arch: aarch64'; then
    fail "the platform field did not carry the guard's own message: $_out"
elif ! printf '%s' "$_out" | grep -q "unsupported platform"; then
    fail "the per-tool row did not report an unsupported platform: $_out"
elif [ -n "$_err" ]; then
    fail "a stray '[grubstake] unsupported arch' line leaked to stderr outside doctor's own report: $_err"
else
    pass
fi

it "clean on an unsupported arch refuses instead of silently no-oping on a fabricated cache path"
# #70 critic finding: cmd_clean's own "_root=\"\$(cache_root)\"" is the same bare-assignment shape
# every other site in this file had. cache_root itself reaches the sixth site (its own
# "elif [ \"\$(platform)\" = darwin ]") only when GRUBSTAKE_CACHE is unset, same as the doctor test
# above, so this reuses that fixture exactly: no GRUBSTAKE_CACHE, no XDG_CACHE_HOME, a scratch HOME.
# Pre-fix, cache_root's own platform() failure is swallowed by the tested "elif" condition, so
# cache_root falls through to the linux-shaped "${XDG_CACHE_HOME:-\$HOME/.cache}/grubstake" path built
# from an arch it never actually confirmed, and cmd_clean's "[ -e \"\$_root\" ] || return 0" quietly
# exits 0 since nothing was ever created at that fabricated path -- a clean that never ran, reporting
# success. The fix (this branch's own "_root=\"\$(cache_root)\" || die ...") makes that refusal
# explicit instead. Discrimination proof (scratch copy of this repo's own committed HEAD, the unfixed
# cache_root and cmd_clean, spliced in): watched failing -- see this dispatch's report.
r=$(new_repo)
_unameshim="$r/uname-shim"; uname_arch_shim "$_unameshim"
_fakehome="$r/fake-home"; mkdir -p "$_fakehome" || fixture_die "cannot create the fake HOME dir"
_out=$( cd "$r" && env -u GRUBSTAKE_CACHE -u XDG_CACHE_HOME PATH="$_unameshim:$PATH" HOME="$_fakehome" ./grubstake.sh clean 2>&1 ); _rc=$?
if [ "$_rc" -eq 0 ]; then
    fail "clean exited 0 on an unsupported arch instead of refusing: $_out"
elif ! printf '%s' "$_out" | grep -q "cannot determine the cache root"; then
    fail "refused, but not with cmd_clean's own cache-root message: $_out"
else
    pass
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

# ---------------------------------------------------------------------------- keyed pins

printf '\nkeyed pins format\n'

it "a keyed line resolves the version and both platforms' shas"
r=$(new_repo); pins "$r" "swiftlint 0.63.2 darwin=$SHA_A linux=$SHA_B"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"
fake_install "$r" swiftlint 0.63.2 "$SHA_B"
_dshim="$r/uname-darwin"; mkdir -p "$_dshim" || fixture_die "cannot create the darwin uname shim dir"
cat > "$_dshim/uname" <<'SHIM'
#!/bin/sh
case "$1" in
    -s) echo Darwin ;;
    *)  echo Darwin ;;
esac
SHIM
chmod +x "$_dshim/uname" || fixture_die "cannot make the darwin uname shim executable"
_lshim="$r/uname-linux"; mkdir -p "$_lshim" || fixture_die "cannot create the linux uname shim dir"
cat > "$_lshim/uname" <<'SHIM'
#!/bin/sh
case "$1" in
    -s) echo Linux ;;
    -m) echo x86_64 ;;
    *)  echo Linux ;;
esac
SHIM
chmod +x "$_lshim/uname" || fixture_die "cannot make the linux uname shim executable"
_dout=$( cd "$r" && PATH="$_dshim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh path swiftlint 2>/dev/null )
_lout=$( cd "$r" && PATH="$_lshim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh path swiftlint 2>/dev/null )
_dver=$(gs "$r" doctor | awk '/^  swiftlint/{print $2}')
if [ "$_dout" != "$r/.cache/swiftlint/$SHA_A/swiftlint" ]; then
    fail "darwin key did not resolve to the darwin-keyed sha: $_dout"
elif [ "$_lout" != "$r/.cache/swiftlint/$SHA_B/swiftlint" ]; then
    fail "linux key did not resolve to the linux-keyed sha: $_lout"
elif [ "$_dver" != "0.63.2" ]; then
    fail "version did not resolve off a keyed line: $_dver"
else
    pass
fi

it "positional and keyed lines coexist in one pins file"
r=$(new_repo)
pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A
xcbeautify 1.6.2 darwin=$SHA_B linux=$SHA_B"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"
fake_install "$r" xcbeautify 1.6.2 "$SHA_B"
expect_ok "$r" check

it "an unknown key on a keyed line is tolerated, and the known key still resolves"
r=$(new_repo); pins "$r" "swiftlint 0.63.2 darwin=$SHA_A linux=$SHA_A windows=$SHA_A"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"
expect_ok "$r" check

it "a key omitted from a keyed line behaves like a positional '-'"
r=$(new_repo); pins "$r" "swiftlint 0.63.2 darwin=$SHA_A"
_lshim="$r/uname-linux"; mkdir -p "$_lshim" || fixture_die "cannot create the linux uname shim dir"
cat > "$_lshim/uname" <<'SHIM'
#!/bin/sh
case "$1" in
    -s) echo Linux ;;
    -m) echo x86_64 ;;
    *)  echo Linux ;;
esac
SHIM
chmod +x "$_lshim/uname" || fixture_die "cannot make the linux uname shim executable"
_out=$( cd "$r" && PATH="$_lshim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh path swiftlint 2>&1 ); _rc=$?
if [ "$_rc" -eq 0 ]; then
    fail "path exited 0 on linux with no linux key pinned: $_out"
else
    case "$_out" in
        *"no linux hash"*) pass ;;
        *) fail "refused, but not with install_tool's own missing-hash message: $_out" ;;
    esac
fi

it "a malformed keyed field is rejected as malformed, not merely non-zero"
r=$(new_repo); pins "$r" "swiftlint 0.63.2 darwin=$SHA_A linux=nothex"
_out=$(gs "$r" check); _rc=$?
if [ "$_rc" -eq 0 ]; then
    fail "check exited 0 over a malformed keyed field: $_out"
else
    case "$_out" in
        *"malformed keyed field"*) pass ;;
        *) fail "refused, but not with the keyed-field guard's own message: $_out" ;;
    esac
fi

it "a positional line missing both shas still dies under the keyed-aware parser"
r=$(new_repo); pins "$r" "swiftlint 0.63.2"; expect_fail "$r" check

it "a keyed line with a duplicate key is rejected as a duplicate, not merely non-zero"
r=$(new_repo); pins "$r" "swiftlint 0.63.2 darwin=$SHA_A darwin=$SHA_B"
_out=$(gs "$r" check); _rc=$?
if [ "$_rc" -eq 0 ]; then
    fail "check exited 0 over a duplicate key: $_out"
else
    case "$_out" in
        *"duplicate key"*) pass ;;
        *) fail "refused, but not with the duplicate-key guard's own message: $_out" ;;
    esac
fi

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
printf 'cache-root 1\n' > "$r/.cache/.grubstake-cache-root"   # fake_install bypasses install_tool, which is what writes this for real (#95)
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

# ---------------------------------------------------------------------------- cache integrity: clean ownership
#
# #95: clean's checks (absolute, not root, not a symlink) say nothing about whether grubstake is the
# one that put the directory there. GRUBSTAKE_CACHE is a normal, documented override -- a CI job
# exporting it alongside a workspace path, a shell profile set once and forgotten -- so the trigger
# is a routine misconfiguration, not an exotic one, and clean silently destroys whatever it finds.

it "clean refuses a cache root it never created, and leaves its contents untouched"
# #95's own fix verifies the sentinel AFTER detaching, not before (see the TOCTOU test below), so
# a plain refusal like this one is no longer "never touched" at the filesystem level -- it is a
# rename out and a rename back. Content surviving byte-for-byte is not enough to tell that apart
# from a destroy-and-recreate that happens to reproduce the same bytes; the inode check below is
# what actually pins "the same file," the same idiom the receipt-in-place tests already use.
r=$(new_repo)
_victim="$r/not-a-cache"
mkdir -p "$_victim/subdir" || fixture_die "cannot create $_victim/subdir"
printf 'do not delete me\n' > "$_victim/keep.txt" || fixture_die "cannot write $_victim/keep.txt"
printf 'nested\n' > "$_victim/subdir/nested.txt" || fixture_die "cannot write $_victim/subdir/nested.txt"
_inode_before="$(ls -i "$_victim/keep.txt" | awk '{print $1}')"
_out=$( cd "$r" && GRUBSTAKE_CACHE="$_victim" ./grubstake.sh clean 2>&1 ); _rc=$?
_inode_after="$(ls -i "$_victim/keep.txt" 2>/dev/null | awk '{print $1}')"
if [ "$_rc" -eq 0 ]; then
    fail "clean exited 0 removing a directory it never created: $_out"
elif [ ! -e "$_victim" ]; then
    fail "the directory was removed even though clean refused: $_out"
elif [ "$(cat "$_victim/keep.txt" 2>/dev/null)" != "do not delete me" ] || [ "$(cat "$_victim/subdir/nested.txt" 2>/dev/null)" != "nested" ]; then
    fail "clean disturbed the directory's contents even though it refused: $_out"
elif [ "$_inode_after" != "$_inode_before" ]; then
    fail "the file was recreated (inode changed) rather than the same bytes surviving a detach-and-restore: $_out"
else
    case "$_out" in
        *"$_victim"*) pass ;;
        *) fail "refused without naming the path: $_out" ;;
    esac
fi

it "clean still removes a cache root grubstake itself created just now"
# Points GRUBSTAKE_CACHE at a path new_repo never touches -- new_repo's own ".cache" already exists
# (empty) before this runs, which would leave an implementation that keys the sentinel off "did this
# exact mkdir just create the directory" untested on the one case that actually matters here.
r=$(new_repo)
_sha=$(fake_release "$r" 0.63.2)
pins "$r" "swiftlint 0.63.2 $_sha $_sha"
_cache="$r/fresh-cache"
[ ! -e "$_cache" ] || fixture_die "fixture cache root already exists before ensure: $_cache"
_out=$( cd "$r" && PATH="$r/curl-shim:$PATH" GRUBSTAKE_CACHE="$_cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
[ "$_rc" -eq 0 ] || fixture_die "cannot seed a real install to clean afterward (rc $_rc): $_out"
[ -e "$_cache" ] || fixture_die "ensure exited 0 but never created $_cache"
_cleanout=$( cd "$r" && GRUBSTAKE_CACHE="$_cache" ./grubstake.sh clean 2>&1 ); _cleanrc=$?
if [ "$_cleanrc" -ne 0 ]; then
    fail "clean refused a cache root grubstake itself had just created: $_cleanout"
elif [ -e "$_cache" ]; then
    fail "clean exited 0 but $_cache is still there"
else
    pass
fi

it "a pre-sentinel cache root is refused by clean even when its layout looks exactly like one grubstake made"
# The sharpest edge of #95's fix: a directory shaped like a real published entry -- the tool/hash
# layout, an executable binary, a receipt -- is not proof grubstake put it there, only that its
# shape matches. Adopting on shape alone reopens the same hole a hand-built decoy would exploit;
# only the sentinel counts. Built by hand rather than fake_install, which never writes a receipt.
r=$(new_repo)
_legacy="$r/legacy-cache"
mkdir -p "$_legacy/swiftlint/$SHA_A" || fixture_die "cannot create $_legacy/swiftlint/$SHA_A"
printf '#!/bin/sh\necho 0.63.2\n' > "$_legacy/swiftlint/$SHA_A/swiftlint" || fixture_die "cannot write the fixture binary"
chmod +x "$_legacy/swiftlint/$SHA_A/swiftlint" || fixture_die "cannot make the fixture binary executable"
printf 'receipt 1\nbinary-sha256 %s\nversion 0.63.2\n' "$SHA_A" > "$_legacy/swiftlint/$SHA_A/.grubstake-receipt" || fixture_die "cannot write the fixture receipt"
_out=$( cd "$r" && GRUBSTAKE_CACHE="$_legacy" ./grubstake.sh clean 2>&1 ); _rc=$?
if [ "$_rc" -eq 0 ]; then
    fail "clean removed a cache-shaped root with no sentinel, on layout alone: $_out"
elif [ ! -x "$_legacy/swiftlint/$SHA_A/swiftlint" ]; then
    fail "the legacy entry was touched even though clean refused: $_out"
else
    case "$_out" in
        *"$_legacy"*) pass ;;
        *) fail "refused without naming the path: $_out" ;;
    esac
fi

it "ensure backfills a pre-sentinel cache root once, so an upgrade does not wedge clean forever"
# The other half of the same design call: refusing every pre-1.0.1 cache forever would be safe but
# permanently locks existing users out of clean. install_tool already backfills a missing receipt
# the same way for an individual legacy entry (see the comment at its own backfill, "the same trust
# the entry already had, now with a baseline to drift from") -- the root sentinel follows the same
# rule, backfilled the moment grubstake actively manages the root, never inferred from its shape.
# Receiptless, not a hand-built receipt: this is exactly the shape a pre-receipt release left
# behind (same fixture "a legacy entry is upgraded to a receipt without ceremony" uses), and a
# receipt with a hash that does not match the fixture binary would hit the mismatch branch instead
# of the backfill one, failing ensure for an unrelated reason.
r=$(new_repo)
_legacy="$r/legacy-cache"
mkdir -p "$_legacy/swiftlint/$SHA_A" || fixture_die "cannot create $_legacy/swiftlint/$SHA_A"
printf '#!/bin/sh\necho 0.63.2\n' > "$_legacy/swiftlint/$SHA_A/swiftlint" || fixture_die "cannot write the fixture binary"
chmod +x "$_legacy/swiftlint/$SHA_A/swiftlint" || fixture_die "cannot make the fixture binary executable"
pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
_out=$( cd "$r" && GRUBSTAKE_CACHE="$_legacy" ./grubstake.sh ensure 2>&1 ); _rc=$?
[ "$_rc" -eq 0 ] || fixture_die "ensure failed against a legacy entry it should self-heal offline (rc $_rc): $_out"
_cleanout=$( cd "$r" && GRUBSTAKE_CACHE="$_legacy" ./grubstake.sh clean 2>&1 ); _cleanrc=$?
if [ "$_cleanrc" -ne 0 ]; then
    fail "clean still refused a pre-sentinel root after ensure had already run against it: $_cleanout"
elif [ -e "$_legacy" ]; then
    fail "clean exited 0 but $_legacy is still there"
else
    pass
fi

it "an unreadable or content-invalid sentinel is repaired by ensure, not left to wedge clean forever"
# Presence alone was never proof; #95's follow-up panel found the same gap one level deeper: a
# sentinel that EXISTS but fails verification (interrupted mid-write, clobbered by an unrelated
# tool, or simply unreadable) wedges clean the same way absence did, unless ensure repairs it the
# moment it manages the root again -- the same self-heal contract as the receipt/root backfills
# above. "unreadable" (chmod 000, non-root) turns out to hit this exact same repair path rather than
# a distinct one: rename() permission is governed by the containing directory's write bit, not the
# target file's own mode, so mv freely replaces a 000 sentinel the same as an empty or foreign one
# once ensure_cache_sentinel decides to overwrite it -- confirmed here rather than assumed, folded in
# as a third case instead of a redundant fourth test.
for _case in empty foreign unreadable; do
    r=$(new_repo)
    pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
    fake_install "$r" swiftlint 0.63.2 "$SHA_A"
    case "$_case" in
        empty)      : > "$r/.cache/.grubstake-cache-root" ;;
        foreign)    printf '.DS_Store\n*.log\nnode_modules/\n' > "$r/.cache/.grubstake-cache-root" ;;
        unreadable) printf 'cache-root 1\n' > "$r/.cache/.grubstake-cache-root"
                    chmod 000 "$r/.cache/.grubstake-cache-root" || fixture_die "cannot chmod 000 the fixture sentinel" ;;
    esac
    _out=$( cd "$r" && GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
    if [ "$_rc" -ne 0 ]; then
        fail "case '$_case': ensure exited $_rc instead of repairing the sentinel: $_out"; _bad=1; break
    fi
    _cleanout=$( cd "$r" && GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh clean 2>&1 ); _cleanrc=$?
    if [ "$_cleanrc" -ne 0 ]; then
        fail "case '$_case': clean still refused after ensure had a chance to repair the sentinel: $_cleanout"; _bad=1; break
    elif [ -e "$r/.cache" ]; then
        fail "case '$_case': clean exited 0 but the cache root is still there"; _bad=1; break
    fi
    chmod -R u+w "$r/.cache" 2>/dev/null
done
[ "${_bad:-0}" = 0 ] && pass; _bad=0

it "ensure refuses to nest into a directory squatting at the sentinel path, and does not litter tmp files on repeat runs"
# The other half of the same follow-up finding: a directory (not a plain file) at the sentinel path
# cannot be repaired by overwriting -- mv nests into an existing directory rather than replacing it,
# no mv -T on macOS -- so silently proceeding would either nest a real tmp file one level deep on
# every future install_tool call (never cleaned up, growing forever) or, worse, read as success while
# never actually recording ownership. Two ensures, not one: a single run cannot tell "wrote nothing"
# apart from "wrote once, harmlessly," only a second run distinguishes ongoing litter from a one-time
# no-op.
r=$(new_repo)
pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"
mkdir -p "$r/.cache/.grubstake-cache-root" || fixture_die "cannot create the squatting directory"
_out1=$( cd "$r" && GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc1=$?
_out2=$( cd "$r" && GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc2=$?
_litter=$(find "$r/.cache" -name '.grubstake-cache-root.tmp.*' 2>/dev/null)
# Litter checked first: it is the assertion #95's follow-up named explicitly (a nested tmp file left
# behind after two runs), so it must fire on its own rather than always being pre-empted by the
# no-diagnostic branch below -- both are real defects a naive fix could reintroduce independently.
if [ -n "$_litter" ]; then
    fail "ensure littered a stray tmp file at the sentinel path after two runs against a squatting directory: $_litter"
elif [ "$_rc1" -eq 0 ] && ! printf '%s' "$_out1" | grep -qiE "not a regular file|could not write|refus|leaving it in place"; then
    fail "ensure exited 0 against a directory squatting at the sentinel path without saying anything about it: $_out1"
elif [ ! -d "$r/.cache/.grubstake-cache-root" ]; then
    fail "the squatting directory was replaced rather than left alone -- shape-based adoption, the exact #95 hole this exists to close"
else
    pass
fi
chmod -R u+w "$r/.cache" 2>/dev/null

it "an interrupted clean does not strand a full copy of the cache beside the root"
# mv detaches the root, chmod clears read-only, then rm -rf removes the trash. A signal landing
# between the mv and the rm -rf must not kill the process outright and leave the trash -- a full
# copy of the cache -- sitting beside the (now-empty) root forever, recoverable only by hand.
# chmod_pause_shim lands the signal at that exact window; exec replaces the backgrounded subshell
# with grubstake.sh outright, so "$!" is its own pid, the same technique #62's own signal tests use.
r=$(new_repo)
pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"
printf 'cache-root 1\n' > "$r/.cache/.grubstake-cache-root"   # fake_install bypasses install_tool, which is what writes this for real (#95)
_shim="$r/chmod-shim"; _reached="$r/reached"; _go="$r/go"
chmod_pause_shim "$_shim" "$_reached" "$_go"
(
    cd "$r" || exit 1
    PATH="$_shim:$PATH"; export PATH
    GRUBSTAKE_CACHE="$r/.cache"; export GRUBSTAKE_CACHE
    exec ./grubstake.sh clean >"$r/out" 2>&1
) &
_bgpid=$!
_w=0
while [ ! -f "$_reached" ]; do
    _w=$((_w + 1))
    [ "$_w" -gt 300 ] && fixture_die "clean never reached its own read-only-clearing chmod"
    sleep 0.05 2>/dev/null || sleep 1
done
[ -e "$r/.cache" ] && fixture_die "reached the chmod step but the cache root was never renamed aside first"
_trash=$(printf '%s\n' "$r/.cache".trash.* 2>/dev/null | head -1)
[ -n "$_trash" ] && [ -d "$_trash" ] || fixture_die "could not find the trash directory clean should have created by now: the race window is not real"
_t0=$(date +%s)
kill -TERM "$_bgpid" 2>/dev/null
wait "$_bgpid" 2>/dev/null
_t1=$(date +%s)
_elapsed=$((_t1 - _t0))
# The paused chmod shim is a grandchild (forked by the exec'd grubstake.sh, not by this shell), and
# POSIX "wait" only ever waits on this shell's own direct children -- called on anything else it
# returns 127 immediately, which had been read here as "waited," giving false confidence the kill
# had actually landed before the filesystem checks below ran. Polling "kill -0" is what actually
# confirms the process is gone; timed out separately from _elapsed, above, so a slow-to-reap
# grandchild cannot itself push a correctly-fast kill over the "signal never landed" threshold.
if [ -f "$_reached.pid" ]; then
    _gpid="$(cat "$_reached.pid")"
    kill -TERM "$_gpid" 2>/dev/null
    _gw=0
    while kill -0 "$_gpid" 2>/dev/null; do
        _gw=$((_gw + 1))
        [ "$_gw" -gt 100 ] && break
        sleep 0.05 2>/dev/null || sleep 1
    done
fi
_survivor=$(printf '%s\n' "$r/.cache".trash.* 2>/dev/null | head -1)
# Two things have to both be true for the assertion below to mean what it says, not just "no trash
# happened to be lying around": the process the TERM was sent to must actually be gone (kill -0
# fails), not merely reaped for an unrelated reason, and it must have died fast -- the paused chmod
# shim's own 15s timeout (300 * 0.05s) is what "completed on its own, TERM never really landed"
# would look like, so a near-instant death is what tells a real interrupt apart from that.
if kill -0 "$_bgpid" 2>/dev/null; then
    fail "the backgrounded clean did not actually die from the TERM signal"
elif [ "$_elapsed" -ge 5 ]; then
    fail "took ${_elapsed}s to die: the signal likely never landed, and the paused chmod ran out its own timeout instead of being killed"
elif [ -n "$_survivor" ] && [ -e "$_survivor" ]; then
    fail "an interrupted clean stranded a full copy of the cache beside the root: $_survivor"
else
    pass
fi
chmod -R u+w "$r/.cache" 2>/dev/null

it "a root swapped out between clean's sentinel check and its rename is deleted anyway, sentinel or not"
# Outside review, post-panel: clean verifies the sentinel, THEN renames the root into the trash --
# two separate steps, not one atomic operation. Between them, another process can rename the
# verified root away and drop an unrelated directory at the same path; clean's rename then grabs
# whatever is there NOW, not what it just checked, and deletes it. The symlink guard does not help
# here -- a symlink swap is what rm -rf on a symlink already tolerates (it removes the link, not the
# target), but this is a real directory replacing a real directory at the same path, and mv follows
# the path, not an identity it verified earlier. mv_source_pause_shim lands the pause before the
# rename ever touches disk, which is where the swap below happens; the real mv, once released,
# operates on whatever mkdir/mv left at that path in the meantime, exactly reproducing the race
# without needing to win a real one.
r=$(new_repo)
pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"
printf 'cache-root 1\n' > "$r/.cache/.grubstake-cache-root"   # fake_install bypasses install_tool, which is what writes this for real (#95)
_marker="important-data.txt"; _markercontent="do not delete me"
mkdir -p "$r/swap-src" || fixture_die "cannot create the swap-in staging directory"
printf '%s\n' "$_markercontent" > "$r/swap-src/$_marker" || fixture_die "cannot write the swap-in marker file"
_shim="$r/mv-shim"; _reached="$r/reached"; _go="$r/go"
mv_source_pause_shim "$_shim" "$_reached" "$_go" "$r/.cache"
( cd "$r" && PATH="$_shim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh clean >"$r/out" 2>&1; echo $? > "$r/rc" ) &
_bgpid=$!
_w=0
while [ ! -f "$_reached" ]; do
    _w=$((_w + 1))
    [ "$_w" -gt 300 ] && fixture_die "clean never reached the paused rename"
    sleep 0.05 2>/dev/null || sleep 1
done
# The swap itself: the verified, sentineled root is relocated out of clean's way (standing in for
# whatever the concurrent process did with it -- irrelevant to this test beyond "not at $r/.cache
# anymore"), and an unrelated, sentinel-less directory takes its exact path before the paused mv is
# released to grab it.
mv "$r/.cache" "$r/.cache-holding" || fixture_die "cannot relocate the verified root for the swap"
mv "$r/swap-src" "$r/.cache" || fixture_die "cannot swap the unrelated directory into $r/.cache"
: > "$_go"
wait "$_bgpid" 2>/dev/null
[ -f "$r/rc" ] || fixture_die "the backgrounded clean never recorded an exit status"
_rc="$(cat "$r/rc")"
_out="$(cat "$r/out" 2>/dev/null)"
_trashleft=$(printf '%s\n' "$r/.cache".trash.* 2>/dev/null | head -1)
# "-n" alone cannot tell a real trash directory apart from an unmatched glob: dash's default (no
# nullglob) leaves the pattern unexpanded when nothing matches, and that literal string is itself
# non-empty, so "-n" reads "nothing survived" as "something survived" every time. "-e" is what
# actually asks the filesystem, the same guard the sibling interrupted-clean test's own $_survivor
# check above already uses.
if [ "$_rc" -eq 0 ]; then
    fail "clean exited 0 after the root was swapped mid-race, instead of refusing: $_out"
elif [ ! -e "$r/.cache" ] && { [ -z "$_trashleft" ] || [ ! -e "$_trashleft" ]; }; then
    fail "the swapped-in directory was deleted outright: clean verified one directory's sentinel and destroyed a different one at the same path -- the exact TOCTOU this test exists to catch: $_out"
elif [ ! -e "$r/.cache" ] && [ -n "$_trashleft" ] && [ -e "$_trashleft" ]; then
    fail "the swapped-in directory was detached into $_trashleft and never restored to $r/.cache after the refusal"
elif [ -n "$_trashleft" ] && [ -e "$_trashleft" ]; then
    fail "clean refused correctly but left a trash directory behind: $_trashleft"
elif [ "$(cat "$r/.cache/$_marker" 2>/dev/null)" != "$_markercontent" ]; then
    fail "$r/.cache exists but its contents do not match the swapped-in directory -- something else ended up there"
else
    pass
fi
chmod -R u+w "$r/.cache" "$r/.cache-holding" 2>/dev/null

it "a signal landing after clean detaches the root but before verification decides restores it, not deletes it"
# Sol's finding, post-panel: the EXIT/HUP/INT/TERM trap arms before the rename (so a signal during
# the later chmod/rm-rf cannot strand the trash -- the interrupted-clean test above already proves
# that half, on a root that DID verify) and stays armed straight through verification itself.
# clean_trash_on_signal deletes $_trash unconditionally, with no idea whether sentinel_verified has
# had a chance to run yet. A signal landing in that window destroys content that was never checked --
# the exact property #95 exists to guarantee, reopened one signal-handler away from the fix that
# closed it for the non-signal path. sed_pause_shim anchors on sentinel_verified's own read (the
# first and only externally-interceptable step between the rename and the verdict); mv_source_pause_shim
# cannot reach this window at all, since it pauses BEFORE the rename, not after.
# sentinel_verified's own "[ -f ]" existence check is a builtin, not something a shim can pause on --
# a victim directory with no file at all at the sentinel path short-circuits there and never reaches
# sed, so this one needs a foreign file AT that exact name (a stray dotfile some other tool left, not
# grubstake's) to make "[ -f ]" true and actually drive execution into the read this test pauses on.
r=$(new_repo)
_victim="$r/not-a-cache"
mkdir -p "$_victim/subdir" || fixture_die "cannot create $_victim/subdir"
printf 'do not delete me\n' > "$_victim/keep.txt" || fixture_die "cannot write $_victim/keep.txt"
printf 'not a grubstake sentinel\n' > "$_victim/.grubstake-cache-root" || fixture_die "cannot write the foreign sentinel-path file"
printf 'nested\n' > "$_victim/subdir/nested.txt" || fixture_die "cannot write $_victim/subdir/nested.txt"
_shim="$r/sed-shim"; _reached="$r/reached"; _go="$r/go"
sed_pause_shim "$_shim" "$_reached" "$_go" "$_victim.trash."
(
    cd "$r" || exit 1
    PATH="$_shim:$PATH"; export PATH
    GRUBSTAKE_CACHE="$_victim"; export GRUBSTAKE_CACHE
    exec ./grubstake.sh clean >"$r/out" 2>&1
) &
_bgpid=$!
_w=0
while [ ! -f "$_reached" ]; do
    _w=$((_w + 1))
    [ "$_w" -gt 300 ] && fixture_die "clean never reached the paused sentinel read"
    sleep 0.05 2>/dev/null || sleep 1
done
[ -e "$_victim" ] && fixture_die "reached the sentinel read but the root was never detached first: the race window is not real"
_trash=$(printf '%s\n' "$_victim".trash.* 2>/dev/null | head -1)
[ -n "$_trash" ] && [ -d "$_trash/detached" ] || fixture_die "could not find the detached content clean should have created by now"
kill -TERM "$_bgpid" 2>/dev/null
wait "$_bgpid" 2>/dev/null
if [ -f "$_reached.pid" ]; then
    _gpid="$(cat "$_reached.pid")"
    kill -TERM "$_gpid" 2>/dev/null
    _gw=0
    while kill -0 "$_gpid" 2>/dev/null; do
        _gw=$((_gw + 1))
        [ "$_gw" -gt 100 ] && break
        sleep 0.05 2>/dev/null || sleep 1
    done
fi
_trashleft=$(printf '%s\n' "$_victim".trash.* 2>/dev/null | head -1)
if [ ! -e "$_victim" ]; then
    fail "the unverified directory was deleted by the signal handler instead of being restored: never checked, destroyed anyway -- the exact property #95 promises: $(cat "$r/out" 2>/dev/null)"
elif [ -n "$_trashleft" ] && [ -e "$_trashleft" ]; then
    fail "the root was restored to $_victim but the trash container $_trashleft was left behind"
elif [ "$(cat "$_victim/keep.txt" 2>/dev/null)" != "do not delete me" ] || [ "$(cat "$_victim/subdir/nested.txt" 2>/dev/null)" != "nested" ]; then
    fail "the directory came back but its contents do not match what was detached"
else
    pass
fi
chmod -R u+w "$_victim" 2>/dev/null

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

it "ensure fails fast on a permission-denied lock, not a five-second contention stall"
# #88: with_lock decides why its own "mkdir" failed by testing "[ -d "$_lkdir" ]" afterwards, which
# answers "does the parent still exist," not "why did the write fail." A lock directory whose own
# parent has lost its write bit fails mkdir with EACCES, but the parent is still perfectly readable
# and traversable (555 keeps the execute bit), so "[ -d ]" reports true -- the same as ordinary
# EEXIST contention -- and the retry loop spins its full budget before dying blaming a holder that
# was never there. fake_install, not fake_release: this needs no download, only a legacy
# (receiptless) entry that reaches with_lock through install_tool's own write_receipt call, the
# cheapest path to the mkdir under test, same technique the vanished-cache-root test above uses.
r=$(new_repo)
pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"
chmod 555 "$r/.cache/swiftlint" || fixture_die "cannot make $r/.cache/swiftlint read-only"
_t0=$(date +%s)
_out=$( cd "$r" && GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
_t1=$(date +%s)
chmod 755 "$r/.cache/swiftlint" 2>/dev/null
_elapsed=$((_t1 - _t0))
if [ "$_rc" -eq 0 ]; then
    fail "ensure exited 0 despite a permission-denied lock directory: $_out"
elif [ "$_elapsed" -ge 3 ]; then
    fail "ensure spun ${_elapsed}s instead of failing fast on a non-retryable permission denial: $_out"
elif printf '%s' "$_out" | grep -qi "locked by another run"; then
    fail "blamed a lock nobody held instead of the real permission failure: $_out"
elif ! printf '%s' "$_out" | grep -qi "permission denied"; then
    fail "did not carry the real cause (permission denied): $_out"
else
    pass
fi

it "ensure blames an unreadable ancestor honestly, not a cache that was never removed"
# The other wrong diagnosis at the same site: "[ -d "$_lkdir" ]" is answering the existence
# question from the lock's own parent, ".cache/<tool>", but an ancestor further up (".cache"
# itself) can be the thing that becomes untraversable, which fails that existence test too --
# indistinguishable, to with_lock, from the parent genuinely having been removed by a concurrent
# clean (the #56 case the vanished-cache-root test above covers). Nothing was removed here; only a
# permission bit changed. A static pre-chmod cannot isolate this cleanly: install_tool's own
# "[ -x "$_bin" ]" check reads the identical ".cache" ancestor before with_lock ever runs, so
# chmod'ing it up front just makes the tool look not-yet-installed and take an entirely different
# path. Shimming "mkdir" to flip the permission the instant a "*.lock" path is attempted -- the same
# match lock_pause_shim uses, since that mkdir shape is with_lock's alone -- lands the change after
# the earlier check has already passed and right before the one under test.
r=$(new_repo)
pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"
_shim="$r/mkdir-shim"; mkdir -p "$_shim" || fixture_die "cannot create $_shim"
_realmkdir="$(command -v mkdir)" || fixture_die "no real mkdir on PATH to wrap"
cat > "$_shim/mkdir" <<SHIM
#!/bin/sh
case "\$*" in
    *.lock)
        chmod 000 "$r/.cache"
        ;;
esac
exec "$_realmkdir" "\$@"
SHIM
chmod +x "$_shim/mkdir" || fixture_die "cannot make the mkdir shim executable"
_t0=$(date +%s)
_out=$( cd "$r" && PATH="$_shim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
_t1=$(date +%s)
chmod 755 "$r/.cache" 2>/dev/null
_elapsed=$((_t1 - _t0))
if [ "$_rc" -eq 0 ]; then
    fail "ensure exited 0 despite its own cache ancestor being unreadable: $_out"
elif [ "$_elapsed" -ge 3 ]; then
    fail "ensure spun ${_elapsed}s on an unreadable ancestor instead of failing fast: $_out"
elif printf '%s' "$_out" | grep -qi "removed the cache mid-install"; then
    fail "claimed the cache was removed when only a permission bit changed: $_out"
elif ! printf '%s' "$_out" | grep -Eqi "permission|denied|access|unreadable|cannot (read|search|traverse)"; then
    fail "failed fast without naming the real cause: $_out"
else
    pass
fi

it "a cache path containing the discriminator's own match text does not turn a permission denial into contention"
# Panel review on #88: the fix reads mkdir's own stderr and discriminates with "case ... in
# *"File exists"*)", but that match is unanchored -- it fires if the substring appears ANYWHERE in
# the captured text, and the captured text is mkdir's whole message, path included ("mkdir: <path>:
# <reason>"). A cache rooted at a directory literally named "File exists.cache" makes every lock
# path under it contain that text regardless of what actually went wrong, so a genuine permission
# denial on the lock's own parent reads as contention again -- the exact defect this branch exists
# to remove, reopened by the fix meant to close it. GRUBSTAKE_CACHE can point anywhere; it does not
# need to live under the repo, so the collision text sits in the cache root itself here.
r=$(new_repo)
_cache="$ROOT/lock-collision.$$/File exists.cache"
mkdir -p "$_cache/swiftlint/$SHA_A" || fixture_die "cannot create $_cache/swiftlint/$SHA_A"
printf '#!/bin/sh\necho 0.63.2\n' > "$_cache/swiftlint/$SHA_A/swiftlint" || fixture_die "cannot write the fixture binary"
chmod +x "$_cache/swiftlint/$SHA_A/swiftlint" || fixture_die "cannot make the fixture binary executable"
pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
chmod 555 "$_cache/swiftlint" || fixture_die "cannot make $_cache/swiftlint read-only"
_t0=$(date +%s)
_out=$( cd "$r" && GRUBSTAKE_CACHE="$_cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
_t1=$(date +%s)
chmod 755 "$_cache/swiftlint" 2>/dev/null
_elapsed=$((_t1 - _t0))
if [ "$_rc" -eq 0 ]; then
    fail "ensure exited 0 despite a permission-denied lock directory: $_out"
elif [ "$_elapsed" -ge 3 ]; then
    fail "ensure spun ${_elapsed}s instead of failing fast on a non-retryable permission denial: $_out"
elif printf '%s' "$_out" | grep -qi "locked by another run"; then
    fail "a cache path containing the discriminator's own text was misread as contention: $_out"
elif ! printf '%s' "$_out" | grep -qi "permission denied"; then
    fail "did not carry the real cause (permission denied): $_out"
else
    pass
fi

it "a cache path containing the discriminator's own match text still reports a genuinely vanished parent as gone, not locked"
# The mirror the panel asked for: an over-broad fix that matches "File exists" anywhere, rather than
# only where mkdir's own message actually reports it, can also misfire in the other direction. Here
# the lock's parent is genuinely removed (mkdir's real message ends "No such file or directory"),
# but the message still contains "File exists" too, purely because the collision text sits earlier
# in the same string as the cache root's name -- an unanchored match on a case arm listed before the
# ENOENT arm wins on substring presence alone, misreporting a real removal as a lock nobody held.
# The existing mkdir-shim technique still applies: the shim removes the lock's own parent instead of
# chmod'ing it, right before letting the real mkdir run, which is what actually produces a genuine
# ENOENT (not read-only-directory noise) here.
r=$(new_repo)
_cache="$ROOT/lock-collision-gone.$$/File exists.cache"
mkdir -p "$_cache/swiftlint/$SHA_A" || fixture_die "cannot create $_cache/swiftlint/$SHA_A"
printf '#!/bin/sh\necho 0.63.2\n' > "$_cache/swiftlint/$SHA_A/swiftlint" || fixture_die "cannot write the fixture binary"
chmod +x "$_cache/swiftlint/$SHA_A/swiftlint" || fixture_die "cannot make the fixture binary executable"
pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
_shim="$r/mkdir-shim"; mkdir -p "$_shim" || fixture_die "cannot create $_shim"
_realmkdir="$(command -v mkdir)" || fixture_die "no real mkdir on PATH to wrap"
cat > "$_shim/mkdir" <<SHIM
#!/bin/sh
case "\$*" in
    *.lock)
        rm -rf "$_cache/swiftlint"
        ;;
esac
exec "$_realmkdir" "\$@"
SHIM
chmod +x "$_shim/mkdir" || fixture_die "cannot make the mkdir shim executable"
_t0=$(date +%s)
_out=$( cd "$r" && PATH="$_shim:$PATH" GRUBSTAKE_CACHE="$_cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
_t1=$(date +%s)
_elapsed=$((_t1 - _t0))
if [ "$_rc" -eq 0 ]; then
    fail "ensure exited 0 despite its own cache parent being removed mid-lock: $_out"
elif [ "$_elapsed" -ge 3 ]; then
    fail "ensure spun ${_elapsed}s instead of failing fast when its cache parent vanished: $_out"
elif printf '%s' "$_out" | grep -qi "locked by another run"; then
    fail "a genuinely vanished parent was misread as contention because the path also contains the discriminator's own text: $_out"
elif ! printf '%s' "$_out" | grep -qi "removed the cache mid-install"; then
    fail "failed fast without naming the real cause (the cache parent vanishing): $_out"
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

it "a lock failure on one tool stays scoped to that tool, instead of aborting ensure for the rest"
# #67: with_lock's own retry loop calls die() directly when it can never acquire the lock -- both
# the #56 vanished-parent fast-fail and the stale-lock timeout below it are a hard exit of the
# whole process, regardless of how the caller structured its own error handling. Every other
# install_tool failure mode instead warns, marks the run bad, and lets cmd_ensure continue to the
# next tool (see "a receipt mismatch on one tool does not stop ensure from verifying the rest"
# above) -- a lock failure is the one exception, pre-existing and untouched by #56, which only
# improved the message on the way to the same die(). A directory already sitting at "<dest>.lock"
# before ensure ever runs makes mkdir fail every retry the same way a real concurrent holder would,
# no second process needed, for the same five-second budget a genuinely stale lock would cost.
# swiftlint is pinned first, its lock is what's blocked, and swiftformat second as a plain
# receiptless legacy entry that converges with no download, so its receipt appearing is unambiguous
# evidence ensure reached it rather than dying at swiftlint.
r=$(new_repo)
fake_install "$r" swiftlint 0.63.2 "$SHA_A"
fake_install "$r" swiftformat 0.61.1 "$SHA_B"
pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A
swiftformat 0.61.1 $SHA_B $SHA_B"
_lockdir="$r/.cache/swiftlint/$SHA_A.lock"
mkdir -p "$_lockdir" || fixture_die "cannot plant the stale lock"
_fmt_receipt="$r/.cache/swiftformat/$SHA_B/.grubstake-receipt"
_out=$( cd "$r" && GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
if [ "$_rc" -eq 0 ]; then
    fail "ensure exited 0 despite a tool it could never lock: $_out"
elif ! printf '%s' "$_out" | grep -F -q "$_lockdir"; then
    fail "the lock failure was reported without naming swiftlint's lock: $_out"
elif [ ! -f "$_fmt_receipt" ]; then
    # Seen to flake under a loaded machine (full-suite dash runs), never in isolation: nothing in
    # this fixture pre-plants or contends for swiftformat's own "$SHA_B.lock", so its mkdir should
    # always win on the first try. If it ever doesn't, this fixture cannot yet tell "genuinely
    # contended" apart from "mkdir failed for an unrelated transient reason" -- with_lock's own
    # `mkdir "$_lk" 2>/dev/null` discards the real errno either way -- so the diagnostic below is
    # what the next occurrence needs to tell those apart, per AGENTS.md 15.
    fail "ensure stopped at swiftlint's lock instead of continuing: swiftformat was never reached, no receipt recorded (swiftformat entry: $(ls -la "$r/.cache/swiftformat" 2>&1 | tr '\n' ';'); its lock: $([ -d "$r/.cache/swiftformat/$SHA_B.lock" ] && echo present || echo absent)): $_out"
elif ! printf '%s' "$_out" | grep -q '^\[grubstake\] ok ('; then
    fail "check's own summary never ran: $_out"
else
    pass
fi
rm -rf "$_lockdir" 2>/dev/null

it "a lock failure while correcting a stale receipt version is scoped to that tool, not fatal to the rest"
# #67, the sibling site to the one above: a genuinely verified entry whose receipt just records an
# older version than the pin takes the "correct the receipt version in place" branch (no download,
# since the binary on disk already reports the pinned version -- see "a version-only receipt edit is
# corrected in place, not re-fetched" above). If with_lock can never acquire this entry's own lock,
# the correction must warn and flag the run rather than silently return 0 and let a stale version
# label stand as if it had been fixed. fake_receipt anchors binary-sha256 to the binary fake_install
# actually wrote, so entry_verified passes and this reaches the version-rewrite branch, never the
# mismatch-warn branch above it (which fires on a *reported* version mismatch, not a stale label).
# swiftformat is pinned second, as a plain receiptless legacy entry, so its receipt appearing is
# unambiguous evidence ensure continued past swiftlint's stuck lock rather than stopping there.
r=$(new_repo)
fake_install "$r" swiftlint 0.63.2 "$SHA_A"
fake_receipt "$r/.cache/swiftlint/$SHA_A" swiftlint 0.60.0
fake_install "$r" swiftformat 0.61.1 "$SHA_B"
pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A
swiftformat 0.61.1 $SHA_B $SHA_B"
_lockdir="$r/.cache/swiftlint/$SHA_A.lock"
mkdir -p "$_lockdir" || fixture_die "cannot plant the stale lock"
_receipt="$r/.cache/swiftlint/$SHA_A/.grubstake-receipt"
_fmt_receipt="$r/.cache/swiftformat/$SHA_B/.grubstake-receipt"
_out=$( cd "$r" && GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
_rver="$(awk '/^version/{print $2}' "$_receipt" 2>/dev/null)"
if [ "$_rc" -eq 0 ]; then
    fail "ensure exited 0 despite a stale receipt it could never correct: $_out"
elif [ "$_rver" != "0.60.0" ]; then
    fail "the receipt's stale version was rewritten despite the lock never being acquired: $(cat "$_receipt" 2>/dev/null)"
elif ! printf '%s' "$_out" | grep -F -q "$_lockdir"; then
    fail "the lock failure was reported without naming swiftlint's lock: $_out"
elif [ ! -f "$_fmt_receipt" ]; then
    fail "ensure stopped at swiftlint's stuck receipt instead of continuing: swiftformat was never reached, no receipt recorded: $_out"
else
    pass
fi
rm -rf "$_lockdir" 2>/dev/null

it "a lock failure on a cold install is scoped to that tool, and check runs its own full pass too"
# #67's third site: the two tests above cover with_lock's own retry loop and the stale-receipt
# rewrite, both reached through an entry that already has a binary on disk. Neither can reach the
# cold-install branch, where fake_install's shortcut never runs at all: install_tool's early
# "already installed" check only defers to with_lock once a real download has verified and staged
# the archive, so the publish lock is the one this scenario needs a real (offline) install to reach.
# swiftlint is pinned cold, served by fake_release/curl-shim, with its eventual publish lock
# pre-planted so it never lands; swiftformat is pinned second as a plain receiptless legacy entry,
# proving the install loop itself is scoped exactly as the sibling tests above already prove.
# The install loop being scoped is not the same claim as check's own pass being scoped: verify_tool
# still dies outright on a missing binary today, and cmd_ensure calls cmd_check after the install
# loop, so that die is what kills the whole run before it ever reaches its own summary line. A
# second, direct "check" invocation with a third tool that has no entry at all is what actually
# discriminates that -- swiftformat's own binary exists either way, so it proves nothing about
# whether check's loop can survive a missing one; xcbeautify's absence does, since it is only ever
# reached if check's pass over swiftlint's absence did not just die.
r=$(new_repo)
_sha=$(fake_release "$r" 0.63.2)
fake_install "$r" swiftformat 0.61.1 "$SHA_B"
pins "$r" "swiftlint 0.63.2 $_sha $_sha
swiftformat 0.61.1 $SHA_B $SHA_B"
_lockdir="$r/.cache/swiftlint/$_sha.lock"
mkdir -p "$_lockdir" || fixture_die "cannot plant the stale lock"
_fmt_receipt="$r/.cache/swiftformat/$SHA_B/.grubstake-receipt"
_out=$( cd "$r" && PATH="$r/curl-shim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
if [ "$_rc" -eq 0 ]; then
    fail "ensure exited 0 despite a tool that was never installed: $_out"
elif [ -e "$r/.cache/swiftlint/$_sha/swiftlint" ]; then
    fail "swiftlint was published despite never acquiring its publish lock: $_out"
elif ! printf '%s' "$_out" | grep -F -q "$_lockdir"; then
    fail "the lock failure was reported without naming swiftlint's lock: $_out"
elif [ ! -f "$_fmt_receipt" ]; then
    fail "the install loop stopped at swiftlint's lock instead of continuing: swiftformat was never reached: $_out"
elif printf '%s' "$_out" | grep -q '^\[grubstake\] ok ('; then
    fail "the summary claimed ok despite a tool that was never installed: $_out"
else
    # A third tool with no entry at all, added only now: check never installs anything, so this
    # cannot send the earlier ensure run off to actually try downloading it.
    pins "$r" "swiftlint 0.63.2 $_sha $_sha
swiftformat 0.61.1 $SHA_B $SHA_B
xcbeautify 1.0.0 $SHA_A $SHA_A"
    _cout=$( cd "$r" && GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh check 2>&1 ); _crc=$?
    _missing=$(printf '%s\n' "$_cout" | grep -c "not installed")
    if [ "$_crc" -eq 0 ]; then
        fail "check exited 0 despite two tools that were never installed: $_cout"
    elif [ "$_missing" -ne 2 ]; then
        fail "check named only $_missing of 2 missing tools instead of running its full pass (died at the first?): $_cout"
    elif printf '%s' "$_cout" | grep -q '^\[grubstake\] ok ('; then
        fail "check claimed ok despite two tools that were never installed: $_cout"
    else
        pass
    fi
fi
rm -rf "$_lockdir" 2>/dev/null

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

it "a signal landing while write_receipt holds the lock does not strand it"
# #62: with_lock has no trap, so a signal between its mkdir and rmdir leaves the lock directory
# behind. It stays latent until the same entry is locked again, which then spins the full retry
# budget and warns about a lock nobody holds -- recoverable only by hand. A legacy (receiptless)
# entry reaches with_lock the cheapest way, through write_receipt, with no download needed.
# mv_pause_shim pauses write_receipt's own tmp-to-real rename, the last thing it does before
# returning and letting with_lock rmdir the lock, so the process is killed with the lock genuinely
# held. The specific pid, not its process group: the wrapped command here is write_receipt, a shell
# function running in grubstake.sh's own process, not a separate one -- the only real child is the
# shimmed mv itself, and "exec" replaces the backgrounded subshell with grubstake.sh outright, so
# "$!" is grubstake.sh's own pid, no job-control or process-group games needed to reach it directly.
# Confirmed in scratch first: with no trap in play, dash returns from a blocked wait() the instant
# the signal lands rather than deferring until the child exits, leaving that child an orphan --
# reaped explicitly below, since #64 is plain that backgrounding something and not reaping it is a
# sampled result, not a real one.
r=$(new_repo)
pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"
_shim="$r/mv-shim"; _reached="$r/reached"; _go="$r/go"
_lockdir="$r/.cache/swiftlint/$SHA_A.lock"
mv_pause_shim "$_shim" "$_reached" "$_go" "$r/.cache/swiftlint/$SHA_A/.grubstake-receipt"
(
    cd "$r" || exit 1
    PATH="$_shim:$PATH"; export PATH
    GRUBSTAKE_CACHE="$r/.cache"; export GRUBSTAKE_CACHE
    exec ./grubstake.sh ensure >"$r/out" 2>&1
) &
_bgpid=$!
_w=0
while [ ! -f "$_reached" ]; do
    _w=$((_w + 1))
    [ "$_w" -gt 300 ] && fixture_die "the run never reached write_receipt's critical section"
    sleep 0.05 2>/dev/null || sleep 1
done
[ -d "$_lockdir" ] || fixture_die "reached the critical section without holding its own lock"
kill -TERM "$_bgpid" 2>/dev/null
wait "$_bgpid" 2>/dev/null
if [ -f "$_reached.pid" ]; then
    kill -TERM "$(cat "$_reached.pid")" 2>/dev/null
    wait "$(cat "$_reached.pid")" 2>/dev/null
fi
if [ -d "$_lockdir" ]; then
    fail "the lock directory was stranded after the run was killed mid-write_receipt"
else
    _t0=$(date +%s)
    _out2=$( cd "$r" && GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc2=$?
    _t1=$(date +%s)
    _elapsed=$((_t1 - _t0))
    if [ "$_rc2" -ne 0 ]; then
        fail "the follow-up ensure failed against a lock that should have been released by the trap: $_out2"
    elif printf '%s' "$_out2" | grep -q "cache entry locked by another run"; then
        fail "the follow-up ensure spun the retry budget and warned about a stale lock nobody holds: $_out2"
    elif [ "$_elapsed" -ge 3 ]; then
        fail "the follow-up ensure took ${_elapsed}s instead of acquiring the lock immediately: $_out2"
    else
        pass
    fi
fi
rm -rf "$_lockdir" 2>/dev/null

it "a signal landing while publish_dir holds the lock does not nest the staging install_tool's own trap names"
# #62's other with_lock call site, and the one the contract calls out by name: install_tool already
# arms its own trap over $_tmp and $_staging before this call (~450), so with_lock's own trap must
# compose with that one -- save the caller's trap and restore it, rather than clobber it -- since
# POSIX traps are per-signal per-shell and the wrapped command runs in the very same shell, not a
# subshell.
#
# What this test actually guards, proven by scratch mutation rather than asserted on faith: a
# with_lock that arms its own trap bare, with no save/restore of whatever the caller already had
# armed (the naive, clobbering shape), makes this test fail with $_staging left behind -- verified
# against a scratch copy with with_lock's save/restore deleted and its trap set to a plain
# "rmdir $_lk" on EXIT HUP INT TERM. Against that mutation the run dies with "install incomplete"
# and $_staging survives; against the composed fix it does not. That is the one thing this test can
# tell apart, and the comment used to hedge on it before the mutation was actually run.
#
# It cannot cheaply also discriminate a stranded *lock*: the clobbering mutation above still frees
# $_lk fine, because with_lock's own trap only ever has to do its own job (rmdir the lock it holds),
# never the caller's -- clobbering the outer trap and still releasing the lock are independent
# failures. Making this test also catch a stranded lock would need a with_lock that skips its own
# rmdir on signal entirely, which is not a composition bug at all -- it is "no trap", the exact
# defect the write_receipt test above already exists to catch. The two invariants are orthogonal by
# construction, not by an accident of this fixture, so there is no cheap way to fold them into one
# assertion here.
#
# A cold pin reaches this, served offline by fake_release/curl-shim; mv_pause_shim pauses the actual
# publish rename ("mv $_staging $_dest"), gated on that exact destination so it never catches the
# member rename that happens earlier inside staging on Linux (there the archived member is
# "swiftlint-static", not "swiftlint", so that rename lands at a different destination than either
# this one or the receipt's own tmp-to-real rename). $_staging is found by the same glob the #56
# fixtures already use rather than assumed from "$_dest.staging.$!": exec makes that pid correct
# under every shell tested so far, but the glob costs nothing and does not depend on it.
r=$(new_repo)
_sha=$(fake_release "$r" 0.63.2)
pins "$r" "swiftlint 0.63.2 $_sha $_sha"
_dest="$r/.cache/swiftlint/$_sha"
_lockdir="$_dest.lock"
_shim="$r/mv-shim"; _reached="$r/reached"; _go="$r/go"
mv_pause_shim "$_shim" "$_reached" "$_go" "$_dest"
(
    cd "$r" || exit 1
    PATH="$r/curl-shim:$_shim:$PATH"; export PATH
    GRUBSTAKE_CACHE="$r/.cache"; export GRUBSTAKE_CACHE
    exec ./grubstake.sh ensure >"$r/out" 2>&1
) &
_bgpid=$!
_w=0
while [ ! -f "$_reached" ]; do
    _w=$((_w + 1))
    [ "$_w" -gt 300 ] && fixture_die "the run never reached publish_dir's critical section"
    sleep 0.05 2>/dev/null || sleep 1
done
[ -d "$_lockdir" ] || fixture_die "reached the critical section without holding its own lock"
_staging=$(printf '%s\n' "$_dest".staging.* 2>/dev/null | head -1)
[ -n "$_staging" ] && [ -d "$_staging" ] || fixture_die "could not find the staging directory install_tool was about to publish"
kill -TERM "$_bgpid" 2>/dev/null
wait "$_bgpid" 2>/dev/null
if [ -f "$_reached.pid" ]; then
    kill -TERM "$(cat "$_reached.pid")" 2>/dev/null
    wait "$(cat "$_reached.pid")" 2>/dev/null
fi
if [ -d "$_staging" ]; then
    fail "the staging directory install_tool's own trap names was left behind: with_lock's fix must compose with that trap, not clobber it"
elif [ -d "$_lockdir" ]; then
    fail "the lock directory was stranded after the run was killed mid-publish"
else
    pass
fi
rm -rf "$_lockdir" "$_staging" 2>/dev/null

it "with_lock refuses a lock it cannot safely hold when it cannot save the caller's trap state"
# with_lock's own trap composition needs somewhere to stash the caller's existing trap before
# overwriting it (a plain redirect into a mktemp file, not command substitution -- dash resets a
# subshell's own trap table, so "$(trap)" reads back empty even with one already armed). An
# unwritable TMPDIR makes that mktemp fail, and with_lock refuses to hold a lock it could not make
# safe to interrupt: it warns, releases the lock it had just acquired, and returns 1 -- the same
# tool-scoped shape every other with_lock-adjacent failure already has (see the two signal tests
# above and #67's sibling tests), not a die. Two legacy (receiptless) entries, both reaching
# with_lock the cheapest way through write_receipt, prove this is genuinely per-tool and not a
# one-and-done abort: both must be refused independently, in the same run, since a broken TMPDIR
# does not clear itself between them.
r=$(new_repo)
pins "$r" "swiftlint 0.63.2 $SHA_A $SHA_A
swiftformat 0.61.1 $SHA_B $SHA_B"
fake_install "$r" swiftlint 0.63.2 "$SHA_A"
fake_install "$r" swiftformat 0.61.1 "$SHA_B"
_badtmp="$r/no-tmp"
mkdir -p "$_badtmp" || fixture_die "cannot create $_badtmp"
chmod a-w "$_badtmp" || fixture_die "cannot make $_badtmp read-only"
# A test operator, not an actual write attempt: a failed redirection into a directory that lacks
# write permission is fatal to a non-interactive shell regardless of set -e, so "{ : > file; }
# 2>/dev/null" does not survive to report anything -- 2>/dev/null only silences a command's own
# stderr, not the shell's own inability to open the redirection target.
[ -w "$_badtmp" ] && fixture_die "chmod a-w did not make $_badtmp unwritable (running as root?)"
_lockA="$r/.cache/swiftlint/$SHA_A.lock"
_lockB="$r/.cache/swiftformat/$SHA_B.lock"
_out=$( cd "$r" && TMPDIR="$_badtmp" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh ensure 2>&1 ); _rc=$?
_warns=$(printf '%s\n' "$_out" | grep -c "cannot save the caller's trap state")
chmod -R u+rwx "$_badtmp" 2>/dev/null
if [ "$_rc" -eq 0 ]; then
    fail "ensure exited 0 despite never being able to safely hold a lock: $_out"
elif [ "$_warns" -ne 2 ]; then
    fail "expected both tools refused per-tool (2 warns), got $_warns: $_out"
elif [ -d "$_lockA" ] || [ -d "$_lockB" ]; then
    fail "a lock directory was left behind despite with_lock refusing to hold it: $_out"
else
    pass
fi

it "release versions sort newest first"
# A trailing -r is ignored when per-key flags are present, which once made update install the
# oldest release every time.
top=$(printf '0.2.0\n0.10.0\n0.9.9\n' | LC_ALL=C sort -t. -k1,1nr -k2,2nr -k3,3nr | head -1)
[ "$top" = "0.10.0" ] && pass || fail "sorted to $top, expected 0.10.0"

# Shared by both version-filter tests below: a fixed set of ls-remote refs covering every shape that
# would sort wrong if it reached "sort -t. -k1,1nr" unfiltered -- a pre-release suffix, a two-component
# version, a tag with a leftover "v" (as if the tag itself were misnamed "vv1.2.3"), and a non-numeric
# tag -- alongside three well-formed releases, including the classic double-digit trap (0.10.0 above
# 0.9.9 lexically fails, numerically it must not). Unfiltered, "1.2.3-beta" sorts on key1=1, which
# outranks every 0.x release below it, and a leading non-numeric field reads as 0 -- exactly the
# wrong-sort the issue describes, and exactly what grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' exists to prevent
# before either site's sort ever sees these values.
git_tags_shim() {
    mkdir -p "$1" || fixture_die "cannot create the git shim dir"
    cat > "$1/git" <<'SHIM'
#!/bin/sh
if [ "$1" = "ls-remote" ]; then
    printf '%s\trefs/tags/v%s\n' \
        aaa 0.2.0 \
        bbb 0.10.0 \
        ccc 0.9.9 \
        ddd 1.2.3-beta \
        eee 1.2 \
        fff v1.2.3 \
        ggg abc
    exit 0
fi
exit 1
SHIM
    chmod +x "$1/git" || fixture_die "cannot make the git shim executable"
}

it "release_tags excludes shapes that would otherwise outrank a well-formed release"
# release_tags is extracted from grubstake.sh by name (the same technique extract_fns and
# cmd_legacy_replace's own extraction above use), never reimplemented, so a change to the real regex or
# sort flags breaks this test instead of a hand-copied stand-in silently drifting from the source. git
# is shimmed to answer any ls-remote call with the fixed refs above, offline, so the only thing under
# test is the pipeline grubstake.sh actually runs on whatever git returns.
r=$(new_repo)
_shim="$r/git-shim"; git_tags_shim "$_shim"
_fn="$(sed -n '/^release_tags() {/,/^}/p' "$GS")"
printf '%s\n' "$_fn" | grep -q '^release_tags() {$' \
    || fixture_die "extract release_tags: no line-anchored '{' in $GS (reformatted?)"
_closes="$(printf '%s\n' "$_fn" | grep -c '^}$' | tr -d ' ')"
[ "$_closes" = 1 ] || fixture_die "extract release_tags: $_closes closing braces, expected 1 (truncated)"
{
    printf '#!/bin/sh\nset -eu\nGRUBSTAKE_REPO=fake\n'
    printf '%s\n' "$_fn"
    printf 'release_tags\n'
} > "$r/t.sh"
_out=$( cd "$r" && PATH="$_shim:$PATH" sh "$r/t.sh" 2>&1 ); _rc=$?
_want="0.10.0
0.9.9
0.2.0"
if [ "$_rc" -ne 0 ]; then
    fail "the generated script exited $_rc, so release_tags did not run cleanly: $_out"
elif [ "$_out" != "$_want" ]; then
    fail "got:
$_out
expected:
$_want"
else
    pass
fi

it "post-commit's own tag comparison excludes the same malformed shapes, not just grubstake.sh's copy"
# hooks/post-commit runs its own inline copy of the filter-then-sort pipeline; it is not a call into
# grubstake.sh, so the release_tags test above says nothing about this one. Extracted from
# hooks/post-commit itself, byte for byte, for the same reason as above. The extraction is asserted to
# actually contain the version filter, not just be non-empty: the sed range's end pattern
# ("head -1)$") matches twice in this file (this pipeline and the later CURRENT-vs-LATEST comparison,
# which has no filter in front of it and is out of scope here -- see the report), so a change nearby
# that shifted the range without breaking it outright would otherwise go unnoticed. This pipeline ends
# in "| head -1", so it reports the single winner rather than the full filtered list.
r=$(new_repo)
_shim="$r/git-shim"; git_tags_shim "$_shim"
_snippet="$(sed -n '/^        latest=$(git ls-remote/,/head -1)$/p' "$HOOKS/post-commit")"
[ -n "$_snippet" ] || fixture_die "extract post-commit's latest= pipeline: nothing matched (reformatted?)"
printf '%s\n' "$_snippet" | grep -qF "grep -E '^[0-9]+\\.[0-9]+\\.[0-9]+\$'" \
    || fixture_die "extract post-commit's latest= pipeline: the version filter is missing from the extraction (reformatted?)"
{
    printf '#!/bin/sh\nset -eu\n'
    printf '%s\n' "$_snippet"
    printf 'echo "$latest"\n'
} > "$r/t.sh"
_out=$( cd "$r" && PATH="$_shim:$PATH" sh "$r/t.sh" 2>&1 ); _rc=$?
if [ "$_rc" -ne 0 ]; then
    fail "the generated script exited $_rc: $_out"
elif [ "$_out" != "0.10.0" ]; then
    fail "got '$_out', expected 0.10.0 (a pre-release suffix sorts ahead of it unfiltered: see the release_tags test above)"
else
    pass
fi

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

# known_hook_hashes/is_known_hook_hash, for the ratchet test below to assert through the real
# lookup rather than a bare grep across the whole file: a hash filed under the wrong hook's own
# case arm (the exact "forgot to append it in the right place" failure #58's ratchet exists to
# catch) would still satisfy "does this string appear anywhere in grubstake.sh", but must not
# satisfy is_known_hook_hash called with that hook's own name.
extract_hook_hash_fns() {
    sed -n '/^known_hook_hashes() {/,/^}/p;/^is_known_hook_hash() {/,/^}/p' "$GS"
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

it "install refreshes a hook that matches a known previous release, not just the current one"
# #58: install writes a hook once and never revisits it, so a fix to a shipped hook (like #71's
# post-commit version validation) is undeliverable to an already-adopted repo except by deleting
# the hook by hand and reinstalling. The design constraint recorded on the issue itself: overwrite
# only a hook byte-identical to a KNOWN previous embedded copy, so repo-local edits are never at
# risk -- an unrecognized hook is a different, separate case below. v0.5.0's post-commit (the
# pre-#71 bytes) is embedded here as a literal fixture, not fetched: CI is a depth-1 checkout, so no
# test may shell out to "git show vX:..." for historical bytes. This is grubstake's own published
# content (v0.5.0/hooks/post-commit), not a leak. Verified once, by hand, against the tag at the
# time this test was written: byte-identical to what that release's own embedded_hook() produced.
r=$(new_repo)
mkdir -p "$r/.githooks"
cat > "$r/.githooks/post-commit" <<'GST_V0_5_0_POST_COMMIT'
#!/bin/sh
# grubstake post-commit: report that a newer grubstake exists. Notify only. It never updates,
# never blocks, and never fails a commit.
#
# post-commit rather than pre-commit on purpose: nothing here should sit in the path that gates a
# commit. The synchronous cost is one file read; the network refresh is backgrounded and only
# runs once per TTL, so an offline machine stays silent instead of stalling.

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
GRUBSTAKE="$ROOT/grubstake.sh"
[ -x "$GRUBSTAKE" ] || exit 0

CACHE="$(git rev-parse --git-dir)/grubstake-latest"   # inside .git, so it needs no gitignore entry
TTL=86400

CURRENT="$("$GRUBSTAKE" version 2>/dev/null)" || exit 0

now=$(date +%s)
stamp=0
[ -f "$CACHE" ] && stamp=$(sed -n 1p "$CACHE" 2>/dev/null || echo 0)
case "$stamp" in ''|*[!0-9]*) stamp=0 ;; esac

if [ $((now - stamp)) -gt "$TTL" ]; then
    # Backgrounded and detached: a slow or unreachable network must not extend a commit.
    (
        latest=$(git ls-remote --tags --refs https://github.com/seriouslysean/grubstake 'v*' 2>/dev/null \
            | awk '{print $2}' | sed 's|refs/tags/v||' \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
            | LC_ALL=C sort -t. -k1,1nr -k2,2nr -k3,3nr | head -1)
        [ -n "$latest" ] && printf '%s\n%s\n' "$now" "$latest" > "$CACHE"
    ) >/dev/null 2>&1 &
fi

LATEST=$(sed -n 2p "$CACHE" 2>/dev/null) || exit 0
[ -n "$LATEST" ] || exit 0
[ "$LATEST" = "$CURRENT" ] && exit 0

# Only speak when the cached latest is genuinely newer than what is installed.
newest=$(printf '%s\n%s\n' "$CURRENT" "$LATEST" | LC_ALL=C sort -t. -k1,1nr -k2,2nr -k3,3nr | head -1)
[ "$newest" = "$LATEST" ] || exit 0

echo "[grubstake] $LATEST available (pinned $CURRENT) -- run: ./grubstake.sh update"
exit 0
GST_V0_5_0_POST_COMMIT
chmod +x "$r/.githooks/post-commit"
_shims="$(mktemp -d "$ROOT/no-net-refresh.XXXXXX")" || fixture_die "cannot create a scratch dir for the network shim"
printf '#!/bin/sh\necho "curl: network blocked in test" >&2\nexit 6\n' > "$_shims/curl"
chmod +x "$_shims/curl"
_out=$( cd "$r" && PATH="$_shims:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh install 2>&1 ); _rc=$?
_got="$(mktemp "$ROOT/refresh-check.XXXXXX")" || fixture_die "cannot create a scratch file for post-commit extraction"
extract_embedded_hook post-commit > "$_got"
if [ "$_rc" -ne 0 ]; then
    fail "install failed refreshing a known previous release's post-commit (rc $_rc): $_out"
elif ! cmp -s "$_got" "$r/.githooks/post-commit"; then
    fail "post-commit was not refreshed to the current embedded copy: $_out"
elif ! { printf '%s' "$_out" | grep -qi "post-commit" && printf '%s' "$_out" | grep -qi "refresh"; }; then
    fail "post-commit was refreshed, but nothing logged it as a refresh: $_out"
else
    pass
fi

it "install leaves a marker-bearing hook with unrecognized edits untouched, but warns"
# The other side of #58's constraint: a hook that carries grubstake's own marker but matches
# neither the current embedded copy nor any known previous one may carry repo-local edits install
# cannot prove it wrote -- it is left alone, not overwritten, and the human is told it differs
# rather than left to discover that by hand later. Appending one line to the current embedded copy
# keeps the marker (still line 2) while making the sha256 match nothing on record.
r=$(new_repo)
mkdir -p "$r/.githooks"
extract_embedded_hook pre-commit > "$r/.githooks/pre-commit"
printf '# a local edit grubstake has never shipped\n' >> "$r/.githooks/pre-commit"
chmod +x "$r/.githooks/pre-commit"
_before="$(mktemp "$ROOT/unrecognized-before.XXXXXX")" || fixture_die "cannot snapshot the edited hook"
cp "$r/.githooks/pre-commit" "$_before"
_shims="$(mktemp -d "$ROOT/no-net-unrecognized.XXXXXX")" || fixture_die "cannot create a scratch dir for the network shim"
printf '#!/bin/sh\necho "curl: network blocked in test" >&2\nexit 6\n' > "$_shims/curl"
chmod +x "$_shims/curl"
_out=$( cd "$r" && PATH="$_shims:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh install 2>&1 ); _rc=$?
if [ "$_rc" -ne 0 ]; then
    fail "install failed over a hook it should only have warned about (rc $_rc): $_out"
elif ! cmp -s "$_before" "$r/.githooks/pre-commit"; then
    fail "a marker-bearing hook with unrecognized edits was overwritten: $_out"
elif ! { printf '%s' "$_out" | grep -qi "pre-commit" && printf '%s' "$_out" | grep -Eqi "warn|differ|drift"; }; then
    fail "install left the hook alone but did not warn that it differs: $_out"
else
    pass
fi

it "install leaves a markerless hand-rolled hook alone, without warning about drift"
# A hook that never carried grubstake's marker predates adoption or was never grubstake's to begin
# with -- the #59 semantics doctor already applies, now needed at install too, since install is
# where a hook first gets judged. Silence here matters as much as the warn above does: a repo that
# rolled its own pre-commit long before adopting grubstake must not be told its own hook "differs"
# from something it was never trying to match.
r=$(new_repo)
mkdir -p "$r/.githooks"
printf '#!/bin/sh\necho "this repo rolled its own pre-commit hook"\nexit 0\n' > "$r/.githooks/pre-commit"
chmod +x "$r/.githooks/pre-commit"
_before="$(mktemp "$ROOT/markerless-before.XXXXXX")" || fixture_die "cannot snapshot the hand-rolled hook"
cp "$r/.githooks/pre-commit" "$_before"
_shims="$(mktemp -d "$ROOT/no-net-markerless.XXXXXX")" || fixture_die "cannot create a scratch dir for the network shim"
printf '#!/bin/sh\necho "curl: network blocked in test" >&2\nexit 6\n' > "$_shims/curl"
chmod +x "$_shims/curl"
_out=$( cd "$r" && PATH="$_shims:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh install 2>&1 ); _rc=$?
if [ "$_rc" -ne 0 ]; then
    fail "install failed over a repo-owned hook it should have left alone (rc $_rc): $_out"
elif ! cmp -s "$_before" "$r/.githooks/pre-commit"; then
    fail "a markerless, hand-rolled hook was touched: $_out"
elif printf '%s' "$_out" | grep -qi "pre-commit" && printf '%s' "$_out" | grep -Eqi "warn|differ|drift"; then
    fail "install warned about drift on a hook that was never grubstake's: $_out"
else
    pass
fi

it "install is idempotent on a hook already at the current embedded copy"
# The refresh contract must not turn every install into a rewrite: a hook already byte-identical to
# what would be written needs no touching and no refresh log, or install stops being safe to rerun.
r=$(new_repo)
mkdir -p "$r/.githooks"
extract_embedded_hook pre-commit > "$r/.githooks/pre-commit"
chmod +x "$r/.githooks/pre-commit"
_before="$(mktemp "$ROOT/idempotent-before.XXXXXX")" || fixture_die "cannot snapshot the current hook"
cp "$r/.githooks/pre-commit" "$_before"
_shims="$(mktemp -d "$ROOT/no-net-idempotent.XXXXXX")" || fixture_die "cannot create a scratch dir for the network shim"
printf '#!/bin/sh\necho "curl: network blocked in test" >&2\nexit 6\n' > "$_shims/curl"
chmod +x "$_shims/curl"
_out=$( cd "$r" && PATH="$_shims:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh install 2>&1 ); _rc=$?
if [ "$_rc" -ne 0 ]; then
    fail "install failed on a hook already at the current embedded copy (rc $_rc): $_out"
elif ! cmp -s "$_before" "$r/.githooks/pre-commit"; then
    fail "an already-current hook's bytes changed: $_out"
elif printf '%s' "$_out" | grep -qi "pre-commit" && printf '%s' "$_out" | grep -qi "refresh"; then
    fail "install logged a refresh for a hook that was already current: $_out"
else
    pass
fi

it "the current embedded hooks' hashes are in grubstake.sh's own known-hashes list"
# Constrains the implementer's data structure for #58's refresh contract: whatever list of hashes
# licenses overwriting an existing hook must contain every historically released variant (per #58:
# six distinct pre-commit variants, two post-commit) plus whatever is currently embedded, or a
# future hook edit that forgets to append its own new hash makes every repo running that edit's
# immediate predecessor unrefreshable without deleting the hook by hand -- the exact manual ceremony
# #58 exists to remove. The historical entries themselves are not re-derived or verified here: CI
# is a depth-1 checkout, so no test may shell out to "git show vX:..." for historical bytes; they
# were verified against the release tags once, by hand, at introduction, and are trusted from then
# on the same way this suite trusts any other hash or receipt. This test only ever asserts the
# CURRENT side of that list, which needs no such trust -- it is computed fresh from the embedded
# copy every run.
#
# Asserted through the real is_known_hook_hash, not a bare "does this string appear anywhere in
# grubstake.sh": a plain grep -qF would pass even if the current hash were filed under the WRONG
# hook's case arm (pre-commit's hash appended to post-commit's list, say) -- byte-for-byte the same
# string, present in the file, and yet not what is_known_hook_hash "post-commit" "$sha" would ever
# find true. That misfiling is exactly the class of forgot-to-append mistake this ratchet exists to
# catch, so the lookup has to be hook-scoped the same way the real call sites use it.
_bad=""
for _hook in pre-commit post-commit; do
    _got="$(mktemp "$ROOT/ratchet.XXXXXX")" || fixture_die "cannot create a scratch file for $_hook extraction"
    extract_embedded_hook "$_hook" > "$_got"
    _sha="$(sha256_of "$_got")"
    _check="$(mktemp "$ROOT/ratchet-check.XXXXXX")" || fixture_die "cannot create a scratch script for $_hook's hash check"
    { extract_hook_hash_fns
      echo 'die() { echo "$1" >&2; exit 1; }'
      printf 'is_known_hook_hash %s %s\n' "$_hook" "$_sha"
    } > "$_check"
    sh "$_check" || _bad="$_bad $_hook"
done
[ -z "$_bad" ] && pass || fail "is_known_hook_hash does not recognize the current embedded hash for:$_bad"

it "two concurrent installs against the same refresh-eligible repo do not race each other's tmp"
# Panel review reproduced two concurrent `install` runs corrupting each other 39/40 times under
# dash: the refresh path (and the fresh-install path, for whichever hook does not exist yet) wrote
# the current embedded copy to a single, predictable "$_dest.tmp" name shared by every concurrent
# invocation of the same command against the same repo, so one process's write, chmod, or cleanup
# could land on the other's in-flight temp file. The fix moves every write behind a uniquely-named,
# trap-guarded mktemp beside the destination instead. post-commit is seeded fresh from a known
# previous release before every iteration, so it is refresh-eligible every time; pre-commit starts
# absent, so the first iteration also exercises the fresh-install race, and both concurrent
# processes racing to create it land on the same bytes either way once "mv" wins for whichever one
# gets there first.
#
# Two concurrent installs share more than the hook tmp name: both also run the unconditional
# `git config core.hooksPath .githooks` write at the end of the command, which races on git's own
# ".git/config.lock" the same way -- one process's write can lose that race and surface git's own
# raw "error: could not lock config file" instead of anything grubstake ever voices. Either race is
# the same class of defect (an unguarded shared write two concurrent installs both make), so both
# are asserted as one contract here -- "two concurrent installs must not corrupt each other or leak
# a raw tool error" -- with the failure message naming which one actually fired.
#
# A natural race, hoping two full "install" runs happen to reach the same call at the same
# instant, is what the earlier version of this test relied on -- it caught the git-config race only
# 1 run in 3 across sh/dash/env-i, which is not something to watch fail and trust. git_pause_shim
# gives each racer a fixed point to stop at (the hooksPath write, the last shared-state write
# `install` makes) and releases both together, so the collision this test exists to catch happens on
# purpose instead of by luck. The hook-tmp write earlier in the same run is not pinned this way: it
# already has its own isolated, 30/30-vs-0/30 discrimination proof (built at test-authoring time,
# not part of this file), so here it rides along as a natural, unforced check on top of the forced
# git-config collision -- same standing as the probabilistic catches elsewhere in this suite (see
# "two repos sharing one cache" above): a clean run on this half proves nothing beyond itself, but a
# red one is real.
#
# The reaped-loop discipline from #64 still applies to the handful of repeats below: nothing here is
# sampled or left unreaped, and the loop stops at the first iteration that fails rather than
# overwriting the evidence with a clean one that runs after it.
r=$(new_repo)
_shims="$(mktemp -d "$ROOT/no-net-concurrent-install.XXXXXX")" || fixture_die "cannot create a scratch dir for the network shim"
printf '#!/bin/sh\necho "curl: network blocked in test" >&2\nexit 6\n' > "$_shims/curl"
chmod +x "$_shims/curl"
_reached="$r/git-reached"; _go="$r/git-go"
git_pause_shim "$_shims" "$_reached" "$_go"
_got="$(mktemp "$ROOT/concurrent-install-current.XXXXXX")" || fixture_die "cannot create a scratch file for post-commit extraction"
extract_embedded_hook post-commit > "$_got"
_iterations=5
_i=0
_bad=""
while [ "$_i" -lt "$_iterations" ] && [ -z "$_bad" ]; do
    _i=$((_i + 1))
    rm -f "$_reached".* "$_go"
    mkdir -p "$r/.githooks"
    cat > "$r/.githooks/post-commit" <<'GST_V0_5_0_POST_COMMIT_RACE'
#!/bin/sh
# grubstake post-commit: report that a newer grubstake exists. Notify only. It never updates,
# never blocks, and never fails a commit.
#
# post-commit rather than pre-commit on purpose: nothing here should sit in the path that gates a
# commit. The synchronous cost is one file read; the network refresh is backgrounded and only
# runs once per TTL, so an offline machine stays silent instead of stalling.

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
GRUBSTAKE="$ROOT/grubstake.sh"
[ -x "$GRUBSTAKE" ] || exit 0

CACHE="$(git rev-parse --git-dir)/grubstake-latest"   # inside .git, so it needs no gitignore entry
TTL=86400

CURRENT="$("$GRUBSTAKE" version 2>/dev/null)" || exit 0

now=$(date +%s)
stamp=0
[ -f "$CACHE" ] && stamp=$(sed -n 1p "$CACHE" 2>/dev/null || echo 0)
case "$stamp" in ''|*[!0-9]*) stamp=0 ;; esac

if [ $((now - stamp)) -gt "$TTL" ]; then
    # Backgrounded and detached: a slow or unreachable network must not extend a commit.
    (
        latest=$(git ls-remote --tags --refs https://github.com/seriouslysean/grubstake 'v*' 2>/dev/null \
            | awk '{print $2}' | sed 's|refs/tags/v||' \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
            | LC_ALL=C sort -t. -k1,1nr -k2,2nr -k3,3nr | head -1)
        [ -n "$latest" ] && printf '%s\n%s\n' "$now" "$latest" > "$CACHE"
    ) >/dev/null 2>&1 &
fi

LATEST=$(sed -n 2p "$CACHE" 2>/dev/null) || exit 0
[ -n "$LATEST" ] || exit 0
[ "$LATEST" = "$CURRENT" ] && exit 0

# Only speak when the cached latest is genuinely newer than what is installed.
newest=$(printf '%s\n%s\n' "$CURRENT" "$LATEST" | LC_ALL=C sort -t. -k1,1nr -k2,2nr -k3,3nr | head -1)
[ "$newest" = "$LATEST" ] || exit 0

echo "[grubstake] $LATEST available (pinned $CURRENT) -- run: ./grubstake.sh update"
exit 0
GST_V0_5_0_POST_COMMIT_RACE
    chmod +x "$r/.githooks/post-commit"
    ( cd "$r" && GST_LABEL=1 PATH="$_shims:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh install >"$r/out1" 2>&1; echo $? > "$r/rc1" ) &
    _p1=$!
    ( cd "$r" && GST_LABEL=2 PATH="$_shims:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh install >"$r/out2" 2>&1; echo $? > "$r/rc2" ) &
    _p2=$!
    # Both racers have to be waiting at the hooksPath write, not just one, before releasing either.
    # No sleep on this poll: a `sleep`-paced check (on either side of the release) is exactly what
    # let the two racers slip past each other in the tuning that landed on this handshake (see the
    # comment on git_pause_shim); a plain "[ -f ]" busy-wait removes that gap. A caller stuck here
    # for real means the shim itself is broken, not that the race under test failed to land, so this
    # is a fixture_die, not a fail.
    _w=0
    while [ ! -f "$_reached.1" ] || [ ! -f "$_reached.2" ]; do
        _w=$((_w + 1))
        [ "$_w" -gt 2000000 ] && fixture_die "iteration $_i: both concurrent installs never reached the hooksPath write together"
    done
    : > "$_go"
    wait "$_p1" 2>/dev/null
    wait "$_p2" 2>/dev/null
    _rc1="$(cat "$r/rc1" 2>/dev/null)"; case "$_rc1" in ''|*[!0-9]*) _rc1=1 ;; esac
    _rc2="$(cat "$r/rc2" 2>/dev/null)"; case "$_rc2" in ''|*[!0-9]*) _rc2=1 ;; esac
    _out1="$(cat "$r/out1" 2>/dev/null)"
    _out2="$(cat "$r/out2" 2>/dev/null)"
    _files="$(find "$r/.githooks" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
    if printf '%s\n%s\n' "$_out1" "$_out2" | grep -qE '^(mv|chmod|error):'; then
        _bad="iteration $_i: a raw, unvoiced tool error leaked instead of a [grubstake]-voiced failure: $_out1 || $_out2"
    elif [ "$_rc1" -ne 0 ] || [ "$_rc2" -ne 0 ]; then
        _bad="iteration $_i: an install exited non-zero (rc1=$_rc1 rc2=$_rc2): $_out1 || $_out2"
    elif ! cmp -s "$_got" "$r/.githooks/post-commit" 2>/dev/null; then
        _bad="iteration $_i: post-commit did not end at the current embedded copy"
    elif [ "$_files" != "2" ]; then
        _bad="iteration $_i: .githooks has $_files files instead of exactly 2 (pre-commit, post-commit) -- tmp litter: $(ls -la "$r/.githooks" 2>/dev/null)"
    fi
done
rm -f "$r/out1" "$r/out2" "$r/rc1" "$r/rc2"
[ -z "$_bad" ] && pass || fail "$_bad"

it "install fails fast with git's own error, not a lock nobody held, when .git itself is unwritable"
# #85: the retry around the hooksPath write discards every attempt's stderr with "2>/dev/null", so
# it cannot tell git losing a genuine lock race (retryable) apart from any other reason the write
# failed (not retryable). A read-only .git is an ordinary way for that write to fail for a reason
# that will never clear no matter how many times it is retried: chmod 555 leaves .githooks itself
# writable (a sibling of .git, not inside it), so the hook loop still succeeds, and only the
# hooksPath write -- which needs to create .git/config.lock -- hits EACCES. Verified directly
# against git itself before writing this assertion: the real message is "could not lock config
# file .git/config: Permission denied", never "File exists" (that text is reserved for a lock
# already held, the case #85 says must still retry). Pre-fix this spins the full ~50-attempt
# budget and then dies blaming "git kept losing the lock" -- true of no attempt that ran.
r=$(new_repo)
_shims="$(mktemp -d "$ROOT/no-net-readonly-git.XXXXXX")" || fixture_die "cannot create a scratch dir for the network shim"
printf '#!/bin/sh\necho "curl: network blocked in test" >&2\nexit 6\n' > "$_shims/curl"
chmod +x "$_shims/curl"
chmod 555 "$r/.git" || fixture_die "cannot make $r/.git read-only"
_t0=$(date +%s)
_out=$( cd "$r" && PATH="$_shims:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh install 2>&1 ); _rc=$?
_t1=$(date +%s)
chmod 755 "$r/.git" 2>/dev/null
_elapsed=$((_t1 - _t0))
if [ "$_rc" -eq 0 ]; then
    fail "install exited 0 with .git itself read-only: $_out"
elif [ "$_elapsed" -ge 3 ]; then
    fail "install spun ${_elapsed}s instead of failing fast on a non-retryable git error: $_out"
elif printf '%s' "$_out" | grep -qi "kept losing the lock"; then
    fail "blamed a lock nobody held instead of the real permission failure: $_out"
elif ! printf '%s' "$_out" | grep -qi "permission denied"; then
    fail "did not carry git's own error text: $_out"
else
    pass
fi

it "install still wins a genuine git-config lock race once the lock clears"
# Not proof of #85's fix -- verified directly against pre-#85 HEAD, this already passes there
# unchanged, because the old blind retry retries through everything regardless of cause. What it
# guards is a fix that overcorrects: #85's contract is "retry reserved for contention, anything
# else fails immediately," and a fix that reads that as "only retry on an exact, narrow signature"
# could start treating real, transient contention as the "anything else" case and die on it. A
# plain file at .git/config.lock is exactly what git's own locking leaves behind while it holds the
# write -- confirmed directly: git reports the identical "File exists" either way, whether the
# holder is a concurrent grubstake install or anything else. Planting it and then releasing it
# after a beat, rather than never releasing it (that is the case below), reproduces a lock that is
# genuinely contended and genuinely clears, which the retry exists to wait out. One second is
# enough of a hold to guarantee install's first attempt lands while the lock is still there even on
# the whole-second sleep fallback, without demanding a tight race.
r=$(new_repo)
_shims="$(mktemp -d "$ROOT/no-net-lock-clears.XXXXXX")" || fixture_die "cannot create a scratch dir for the network shim"
printf '#!/bin/sh\necho "curl: network blocked in test" >&2\nexit 6\n' > "$_shims/curl"
chmod +x "$_shims/curl"
: > "$r/.git/config.lock" || fixture_die "cannot plant a genuine git-config lock in $r"
( sleep 2; rm -f "$r/.git/config.lock" ) &
_releaser=$!
_out=$( cd "$r" && PATH="$_shims:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh install 2>&1 ); _rc=$?
wait "$_releaser" 2>/dev/null
_hp=$( cd "$r" && git config core.hooksPath 2>/dev/null )
if [ "$_rc" -ne 0 ]; then
    fail "install gave up on a lock that genuinely cleared: $_out"
elif [ "$_hp" != ".githooks" ]; then
    fail "install exited 0 but never actually set hooksPath (got '$_hp'): $_out"
else
    pass
fi

it "install exhausting a genuinely stale git-config lock still blames the lock, not a fabricated cause"
# Also not proof of #85's fix -- verified directly against pre-#85 HEAD, this already passes there
# unchanged too: the old blind retry exhausts the identical 50-iteration budget on any persistent
# failure and its die message already contains "lock" regardless of cause. What it guards is a fix
# that keeps the fast-fail from the read-only-.git test above but loses the honest report when
# contention is real and simply never clears (its holder crashed, say) -- the die still has to name
# the lock, not go silent or say something fabricated, once the budget genuinely runs out.
#
# A lower bound alone ("some time passed") does not prove the loop ran to its real end rather than
# a shortened one -- a budget quietly gutted from 50 iterations to a handful would still clear a
# loose floor on the whole-second sleep fallback (5 iterations * 1s = 5s already clears a flat "3").
# The floor is derived from the same 0.1-or-1 fallback the loop itself falls back to, so it tracks
# whichever this machine actually has: a few seconds short of the true ~5s/~50s total, comfortably
# above what a materially smaller budget would produce on either path, without hardcoding a bound
# that assumes fractional sleep works everywhere. This is the honest cost of proving exhaustion
# rather than any death: on a fractional-sleep machine this test alone costs ~5s; on one that falls
# back to whole-second sleeps, up to ~50s. Not flaky -- the lock never clears here, so every attempt
# fails the same deterministic way -- just genuinely slow on the fallback path.
r=$(new_repo)
_shims="$(mktemp -d "$ROOT/no-net-lock-stale.XXXXXX")" || fixture_die "cannot create a scratch dir for the network shim"
printf '#!/bin/sh\necho "curl: network blocked in test" >&2\nexit 6\n' > "$_shims/curl"
chmod +x "$_shims/curl"
if sleep 0.1 2>/dev/null; then _min_elapsed=4; else _min_elapsed=45; fi
: > "$r/.git/config.lock" || fixture_die "cannot plant a genuine git-config lock in $r"
_t0=$(date +%s)
_out=$( cd "$r" && PATH="$_shims:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh install 2>&1 ); _rc=$?
_t1=$(date +%s)
rm -f "$r/.git/config.lock" 2>/dev/null
_elapsed=$((_t1 - _t0))
if [ "$_rc" -eq 0 ]; then
    fail "install exited 0 despite a git-config lock that was never released: $_out"
elif [ "$_elapsed" -lt "$_min_elapsed" ]; then
    fail "gave up on the lock after only ${_elapsed}s (expected at least ${_min_elapsed}s) -- the retry budget was not honestly exhausted: $_out"
elif ! printf '%s' "$_out" | grep -qi "lock"; then
    fail "exhausted the retry budget without naming the lock as the cause: $_out"
else
    pass
fi

it "install still retries through a locale-translated lock message instead of treating it as fatal"
# The fast-fail fix reads git's own stderr and only retries on the literal English "File exists" --
# git's actual signature for its own lock already being held. That match is only reliable if the
# git subprocess is forced into the C locale for this call: an interactive user's real LC_ALL/LANG
# reaches every child process by default, and a git built with message translations installed
# prints a translated line for the identical failure under a non-C locale, which the literal match
# can never recognize. Unrecognized then falls to the same immediate-death branch the read-only-.git
# test above depends on, so without forcing C, genuine contention under a translated locale would
# die on its very first attempt instead of retrying -- the opposite of what #85 wants preserved.
#
# A real foreign locale need not be installed on the machine running this suite to prove it: the
# shim below only ever fabricates git's own two possible strings, choosing between them by reading
# back whatever LC_ALL it was actually invoked with, so it tests grubstake.sh's own invocation
# (does it force C on the call it makes), not this machine's locale catalog. The outer LC_ALL below
# is what a French-locale user's environment would already have set before ever running install; if
# grubstake.sh's own call does not override it, the shim sees that same value and answers in kind.
r=$(new_repo)
_shims="$(mktemp -d "$ROOT/no-net-locale-lock.XXXXXX")" || fixture_die "cannot create a scratch dir for the network shim"
printf '#!/bin/sh\necho "curl: network blocked in test" >&2\nexit 6\n' > "$_shims/curl"
chmod +x "$_shims/curl"
_marker="$r/.lock-marker"
: > "$_marker" || fixture_die "cannot plant the lock marker for $r"
( sleep 2; rm -f "$_marker" ) &
_releaser=$!
_realgit="$(command -v git)" || fixture_die "no real git on PATH to wrap"
cat > "$_shims/git" <<SHIM
#!/bin/sh
if [ "\$#" -eq 5 ] && [ "\$1" = "-C" ] && [ "\$3" = "config" ] && [ "\$4" = "core.hooksPath" ] && [ "\$5" = ".githooks" ]; then
    if [ -e "$_marker" ]; then
        if [ "\${LC_ALL:-}" = "C" ]; then
            echo "error: could not lock config file .git/config: File exists" >&2
        else
            echo "erreur : impossible de verrouiller le fichier de configuration .git/config : Le fichier existe" >&2
        fi
        exit 255
    fi
fi
exec "$_realgit" "\$@"
SHIM
chmod +x "$_shims/git" || fixture_die "cannot make the locale git shim executable"
_out=$( cd "$r" && LC_ALL=fr_FR.UTF-8 PATH="$_shims:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh install 2>&1 ); _rc=$?
wait "$_releaser" 2>/dev/null
_hp=$( cd "$r" && git config core.hooksPath 2>/dev/null )
if [ "$_rc" -ne 0 ]; then
    fail "install treated a locale-translated lock message as fatal instead of retrying: $_out"
elif [ "$_hp" != ".githooks" ]; then
    fail "install exited 0 but hooksPath was never actually set: $_out"
else
    pass
fi

it "a repository path containing the discriminator's own match text does not turn a git permission denial into contention"
# The with_lock/add_one collision above, at the third site the same panel round flagged: install's
# own fix reads git's stderr and discriminates with "case ... in *": File exists")", anchored to the
# end because the diff's own comment already names the counter-case -- an ambient GIT_DIR makes git
# report the config file's full path instead of the usual plain ".git/config", so a repo whose path
# contains "File exists" would otherwise collide with git's own trailing reason. Verified directly
# before writing this: with plain "-C" alone (no GIT_DIR), git's message never carries the repo's
# path at all, which is why the earlier panel round correctly found nothing to test here -- exporting
# GIT_DIR is what actually makes the collision text reach the matched string. GIT_DIR has to be
# exported into the same environment "install" runs in, not just handed to a standalone git call, to
# prove this reaches the discriminator through the real invocation rather than a hand-picked one.
r="$ROOT/gitdir-collision.$$/File exists.repo"
mkdir -p "$r" || fixture_die "cannot create $r"
( cd "$r" && git init -q . ) || fixture_die "git init failed in $r"
cp "$GS" "$r/grubstake.sh" || fixture_die "cannot copy grubstake.sh into $r"
chmod +x "$r/grubstake.sh" || fixture_die "cannot make grubstake.sh executable in $r"
_shims="$(mktemp -d "$ROOT/no-net-gitdir-collision.XXXXXX")" || fixture_die "cannot create a scratch dir for the network shim"
printf '#!/bin/sh\necho "curl: network blocked in test" >&2\nexit 6\n' > "$_shims/curl"
chmod +x "$_shims/curl"
chmod 555 "$r/.git" || fixture_die "cannot make $r/.git read-only"
_t0=$(date +%s)
_out=$( cd "$r" && GIT_DIR="$r/.git" PATH="$_shims:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh install 2>&1 ); _rc=$?
_t1=$(date +%s)
chmod 755 "$r/.git" 2>/dev/null
_elapsed=$((_t1 - _t0))
if [ "$_rc" -eq 0 ]; then
    fail "install exited 0 with .git itself read-only: $_out"
elif [ "$_elapsed" -ge 3 ]; then
    fail "install spun ${_elapsed}s instead of failing fast on a non-retryable git error: $_out"
elif printf '%s' "$_out" | grep -qi "kept losing the lock"; then
    fail "a repository path containing the discriminator's own text was misread as contention: $_out"
elif ! printf '%s' "$_out" | grep -qi "permission denied"; then
    fail "did not carry git's own error text: $_out"
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

it "post-commit stays quiet on a malformed CURRENT rather than comparing it against a genuinely newer release"
# #71: the third comparison, newest=$(printf ... "$CURRENT" "$LATEST" ... | sort ...), has no
# filter in front of it, unlike the two sort sites that select LATEST in the first place. CURRENT is
# whatever the installed script's own "version" verb prints, so a dev/pre-release build with a
# non-numeric suffix reaches this comparison unvalidated. A real hook invocation reaches this cleanly:
# new_hook_repo copies the shipped hooks/post-commit verbatim, and latest_cache writes the exact
# cache line the hook reads. NOTES.md, not a .swift path: staging Swift would send pre-commit into
# its own "check" call, whose output lands in the same combined "$_out" hook_commit returns and
# could mask or fake the very "available" line this test greps for.
r=$(new_hook_repo)
sed -i.bak 's/^GRUBSTAKE_VERSION=.*/GRUBSTAKE_VERSION="0.5.0-dev"/' "$r/grubstake.sh" && rm -f "$r/grubstake.sh.bak"
latest_cache "$r" 9.9.9
_c0=$(commits "$r")
stage "$r" NOTES.md "notes"
_out=$(hook_commit "$r"); _rc=$?
if [ "$_rc" -ne 0 ]; then
    fail "a malformed CURRENT failed the commit outright, not just stayed quiet (rc $_rc): $_out"
elif [ "$(commits "$r")" != "$((_c0 + 1))" ]; then
    fail "the commit did not land, so silence proves nothing here: $_out"
elif printf '%s' "$_out" | grep -q "available"; then
    fail "advised an update by comparing an unvalidated, malformed CURRENT against LATEST: $_out"
else
    pass
fi

it "post-commit stays quiet on a poisoned LATEST cache rather than comparing it against a well-formed CURRENT"
# #71's sharper case: LATEST is filtered by grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' when the background
# refresh writes it, but read back raw from the cache file with no re-validation, so a poisoned or
# stale cache carries anything into the same unguarded comparison. This is worse than scenario 1: the
# advisory below would name a version no tag filter could ever have produced, not merely an
# unvalidated-but-plausible one.
r=$(new_hook_repo)
latest_cache "$r" "99.0.0-dev"
_c0=$(commits "$r")
stage "$r" NOTES.md "notes"
_out=$(hook_commit "$r"); _rc=$?
if [ "$_rc" -ne 0 ]; then
    fail "a poisoned LATEST cache failed the commit outright, not just stayed quiet (rc $_rc): $_out"
elif [ "$(commits "$r")" != "$((_c0 + 1))" ]; then
    fail "the commit did not land, so silence proves nothing here: $_out"
elif printf '%s' "$_out" | grep -q "available"; then
    fail "advised an update by comparing a well-formed CURRENT against a poisoned, unvalidated LATEST: $_out"
else
    pass
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

it "doctor never advises deleting a hook grubstake did not write"
# #59: the drift check above compares .githooks/pre-commit to embedded_hook unconditionally, with
# no notion of a repo that wired core.hooksPath itself and never ran install. That repo's own hook
# gets called DRIFTED and told to `rm it and run: grubstake install` -- a remedy that deletes a
# hook grubstake never wrote. Nothing here carries the marker embedded_hook's own copy does, so
# there is nothing for doctor to have adopted.
r=$(new_repo)
mkdir -p "$r/.githooks" || fixture_die "cannot create $r/.githooks"
printf '#!/bin/sh\necho "repo-managed gate"\n' > "$r/.githooks/pre-commit" \
    || fixture_die "cannot write $r/.githooks/pre-commit"
chmod +x "$r/.githooks/pre-commit" || fixture_die "cannot make $r/.githooks/pre-commit executable"
( cd "$r" && git config core.hooksPath .githooks ) || fixture_die "cannot set core.hooksPath in $r"
# Read back what was just written: doctor's report hinges entirely on this value, so a config
# write that silently did not take must fail the fixture, not masquerade as doctor misbehaving.
[ "$(cd "$r" && git config core.hooksPath)" = ".githooks" ] \
    || fixture_die "core.hooksPath did not read back as .githooks in $r"
_out=$(gs "$r" doctor); _rc=$?
if [ "$_rc" -ne 0 ]; then
    fail "doctor exited non-zero on a repo that keeps its own hook (rc $_rc): $_out"
else
    case "$_out" in
        *DRIFTED*|*"rm it and run"*) fail "doctor advised deleting a hook it never wrote: $_out" ;;
        *"hooksPath  .githooks"*) pass ;;
        *) fail "doctor did not report on this repo at all: $_out" ;;
    esac
fi

it "doctor still reports drift in a hook that carries grubstake's marker"
# The ownership distinction #59 wants must not swallow real drift: a hook that IS the embedded
# copy, then edited, still needs the existing DRIFTED remedy -- that report is correct today and
# must survive the fix. new_hook_repo seeds the real hooks/pre-commit (marker and all), so
# corrupting it in place keeps the marker but changes the bytes.
r=$(new_hook_repo)
printf '# corrupted for test\n' >> "$r/.githooks/pre-commit"
_out=$(gs "$r" doctor)
# Grep the pre-commit line specifically: a case glob spans newlines, so matching the three
# substrings anywhere in $_out (in any order across lines) would not pin them to the one line
# that must carry them together.
_line=$(printf '%s\n' "$_out" | grep 'pre-commit')
case "$_line" in
    *"DRIFTED"*"rm it and run: grubstake install"*) pass ;;
    *) fail "doctor stopped flagging a genuinely drifted grubstake hook: $_out" ;;
esac

# Adoption rule chosen here: a hooksPath other than .githooks means the repo manages its own hooks
# outright, mirroring cmd_install's own refusal to touch a foreign hooksPath. doctor must not grade
# hooks it was never asked to install, so "not installed" (a defect reading) must not appear for a
# repo that never pointed hooksPath at .githooks in the first place.
it "doctor does not grade hooks in a repo whose hooksPath is not .githooks"
r=$(new_repo)
( cd "$r" && git config core.hooksPath .other-hooks ) || fixture_die "cannot set core.hooksPath in $r"
# Read back what was just written, for the same reason as the fixture above: a config write that
# silently did not take must fail the fixture, not masquerade as doctor misbehaving.
[ "$(cd "$r" && git config core.hooksPath)" = ".other-hooks" ] \
    || fixture_die "core.hooksPath did not read back as .other-hooks in $r"
_out=$(gs "$r" doctor); _rc=$?
if [ "$_rc" -ne 0 ]; then
    fail "doctor exited non-zero for a repo that manages its own hooksPath (rc $_rc): $_out"
else
    case "$_out" in
        *"not installed"*|*"DRIFTED"*) fail "doctor graded a hook in a repo it was never asked to install: $_out" ;;
        *) pass ;;
    esac
fi

it "a reworded hook header would make doctor mistake real drift for a hand-off"
# cmd_doctor's ownership discriminator is `grep -q "^# grubstake <hook>"` against the installed
# file. That line is ordinary prose in hooks/pre-commit and hooks/post-commit, not a declared
# sentinel -- nothing marks it as machine-read. A plausible reword of it (e.g. "grubstake's
# pre-commit gate.") would silently flip doctor from reporting a drifted-but-still-grubstake's hook
# to reporting "not grubstake's; hands off" for every repo that installed this hook, since the
# marker doctor looks for would simply no longer be there. Changing the shipped hook bytes to carry
# a declared sentinel instead would trigger the manual hook-refresh ceremony in every consuming
# repo, so this constraint is enforced here, at development time, rather than at runtime.
#
# Extracted from grubstake.sh rather than hardcoded a second time here, so the mirror failure --
# cmd_doctor's own grep pattern drifting instead of hooks/'s prose -- fails this test too; a
# hardcoded copy would only ever catch one direction of the coupling.
_raw="$(grep -Fo '"^# grubstake $_hook"' "$GS")"
_pat="${_raw#\"}"; _pat="${_pat%\"}"
if [ -z "$_pat" ]; then
    fail "cmd_doctor no longer greps '^# grubstake \$_hook'; this test's extraction needs updating to match"
else
    _bad=""
    for _hook in pre-commit post-commit; do
        _want="${_pat%\$_hook}$_hook"
        grep -q "$_want" "$HOOKS/$_hook" 2>/dev/null || _bad="$_bad $_hook"
    done
    [ -z "$_bad" ] && pass || fail "missing doctor's ownership marker line ('# grubstake <hook>'):$_bad"
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

it "add's pins lock fails fast naming the vanished directory, not a phantom holder"
# #68: add_one's pins lock is a hand-rolled "while ! mkdir" loop, the same shape with_lock had
# before #56 -- mkdir cannot distinguish its parent being gone from another run genuinely holding
# the lock, so if the directory holding grubstake.tools disappears between add's fetch loop and its
# lock attempt, the loop spins the full ~5s retry budget and then blames a run that was never
# there. The trigger is far-fetched (the repo's own working directory vanishing mid-add, not
# something anything in normal use does), which is why this is filed for consistency with #56
# rather than urgency -- but the fix is the same shape: check the parent inside the loop, fail
# fast, name what actually happened.
#
# add's own network fetches happen before the lock (hashing every platform first), so
# fake_release/curl-shim get add_one to the lock cheaply and offline. lock_pause_shim pauses
# add_one's own lock mkdir (it ends in ".lock" the same way with_lock's does, so the existing shim
# needs no changes), which is the deterministic point to rename the repo directory away: renaming
# it does not disturb the already-running, already-exec'd grubstake.sh process (the open script and
# its cwd survive a renamed-away directory entry same as any Unix process would), but the lock's
# own path, computed once from script_dir() before the loop started, no longer resolves once the
# real mkdir is finally allowed to run. The reached/go handshake files live under $ROOT, one level
# above the repo, since the repo itself is what gets renamed out from under this test.
r=$(new_repo)
_sha=$(fake_release "$r" 1.0.0)
_shim="$r/mkdir-shim"; _reached="$ROOT/add-reached.$$"; _go="$ROOT/add-go.$$"
lock_pause_shim "$_shim" "$_reached" "$_go"
(
    cd "$r" || exit 1
    PATH="$r/curl-shim:$_shim:$PATH"; export PATH
    GRUBSTAKE_CACHE="$r/.cache"; export GRUBSTAKE_CACHE
    exec ./grubstake.sh add swiftlint@1.0.0 >"$r/out" 2>&1
) &
_bgpid=$!
_w=0
while [ ! -f "$_reached" ]; do
    _w=$((_w + 1))
    [ "$_w" -gt 300 ] && fixture_die "add never reached its pins lock"
    sleep 0.05 2>/dev/null || sleep 1
done
_trash="$ROOT/add-vanished-repo.$$"
mv "$r" "$_trash" || fixture_die "cannot rename the repo directory away while add is paused at its lock"
_t0=$(date +%s)
: > "$_go"
wait "$_bgpid" 2>/dev/null
_rc=$?
_t1=$(date +%s)
_elapsed=$((_t1 - _t0))
_out="$(cat "$_trash/out" 2>/dev/null)"
if [ "$_rc" -eq 0 ]; then
    fail "add exited 0 despite its own repo directory vanishing mid-run: $_out"
elif [ "$_elapsed" -ge 3 ]; then
    fail "add spun ${_elapsed}s instead of failing fast when its own directory vanished mid-lock: $_out"
elif printf '%s' "$_out" | grep -q "locked by another run"; then
    fail "misdiagnosed a vanished directory as another run holding the pins lock: $_out"
elif ! printf '%s' "$_out" | grep -Eqi "gone|removed|disappear|vanish|no longer|does not exist"; then
    fail "failed fast without naming the real cause: $_out"
else
    pass
fi
rm -f "$_reached" "$_go" 2>/dev/null
chmod -R u+w "$_trash" 2>/dev/null
rm -rf "$_trash" 2>/dev/null

it "add's pins lock still reports a genuine holder when the directory is intact"
# The other half of #68: the fix must not turn genuine contention into the same fast-fail. A
# directory already sitting at grubstake.tools.lock before add ever runs, with the repo directory
# left alone this time, makes add_one's mkdir fail every retry the same way a real concurrent
# `add` would, for the same budget a genuinely stale lock costs -- no second process or pause shim
# needed, the same static-plant technique #67's sibling lock test used. Exit and message alone do
# not prove the retry budget was honestly exhausted rather than skipped (a "> 0" in place of the
# real "> 50" would still exit non-zero and still say "locked by another run" on its very first
# retry) -- the elapsed time, timed the same way the vanished-directory test above times its fast
# path, is what actually distinguishes a real ~5s budget from a gutted one.
r=$(new_repo)
fake_release "$r" 1.0.0 >/dev/null
_lockdir="$r/grubstake.tools.lock"
mkdir -p "$_lockdir" || fixture_die "cannot plant the stale pins lock"
_t0=$(date +%s)
_out=$( cd "$r" && PATH="$r/curl-shim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh add swiftlint@1.0.0 2>&1 ); _rc=$?
_t1=$(date +%s)
_elapsed=$((_t1 - _t0))
rm -rf "$_lockdir" 2>/dev/null
if [ "$_rc" -eq 0 ]; then
    fail "add exited 0 despite a pins lock genuinely held by another run: $_out"
elif ! printf '%s' "$_out" | grep -q "locked by another run"; then
    fail "genuine contention was not reported as locked by another run: $_out"
elif [ "$_elapsed" -lt 3 ]; then
    fail "reported contention after only ${_elapsed}s -- the retry budget was not honestly exhausted: $_out"
else
    pass
fi

it "add fails fast on a permission-denied pins lock, not a five-second contention stall"
# #88, add_one's own copy of the with_lock gap: "[ -d "$_lockdir" ]" (=the repo root itself here,
# since the pins lock sits directly in it) only answers "does the parent still exist." A read-only
# repo root fails add_one's own mkdir with EACCES while remaining perfectly traversable (555 keeps
# the execute bit), so the existence test still reports true, the same as genuine EEXIST contention
# -- the retry spins its full budget before dying blaming a holder that was never there. fake_release
# is required here, not fake_install: add always downloads and hashes before it ever reaches its own
# lock, so nothing short of a real (if fixture-served) fetch reaches the mkdir under test.
r=$(new_repo)
fake_release "$r" 1.0.0 >/dev/null
chmod 555 "$r" || fixture_die "cannot make $r read-only"
_t0=$(date +%s)
_out=$( cd "$r" && PATH="$r/curl-shim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh add swiftlint@1.0.0 2>&1 ); _rc=$?
_t1=$(date +%s)
chmod 755 "$r" 2>/dev/null
_elapsed=$((_t1 - _t0))
if [ "$_rc" -eq 0 ]; then
    fail "add exited 0 despite a permission-denied pins lock: $_out"
elif [ "$_elapsed" -ge 3 ]; then
    fail "add spun ${_elapsed}s instead of failing fast on a non-retryable permission denial: $_out"
elif printf '%s' "$_out" | grep -qi "locked by another run"; then
    fail "blamed a lock nobody held instead of the real permission failure: $_out"
elif ! printf '%s' "$_out" | grep -qi "permission denied"; then
    fail "did not carry the real cause (permission denied): $_out"
else
    pass
fi

it "add blames an unreadable ancestor honestly, not a repository that was never removed"
# The other wrong diagnosis at add_one's site: an ancestor of the repo itself -- not the repo root,
# which "[ -d "$_lockdir" ]" checks, but something above it -- can be the thing that becomes
# untraversable, which fails that same existence test, indistinguishable to add_one from the #68
# case (the repo directory genuinely renamed away mid-add) the vanished-directory test above covers.
# Nothing was removed here; only a permission bit changed on a directory the repo sits inside.
# new_gated_repo, not new_repo: the ancestor under test has to be a directory this suite controls
# and nothing else shares, never $ROOT itself. A static pre-chmod on it does not isolate this
# cleanly, though: with the ancestor already broken, the shell cannot even absolute-path back into
# the repo to start the run, and a relative "./grubstake.sh" invocation sidesteps the break entirely
# (script_dir()'s own "cd . && pwd" never needs to leave a cwd it is already validly inside). Same
# fix as with_lock's equivalent test above: shim "mkdir" to flip the permission the instant the
# pins-lock path is attempted, landing the change after add_one's own hash/download phase -- which
# never touches the repo; the download lands in system $TMPDIR -- and right before the mkdir under
# test, with grubstake.sh itself still reached via the repo's own absolute path throughout.
r=$(new_gated_repo)
_gate="$(dirname "$r")"
fake_release "$r" 1.0.0 >/dev/null
_shim="$r/mkdir-shim"; mkdir -p "$_shim" || fixture_die "cannot create $_shim"
_realmkdir="$(command -v mkdir)" || fixture_die "no real mkdir on PATH to wrap"
cat > "$_shim/mkdir" <<SHIM
#!/bin/sh
case "\$*" in
    *.lock)
        chmod 000 "$_gate"
        ;;
esac
exec "$_realmkdir" "\$@"
SHIM
chmod +x "$_shim/mkdir" || fixture_die "cannot make the mkdir shim executable"
_t0=$(date +%s)
_out=$( cd "$r" && PATH="$_shim:$r/curl-shim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh add swiftlint@1.0.0 2>&1 ); _rc=$?
_t1=$(date +%s)
chmod 755 "$_gate" 2>/dev/null
_elapsed=$((_t1 - _t0))
if [ "$_rc" -eq 0 ]; then
    fail "add exited 0 despite its own repository ancestor being unreadable: $_out"
elif [ "$_elapsed" -ge 3 ]; then
    fail "add spun ${_elapsed}s on an unreadable ancestor instead of failing fast: $_out"
elif printf '%s' "$_out" | grep -qi "removed mid-add"; then
    fail "claimed the repository was removed when only a permission bit changed: $_out"
elif ! printf '%s' "$_out" | grep -Eqi "permission|denied|access|unreadable|cannot (read|search|traverse)"; then
    fail "failed fast without naming the real cause: $_out"
else
    pass
fi

it "a repository path containing the discriminator's own match text does not turn a permission denial into contention"
# add_one's mirror of the with_lock collision above: its own fix reads the identical unanchored
# "case ... in *"File exists"*)" shape against mkdir's own message for "$_pins.lock", which sits
# directly in the repo root -- so here the collision text has to be in the repo's own path, not a
# separate cache root the way with_lock's equivalent test manages it. new_repo builds its own name
# from a timestamp and pass/fail counters, with no hook to choose that name, so this is built
# inline instead, mirroring new_repo()'s own steps (git init, copy grubstake.sh, create .cache) at a
# chosen path -- the one part of this dispatch's fixtures new_repo could not carry as asked.
r="$ROOT/repo-collision.$$/File exists.repo"
mkdir -p "$r" || fixture_die "cannot create $r"
( cd "$r" && git init -q . ) || fixture_die "git init failed in $r"
cp "$GS" "$r/grubstake.sh" || fixture_die "cannot copy grubstake.sh into $r"
chmod +x "$r/grubstake.sh" || fixture_die "cannot make grubstake.sh executable in $r"
mkdir -p "$r/.cache" || fixture_die "cannot create $r/.cache"
fake_release "$r" 1.0.0 >/dev/null
chmod 555 "$r" || fixture_die "cannot make $r read-only"
_t0=$(date +%s)
_out=$( cd "$r" && PATH="$r/curl-shim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh add swiftlint@1.0.0 2>&1 ); _rc=$?
_t1=$(date +%s)
chmod 755 "$r" 2>/dev/null
_elapsed=$((_t1 - _t0))
if [ "$_rc" -eq 0 ]; then
    fail "add exited 0 despite a permission-denied pins lock: $_out"
elif [ "$_elapsed" -ge 3 ]; then
    fail "add spun ${_elapsed}s instead of failing fast on a non-retryable permission denial: $_out"
elif printf '%s' "$_out" | grep -qi "locked by another run"; then
    fail "a repository path containing the discriminator's own text was misread as contention: $_out"
elif ! printf '%s' "$_out" | grep -qi "permission denied"; then
    fail "did not carry the real cause (permission denied): $_out"
else
    pass
fi

it "an unreadable pins file is left alone, not collapsed down to the one new pin"
# #96: add_one's own rewrite ends "grep -v ... > \"\$_pt\" || true" -- the "|| true" exists so an
# empty pins file (grep selects nothing, exit 1) is not mistaken for failure, but it swallows a
# genuine read failure the same way: $_pt stays empty, the new pin is appended to nothing, and the
# mv installs a one-line pins file. Confirmed on disk, not just by exit status, per CLAUDE.md's own
# rule that a fix verified once by hand is a fix the next change can break silently.
#
# ./grubstake.sh always execs via its own "#!/bin/sh" shebang, unaffected by which shell runs this
# suite -- so all three of sh/dash/env-i test/run.sh reproduce this the same way here, because this
# machine's own /bin/sh is bash: it runs the permission-denied read past validate_pins and reaches
# add_one's rewrite. AGENTS.md says CI's /bin/sh is dash, and there validate_pins' own
# "< \"\$_f\"" redirect aborts first with its own fatal error -- an accident of dash's harsher
# redirection semantics, not a guard add_one owns -- so this specific fixture would likely pass on
# CI for the wrong reason even unfixed. Test 3 below reproduces the same contract violation without
# depending on that redirect at all, so it does not share this gap.
r=$(new_repo)
pins "$r" "periphery 3.7.4 $SHA_A $SHA_A
swiftformat 0.61.1 $SHA_B $SHA_B"
_before=$(cat "$r/grubstake.tools")
fake_release "$r" 1.0.0 >/dev/null
chmod 000 "$r/grubstake.tools" || fixture_die "cannot make $r/grubstake.tools unreadable"
[ ! -r "$r/grubstake.tools" ] || fixture_die "chmod 000 did not take; the unreadable-pins fixture proves nothing"
_out=$( cd "$r" && PATH="$r/curl-shim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh add swiftlint@1.0.0 2>&1 ); _rc=$?
chmod u+rw "$r/grubstake.tools" 2>/dev/null
_after=$(cat "$r/grubstake.tools" 2>/dev/null)
if [ "$_rc" -eq 0 ]; then
    fail "add exited 0 despite an unreadable pins file. pins file now:
$_after"
elif [ "$_after" != "$_before" ]; then
    fail "add refused, but the pins file was rewritten anyway (data lost). before:
$_before
after:
$_after"
elif [ -e "$r/grubstake.tools.lock" ]; then
    fail "add refused, but left the pins lock behind: $r/grubstake.tools.lock"
elif ! printf '%s' "$_out" | grep -Eqi "read|unreadable|permission|denied|cannot"; then
    fail "refused, but without saying why: $_out"
else
    pass
fi

it "the first pin still lands when the pins file starts empty or absent"
# Guards against a fix that turns the ordinary case -- grep selecting nothing -- into a refusal
# along with the genuine failure it is meant to catch. Two distinct starting shapes: "absent"
# exercises the header-line creation at add_one's own "[ -f \"\$_pins\" ] || printf ..."; "empty"
# (an existing, zero-byte file) skips that write and is the shape the contract's own exception
# ("unless the original genuinely had none") has to cover. Watched green on unfixed code, on
# purpose: the "|| true" this issue removes exists to make exactly this case work, and this is the
# regression guard that must stay green once the fix lands, not a defect this issue is proving.
_bad=""
for _case in absent empty; do
    [ -z "$_bad" ] || break
    r=$(new_repo)
    [ "$_case" = empty ] && : > "$r/grubstake.tools"
    fake_release "$r" 1.0.0 >/dev/null
    _out=$( cd "$r" && PATH="$r/curl-shim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh add swiftlint@1.0.0 2>&1 ); _rc=$?
    _n=$(grep -cvE '^[[:space:]]*(#|$)' "$r/grubstake.tools" 2>/dev/null || echo 0)
    [ "$_rc" -eq 0 ] && [ "$_n" = "1" ] || _bad="$_case pins file: rc=$_rc, pin count=$_n, output: $_out"
done
if [ -n "$_bad" ]; then fail "add over an $_bad"; else pass; fi

it "a rewrite that silently drops unrelated pins is refused, not just one that cannot read the file"
# #96's second half: refuse any replacement with fewer pins than the original, not only ones caused
# by an unreadable file. add_one's own rewrite line is grep -v -E "^$_tool[[:space:]]" "$_pins" |
# grep -v '^$' > "$_pt" -- a grep shim intercepts only that exact invocation (double-quoted, so
# [[:space:]] matches as literal text rather than expanding as a glob bracket expression in the
# case pattern) and exits 1 with no output, the same shape a real grep -v takes when it genuinely
# selects nothing, so this cannot be told apart from an ordinary empty match by anything short of
# comparing pin counts. The pins file itself stays perfectly readable throughout, unlike the test
# above -- proving the guard has to be a count check, not just a read-failure detector. A sentinel
# file proves the shim actually fired, so this stays a real test rather than passing vacuously the
# moment a fix changes the shape of the read.
r=$(new_repo)
pins "$r" "periphery 3.7.4 $SHA_A $SHA_A
swiftformat 0.61.1 $SHA_B $SHA_B"
_before=$(cat "$r/grubstake.tools")
fake_release "$r" 1.0.0 >/dev/null
_fired="$r/grep-shim-fired"
_gshim="$r/grep-shim"; mkdir -p "$_gshim" || fixture_die "cannot create $_gshim"
_realgrep="$(command -v grep)" || fixture_die "no real grep on PATH to wrap"
cat > "$_gshim/grep" <<SHIM
#!/bin/sh
case "\$*" in
    "-v -E ^swiftlint[[:space:]] $r/grubstake.tools")
        : > "$_fired"
        exit 1
        ;;
esac
exec "$_realgrep" "\$@"
SHIM
chmod +x "$_gshim/grep" || fixture_die "cannot make the grep shim executable"
_out=$( cd "$r" && PATH="$_gshim:$r/curl-shim:$PATH" GRUBSTAKE_CACHE="$r/.cache" ./grubstake.sh add swiftlint@1.0.0 2>&1 ); _rc=$?
_after=$(cat "$r/grubstake.tools")
if [ ! -f "$_fired" ]; then
    fail "fixture never intercepted add's rewrite grep; the shim did not run as expected"
elif [ "$_rc" -eq 0 ]; then
    fail "add exited 0 despite a rewrite that dropped every unrelated pin. pins file now:
$_after"
elif [ "$_after" != "$_before" ]; then
    fail "add refused, but the pins file was rewritten anyway (data lost). before:
$_before
after:
$_after"
elif [ -e "$r/grubstake.tools.lock" ]; then
    fail "add refused, but left the pins lock behind: $r/grubstake.tools.lock"
else
    pass
fi

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

# ---------------------------------------------------------------------------- ci workflows

printf '\nci workflows\n'

it "the network workflow declares workflow_dispatch, not just a tag trigger"
# #86: gating only on the release tag means the network tier reports after the artifacts are
# already published -- confirmation, not a gate. The fix a release now depends on is dispatching
# this workflow against the commit about to be tagged, after that commit is known (gst-release/
# SKILL.md's own gate step -- see the test below for why "step 2" is not a safe way to say that
# anymore), and checking the run's headSha; that only works while the workflow can actually be
# dispatched. If a future edit ever drops "workflow_dispatch:" (reverting to tag-only, maybe while
# "simplifying" the trigger list), the release procedure's own dispatch step starts failing at
# release time -- this pins the trigger's presence in the file so that regression is caught here
# instead.
#
# What this proves and no more: that the trigger is declared. It does not run a real dispatch (that
# needs an actual GitHub Actions run, out of reach for an offline suite) and does not prove a
# dispatched run would actually pass -- only that the capability the release procedure depends on
# has not silently regressed out of the workflow file.
_wf="$REPO/.github/workflows/network.yml"
[ -f "$_wf" ] || fixture_die "cannot find $_wf"
grep -qE '^[[:space:]]*workflow_dispatch:' "$_wf" && pass || fail "workflow_dispatch is not declared in $_wf"

it "the release skill dispatches the network workflow only after the tagged commit is known, comparing headSha in that same step"
# Panel review on #86: a first version of this test only pinned that the skill names a dispatch of
# the workflow SOMEWHERE, which is exactly what let a real bug through review -- the dispatch sat
# right after the local run, before the version bump and the merge commit that follows it, so the
# commit the dispatch proved was never the commit that ended up tagged. The gate would have gone
# green on every release while proving nothing, the same hole #86 exists to close, rebuilt inside
# its own fix. Presence was never the property that mattered; order is.
#
# Anchored on the two commands themselves, not on step numbers or heading prose (both legitimately
# change; a step could be renamed or renumbered without the procedure regressing at all): the line
# capturing the commit about to be tagged ("git rev-parse HEAD", the one place in this doc that
# names the exact SHA a tag will point at) has to appear, in document order, before the line that
# dispatches the workflow ("gh workflow run <name>"). A doc that reverts to dispatching before that
# capture -- or drops the capture entirely -- fails here rather than only in production, on the
# next release.
#
# Exactly two structural facts are pinned, and no more: the dispatch's position relative to the SHA
# capture, and that the literal word "headSha" appears somewhere within the dispatch's own step (its
# "## " heading through the next one). That second check cannot tell a genuine comparison apart from
# the bare word surviving by accident -- the panel proved a doc that deletes every sentence enforcing
# the comparison ("a headSha that is not the SHA from step 5 stops the release") while keeping the
# `--json ...,headSha,...` flag in the command itself still passes, because the substring was never
# going anywhere. Anchoring tighter, on enforcement phrasing, would fail on a legitimate reword of
# that prose -- a test that breaks every time a sentence is improved is worse than one with an
# honestly-scoped gap. What this catches is the comparison disappearing from the step entirely, not
# the comparison losing its teeth while the word stays.
_wf="$REPO/.github/workflows/network.yml"
_skill="$REPO/.claude/skills/gst-release/SKILL.md"
[ -f "$_wf" ] || fixture_die "cannot find $_wf"
[ -f "$_skill" ] || fixture_die "cannot find $_skill"
# basename, not because a renamed workflow file survives this check -- it does not; $_wf above is a
# hardcoded path, so a real rename makes the "[ -f ]" guard above fixture_die loudly, which is the
# right failure, not a silent one -- but so the literal "network.yml" is spelled once here instead
# of twice within this same test.
_wfname="$(basename "$_wf")"
_shaline="$(grep -n '^git rev-parse HEAD$' "$_skill" | head -1 | cut -d: -f1)"
_dispatchline="$(grep -nE "gh workflow run[[:space:]]+$_wfname" "$_skill" | head -1 | cut -d: -f1)"
if [ -z "$_dispatchline" ]; then
    fail "the release skill no longer names a dispatch of $_wfname"
elif [ -z "$_shaline" ]; then
    fail "the release skill dispatches $_wfname but no longer captures the commit (git rev-parse HEAD) to compare it against"
elif [ "$_shaline" -ge "$_dispatchline" ]; then
    fail "the release skill dispatches $_wfname (line $_dispatchline) before capturing the commit it should prove (line $_shaline), the exact #86 hole rebuilt inside its own fix"
else
    _section_start="$(awk -v n="$_dispatchline" '/^## / { h = NR } NR == n { print h }' "$_skill")"
    _section_end="$(awk -v start="$_section_start" 'NR > start && /^## / { print NR; exit }' "$_skill")"
    [ -n "$_section_end" ] || _section_end=$(( $(wc -l < "$_skill") + 1 ))
    if sed -n "${_section_start},$(( _section_end - 1 ))p" "$_skill" | grep -q headSha; then
        pass
    else
        fail "the dispatch step (line $_dispatchline) does not compare headSha in the same step"
    fi
fi

# ---------------------------------------------------------------------------- result

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
