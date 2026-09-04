#!/bin/sh
# grubstake: pinned, verified build tooling for iOS repos.
#
# main() wraps everything and runs last. A shell reads scripts incrementally, so a truncated file
# would otherwise execute its valid prefix silently. Same reason nvm and rustup-init do it.

set -eu

GRUBSTAKE_VERSION="1.0.0"
GRUBSTAKE_MIN_VERSION="0.3.0"   # every earlier release has a known blocking defect
# Named so cmd_update can tell an override apart from the default it is comparing against.
GRUBSTAKE_REPO_DEFAULT="https://github.com/seriouslysean/grubstake"
GRUBSTAKE_RAW_DEFAULT="https://raw.githubusercontent.com/seriouslysean/grubstake"
GRUBSTAKE_REPO="${GRUBSTAKE_REPO:-$GRUBSTAKE_REPO_DEFAULT}"
GRUBSTAKE_RAW="${GRUBSTAKE_RAW:-$GRUBSTAKE_RAW_DEFAULT}"
# Seeded here, not on first use: install_tool calls warn_sentinel_once once per pinned tool, and set -u would crash on an unset read from whichever tool happens to run first.
_gst_sentinel_warned=0

# ---------------------------------------------------------------------------- output

log()  { printf '[grubstake] %s\n' "$1"; }
warn() { printf '[grubstake] %s\n' "$1" >&2; }
die()  { printf '[grubstake] %s\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------- quoting

# A trap string is shell source expanded once when the trap is set and re-parsed when it fires,
# so a value embedded in it has to survive that second parse regardless of what characters it holds.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

usage() {
    cat <<'USAGE'
grubstake: pinned, verified build tooling for iOS repos.

  grubstake install                  adopt this repo: write config, wire hooks, install tools
  grubstake update [<tag>]           fetch a newer grubstake, replace this script, leave the diff
  grubstake ensure                   install and verify every pinned tool
  grubstake check                    confirm every pinned tool is installed for this platform
  grubstake add <tool>@<version>...  pin one or more tools: download, hash, record
  grubstake path <tool>              absolute path to a pinned tool
  grubstake doctor                   report install health
  grubstake clean                    remove the entire cache, read-only entries included
  grubstake version                  print the version of this script

Tools: swiftlint, swiftformat, xcbeautify, periphery
USAGE
}

# ---------------------------------------------------------------------------- platform

platform() {
    case "$(uname -s)" in
        Darwin) echo darwin ;;
        Linux)  [ "$(uname -m)" = x86_64 ] || die "unsupported arch: $(uname -m)"
                echo linux ;;
        *)      die "unsupported platform: $(uname -s)" ;;
    esac
}

cache_root() {
    if [ -n "${GRUBSTAKE_CACHE:-}" ]; then
        echo "$GRUBSTAKE_CACHE"
        return 0
    fi
    # Checked, not tested directly: a die inside $( ) only kills that subshell, so comparing its
    # empty result against "darwin" would read as false and fall through to a Linux-shaped path.
    _cr_plat="$(platform)" || return 1
    if [ "$_cr_plat" = darwin ]; then
        echo "$HOME/Library/Caches/grubstake"
    else
        echo "${XDG_CACHE_HOME:-$HOME/.cache}/grubstake"
    fi
}

sha256_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        die "no shasum or sha256sum available"
    fi
}

repo_root() {
    git rev-parse --show-toplevel 2>/dev/null || die "not inside a git repository"
}

# ---------------------------------------------------------------------------- tool registry
# Properties of the tool, not the repo. Pins live in the consumer's grubstake.tools.

tool_url() {
    _v="$2"
    case "$1:$3" in
        swiftlint:darwin)    echo "https://github.com/realm/SwiftLint/releases/download/$_v/portable_swiftlint.zip" ;;
        swiftlint:linux)     echo "https://github.com/realm/SwiftLint/releases/download/$_v/swiftlint_linux_amd64.zip" ;;
        swiftformat:darwin)  echo "https://github.com/nicklockwood/SwiftFormat/releases/download/$_v/swiftformat.zip" ;;
        swiftformat:linux)   echo "https://github.com/nicklockwood/SwiftFormat/releases/download/$_v/swiftformat_linux.zip" ;;
        xcbeautify:darwin)   echo "https://github.com/cpisciotta/xcbeautify/releases/download/$_v/xcbeautify-$_v-universal-apple-macosx.zip" ;;
        xcbeautify:linux)    echo "https://github.com/cpisciotta/xcbeautify/releases/download/$_v/xcbeautify-$_v-x86_64-linux-static.tar.xz" ;;
        periphery:darwin)    echo "https://github.com/peripheryapp/periphery/releases/download/$_v/periphery-$_v.zip" ;;
        periphery:linux)     echo "" ;;
        *)                   die "unknown tool: $1" ;;
    esac
}

# Name of the executable inside the archive, which is not always the tool's name.
tool_member() {
    case "$1:$2" in
        swiftlint:linux)    echo "swiftlint-static" ;;
        swiftformat:linux)  echo "swiftformat_linux" ;;
        *)                  echo "$1" ;;
    esac
}

tool_version_args() {
    case "$1" in
        swiftlint|periphery) echo "version" ;;
        *)                   echo "--version" ;;
    esac
}

known_tools() { echo "swiftlint swiftformat xcbeautify periphery"; }

# grep -qw matches "$1" as a basic regex, so "swift.int" matches "swiftlint"; -xF keeps it literal.
is_known_tool() { known_tools | tr ' ' '\n' | grep -qxF "$1"; }

# ---------------------------------------------------------------------------- pins
# Not JSON: greppable, diffable, no parser needed.
# Columns: name version sha256-darwin sha256-linux ("-" when absent).

# Resolved from the script, never from the working directory. Reading pins from cwd is exactly
# the failure this tool exists to prevent: the same script would serve a different repo's pins.
# Symlinks are followed by hand; macOS has no readlink -f.
script_path() {
    _p="$0"
    while [ -L "$_p" ]; do
        _t="$(readlink "$_p")"
        case "$_t" in /*) _p="$_t" ;; *) _p="$(dirname "$_p")/$_t" ;; esac
    done
    echo "$_p"
}
script_dir() { cd "$(dirname "$(script_path)")" && pwd; }
pins_file() { echo "$(script_dir)/grubstake.tools"; }

pin_field() {
    _line=$(grep -E "^$1[[:space:]]" "$(pins_file)" 2>/dev/null || true)
    [ -n "$_line" ] || return 1
    echo "$_line" | awk -v n="$2" '{print $n}'
}

pin_version() { pin_field "$1" 2 ; }

# A "=" in field 3 marks the keyed form (key=sha256; unknown keys ignored, so a later platform is additive); add still only writes positional, forever -- see STABILITY.md.
pin_sha() {
    _ps_tool="$1"
    _ps_plat="$2"
    _ps_line=$(grep -E "^$_ps_tool[[:space:]]" "$(pins_file)" 2>/dev/null || true)
    [ -n "$_ps_line" ] || return 1
    # Unquoted on purpose to split the line into fields, but that also pathname-expands any field
    # shaped like a glob against cwd -- set -f/+f keeps a "?"-shaped sha from resolving to a decoy file.
    set -f
    set -- $_ps_line
    set +f
    case "${3:-}" in
        *=*)
            shift 2
            for _ps_kv in "$@"; do
                case "$_ps_kv" in
                    "$_ps_plat"=*) printf '%s\n' "${_ps_kv#*=}"; return 0 ;;
                esac
            done
            echo -
            ;;
        *)
            case "$_ps_plat" in
                darwin) printf '%s\n' "${3:-}" ;;
                linux)  printf '%s\n' "${4:-}" ;;
            esac
            ;;
    esac
}

pinned_tools() {
    [ -f "$(pins_file)" ] || return 0
    grep -vE '^[[:space:]]*(#|$)' "$(pins_file)" | awk '{print $1}'
}

# grubstake.tools is hand-editable and merge-conflict-prone. Reject a malformed file loudly
# instead of letting a duplicate line, a CRLF, or a conflict marker fail somewhere downstream.
validate_pins() {
    _f="$(pins_file)"
    [ -f "$_f" ] || return 0
    grep -q "$(printf '\r')" "$_f" && die "grubstake.tools has CRLF line endings"
    grep -qE '^(<<<<<<<|=======|>>>>>>>)' "$_f" && die "grubstake.tools has unresolved conflict markers"
    _n=0
    while IFS= read -r _l || [ -n "$_l" ]; do
        _n=$((_n + 1))
        case "$_l" in ''|\#*) continue ;; esac
        case "$_l" in [[:space:]]*) die "grubstake.tools:$_n line must not be indented" ;; esac
        # Same reason as pin_sha's own set -f: an unquoted split pathname-expands a glob-shaped field.
        set -f
        set -- $_l
        set +f
        is_known_tool "${1:-}" || die "grubstake.tools:$_n unknown tool: ${1:-}"
        printf '%s\n' "${2:-}" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)?$' || die "grubstake.tools:$_n bad version: ${2:-}"
        case "${3:-}" in
            *=*)
                shift 2
                _seen=""
                for _kv in "$@"; do
                    printf '%s\n' "$_kv" | grep -qE '^[a-z0-9_]+=[0-9a-f]{64}$' \
                        || die "grubstake.tools:$_n malformed keyed field: $_kv"
                    _key="${_kv%%=*}"
                    case " $_seen " in
                        *" $_key "*) die "grubstake.tools:$_n duplicate key: $_key" ;;
                    esac
                    _seen="$_seen $_key"
                done
                ;;
            *)
                [ $# -eq 4 ] || die "grubstake.tools:$_n expected 4 fields, got $#"
                for _h in "$3" "$4"; do
                    [ "$_h" = "-" ] || printf '%s\n' "$_h" | grep -qE '^[0-9a-f]{64}$' \
                        || die "grubstake.tools:$_n sha256 must be 64 hex chars or -, got: $_h"
                done
                ;;
        esac
    done < "$_f"
    _dupes="$(pinned_tools | LC_ALL=C sort | uniq -d)"
    [ -z "$_dupes" ] || die "grubstake.tools pins a tool more than once: $_dupes"
}

# ---------------------------------------------------------------------------- install tools

# Keyed by the pinned archive hash, not the version. The path identifies the bytes, so editing a
# pin changes the path, which is a cache miss, which reinstalls. Nothing has to detect staleness.
tool_dir()  { _tdr="$(cache_root)" || return 1; echo "$_tdr/$1/$2"; }   # $2 is the pinned sha256
tool_bin()  { _tbd="$(tool_dir "$1" "$2")" || return 1; echo "$_tbd/$1"; }

receipt_file() {
    echo "$1/.grubstake-receipt"
}

cache_sentinel_file() {
    echo "$1/.grubstake-cache-root"
}

# Same shape as entry_verified: presence alone is not proof, only a matching header is -- an empty or
# foreign file at this path must not read as owned. Shared so install_tool's own backfill and
# cmd_clean's own refusal judge the same file by the same rule.
sentinel_verified() {
    _sv_f="$1"
    [ -f "$_sv_f" ] || return 1
    [ "$(sed -n 1p "$_sv_f" 2>/dev/null)" = "cache-root 1" ]
}

# Backfilled the moment install_tool actively manages the root, never inferred later from its shape
# (#95): a root that already exists, empty, is just as actively managed as one mkdir just created, so
# gating this write on "did mkdir just create it" would leave an already-adopted repo's cache -- and
# every one of this suite's own fixtures, which pre-create an empty .cache -- unsentineled forever.
ensure_cache_sentinel() {
    _ecs_root="$1"
    mkdir -p "$_ecs_root" 2>/dev/null || return 1
    _ecs_file="$(cache_sentinel_file "$_ecs_root")"
    sentinel_verified "$_ecs_file" && return 0
    # A directory at the sentinel's own path cannot be replaced by mv -- mv nests into an existing
    # directory instead of overwriting it, no mv -T on macOS -- so this refuses rather than clearing
    # something that might not be grubstake's, the same never-infer-never-destroy rule clean itself
    # follows. Left unresolved, cmd_clean's own refusal is what keeps the root safe in the meantime.
    if [ -e "$_ecs_file" ] && [ ! -f "$_ecs_file" ]; then
        return 2
    fi
    _ecs_tmp="$_ecs_root/.grubstake-cache-root.tmp.$$"
    printf 'cache-root 1\n' > "$_ecs_tmp" 2>/dev/null && mv "$_ecs_tmp" "$_ecs_file" 2>/dev/null && return 0
    rm -f "$_ecs_tmp" 2>/dev/null || true
    return 1
}

# install_tool calls this once per pinned tool; without a per-process latch the same wedged-root
# fault would report once per tool instead of once per run, and the noise would scale with the pin
# count rather than with the fault. rc 2 is the squat case ensure_cache_sentinel returns for a
# non-regular-file at the sentinel path; anything else collapses to the generic could-not-write case,
# which also covers the root itself being a plain file -- mkdir -p can never fix that, only removal can.
warn_sentinel_once() {
    [ "$_gst_sentinel_warned" = 0 ] || return 0
    _gst_sentinel_warned=1
    if [ "$1" = 2 ]; then
        warn "$(cache_sentinel_file "$2") is not a regular file; remove or chown it by hand, or clean will keep refusing $2 until then"
    else
        warn "could not write the ownership sentinel under $2; chown or chmod the root by hand if it is a permissions problem, or remove $2 by hand if it is not even a directory, or clean will keep refusing it"
    fi
}

# Hashes $1 and prints it only if it comes back 64 lowercase hex; prints nothing otherwise. Shared
# by every receipt write, so a transient hash failure never reaches a printf that would record it.
hashed_or_empty() {
    _h="$(sha256_file "$1" 2>/dev/null || echo '')"
    if printf '%s' "$_h" | grep -qE '^[0-9a-f]{64}$'; then
        printf '%s' "$_h"
    fi
}

# Stages a receipt for $1 recording $2 as its binary-sha256 and $3 as its version into a tmp name,
# then renames it over the real path -- the same idiom the staging directory and the pins file use
# elsewhere in this script -- so a write interrupted mid-truncate never leaves the real receipt
# partial. Callers run this under $1.lock, the same lock publish_dir uses, so a legacy entry two
# concurrent ensures both want to backfill does not strand a tmp file one of them can no longer
# reach. Never dies; a failure here just returns non-zero for the caller to warn about.
write_receipt() {
    _wr_tmp="$1/.grubstake-receipt.tmp.$$"
    chmod u+w "$1" 2>/dev/null || true
    if printf 'receipt 1\nbinary-sha256 %s\nversion %s\n' "$2" "$3" > "$_wr_tmp" 2>/dev/null \
        && mv "$_wr_tmp" "$(receipt_file "$1")" 2>/dev/null; then
        chmod -R a-w "$1" 2>/dev/null || true
        return 0
    fi
    rm -f "$_wr_tmp" 2>/dev/null || true
    return 1
}

# Every failure mode -- missing, foreign header, unreadable, hash mismatch -- collapses to the
# same plain non-zero; the caller decides how loud to be about what the mismatch means.
entry_verified() {
    _ev_bin="$1/$2"
    [ -x "$_ev_bin" ] || return 1
    _ev_rf="$(receipt_file "$1")"
    [ -f "$_ev_rf" ] || return 1
    [ "$(sed -n 1p "$_ev_rf" 2>/dev/null)" = "receipt 1" ] || return 1
    _ev_sha="$(awk '/^binary-sha256/{print $2}' "$_ev_rf" 2>/dev/null)"
    printf '%s' "$_ev_sha" | grep -qE '^[0-9a-f]{64}$' || return 1
    [ "$_ev_sha" = "$(sha256_file "$_ev_bin")" ]
}

# mkdir is the portable atomic lock. flock(1) is not present on macOS.
with_lock() {
    # A nested call would clobber this call's own _lk/_wl_saved globals (no `local` in POSIX sh); no caller nests today, so a re-entry dies loud rather than silently losing a saved trap.
    [ -z "${_wl_active:-}" ] || die "with_lock: called re-entrantly, nesting is not supported"
    _lk="$1"; shift
    _w=0
    while :; do
        # The cause comes from mkdir's own words, not a second [ -d ] test taken afterwards: that
        # test answers "does the parent still exist," which a read-only parent (EACCES) passes same
        # as genuine contention, and an unreadable ancestor fails same as a parent actually removed.
        # LC_ALL=C: the discriminator below reads mkdir's own message, so it has to stay in the
        # language it was written against, the same convention #85 uses for git's own message.
        _mkerr="$(LC_ALL=C mkdir "$_lk" 2>&1 >/dev/null)" && break
        # Anchored to the end, not a bare substring: the lock path is interpolated into this very
        # message, and an unanchored match lets a path that happens to contain "File exists" (or the
        # ENOENT text) collide with mkdir's own trailing reason instead of reading it.
        case "$_mkerr" in
            *": File exists") : ;;
            *": No such file or directory")
                warn "$_lk: its directory is gone, most likely a concurrent clean removed the cache mid-install"
                return 1
                ;;
            *)
                warn "cannot create lock: $_mkerr"
                return 1
                ;;
        esac
        _w=$((_w + 1))
        # Acquisition failure is the caller's to scope; with_lock never decides how loud it is.
        if [ "$_w" -gt 50 ]; then
            warn "cache entry locked by another run: $_lk (stale? rmdir it)"
            return 1
        fi
        sleep 0.1 2>/dev/null || sleep 1
    done
    _wl_active=1
    # Captured via a plain redirect, not $(trap): dash resets a subshell's own trap table, so
    # command substitution reads this back empty even with a trap already armed in this shell.
    _wl_savefile="$(mktemp "${TMPDIR:-/tmp}/grubstake-trap.XXXXXX")" || {
        warn "$_lk: cannot save the caller's trap state, refusing to hold this lock unsafely"
        rmdir "$_lk" 2>/dev/null || true
        _wl_active=""
        return 1
    }
    # A redirect failure here is fatal to the whole process under dash (a special builtin's own redirection error is unconditionally fatal there), not something an if around it can catch.
    trap > "$_wl_savefile" 2>/dev/null
    # A swallowed read failure here would read as "caller had no trap" and restore nothing.
    if ! _wl_saved="$(cat "$_wl_savefile" 2>/dev/null)"; then
        warn "$_lk: cannot read back the caller's trap state, refusing to hold this lock unsafely"
        rm -f "$_wl_savefile" 2>/dev/null || true
        rmdir "$_lk" 2>/dev/null || true
        _wl_active=""
        return 1
    fi
    rm -f "$_wl_savefile" 2>/dev/null || true
    # Commands passed here must warn and return, never exit or die: the EXIT trap below only releases the lock, it does not restore this trap.
    # Restoring (or clearing, with no caller trap) always runs first below, so no instruction boundary is ever left with neither this trap nor the caller's armed.
    trap '
        if [ -n "$_wl_saved" ]; then eval "$_wl_saved"; else trap - EXIT HUP INT TERM; fi
        rmdir "$_lk" 2>/dev/null || true
        exit 1
    ' HUP INT TERM
    trap 'rmdir "$_lk" 2>/dev/null || true' EXIT
    # `cmd; rc=$?` does not survive set -e: the shell exits at cmd and never reaches the rmdir.
    if "$@"; then _rc=0; else _rc=$?; fi
    # Same restore-first order as the signal handler: disarming before releasing would let a signal here rmdir a second time, after another run may have already reclaimed the path.
    if [ -n "$_wl_saved" ]; then eval "$_wl_saved"; else trap - EXIT HUP INT TERM; fi
    rmdir "$_lk" 2>/dev/null || true
    _wl_active=""
    return $_rc
}

# A published entry is never unlinked: another repo may be executing from it. The loser of a real
# race discards its own staging, and both copies are identical by construction.
# A receipt mismatch does not change that: destroying a live binary to repair a mismatch it cannot
# explain risks handing a concurrent exec an ENOENT mid-run, the exact hazard this rule prevents.
# install_tool's deep pass is where a mismatch gets surfaced; publish_dir only ever adds an entry.
# A destination that exists but lacks the executable is not a winner, only debris from an
# interrupted publish or a stray mkdir, so it is cleared and the verified staging published instead.
# The lock exists because `mv dir existing-dir` nests rather than fails, and macOS mv has no -T.
# Read-only comes after publishing, never before: unlinking needs write permission on the
# containing directory, so hardening the staging first is what stops the loser cleaning up.
publish_dir() {
    if [ -e "$2" ]; then
        if [ -x "$2/$3" ]; then
            chmod -R u+w "$1" 2>/dev/null || true
            rm -rf "$1"
        else
            chmod -R u+w "$2" 2>/dev/null || true
            rm -rf "$2"
            # rm -rf can no-op on an immutable file, and a die here would exit past with_lock's
            # rmdir and leak the lock, so both failures warn and return for the caller to fail on.
            [ ! -e "$2" ] || { warn "$3: cannot clear partial $2 (remove it by hand and retry)"; return 1; }
            mv "$1" "$2" || { warn "$3: cannot publish into $2"; return 1; }
            chmod -R a-w "$2" 2>/dev/null || true
        fi
    else
        mv "$1" "$2"
        chmod -R a-w "$2" 2>/dev/null || true
    fi
}

# The pinned hash, checked here against the bytes that arrived, is the trust root. Everything
# after publish is a cache: fast, disposable, and not a security boundary.
install_tool() {
    _tool="$1"
    _ver="$2"
    # Checked, not assigned: errexit is suspended for this whole body under "install_tool ... || _bad=1",
    # so a bare assignment would swallow platform()'s own die and fall through to a misleading empty-platform skip.
    _plat="$(platform)" || return 1
    _want="$(pin_sha "$_tool" "$_plat" 2>/dev/null || echo '-')"
    _url="$(tool_url "$_tool" "$_ver" "$_plat")"

    if [ -z "$_url" ]; then
        log "$_tool: not published for $_plat, skipping"
        return 0
    fi
    [ "$_want" != "-" ] && [ -n "$_want" ] || die "$_tool has no $_plat hash in grubstake.tools (run: grubstake add $_tool@$_ver)"

    _dest="$(tool_dir "$_tool" "$_want")"
    _bin="$(tool_bin "$_tool" "$_want")"
    # Ahead of every branch below, not only the fresh-install one: an already-existing entry still
    # means install_tool is actively managing this root right now (#95).
    _croot="$(cache_root)" || return 1
    # Captured, not chained on $?: dash's own $? after `if !` reads the negated status, not ensure_cache_sentinel's.
    if ensure_cache_sentinel "$_croot"; then _secrc=0; else _secrc=$?; fi
    [ "$_secrc" = 0 ] || warn_sentinel_once "$_secrc" "$_croot"
    # Existence alone is no longer proof: the receipt is what tells a verified entry apart from debris.
    if [ -x "$_bin" ]; then
        if entry_verified "$_dest" "$_tool"; then
            _rver="$(awk '/^version/{print $2}' "$(receipt_file "$_dest")" 2>/dev/null)"
            if [ "$_rver" = "$_ver" ]; then
                return 0
            fi
            # A stale receipt line is not license to trust the pin's claim unchecked: rule 3 requires
            # the binary itself to report the pinned version before that label is ever recorded, so
            # this asserts it here, offline, against the binary already on disk -- the one path that
            # could otherwise relabel a receipt to a version the binary was never shown to be.
            _reported="$(reported_version "$_bin" "$_tool" || echo '')"
            if [ "$_reported" != "$_ver" ]; then
                warn "$_tool: $_dest reports ${_reported:-nothing}, not the pinned $_ver.
  The pin may have been edited without re-hashing; run: grubstake add $_tool@$_ver, or remove $_dest by hand."
                return 1
            fi
            # The binary genuinely reports the pinned version -- only the receipt's version line was
            # stale -- so this rewrites it in place rather than downloading: publish_dir would discard
            # a fresh download here anyway, since this entry's own executable already makes it the
            # winner, so nothing built from that download would ever actually land.
            _bsha="$(hashed_or_empty "$_bin")"
            if [ -z "$_bsha" ]; then
                # A failed or empty hash must never fail the run, the same rule the sibling branch and fresh publish both hold.
                warn "$_tool: entry records version ${_rver:-nothing}, pinned $_ver, but could not be hashed to correct the receipt"
            elif with_lock "$_dest.lock" write_receipt "$_dest" "$_bsha" "$_ver"; then
                log "$_tool: entry recorded version ${_rver:-nothing}, updated the receipt to pinned $_ver"
            else
                # Scoped like the mismatch branch above: the entry is never touched, only the run is flagged.
                warn "$_tool: entry records version ${_rver:-nothing}, pinned $_ver, but the receipt could not be updated"
                return 1
            fi
            return 0
        else
            _rf="$(receipt_file "$_dest")"
            if [ -f "$_rf" ] && [ "$(sed -n 1p "$_rf" 2>/dev/null)" = "receipt 1" ]; then
                # Never reinstall over this: publish_dir never unlinks a live binary, and neither does
                # this path -- a mismatch this script cannot explain is a human's call, not a repair.
                # Warned, not died: one flagged entry must not block installing or verifying every
                # other pinned tool; cmd_ensure exits non-zero at the end if any were flagged.
                warn "$_tool: $_dest does not match its receipt recorded at install.
  Remove that directory by hand, or run: grubstake clean"
                return 1
            fi
            # No receipt, or a header this script does not recognize: predates receipts, or was
            # written by a version that will. Record one against what is already there, offline and
            # in place -- it is the same trust the entry already had, now with a baseline to drift from.
            _bsha="$(hashed_or_empty "$_bin")"
            if [ -z "$_bsha" ]; then
                # A hash that failed or came back empty must never be recorded: a legacy entry with no
                # receipt is still usable, and a broken one would leave the next run nothing to self-heal from.
                warn "$_tool: could not hash $_bin to record a receipt (leaving it as-is)"
            elif with_lock "$_dest.lock" write_receipt "$_dest" "$_bsha" "$_ver"; then
                log "$_tool $_ver: recorded a receipt for the existing entry"
            else
                # A read-only parent or a full disk must not turn an already-usable entry into a
                # forced reinstall; the tool ran before this and still does.
                # Only the run is flagged; the entry is left exactly as it was.
                warn "$_tool: could not record a receipt for $_dest (leaving it as-is)"
                return 1
            fi
            return 0
        fi
    fi

    _tmp="$(mktemp -d "${TMPDIR:-/tmp}/grubstake.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf $(sq "$_tmp")" EXIT HUP INT TERM

    log "$_tool $_ver: downloading"
    _archive="$_tmp/archive"
    curl -fsSL --retry 3 --retry-all-errors --max-time 300 "$_url" -o "$_archive" \
        || die "$_tool $_ver: download failed"

    _got="$(sha256_file "$_archive")"
    [ "$_got" = "$_want" ] || die "$_tool $_ver: sha256 mismatch
  expected $_want
  got      $_got"

    _extract="$_tmp/x"
    mkdir -p "$_extract"
    case "$_url" in
        *.tar.xz) tar -xJf "$_archive" -C "$_extract" ;;
        *)        unzip -oq "$_archive" -d "$_extract" ;;
    esac

    _member="$(tool_member "$_tool" "$_plat")"
    _found="$(find "$_extract" -type f -name "$_member" -perm -u+x 2>/dev/null | head -1)"
    [ -n "$_found" ] || _found="$(find "$_extract" -type f -name "$_member" 2>/dev/null | head -1)"
    [ -n "$_found" ] || die "$_tool $_ver: '$_member' not found in archive"

    # Keep the binary's siblings: periphery loads libIndexStore.dylib via @rpath from its own dir.
    _staging="$_dest.staging.$$"
    # Staging lives outside $_tmp, so a die between here and publish leaked it; rm -rf tolerates publish having moved it.
    # shellcheck disable=SC2064
    trap "rm -rf $(sq "$_tmp") $(sq "$_staging")" EXIT HUP INT TERM
    rm -rf "$_staging"
    mkdir -p "$_staging"
    cp -R "$(dirname "$_found")"/. "$_staging"/
    [ "$_member" = "$_tool" ] || mv "$_staging/$_member" "$_staging/$_tool"
    chmod +x "$_staging/$_tool"

    # Asserted once, here, on bytes that have already matched the pin. No later run re-checks it.
    _reported="$(reported_version "$_staging/$_tool" "$_tool" || echo '')"
    [ "$_reported" = "$_ver" ] || die "$_tool: archive contains ${_reported:-nothing}, pinned $_ver"

    # The cp -R above already copied any dotfile the archive shipped, so a receipt written here
    # deterministically overwrites whatever landed at that name rather than merging with it. No
    # tmp+mv needed here: staging rides one atomic rename into place, so this is never seen half-written.
    _bsha="$(hashed_or_empty "$_staging/$_tool")"
    if [ -n "$_bsha" ]; then
        printf 'receipt 1\nbinary-sha256 %s\nversion %s\n' "$_bsha" "$_ver" > "$(receipt_file "$_staging")"
    else
        # A hash that failed or came back empty must never be written: publishing receiptless is a
        # fully supported state -- the same one every legacy entry is in -- and self-heals next ensure.
        warn "$_tool $_ver: could not hash the installed binary to record a receipt (publishing without one)"
    fi

    mkdir -p "$(dirname "$_dest")"
    # errexit is suspended for this function's whole body under cmd_ensure's "install_tool ... || _bad=1".
    with_lock "$_dest.lock" publish_dir "$_staging" "$_dest" "$_tool" || {
        rm -rf "$_tmp"
        trap - EXIT HUP INT TERM
        chmod -R u+w "$_staging" 2>/dev/null || true
        rm -rf "$_staging"
        # Named only if it survives the attempt above: a plain lock failure never touched staging at all.
        if [ -e "$_staging" ]; then
            warn "$_tool $_ver: could not finish publishing (remove $_staging and retry)"
        else
            warn "$_tool $_ver: could not finish publishing (retry)"
        fi
        return 1
    }

    rm -rf "$_tmp"
    trap - EXIT HUP INT TERM
    # Should be unreachable: a with_lock failure above already warns and returns before this executes.
    [ -x "$_bin" ] || die "$_tool $_ver: install incomplete (remove $_dest and retry)"
    log "$_tool $_ver: installed"
}

reported_version() {
    # A pipeline reports its last command's exit status (tr's), not the tool's; split it out to catch that.
    _rv="$("$1" $(tool_version_args "$2") 2>/dev/null)" || return 1
    printf '%s\n' "$_rv" | head -1 | sed 's|^[Vv]ersion:[[:space:]]*||' | tr -d '[:space:]'
}

# Existence at the hash-named path. Re-hashing on every read protects nothing: anything that can
# rewrite the binary can rewrite whatever we compared it against.
# A stale or mismatched entry is instead caught by ensure's deeper, receipt-based pass, not here.
verify_tool() {
    _tool="$1"
    # Checked before use, not nested as an argument: embedding it in tool_url's own argument list
    # would let tool_url's unrelated catch-all die (and print) before this ever sees the failure.
    if ! _plat="$(platform)"; then
        warn "$_tool $2: could not resolve for this platform"
        return 1
    fi
    _sha="$(pin_sha "$_tool" "$_plat" 2>/dev/null || echo '-')"
    _url="$(tool_url "$_tool" "$2" "$_plat")"
    [ -n "$_url" ] || return 0
    [ -x "$(tool_bin "$_tool" "$_sha")" ] && return 0
    # Warned, not died: cmd_check's own loop is where every missing tool gets named, not just the first.
    warn "$_tool $2: not installed (run: grubstake ensure)"
    return 1
}

# ---------------------------------------------------------------------------- hooks
# hooks/ is the reviewable source; install and doctor read these copies so neither needs the network.
# Quoted heredocs because an expanded `$` here would corrupt the hook the test compares byte for byte.

embedded_hook() {
    case "$1" in
        pre-commit|post-commit|commit-msg) : ;;
        *)                                 die "unknown hook: $1" ;;
    esac
    case "$1" in
        pre-commit)
            cat <<'GST_EMBED_PRE_COMMIT' | sed -e '1d' -e '$d'
# gst-embedded-hook-begin: pre-commit
#!/bin/sh
# grubstake pre-commit spine. Verifies pinned tools, lints staged Swift, then runs repo-local
# gates. Repo-specific checks belong in .githooks/pre-commit.d/, not in this file, which is
# overwritten whenever the hooks are reinstalled.

set -eu

ROOT="$(git rev-parse --show-toplevel)"
GRUBSTAKE="$ROOT/grubstake.sh"

[ -x "$GRUBSTAKE" ] || {
    echo "[pre-commit] grubstake.sh missing or not executable at repo root" >&2
    exit 1
}

# Only verify tools when something this spine gates is staged. A cold cache should not refuse a
# docs-only commit, and a repo with no pins has nothing to verify.
STAGED_SWIFT=$(git diff --cached --name-only --diff-filter=ACMR -- '*.swift')
[ -n "$STAGED_SWIFT" ] && "$GRUBSTAKE" check >/dev/null

# Only lint if the repo pinned swiftlint. A repo that does not use it should not be blocked by
# the shared spine; its own gates in pre-commit.d decide. One line per tool, so grep is enough.
if [ -n "$STAGED_SWIFT" ] && grep -qE '^swiftlint[[:space:]]' "$ROOT/grubstake.tools" 2>/dev/null; then
    SWIFTLINT="$("$GRUBSTAKE" path swiftlint)" || exit 1
    # Verify and refuse rather than format-and-restage: re-adding after a fix folds unrelated
    # hunks into a partial `git add -p` and re-stages a working-tree deletion of a file staged
    # as new. The developer fixes and re-stages; the hook never touches the index.
    #
    # Known limitation: SwiftLint reads the working tree, so this checks the current contents of
    # files whose paths are staged, not the staged blobs. Linting a temp copy would break config
    # resolution, and stashing the remainder to lint the index is what strands work in the tools
    # that do it. AD/MD is refused below and AM/MM is warned about, and CI lints the committed tree.
    STATUS=$(git status --porcelain -- '*.swift')
    # AD/MD: the worktree copy is gone, so the linter would read nothing at all. Decide this
    # ourselves rather than trust the linter's exit status, which a batched run can mask.
    GONE=$(printf '%s\n' "$STATUS" | sed -n 's/^[ACMR]D //p')
    # "--" ends option parsing, so a staged path starting with "-" is a path, never a linter flag.
    OUT=$(git diff --cached --name-only -z --diff-filter=ACMR -- '*.swift' \
        | xargs -0 "$SWIFTLINT" lint --strict --quiet -- 2>&1) && RC=0 || RC=$?
    if [ -n "$GONE" ]; then
        # Print first: a real violation in a co-staged file the linter did read must not be
        # swallowed by this refusal, or the developer only learns about it on a second retry.
        [ -n "$OUT" ] && echo "$OUT" >&2
        echo "[pre-commit] staged Swift file(s) missing from the working tree, so nothing was linted:" >&2
        printf '%s\n' "$GONE" | sed 's/^/[pre-commit]   /' >&2
        exit 1
    fi
    if [ "$RC" -ne 0 ]; then
        echo "$OUT" >&2
        echo "[pre-commit] swiftlint failed on working-tree contents of staged Swift paths." >&2
        echo "[pre-commit] fix, re-stage, retry." >&2
        exit 1
    fi
    [ -n "$OUT" ] && echo "$OUT"

    # AM/MM/CM/RM: the linter read different content than what is staged. Advisory only, since this
    # is legitimate under `git add -p`; AD/MD above already refuses when there is nothing to read.
    if printf '%s\n' "$STATUS" | grep -q '^[ACMR]M '; then
        echo "[pre-commit] warning: staged Swift files have unstaged edits. Lint read the working" >&2
        echo "[pre-commit] tree, not what is being committed. Re-stage if the fix belongs here." >&2
    fi
fi

for gate in "$ROOT"/.githooks/pre-commit.d/*; do
    [ -e "$gate" ] || continue
    # A gate that lost its exec bit must not look like one that passed.
    [ -x "$gate" ] || { echo "[pre-commit] gate not executable: $gate" >&2; exit 1; }
    "$gate" || { echo "[pre-commit] gate failed: $(basename "$gate")" >&2; exit 1; }
done

exit 0
# gst-embedded-hook-end: pre-commit
GST_EMBED_PRE_COMMIT
            ;;
        post-commit)
            cat <<'GST_EMBED_POST_COMMIT' | sed -e '1d' -e '$d'
# gst-embedded-hook-begin: post-commit
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

# CURRENT comes from the installed script's own report; LATEST is read raw from a writable cache
# file. Neither has passed the fetch filter's grep, so an unvalidated one reaches the advisory line.
printf '%s\n%s\n' "$CURRENT" "$LATEST" | grep -qvE '^[0-9]+\.[0-9]+\.[0-9]+$' && exit 0

# Only speak when the cached latest is genuinely newer than what is installed.
newest=$(printf '%s\n%s\n' "$CURRENT" "$LATEST" | LC_ALL=C sort -t. -k1,1nr -k2,2nr -k3,3nr | head -1)
[ "$newest" = "$LATEST" ] || exit 0

echo "[grubstake] $LATEST available (pinned $CURRENT) -- run: ./grubstake.sh update"
exit 0
# gst-embedded-hook-end: post-commit
GST_EMBED_POST_COMMIT
            ;;
        commit-msg)
            cat <<'GST_EMBED_COMMIT_MSG' | sed -e '1d' -e '$d'
# gst-embedded-hook-begin: commit-msg
#!/bin/sh
# grubstake commit-msg spine. Refuses a message that names an agent session, then runs repo-local
# message gates. Repo-specific checks belong in .githooks/commit-msg.d/, not in this file, which
# is overwritten whenever the hooks are reinstalled.
#
# The pre-commit scan reads tracked files, so a reference typed into a message never passes under
# it. A session trailer or link names a transcript outside the repository, which no reader of the
# published history can open.

set -eu

ROOT="$(git rev-parse --show-toplevel)"

# A gate handed nothing has not passed, so an unreadable message is refused rather than skipped.
[ "$#" -eq 1 ] || { echo "[commit-msg] git passed no message file, so nothing was scanned" >&2; exit 1; }
# git hands this hook a path relative to wherever it ran it, and a gate below may run anywhere.
case "$1" in /*) MSG="$1" ;; *) MSG="$PWD/$1" ;; esac

# Each literal is broken by a bracket, so a repo that scans its own tracked text for these shapes
# does not report the hook that refuses them.
RE_SESSION='Claude-[S]ession:|claude\.ai/code/[s]ession'

# git has stripped neither comments nor a --verbose diff yet, so read only what becomes the message.
BODY="$(sed -e '/^#.*>8/,$d' -e '/^#/d' "$MSG")" || {
    echo "[commit-msg] cannot read $MSG, so the message was not scanned" >&2
    exit 1
}
HITS="$(printf '%s\n' "$BODY" | grep -nE "$RE_SESSION")" || HITS=""
if [ -n "$HITS" ]; then
    echo "[commit-msg] an agent-session reference would be published with this commit:" >&2
    printf '%s\n' "$HITS" | sed 's/^/[commit-msg]   /' >&2
    echo "[commit-msg] remove it and retry." >&2
    exit 1
fi

for gate in "$ROOT"/.githooks/commit-msg.d/*; do
    [ -e "$gate" ] || continue
    # A gate that lost its exec bit must not look like one that passed.
    [ -x "$gate" ] || { echo "[commit-msg] gate not executable: $gate" >&2; exit 1; }
    "$gate" "$MSG" || { echo "[commit-msg] gate failed: $(basename "$gate")" >&2; exit 1; }
done

exit 0
# gst-embedded-hook-end: commit-msg
GST_EMBED_COMMIT_MSG
            ;;
        # A pattern reaching here means the two case lists in this function have drifted: without
        # this arm the case falls through, the pipeline still exits 0, and install writes an empty hook.
        *)  die "no embedded copy for hook: $1" ;;
    esac
}

# The one place this ownership-marker grep is spelled out: test/run.sh's own reword-drift test
# extracts it from here verbatim, so cmd_install and cmd_doctor share this rather than each
# spelling it out again, and the variable below is named to match what that test expects.
hook_has_marker() {
    _hook="$1"
    grep -q "^# grubstake $_hook" "$2" 2>/dev/null
}

# Every embedded copy ever released, sha256, plus the current one -- verified once, by hand,
# against each release tag (git show vX.Y.Z:hooks/<name> | shasum -a 256); CI is a depth-1
# checkout and cannot re-derive these. A future hook edit must append its own new hash here or
# the copy it replaces becomes unrefreshable in every repo still running it.
known_hook_hashes() {
    case "$1" in
        pre-commit)
            echo "330d703d3b852c20014a2e6752a8d5128ce424b8c2f5a8518f17c0cf0821d88e cdf7925196ab575befe386141e4213da38b70b312f5362891dffe62939854797 dd03e61a534e76544af5fa8d3a0c55ba184d36499d20e16955601f93814e2062 6089721b6ef137d302069f78708066bea4657e627c27a29189e84fbbbbc4293f ebe69cdf167af9a5d99dd29ce7309ee27f2db6dab43fcd683567a3e9e382f888 971b0e87abc438632ec6016f8dfae68d5005d82b896e29077083d22ca7011307"
            ;;
        post-commit)
            echo "2b69bf0dfa98548b803a713df67e9960fc5cde5b5a6371d77092570b91fee2d7 eb391f8155e0d39f7eb7ec5dda831b5bd742eb1216859a398dcc437102a09dec 90cbd6aec16527b36bd50ef6ef8d0684981242ca9e33a278348ae2a13b16e7fb"
            ;;
        commit-msg)
            # One entry: the release that adds this hook is the first to publish any copy of it.
            echo "9681b8f5667e63d051ef1e35e6a8e170e7f0dab82d1d92d305d6aa1fe56286c9"
            ;;
        *) die "unknown hook: $1" ;;
    esac
}

is_known_hook_hash() {
    # Assigned, not piped: known_hook_hashes' own die exits only the pipe's first stage, and grep on
    # the empty remainder it leaves behind returns 1 same as a genuine non-match, hiding the die.
    _khh="$(known_hook_hashes "$1")" || return 1
    printf '%s\n' "$_khh" | tr ' ' '\n' | grep -qxF "$2"
}

# ---------------------------------------------------------------------------- commands

add_one() {
    _tool="${1%@*}"
    _ver="${1#*@}"
    [ "$_tool" != "$1" ] || die "usage: grubstake add <tool>@<version>"
    is_known_tool "$_tool" || die "unknown tool: $_tool"

    _tmp="$(mktemp -d "${TMPDIR:-/tmp}/grubstake.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf $(sq "$_tmp")" EXIT HUP INT TERM

    # Hash every platform, so a macOS run still pins what Linux CI fetches.
    _shas=""
    for _plat in darwin linux; do
        _url="$(tool_url "$_tool" "$_ver" "$_plat")"
        if [ -z "$_url" ]; then
            _shas="$_shas -"
            continue
        fi
        log "$_tool $_ver: hashing $_plat artifact"
        curl -fsSL --retry 3 --retry-all-errors --max-time 300 "$_url" -o "$_tmp/a" || die "$_tool $_ver: cannot fetch $_plat artifact"
        _shas="$_shas $(sha256_file "$_tmp/a")"
    done

    _pins="$(pins_file)"
    _lock="$_pins.lock"
    _pt="$_pins.$$.tmp"
    # mkdir is the portable atomic lock. Two agents adding pins otherwise write from stale reads.
    _waited=0
    while :; do
        # The cause comes from mkdir's own words, not a second [ -d ] test taken afterwards: that
        # test answers "does the parent still exist," which a read-only parent (EACCES) passes same
        # as genuine contention, and an unreadable ancestor fails same as a parent actually removed.
        # LC_ALL=C: the discriminator below reads mkdir's own message, so it has to stay in the
        # language it was written against, the same convention #85 uses for git's own message.
        _mkerr="$(LC_ALL=C mkdir "$_lock" 2>&1 >/dev/null)" && break
        # Anchored to the end, not a bare substring: the lock path is interpolated into this very
        # message, and an unanchored match lets a path that happens to contain "File exists" (or the
        # ENOENT text) collide with mkdir's own trailing reason instead of reading it.
        case "$_mkerr" in
            *": File exists") : ;;
            *": No such file or directory")
                die "$_lock: its directory is gone, most likely the repository was removed mid-add"
                ;;
            *)
                die "cannot create lock: $_mkerr"
                ;;
        esac
        _waited=$((_waited + 1))
        [ "$_waited" -gt 50 ] && die "grubstake.tools is locked by another run ($_lock)"
        sleep 0.1 2>/dev/null || sleep 1
    done
    # shellcheck disable=SC2064
    trap "rm -rf $(sq "$_tmp") $(sq "$_pt") $(sq "$_lock")" EXIT HUP INT TERM
    # The fetch above can run for minutes with nothing holding the pins file, so its contents are
    # only known-good once the lock that guards the rewrite below is held.
    validate_pins
    [ -f "$_pins" ] || printf '# grubstake pins: name version sha256-darwin sha256-linux\n' > "$_pins"
    # grep -v exits 1 when it selects nothing, the ordinary shape of the first pin in an empty or
    # tool-only file; anything else is a real read failure and must abort before the rename below.
    # A pipeline's own exit status is its last stage's, not grep's, so neither stage can run inside
    # one and still have its own failure seen.
    if grep -v -E "^$_tool[[:space:]]" "$_pins" 2>/dev/null > "$_tmp/pins-sel"; then _selrc=0; else _selrc=$?; fi
    case "$_selrc" in
        0|1) : ;;
        *) die "$_pins: cannot read pins file (grep exit $_selrc), $_tool@$_ver was not recorded" ;;
    esac
    if grep -v '^$' "$_tmp/pins-sel" > "$_pt"; then _filtrc=0; else _filtrc=$?; fi
    case "$_filtrc" in
        0|1) : ;;
        *) die "$_pins: cannot read pins file (grep exit $_filtrc), $_tool@$_ver was not recorded" ;;
    esac
    # Counted, not just read: a rewrite that drops pins without erroring is indistinguishable from
    # grep's own "selected nothing" by exit status alone, so only a pin count catches it. Same filter
    # pinned_tools uses, so the header comment and a blank line are never mistaken for a pin lost.
    if _before="$(grep -vcE '^[[:space:]]*(#|$)' "$_pins" 2>/dev/null)"; then _bnrc=0; else _bnrc=$?; fi
    case "$_bnrc" in
        0|1) : ;;
        *) die "$_pins: cannot read pins file (grep exit $_bnrc), $_tool@$_ver was not recorded" ;;
    esac
    # shellcheck disable=SC2086
    printf '%s %s%s\n' "$_tool" "$_ver" "$_shas" >> "$_pt"
    # sort's own failure here must not let a partial or unchanged $_pt reach the count check below
    # unnoticed, since that check is the one guard standing between a bad write and the rename.
    if LC_ALL=C sort -o "$_pt" "$_pt"; then _srtrc=0; else _srtrc=$?; fi
    [ "$_srtrc" -eq 0 ] || die "$_pins: cannot sort pins file (sort exit $_srtrc), $_tool@$_ver was not recorded"
    # The pin appended above guarantees this always matches; anything else is a real read failure on
    # the file just written, not zero pins, and must not reach the comparison below.
    if _after="$(grep -vcE '^[[:space:]]*(#|$)' "$_pt")"; then _anrc=0; else _anrc=$?; fi
    [ "$_anrc" -eq 0 ] || die "$_pins: cannot verify the rewritten pins file (grep exit $_anrc), $_tool@$_ver was not recorded"
    [ "$_before" -eq 0 ] || [ "$_after" -ge "$_before" ] \
        || die "$_pins: rewrite would drop pins ($_before -> $_after), $_tool@$_ver was not recorded"
    mv "$_pt" "$_pins"
    rmdir "$_lock" 2>/dev/null || true

    rm -rf "$_tmp"
    trap - EXIT HUP INT TERM
    log "pinned $_tool $_ver"
    install_tool "$_tool" "$_ver"
}

# Every argument is pinned. Reading only $1 meant a batched call pinned one tool and exited 0.
cmd_add() {
    [ $# -ge 1 ] || die "usage: grubstake add <tool>@<version>..."
    validate_pins
    for _spec in "$@"; do
        add_one "$_spec"
    done
}

cmd_ensure() {
    validate_pins
    _any=0
    _bad=0
    for _tool in $(pinned_tools); do
        _any=1
        install_tool "$_tool" "$(pin_version "$_tool")" || _bad=1
    done
    [ "$_any" = 1 ] || warn "no tools pinned yet (run: grubstake add swiftlint@x.y.z)"
    # Bare would let verify_pinned's own now-possible non-zero return trip set -e before the line below runs.
    verify_pinned || _bad=1
    # verify_pinned's status alone still cannot stand in for this: a receipt mismatch above already left
    # a binary that passes verify's existence-only pass, so folding it in here is additive, not a substitute.
    [ "$_bad" = 0 ] || return 1
    log "ok ($GRUBSTAKE_VERSION)"
}

# No validate_pins and no ok line: shared by cmd_check and cmd_ensure, which each gate the ok line on their own failures too.
verify_pinned() {
    _cbad=0
    for _tool in $(pinned_tools); do
        verify_tool "$_tool" "$(pin_version "$_tool")" || _cbad=1
    done
    [ "$_cbad" = 0 ] || return 1
}

cmd_check() {
    validate_pins
    verify_pinned || return 1
    log "ok ($GRUBSTAKE_VERSION)"
}

cmd_path() {
    [ $# -ge 1 ] || die "usage: grubstake path <tool>"
    validate_pins
    is_known_tool "$1" || die "unknown tool: $1"
    _ver="$(pin_version "$1")" || die "$1 is not pinned"
    # Assigned on its own, not nested as an argument: a die inside $( ) only kills that subshell, so
    # embedding it in tool_url's own argument would let tool_url's unrelated death mask this one.
    _plat="$(platform)"
    _url="$(tool_url "$1" "$_ver" "$_plat")"
    [ -n "$_url" ] || die "$1 is not published for $_plat"
    _bin="$(tool_bin "$1" "$(pin_sha "$1" "$_plat")")"
    # Existence only, deliberately: the commit path stays hash-free and offline, and a receipt
    # mismatch surfacing here would put a network-shaped check back in front of every commit. Catching
    # drift is ensure's job.
    [ -x "$_bin" ] || install_tool "$1" "$_ver" >&2
    verify_tool "$1" "$_ver"
    echo "$_bin"
}

cmd_doctor() {
    validate_pins
    _root="$(repo_root)"
    printf 'grubstake  %s\n' "$GRUBSTAKE_VERSION"
    printf 'repo       %s\n' "$_root"
    # Captured and checked, not embedded: a die inside $( ) only kills that subshell, so an
    # unsupported arch here would otherwise print as a blank field rather than doctor's own report of it.
    if _plat="$(platform 2>&1)"; then
        _plat_ok=1
    else
        _plat_ok=0
        _plat="${_plat#\[grubstake\] }"
    fi
    printf 'platform   %s\n' "$_plat"
    # Same shape as the platform field above: cache_root can fail on its own (GRUBSTAKE_CACHE unset,
    # platform unsupported) even when $_plat_ok already covered the platform line's own failure.
    # 2>/dev/null: cache_root's own nested platform() call still writes its die to stderr directly,
    # unredirected by cache_root's own capture, so it must be silenced here or it leaks past this report.
    if _cache="$(cache_root 2>/dev/null)"; then
        printf 'cache      %s\n' "$_cache"
        # Skipped when the cache dir does not exist yet: nothing has run against this root, so there is
        # nothing to report -- install_tool's own backfill is what first writes the sentinel (#95).
        # -L checked before -d: test -d follows a symlink to whatever real directory sits at the far
        # end, which would call a symlinked root healthy when cmd_clean refuses that exact root outright.
        if [ -L "$_cache" ]; then
            printf 'sentinel   %s is a symlink; clean refuses this root outright, so its sentinel is never checked\n' "$_cache"
        elif [ -e "$_cache" ] && [ ! -d "$_cache" ]; then
            printf 'sentinel   %s is not a directory; clean refuses this root until it is removed or chowned by hand\n' "$_cache"
        elif [ -d "$_cache" ]; then
            _dsent="$(cache_sentinel_file "$_cache")"
            if sentinel_verified "$_dsent"; then
                printf 'sentinel   ok\n'
            elif [ -e "$_dsent" ] && [ ! -f "$_dsent" ]; then
                printf 'sentinel   %s is not a regular file; clean refuses this root until it is removed or chowned by hand\n' "$_dsent"
            elif [ -f "$_dsent" ]; then
                printf 'sentinel   %s is not grubstake'"'"'s; clean refuses this root\n' "$_dsent"
            else
                printf 'sentinel   nothing recorded yet, will be written on the next ensure\n'
            fi
        fi
    else
        printf 'cache      unresolved (platform unsupported)\n'
    fi
    _hookspath="$(git -C "$_root" config core.hooksPath || true)"
    printf 'hooksPath  %s\n' "${_hookspath:-(unset)}"
    printf 'pins       %s\n' "$(pins_file)"
    if [ -n "$_hookspath" ] && [ "$_hookspath" != ".githooks" ]; then
        # A foreign hooksPath means the repo owns its hooks, the same reason install refuses one.
        printf '  hooks        not graded, hooksPath is not .githooks\n'
    else
        for _hook in pre-commit post-commit commit-msg; do
            _installed="$_root/.githooks/$_hook"
            if [ ! -f "$_installed" ]; then
                printf '  %-12s not installed\n' "$_hook"
            else
                hook_has_marker "$_hook" "$_installed" && _marker_rc=0 || _marker_rc=$?
                if [ "$_marker_rc" -eq 1 ]; then
                    printf '  %-12s not grubstake'"'"'s (repo-managed; leaving it alone)\n' "$_hook"
                elif [ "$_marker_rc" -ge 2 ]; then
                    printf '  %-12s cannot be read\n' "$_hook"
                elif embedded_hook "$_hook" | cmp -s - "$_installed"; then
                    printf '  %-12s ok\n' "$_hook"
                elif is_known_hook_hash "$_hook" "$(sha256_file "$_installed")"; then
                    # A known previous copy is refreshed, not deleted: install's own refresh handles this now.
                    printf '  %-12s DRIFTED from the embedded copy (run: grubstake install to refresh)\n' "$_hook"
                else
                    printf '  %-12s DRIFTED from the embedded copy (rm it and run: grubstake install)\n' "$_hook"
                fi
            fi
        done
    fi
    for _tool in $(pinned_tools); do
        _ver="$(pin_version "$_tool")"
        if [ "$_plat_ok" = 0 ]; then
            printf '  %-12s %-10s unsupported platform\n' "$_tool" "$_ver"
            continue
        fi
        # Guarded like verify_tool's own: $_plat_ok only proves the exit status was clean, not the
        # value -- a zero-exit uname that also wrote to stderr got merged into $_plat above, and
        # tool_url's own catch-all die on a bad value would otherwise abort this whole report.
        # 2>/dev/null: that catch-all still prints even when its exit status is caught below, and
        # this report must stay stderr-clean the same way the cache line above does.
        if ! _url="$(tool_url "$_tool" "$_ver" "$_plat" 2>/dev/null)"; then
            printf '  %-12s %-10s could not resolve\n' "$_tool" "$_ver"
            continue
        fi
        if [ -z "$_url" ]; then
            printf '  %-12s %-10s n/a on %s\n' "$_tool" "$_ver" "$_plat"
        elif [ -x "$(tool_bin "$_tool" "$(pin_sha "$_tool" "$_plat")")" ]; then
            printf '  %-12s %-10s installed\n' "$_tool" "$_ver"
        else
            printf '  %-12s %-10s MISSING\n' "$_tool" "$_ver"
        fi
    done
}

# Restores $_trash/detached to $_root, but only calls it success if the rename actually replaced
# $_root rather than nesting into a directory something else recreated there between the "is it free"
# check and the mv landing -- mv reports 0 either way, nesting included, so believing that exit status
# alone is exactly the bug this closes. No lock, no retry: a failed restore only has to be loud and the
# content findable, not that every interleaving succeeds.
# Returns 0: restored cleanly, content now genuinely at $_root. 1: $_root was occupied or the mv
# itself failed; content is unmoved at $_trash/detached. 2: the mv landed nested at $_root/detached
# instead of replacing $_root, because $_root was recreated in the gap between the check and the rename.
restore_detached() {
    [ ! -e "$_root" ] || return 1
    mv "$_trash/detached" "$_root" 2>/dev/null || return 1
    [ ! -e "$_root/detached" ] || return 2
    return 0
}

# Shared by both the EXIT trap and the HUP/INT/TERM trap -- one handler, not two with different rules
# to drift out of sync. errexit turns any failing command into an exit exactly like a signal does; an
# EXIT trap with its own separate, unconditional "always delete" body would still delete an unverified
# $_trash/detached if some future edit added a fallible command between the detach and the verdict,
# even though nothing here signaled at all. $_verified gates which of two things any exit through this
# trap lands as. Unset or 0 means sentinel_verified has not yet had a chance to run, so whatever is
# sitting in $_trash was never checked and must be restored, not destroyed -- the exact property #95
# exists to guarantee. 1 means the verdict was already in (verified) before the exit happened, so the
# trash is known to be grubstake's own and removal proceeds exactly as it did before this flag existed.
clean_trash_teardown() {
    if [ "${_verified:-0}" = 1 ]; then
        # Killed outright, not left to finish on its own: without this, the backgrounded chmod this
        # signal interrupted is still walking $_trash while the rm -rf below deletes it out from under it.
        [ -n "${_chpid:-}" ] && kill -TERM "$_chpid" 2>/dev/null
        rm -rf "$_trash" 2>/dev/null
        [ -e "$_trash" ] || return 0
        chmod -R u+w "$_trash" 2>/dev/null || true
        rm -rf "$_trash"
    else
        # Same restore_detached used by the synchronous path in cmd_clean, and the same three
        # outcomes: this is exactly the drift the last hole came from, two restore sites disagreeing
        # on when a put-back actually counts as one.
        if restore_detached; then _rrc=0; else _rrc=$?; fi
        # $_trash is provably empty here for rc 0 and rc 2 alike -- both moved "detached" out of it,
        # to $_root or to $_root/detached respectively -- and only rc 1 (the mv itself failed) leaves
        # anything behind for the container to still be holding.
        [ "$_rrc" -eq 1 ] || { rmdir "$_trash" 2>/dev/null || rm -rf "$_trash" 2>/dev/null; }
        if [ "$_rrc" -eq 2 ]; then
            # Nested, not restored: mv reported success but landed the content at $_root/detached
            # instead of replacing $_root, because something recreated $_root in the gap. A signal
            # handler can still write to stderr -- unlike the outright-failure case below, this one is
            # silent by construction unless said here, so it is said here.
            warn "clean's restore of an unverified $_root nested at $_root/detached instead of replacing it -- recover it by hand"
        fi
        # $_rrc 1 falls through silently: $_root was occupied by something else, or the mv itself
        # failed. $_trash/detached is untouched -- an rm -rf here would destroy the one thing this
        # branch exists to save, and it is already exactly where the synchronous path's own equivalent
        # message points a human to look.
    fi
}

# No validate_pins: a malformed grubstake.tools must not block the one command that recovers from
# a wedged cache. cache_root can now fail outright (unsupported platform, no GRUBSTAKE_CACHE override);
# a degenerate or relative path is the only case left for the checks below to refuse.
cmd_clean() {
    _root="$(cache_root)" || die "cannot determine the cache root: platform unsupported"
    case "$_root" in
        /|//|/.|/..) die "refusing to remove cache root: '$_root'" ;;
        /*)          : ;;
        *)           die "refusing to remove cache root, not an absolute path: '$_root'" ;;
    esac
    # rm -rf on a symlink unlinks the link and leaves its target untouched while still reporting success.
    [ -L "$_root" ] && die "refusing to remove cache root, it is a symlink: '$_root' -> '$(readlink "$_root")'"
    [ -e "$_root" ] || return 0
    log "removing $_root"
    # No lock: cmd_clean holds none, and a held publish lock or an in-flight staging dir both live
    # under root. Renaming it aside is atomic, so a concurrent ensure either finds it gone and starts
    # a fresh tree with mkdir -p, or is already past the rename and lands its publish in the trash,
    # harmless either way since the cache is a rebuildable download cache, never a source of truth.
    # mktemp names the trash atomically and unpredictably rather than the old $$-derived name, and the
    # trap arms before the rename so a signal between the mv and the final rm -rf cannot strand a full
    # copy of the cache beside the root. mv nests a directory into an existing one rather than
    # replacing it (no mv -T on macOS), so the detached tree lands at a fixed child name inside the
    # mktemp'd directory, not at the mktemp'd path itself.
    _trash="$(mktemp -d "$_root.trash.XXXXXX")" || die "cannot create a trash directory beside $_root"
    # Set before either trap is armed, not after: clean_trash_teardown reads this to decide restore
    # versus delete, and any exit through either trap before sentinel_verified ever runs must find it
    # already 0, never unset -- set -u would otherwise turn that read itself into a crash inside the trap.
    _verified=0
    # Disarmed first, inside its own body: without that, this trap's own "exit 1" would refire the
    # EXIT trap below and run the teardown a second time -- harmless here since it tolerates an
    # already-gone path, but the disarm is what makes that redundancy a non-issue rather than a race.
    trap 'trap - EXIT HUP INT TERM; clean_trash_teardown; exit 1' HUP INT TERM
    # No "exit" of its own: this fires as part of an exit already in progress (errexit, a caught
    # signal that disarmed and re-exited above, or a plain die), and calling exit again here would
    # overwrite whatever status was already on its way out with this trap's own last command instead.
    trap 'clean_trash_teardown' EXIT
    mv "$_root" "$_trash/detached" || die "cannot detach cache root for removal: $_root"
    # #95, outside review: verified here, on the detached copy, never before the rename. Checking the
    # sentinel and renaming the root were two separate steps around an unguarded path, so a concurrent
    # process could swap the checked root for an unrelated directory in between -- mv follows the
    # path, not an identity already verified. This way the bytes verified are exactly the bytes about
    # to be deleted, with nothing observable in between.
    _dsentinel="$(cache_sentinel_file "$_trash/detached")"
    if ! sentinel_verified "$_dsentinel"; then
        # Restored, not deleted: whatever actually landed at $_trash/detached did not verify, so it is
        # someone else's directory, not grubstake's cache, and goes back rather than getting destroyed
        # on a guess. restore_detached's own three outcomes, not a bare mv check: mv reports success
        # even when $_root was recreated in the gap and the rename nested instead of replacing it, so
        # believing that exit status alone would report a restore that never actually happened.
        if restore_detached; then _rrc=0; else _rrc=$?; fi
        # $_trash is provably empty here for rc 0 and rc 2 alike -- both moved "detached" out of it,
        # to $_root or to $_root/detached respectively -- and only rc 1 (the mv itself failed) leaves
        # anything behind for the container to still be holding.
        [ "$_rrc" -eq 1 ] || { rmdir "$_trash" 2>/dev/null || rm -rf "$_trash" 2>/dev/null; }
        if [ "$_rrc" -eq 0 ]; then
            die "refusing to remove cache root, it changed underneath clean before the sentinel could be verified: '$_root'"
        fi
        # The restore did not cleanly land: either $_root was occupied and the mv itself failed
        # (content still at $_trash/detached), or $_root was recreated in the gap and the rename
        # nested instead of replacing it (content now at $_root/detached, misplaced but not lost).
        # Either way the EXIT trap below must not be allowed to delete what this branch could not
        # confirm -- that would destroy exactly what it exists to save -- so it is disarmed before
        # naming where the content actually is.
        trap - EXIT HUP INT TERM
        if [ "$_rrc" -eq 2 ]; then
            die "refusing to remove cache root, it changed underneath clean, and the restore landed nested inside a directory something else created at '$_root' in the meantime -- recover it by hand from $_root/detached"
        fi
        die "refusing to remove cache root, it changed underneath clean, and could not be restored to '$_root' -- recover it by hand from $_trash"
    fi
    # Flipped only once the sentinel has actually verified: an exit through either trap after this
    # point deletes, same as before this flag existed; an exit before it (still 0) restores instead.
    _verified=1
    # Published entries are read-only; unlinking needs write permission on their containing dirs first.
    # Backgrounded and waited on explicitly rather than run as a plain foreground command: both dash
    # and bash defer a trapped signal until a foreground external command finishes on its own, but the
    # "wait" builtin is specifically interruptible and returns the moment the trap runs instead -- the
    # difference is tens of seconds versus tens of milliseconds, confirmed in scratch first.
    chmod -R u+w "$_trash" 2>/dev/null &
    _chpid=$!
    wait "$_chpid" 2>/dev/null || true
    # Cleared once reaped: the signal handler kills whatever this names, and a reaped pid can be
    # reused by an unrelated process before the trap is disarmed a few lines below.
    _chpid=""
    rm -rf "$_trash"
    trap - EXIT HUP INT TERM
}

# An older release fetched this script and handed off with: __replace-self <installed> <version>.
# It is already running from the temp copy, so finish the job the way that release expected.
cmd_legacy_replace() {
    _installed="$1"
    _version="${2:-$GRUBSTAKE_VERSION}"
    _staged="$(mktemp "$(dirname "$_installed")/.grubstake.XXXXXX")" || die "cannot stage beside $_installed"
    cp "$0" "$_staged"
    chmod +x "$_staged"
    mv -f "$_staged" "$_installed"
    log "updated to $_version"
    log "review the diff, then run: ./grubstake.sh install"
}

cmd_install() {
    _root="$(repo_root)"
    # Check before writing anything: refusing after creating files is a half-adopted repo.
    _existing="$(git -C "$_root" config core.hooksPath || true)"
    if [ -n "$_existing" ] && [ "$_existing" != ".githooks" ]; then
        die "core.hooksPath is already '$_existing'; move those hooks into .githooks first"
    fi
    mkdir -p "$_root/.githooks"

    for _hook in pre-commit post-commit commit-msg; do
        _dest="$_root/.githooks/$_hook"
        if [ ! -f "$_dest" ]; then
            # mktemp beside $_dest, not in $TMPDIR: mv across filesystems can silently stop being atomic.
            _hooktmp="$(mktemp "$_root/.githooks/.$_hook.XXXXXX")" || die "cannot create a temp file to install $_hook"
            # shellcheck disable=SC2064
            trap "rm -f $(sq "$_hooktmp")" EXIT HUP INT TERM
            embedded_hook "$_hook" > "$_hooktmp"
            chmod +x "$_hooktmp"
            mv "$_hooktmp" "$_dest"
            trap - EXIT HUP INT TERM
            log "$_hook: installed"
            continue
        fi
        # Checked before anything reads the file's content: an unread-able hook must be named as
        # such, not silently folded into "leaving it alone" the way a marker mismatch is.
        hook_has_marker "$_hook" "$_dest" && _marker_rc=0 || _marker_rc=$?
        if [ "$_marker_rc" -eq 1 ]; then
            # No marker: never grubstake's to begin with (the #59 semantics), hands off, silent.
            log "$_hook: already present, leaving it alone"
            continue
        elif [ "$_marker_rc" -ge 2 ]; then
            warn "$_hook: cannot be read, leaving it alone"
            continue
        fi
        if embedded_hook "$_hook" | cmp -s - "$_dest"; then
            log "$_hook: already present, leaving it alone"
            continue
        fi
        # hashed_or_empty, not sha256_file directly: a hook that vanishes or turns unreadable between
        # the marker check above and here must read as "no known hash", never a raw tool error.
        _installed_sha="$(hashed_or_empty "$_dest")"
        if [ -n "$_installed_sha" ] && is_known_hook_hash "$_hook" "$_installed_sha"; then
            # The recorded constraint licenses re-upgrading any hook byte-identical to a known
            # previous copy, even a deliberate revert; removing the marker line is how to opt out.
            _hooktmp="$(mktemp "$_root/.githooks/.$_hook.XXXXXX")" || die "cannot create a temp file to refresh $_hook"
            # shellcheck disable=SC2064
            trap "rm -f $(sq "$_hooktmp")" EXIT HUP INT TERM
            embedded_hook "$_hook" > "$_hooktmp"
            chmod +x "$_hooktmp"
            mv "$_hooktmp" "$_dest"
            trap - EXIT HUP INT TERM
            log "$_hook: refreshed to the current embedded copy"
        else
            warn "$_hook: differs from every known copy, left alone (repo-local edits are never overwritten)"
        fi
    done

    # git's own config lock is not this script's to hold: a concurrent install racing the same
    # .git/config.lock fails immediately with git's own raw message, not a retryable one, so the
    # retry has to live here rather than trusting git to wait it out.
    # Retried only on git's own "File exists" text -- the literal signature of its own lock file
    # already being held -- so any other failure (a read-only .git, say) fails on the first attempt
    # with git's real words instead of spinning the budget and blaming a lock nobody held; an
    # unrecognized message falls to that same immediate-failure default rather than risking a silent false retry.
    _gcw=0
    while :; do
        # LC_ALL=C, the same convention this file already uses at every sort site: the discriminator
        # below reads git's own message, so that message has to stay in the language it was read in.
        _gcerr="$(LC_ALL=C git -C "$_root" config core.hooksPath .githooks 2>&1 >/dev/null)" && break
        # Anchored to the end, not a bare substring: git's message can itself embed a path (an
        # ambient GIT_DIR overrides the plain ".git/config" this normally reads), so an unanchored
        # match would let a path containing "File exists" collide with git's own trailing reason.
        case "$_gcerr" in
            *": File exists") : ;;
            *) die "cannot set core.hooksPath: $_gcerr" ;;
        esac
        _gcw=$((_gcw + 1))
        [ "$_gcw" -gt 50 ] && die "cannot set core.hooksPath: git kept losing the lock on $_root/.git/config: $_gcerr"
        sleep 0.1 2>/dev/null || sleep 1
    done
    log "hooksPath: .githooks"

    [ -f "$(pins_file)" ] || {
        printf '# grubstake pins: name version sha256-darwin sha256-linux\n' > "$(pins_file)"
        log "grubstake.tools: created (pin tools with: grubstake add swiftlint@x.y.z)"
    }

    cmd_ensure
    log "installed. Review and commit: grubstake.sh grubstake.tools .githooks/"
}

# Every release below the floor has a known blocking defect, so it is not offered or installable.
below_floor() {
    [ "$(printf '%s\n%s\n' "$1" "$GRUBSTAKE_MIN_VERSION" \
        | LC_ALL=C sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$1" ] \
        && [ "$1" != "$GRUBSTAKE_MIN_VERSION" ]
}

# Release tags, newest first. No mutable "latest" pointer.
# Reverse must be per-key (nr); a trailing -r is ignored when key flags are present.
release_tags() {
    git ls-remote --tags --refs "$GRUBSTAKE_REPO" 'v*' 2>/dev/null \
        | awk '{print $2}' | sed 's|refs/tags/v||' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
        | LC_ALL=C sort -t. -k1,1nr -k2,2nr -k3,3nr
}

# Fetch one candidate into $2 and confirm it is a usable script declaring $1. Returns 1, never dies,
# so an unusable tag can be skipped rather than blocking every update.
fetch_release() {
    curl -fsSL --retry 3 --retry-all-errors --max-time 300 "$GRUBSTAKE_RAW/v$1/grubstake.sh" -o "$2" 2>/dev/null || return 1
    sh -n "$2" 2>/dev/null || return 1
    # A tag is a mutable ref, so assert the bytes identify as what the tag claims.
    grep -q "^GRUBSTAKE_VERSION=\"$1\"" "$2" || return 1
}

cmd_update() {
    _pinned="${1:-}"
    _tmp="$(mktemp "${TMPDIR:-/tmp}/grubstake.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f $(sq "$_tmp")" EXIT HUP INT TERM

    # Silent on the common path; an overridden source is the one case a reader cannot infer from
    # the rest of the output, since fetch_release never repeats the host it pulled from.
    if [ "$GRUBSTAKE_REPO" != "$GRUBSTAKE_REPO_DEFAULT" ] || [ "$GRUBSTAKE_RAW" != "$GRUBSTAKE_RAW_DEFAULT" ]; then
        log "release source overridden: repo=$GRUBSTAKE_REPO raw=$GRUBSTAKE_RAW"
    fi

    if [ -n "$_pinned" ]; then
        _pinned="${_pinned#v}"
        echo "$_pinned" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || die "not a release version: $_pinned"
        below_floor "$_pinned" && die "$_pinned is below the supported floor $GRUBSTAKE_MIN_VERSION"
        [ "$_pinned" = "$GRUBSTAKE_VERSION" ] && { log "already on $GRUBSTAKE_VERSION"; return 0; }
        log "fetching $_pinned"
        fetch_release "$_pinned" "$_tmp" || die "v$_pinned is not a usable release"
        _target="$_pinned"
    else
        _candidates="$(release_tags)"
        [ -n "$_candidates" ] || die "cannot resolve a release tag from $GRUBSTAKE_REPO"
        _target=""
        for _c in $_candidates; do
            [ "$_c" = "$GRUBSTAKE_VERSION" ] && { log "already on $GRUBSTAKE_VERSION"; return 0; }
            log "fetching $_c"
            if fetch_release "$_c" "$_tmp"; then _target="$_c"; break; fi
            warn "v$_c is not a usable release, skipping"
        done
        [ -n "$_target" ] || die "no usable release found in $GRUBSTAKE_REPO"
    fi

    chmod +x "$_tmp"

    # Rename from within the running process, as rustup does. The interpreter keeps its open fd on
    # the old inode and finishes reading it undisturbed, so there is no need to hand off to a temp
    # copy. That handoff avoided a hazard rename never had, and cost a $0 that lied about its repo.
    _self="$(script_path)"
    _self="$(cd "$(dirname "$_self")" && pwd)/$(basename "$_self")"
    _staged="$(mktemp "$(dirname "$_self")/.grubstake.XXXXXX")" || die "cannot stage beside $_self"
    cp "$_tmp" "$_staged"
    chmod +x "$_staged"
    mv -f "$_staged" "$_self"
    rm -f "$_tmp"
    trap - EXIT HUP INT TERM

    log "updated to $_target"
    # install, not ensure: a hook a release adds or fixes reaches the repo through install alone, and install ensures on its way out.
    log "review the diff, then run: ./grubstake.sh install"
}

# ---------------------------------------------------------------------------- entry

main() {
    [ $# -ge 1 ] || { usage; exit 0; }
    _cmd="$1"
    shift

    case "$_cmd" in
        # Compatibility only: releases before 0.3.0 end their update by exec'ing the fetched
        # script with this verb. Removing it stranded every existing adopter, because it is a
        # protocol only OLD clients speak and so is the one thing that cannot be fixed forward.
        __replace-self) cmd_legacy_replace "$@" ;;
        install)        cmd_install "$@" ;;
        update)         cmd_update "$@" ;;
        ensure)         cmd_ensure "$@" ;;
        check)          cmd_check "$@" ;;
        add)            cmd_add "$@" ;;
        path)           cmd_path "$@" ;;
        doctor)         cmd_doctor "$@" ;;
        clean)          cmd_clean "$@" ;;
        version)        echo "$GRUBSTAKE_VERSION" ;;
        -h|--help|help) usage ;;
        *)              die "unknown command: $_cmd (try: grubstake help)" ;;
    esac
}

main "$@"
