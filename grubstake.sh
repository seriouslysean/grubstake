#!/bin/sh
# grubstake: pinned, verified build tooling for iOS repos.
#
# main() wraps everything and runs last. A shell reads scripts incrementally, so a truncated file
# would otherwise execute its valid prefix silently. Same reason nvm and rustup-init do it.

set -eu

GRUBSTAKE_VERSION="0.3.2"
GRUBSTAKE_MIN_VERSION="0.3.0"   # every earlier release has a known blocking defect
GRUBSTAKE_REPO="https://github.com/seriouslysean/grubstake"
GRUBSTAKE_RAW="https://raw.githubusercontent.com/seriouslysean/grubstake"

# ---------------------------------------------------------------------------- output

log()  { printf '[grubstake] %s\n' "$1"; }
warn() { printf '[grubstake] %s\n' "$1" >&2; }
die()  { printf '[grubstake] %s\n' "$1" >&2; exit 1; }

usage() {
    cat <<'USAGE'
grubstake: pinned, verified build tooling for iOS repos.

  grubstake install            adopt this repo: write config, wire hooks, install tools
  grubstake update [<tag>]     fetch a newer grubstake, replace this script, leave the diff
  grubstake ensure             install and verify every pinned tool
  grubstake check              confirm every pinned tool is installed for this platform
  grubstake add <tool>@<ver>   pin a tool: download, hash, record it
  grubstake path <tool>        absolute path to a pinned tool
  grubstake doctor             report install health
  grubstake version            print the version of this script

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
    elif [ "$(platform)" = darwin ]; then
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

pin_sha() {
    case "$2" in
        darwin) pin_field "$1" 3 ;;
        linux)  pin_field "$1" 4 ;;
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
        set -- $_l
        [ $# -eq 4 ] || die "grubstake.tools:$_n expected 4 fields, got $#"
        known_tools | grep -qw "$1" || die "grubstake.tools:$_n unknown tool: $1"
        echo "$2" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)?$' || die "grubstake.tools:$_n bad version: $2"
        for _h in "$3" "$4"; do
            [ "$_h" = "-" ] || echo "$_h" | grep -qE '^[0-9a-f]{64}$' \
                || die "grubstake.tools:$_n sha256 must be 64 hex chars or -, got: $_h"
        done
    done < "$_f"
    _dupes="$(pinned_tools | LC_ALL=C sort | uniq -d)"
    [ -z "$_dupes" ] || die "grubstake.tools pins a tool more than once: $_dupes"
}

# ---------------------------------------------------------------------------- install tools

# Keyed by the pinned archive hash, not the version. The path identifies the bytes, so editing a
# pin changes the path, which is a cache miss, which reinstalls. Nothing has to detect staleness.
tool_dir()  { echo "$(cache_root)/$1/$2"; }   # $2 is the pinned sha256
tool_bin()  { echo "$(tool_dir "$1" "$2")/$1"; }

# mkdir is the portable atomic lock. flock(1) is not present on macOS.
with_lock() {
    _lk="$1"; shift
    _w=0
    while ! mkdir "$_lk" 2>/dev/null; do
        _w=$((_w + 1))
        [ "$_w" -gt 50 ] && die "cache entry locked by another run: $_lk (stale? rmdir it)"
        sleep 0.1 2>/dev/null || sleep 1
    done
    # `cmd; rc=$?` does not survive set -e: the shell exits at cmd and never reaches the rmdir.
    if "$@"; then _rc=0; else _rc=$?; fi
    rmdir "$_lk" 2>/dev/null || true
    return $_rc
}

# A published entry is never unlinked: another repo may be executing from it. The loser of a race
# discards its own staging, and both copies are identical by construction.
# The lock exists because `mv dir existing-dir` nests rather than fails, and macOS mv has no -T.
# Read-only comes after publishing, never before: unlinking needs write permission on the
# containing directory, so hardening the staging first is what stops the loser cleaning up.
publish_dir() {
    if [ -e "$2" ]; then
        chmod -R u+w "$1" 2>/dev/null || true
        rm -rf "$1"
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
    _plat="$(platform)"
    _want="$(pin_sha "$_tool" "$_plat" 2>/dev/null || echo '-')"
    _url="$(tool_url "$_tool" "$_ver" "$_plat")"

    if [ -z "$_url" ]; then
        log "$_tool: not published for $_plat, skipping"
        return 0
    fi
    [ "$_want" != "-" ] && [ -n "$_want" ] || die "$_tool has no $_plat hash in grubstake.tools (run: grubstake add $_tool@$_ver)"

    _dest="$(tool_dir "$_tool" "$_want")"
    _bin="$(tool_bin "$_tool" "$_want")"
    # Existence at a hash-named path is validity. There is no other state to be in.
    [ -x "$_bin" ] && return 0

    _tmp="$(mktemp -d "${TMPDIR:-/tmp}/grubstake.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_tmp'" EXIT HUP INT TERM

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
    rm -rf "$_staging"
    mkdir -p "$_staging"
    cp -R "$(dirname "$_found")"/. "$_staging"/
    [ "$_member" = "$_tool" ] || mv "$_staging/$_member" "$_staging/$_tool"
    chmod +x "$_staging/$_tool"

    # Asserted once, here, on bytes that have already matched the pin. No later run re-checks it.
    _reported="$(reported_version "$_staging/$_tool" "$_tool")"
    [ "$_reported" = "$_ver" ] || die "$_tool: archive contains ${_reported:-nothing}, pinned $_ver"

    mkdir -p "$(dirname "$_dest")"
    with_lock "$_dest.lock" publish_dir "$_staging" "$_dest"

    rm -rf "$_tmp"
    trap - EXIT HUP INT TERM
    [ -x "$_bin" ] || die "$_tool $_ver: install incomplete"
    log "$_tool $_ver: installed"
}

reported_version() {
    "$1" $(tool_version_args "$2") 2>/dev/null | head -1 | sed 's|^[Vv]ersion:[[:space:]]*||' | tr -d '[:space:]'
}

# Existence at the hash-named path. Re-hashing on every read protects nothing: anything that can
# rewrite the binary can rewrite whatever we compared it against.
verify_tool() {
    _tool="$1"
    _sha="$(pin_sha "$_tool" "$(platform)" 2>/dev/null || echo '-')"
    _url="$(tool_url "$_tool" "$2" "$(platform)")"
    [ -n "$_url" ] || return 0
    [ -x "$(tool_bin "$_tool" "$_sha")" ] || die "$_tool $2: not installed (run: grubstake ensure)"
}

# ---------------------------------------------------------------------------- commands

add_one() {
    _tool="${1%@*}"
    _ver="${1#*@}"
    [ "$_tool" != "$1" ] || die "usage: grubstake add <tool>@<version>"
    known_tools | grep -qw "$_tool" || die "unknown tool: $_tool"

    _tmp="$(mktemp -d "${TMPDIR:-/tmp}/grubstake.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_tmp'" EXIT HUP INT TERM

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
    while ! mkdir "$_lock" 2>/dev/null; do
        _waited=$((_waited + 1))
        [ "$_waited" -gt 50 ] && die "grubstake.tools is locked by another run ($_lock)"
        sleep 0.1 2>/dev/null || sleep 1
    done
    # shellcheck disable=SC2064
    trap "rm -rf '$_tmp' '$_pt' '$_lock'" EXIT HUP INT TERM
    [ -f "$_pins" ] || printf '# grubstake pins: name version sha256-darwin sha256-linux\n' > "$_pins"
    grep -v -E "^$_tool[[:space:]]" "$_pins" 2>/dev/null | grep -v '^$' > "$_pt" || true
    # shellcheck disable=SC2086
    printf '%s %s%s\n' "$_tool" "$_ver" "$_shas" >> "$_pt"
    LC_ALL=C sort -o "$_pt" "$_pt"
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
    for _spec in "$@"; do
        add_one "$_spec"
    done
}

cmd_ensure() {
    validate_pins
    _any=0
    for _tool in $(pinned_tools); do
        _any=1
        install_tool "$_tool" "$(pin_version "$_tool")"
    done
    [ "$_any" = 1 ] || warn "no tools pinned yet (run: grubstake add swiftlint@x.y.z)"
    cmd_check
}

cmd_check() {
    validate_pins
    for _tool in $(pinned_tools); do
        verify_tool "$_tool" "$(pin_version "$_tool")"
    done
    log "ok ($GRUBSTAKE_VERSION)"
}

cmd_path() {
    [ $# -ge 1 ] || die "usage: grubstake path <tool>"
    validate_pins
    known_tools | grep -qw "$1" || die "unknown tool: $1"
    _ver="$(pin_version "$1")" || die "$1 is not pinned"
    _url="$(tool_url "$1" "$_ver" "$(platform)")"
    [ -n "$_url" ] || die "$1 is not published for $(platform)"
    _bin="$(tool_bin "$1" "$(pin_sha "$1" "$(platform)")")"
    [ -x "$_bin" ] || install_tool "$1" "$_ver" >&2
    verify_tool "$1" "$_ver"
    echo "$_bin"
}

cmd_doctor() {
    validate_pins
    _root="$(repo_root)"
    printf 'grubstake  %s\n' "$GRUBSTAKE_VERSION"
    printf 'repo       %s\n' "$_root"
    printf 'platform   %s\n' "$(platform)"
    printf 'cache      %s\n' "$(cache_root)"
    printf 'hooksPath  %s\n' "$(git -C "$_root" config core.hooksPath || echo '(unset)')"
    printf 'pins       %s\n' "$(pins_file)"
    for _tool in $(pinned_tools); do
        _ver="$(pin_version "$_tool")"
        # Assign, do not test: a die inside $( ) would only kill the subshell.
        _url="$(tool_url "$_tool" "$_ver" "$(platform)")"
        if [ -z "$_url" ]; then
            printf '  %-12s %-10s n/a on %s\n' "$_tool" "$_ver" "$(platform)"
        elif [ -x "$(tool_bin "$_tool" "$(pin_sha "$_tool" "$(platform)")")" ]; then
            printf '  %-12s %-10s installed\n' "$_tool" "$_ver"
        else
            printf '  %-12s %-10s MISSING\n' "$_tool" "$_ver"
        fi
    done
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
    "$_installed" ensure || die "updated to $_version, but ensure failed. Run it again before committing."
    log "review the diff, then commit"
}

cmd_install() {
    _root="$(repo_root)"
    # Check before writing anything: refusing after creating files is a half-adopted repo.
    _existing="$(git -C "$_root" config core.hooksPath || true)"
    if [ -n "$_existing" ] && [ "$_existing" != ".githooks" ]; then
        die "core.hooksPath is already '$_existing'; move those hooks into .githooks first"
    fi
    mkdir -p "$_root/.githooks"

    for _hook in pre-commit post-commit; do
        _dest="$_root/.githooks/$_hook"
        if [ -f "$_dest" ]; then
            log "$_hook: already present, leaving it alone"
            continue
        fi
        curl -fsSL --retry 3 --retry-all-errors --max-time 300 "$GRUBSTAKE_RAW/v$GRUBSTAKE_VERSION/hooks/$_hook" -o "$_dest.tmp" \
            || { rm -f "$_dest.tmp"; die "cannot fetch $_hook for v$GRUBSTAKE_VERSION"; }
        chmod +x "$_dest.tmp"
        mv "$_dest.tmp" "$_dest"
        log "$_hook: installed"
    done

    git -C "$_root" config core.hooksPath .githooks
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
    trap "rm -f '$_tmp'" EXIT HUP INT TERM

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
    "$_self" ensure || die "updated to $_target, but ensure failed. Run it again before committing."
    log "review the diff, then commit"
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
        version)        echo "$GRUBSTAKE_VERSION" ;;
        -h|--help|help) usage ;;
        *)              die "unknown command: $_cmd (try: grubstake help)" ;;
    esac
}

main "$@"
