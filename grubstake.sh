#!/bin/sh
# grubstake: pinned, verified build tooling for iOS repos.
#
# main() wraps everything and runs last. A shell reads scripts incrementally, so a truncated file
# would otherwise execute its valid prefix silently. Same reason nvm and rustup-init do it.

set -eu

GRUBSTAKE_VERSION="0.1.5"
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
  grubstake check              re-verify installed tools against their pins
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

pins_file() { echo "$(repo_root)/grubstake.tools"; }

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

# ---------------------------------------------------------------------------- install tools

tool_dir()  { echo "$(cache_root)/$1/$2"; }
tool_bin()  { echo "$(tool_dir "$1" "$2")/$1"; }

# Hash proves what arrived. Version check proves what is inside it.
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

    _dest="$(tool_dir "$_tool" "$_ver")"
    _bin="$(tool_bin "$_tool" "$_ver")"
    [ -x "$_bin" ] && return 0

    _tmp="$(mktemp -d "${TMPDIR:-/tmp}/grubstake.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_tmp'" EXIT HUP INT TERM

    log "$_tool $_ver: downloading"
    _archive="$_tmp/archive"
    curl -fsSL "$_url" -o "$_archive" || die "$_tool $_ver: download failed"

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
    mkdir -p "$(dirname "$_dest")"
    # Losing a race is fine; clobbering a live install is not.
    mv "$_staging" "$_dest" 2>/dev/null || rm -rf "$_staging"

    rm -rf "$_tmp"
    trap - EXIT HUP INT TERM
    # set -e is suppressed when this runs from a || branch, so assert instead of assuming.
    [ -x "$_bin" ] || die "$_tool $_ver: install incomplete"
    log "$_tool $_ver: installed"
}

reported_version() {
    "$1" $(tool_version_args "$2") 2>/dev/null | head -1 | sed 's|^[Vv]ersion:[[:space:]]*||' | tr -d '[:space:]'
}

verify_tool() {
    _tool="$1"
    _ver="$2"
    # Assign, do not test: a die inside $( ) kills only the subshell and check would pass.
    _url="$(tool_url "$_tool" "$_ver" "$(platform)")"
    [ -n "$_url" ] || return 0
    _bin="$(tool_bin "$_tool" "$_ver")"
    [ -x "$_bin" ] || die "$_tool $_ver: not installed (run: grubstake ensure)"
    _got="$(reported_version "$_bin" "$_tool")"
    [ "$_got" = "$_ver" ] || die "$_tool: binary reports ${_got:-nothing}, pinned $_ver"
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
        curl -fsSL "$_url" -o "$_tmp/a" || die "$_tool $_ver: cannot fetch $_plat artifact"
        _shas="$_shas $(sha256_file "$_tmp/a")"
    done

    _pins="$(pins_file)"
    # shellcheck disable=SC2064
    trap "rm -rf '$_tmp' '$_pins.tmp'" EXIT HUP INT TERM
    [ -f "$_pins" ] || printf '# grubstake pins: name version sha256-darwin sha256-linux\n' > "$_pins"
    _new="$(grep -v -E "^$_tool[[:space:]]" "$_pins" 2>/dev/null || true)"
    printf '%s\n' "$_new" | grep -v '^$' > "$_pins.tmp" || true
    # shellcheck disable=SC2086
    printf '%s %s%s\n' "$_tool" "$_ver" "$_shas" >> "$_pins.tmp"
    sort -o "$_pins.tmp" "$_pins.tmp"
    mv "$_pins.tmp" "$_pins"

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
    _any=0
    for _tool in $(pinned_tools); do
        _any=1
        install_tool "$_tool" "$(pin_version "$_tool")"
    done
    [ "$_any" = 1 ] || warn "no tools pinned yet (run: grubstake add swiftlint@x.y.z)"
    cmd_check
}

cmd_check() {
    for _tool in $(pinned_tools); do
        verify_tool "$_tool" "$(pin_version "$_tool")"
    done
    log "ok ($GRUBSTAKE_VERSION)"
}

cmd_path() {
    [ $# -ge 1 ] || die "usage: grubstake path <tool>"
    known_tools | grep -qw "$1" || die "unknown tool: $1"
    _ver="$(pin_version "$1")" || die "$1 is not pinned"
    _bin="$(tool_bin "$1" "$_ver")"
    [ -x "$_bin" ] || install_tool "$1" "$_ver" >&2
    verify_tool "$1" "$_ver"
    echo "$_bin"
}

cmd_doctor() {
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
        elif [ -x "$(tool_bin "$_tool" "$_ver")" ]; then
            printf '  %-12s %-10s installed\n' "$_tool" "$_ver"
        else
            printf '  %-12s %-10s MISSING\n' "$_tool" "$_ver"
        fi
    done
}

cmd_install() {
    _root="$(repo_root)"
    mkdir -p "$_root/.githooks"

    for _hook in pre-commit post-commit; do
        _dest="$_root/.githooks/$_hook"
        if [ -f "$_dest" ]; then
            log "$_hook: already present, leaving it alone"
            continue
        fi
        curl -fsSL "$GRUBSTAKE_RAW/v$GRUBSTAKE_VERSION/hooks/$_hook" -o "$_dest.tmp" \
            || { rm -f "$_dest.tmp"; die "cannot fetch $_hook for v$GRUBSTAKE_VERSION"; }
        chmod +x "$_dest.tmp"
        mv "$_dest.tmp" "$_dest"
        log "$_hook: installed"
    done

    _existing="$(git -C "$_root" config core.hooksPath || true)"
    if [ -n "$_existing" ] && [ "$_existing" != ".githooks" ]; then
        die "core.hooksPath is already '$_existing'; move those hooks into .githooks first"
    fi
    git -C "$_root" config core.hooksPath .githooks
    log "hooksPath: .githooks"

    [ -f "$(pins_file)" ] || {
        printf '# grubstake pins: name version sha256-darwin sha256-linux\n' > "$(pins_file)"
        log "grubstake.tools: created (pin tools with: grubstake add swiftlint@x.y.z)"
    }

    cmd_ensure
    log "installed. Review and commit: grubstake.sh grubstake.tools .githooks/"
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
    curl -fsSL "$GRUBSTAKE_RAW/v$1/grubstake.sh" -o "$2" 2>/dev/null || return 1
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
    _self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    # The new script does the replacing. Never rewrite the file you are being read from.
    exec "$_tmp" __replace-self "$_self" "$_target"
}

cmd_replace_self() {
    _installed="$1"
    _version="$2"
    _dir="$(dirname "$_installed")"
    _staged="$(mktemp "$_dir/.grubstake.XXXXXX")"
    cp "$0" "$_staged"
    chmod +x "$_staged"
    # Rename, not overwrite: a new inode leaves readers of the old file alone.
    mv -f "$_staged" "$_installed"
    log "updated to $_version"
    log "review the diff, then commit"
}

# ---------------------------------------------------------------------------- entry

main() {
    [ $# -ge 1 ] || { usage; exit 0; }
    _cmd="$1"
    shift

    case "$_cmd" in
        __replace-self) cmd_replace_self "$@" ;;
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
