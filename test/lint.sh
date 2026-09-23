#!/bin/sh
# Downloads the pinned lint toolchain, verifies it, proves each tool still catches known-bad input,
# then lints the repo. The pins below are the only place a lint tool's version changes.
#
#   test/lint.sh    downloads on first run, caches outside the repo, then offline
#
# Every download is checked against a sha256 recorded here; a version tag is not a checksum.

set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${GRUBSTAKE_LINT_CACHE:-$HOME/.cache/grubstake-lint}"

# ---------------------------------------------------------------------------- pins
#
#   tool         version
SHELLCHECK_VERSION=0.11.0
SHFMT_VERSION=3.14.1
ACTIONLINT_VERSION=1.7.12
ZIZMOR_VERSION=1.30.1

platform() {
    case "$(uname -s):$(uname -m)" in
        Linux:x86_64) echo linux_amd64 ;;
        Darwin:arm64) echo darwin_arm64 ;;
        *)
            printf 'lint.sh: unsupported platform: %s %s\n' "$(uname -s)" "$(uname -m)" >&2
            exit 1
            ;;
    esac
}

# One line per tool per platform: download URL, then its recorded sha256, from the release's own
# published digest (cross-checked against actionlint's own checksums.txt for that tool).
lint_asset() {
    case "$1:$2" in
        shellcheck:linux_amd64)
            echo "https://github.com/koalaman/shellcheck/releases/download/v$SHELLCHECK_VERSION/shellcheck-v$SHELLCHECK_VERSION.linux.x86_64.tar.xz 8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198"
            ;;
        shellcheck:darwin_arm64)
            echo "https://github.com/koalaman/shellcheck/releases/download/v$SHELLCHECK_VERSION/shellcheck-v$SHELLCHECK_VERSION.darwin.aarch64.tar.xz 56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79"
            ;;
        shfmt:linux_amd64)
            echo "https://github.com/mvdan/sh/releases/download/v$SHFMT_VERSION/shfmt_v${SHFMT_VERSION}_linux_amd64 76e77641faa025814b77f153b29796b8e6fa2fca03e0c76a691608b86c7ea7bf"
            ;;
        shfmt:darwin_arm64)
            echo "https://github.com/mvdan/sh/releases/download/v$SHFMT_VERSION/shfmt_v${SHFMT_VERSION}_darwin_arm64 b7c872db63553ccffc7253aba3ed7d4885a27d83f1ba567b1138c6315a5847e5"
            ;;
        actionlint:linux_amd64)
            echo "https://github.com/rhysd/actionlint/releases/download/v$ACTIONLINT_VERSION/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz 8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8"
            ;;
        actionlint:darwin_arm64)
            echo "https://github.com/rhysd/actionlint/releases/download/v$ACTIONLINT_VERSION/actionlint_${ACTIONLINT_VERSION}_darwin_arm64.tar.gz aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f"
            ;;
        zizmor:linux_amd64)
            echo "https://github.com/zizmorcore/zizmor/releases/download/v$ZIZMOR_VERSION/zizmor-x86_64-unknown-linux-gnu.tar.gz e65324f4430c2717591937edcec90ccbefaf14c174f8ec9415e03ca875b46e1a"
            ;;
        zizmor:darwin_arm64)
            echo "https://github.com/zizmorcore/zizmor/releases/download/v$ZIZMOR_VERSION/zizmor-aarch64-apple-darwin.tar.gz e28d22b087f9ebb8d99da6e740d348c930f559961c7c3f12badda54f882195a2"
            ;;
        *)
            printf 'lint.sh: no pin for %s on %s\n' "$1" "$2" >&2
            exit 1
            ;;
    esac
}

sha256_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        printf 'lint.sh: no shasum or sha256sum on PATH\n' >&2
        exit 1
    fi
}

# Downloads to a temp file in the cache and renames into place only once verified, so a reader
# never sees a partial or unverified download and a failed one leaves nothing behind to trust.
fetch_verified() {
    _url="$1"
    _sha="$2"
    _dest="$3"
    [ -f "$_dest" ] && [ "$(sha256_file "$_dest")" = "$_sha" ] && return 0
    mkdir -p "$(dirname "$_dest")"
    _tmp="$_dest.$$.tmp"
    curl -fsSL --retry 3 --retry-all-errors --max-time 300 "$_url" -o "$_tmp" || {
        printf 'lint.sh: download failed: %s\n' "$_url" >&2
        rm -f "$_tmp"
        exit 1
    }
    _got="$(sha256_file "$_tmp")"
    [ "$_got" = "$_sha" ] || {
        printf 'lint.sh: sha256 mismatch for %s: got %s, want %s\n' "$_url" "$_got" "$_sha" >&2
        rm -f "$_tmp"
        exit 1
    }
    mv -f "$_tmp" "$_dest"
}

# The member each tool's archive holds; shfmt ships as a bare binary, so it has none.
extract_member() {
    case "$1" in
        shellcheck) echo "shellcheck-v$SHELLCHECK_VERSION/shellcheck" ;;
        actionlint) echo "actionlint" ;;
        zizmor) echo "zizmor" ;;
    esac
}

# Installs one pinned tool for this platform into $CACHE/bin, verified and version-asserted, and
# prints its path. A cache hit still re-asserts the version, so a stale binary left by an older
# pin cannot pass as the one this run asked for.
install_tool() {
    _tool="$1"
    _version="$2"
    _plat="$(platform)"
    _bin="$CACHE/bin/$_tool-$_version"
    if [ ! -x "$_bin" ]; then
        _spec="$(lint_asset "$_tool" "$_plat")"
        _url="${_spec%% *}"
        _sha="${_spec#* }"
        _archive="$CACHE/dl/$(basename "$_url")"
        fetch_verified "$_url" "$_sha" "$_archive"
        mkdir -p "$CACHE/bin"
        _stage="$_bin.$$.tmp"
        if [ "$_tool" = shfmt ]; then
            cp "$_archive" "$_stage"
        else
            _workdir="$CACHE/extract.$$"
            mkdir -p "$_workdir"
            tar -xf "$_archive" -C "$_workdir"
            mv "$_workdir/$(extract_member "$_tool")" "$_stage"
            rm -rf "$_workdir"
        fi
        chmod +x "$_stage"
        mv -f "$_stage" "$_bin"
    fi
    assert_version "$_tool" "$_bin" "$_version"
    echo "$_bin"
}

# A hash proves which bytes arrived, not that they run; this is the reported-version half of that.
assert_version() {
    _tool="$1"
    _bin="$2"
    _want="$3"
    case "$_tool" in
        shellcheck) _got="$("$_bin" --version | awk '/^version:/{print $2}')" ;;
        shfmt)
            _got="$("$_bin" --version)"
            _got="${_got#v}"
            ;;
        actionlint) _got="$("$_bin" -version | sed -n 1p)" ;;
        zizmor) _got="$("$_bin" --version | awk '{print $2}')" ;;
    esac
    [ "$_got" = "$_want" ] || {
        printf 'lint.sh: %s reports version %s, pinned to %s\n' "$_tool" "$_got" "$_want" >&2
        exit 1
    }
}

# ---------------------------------------------------------------------------- rule 14: prove the gates fire

SELFTEST_PASS=0
SELFTEST_FAIL=0

selftest_ok() {
    SELFTEST_PASS=$((SELFTEST_PASS + 1))
    printf '  ok    %s\n' "$1"
}
selftest_fail() {
    SELFTEST_FAIL=$((SELFTEST_FAIL + 1))
    printf '  FAIL  %s\n' "$1"
}

# A gate that never fires looks exactly like one that passes (AGENTS.md 15); this proves each
# tool still rejects a known-bad fixture, and still accepts its corrected twin, before either is
# trusted against the real repo.
selftest() {
    _fx="$(mktemp -d "${TMPDIR:-/tmp}/grubstake-lint-selftest.XXXXXX")"
    trap 'rm -rf "$_fx"' EXIT

    printf '#!/bin/sh\nfoo() {\n    local x=1\n    echo "$x"\n}\nfoo\n' >"$_fx/sc-bad.sh"
    printf '#!/bin/sh\nfoo() {\n    x=1\n    echo "$x"\n}\nfoo\n' >"$_fx/sc-good.sh"
    if "$SHELLCHECK" -s sh -f json "$_fx/sc-bad.sh" 2>/dev/null | grep -q '"code":3043'; then
        selftest_ok "shellcheck flags a bashism (SC3043) in known-bad input"
    else
        selftest_fail "shellcheck did not flag the local-keyword fixture"
    fi
    "$SHELLCHECK" -s sh "$_fx/sc-good.sh" >/dev/null 2>&1 \
        && selftest_ok "shellcheck accepts the corrected twin" \
        || selftest_fail "shellcheck rejected input with no known-bad shape"

    printf '#!/bin/sh\nfoo() {\necho hi\n}\n' >"$_fx/fmt-bad.sh"
    printf '#!/bin/sh\nfoo() {\n    echo hi\n}\n' >"$_fx/fmt-good.sh"
    # Fed on stdin under a path inside the repo, so shfmt reads this repo's own .editorconfig.
    if ! "$SHFMT" -d --filename "$REPO/test/lint-selftest.sh" <"$_fx/fmt-bad.sh" >/dev/null 2>&1; then
        selftest_ok "shfmt -d flags a misindented fixture"
    else
        selftest_fail "shfmt -d did not flag the misindented fixture"
    fi
    "$SHFMT" -d --filename "$REPO/test/lint-selftest.sh" <"$_fx/fmt-good.sh" >/dev/null 2>&1 \
        && selftest_ok "shfmt -d accepts the corrected twin" \
        || selftest_fail "shfmt -d rejected input with no known-bad shape"

    printf 'on: push\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo "${UNBALANCED\n' >"$_fx/al-bad.yml"
    printf 'on: push\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n' >"$_fx/al-good.yml"
    if ! "$ACTIONLINT" -shellcheck="$SHELLCHECK" -pyflakes= "$_fx/al-bad.yml" >/dev/null 2>&1; then
        selftest_ok "actionlint flags a shell syntax error in a run: step"
    else
        selftest_fail "actionlint did not flag the broken run: step"
    fi
    "$ACTIONLINT" -shellcheck="$SHELLCHECK" -pyflakes= "$_fx/al-good.yml" >/dev/null 2>&1 \
        && selftest_ok "actionlint accepts the corrected twin" \
        || selftest_fail "actionlint rejected input with no known-bad shape"

    printf 'on: push\npermissions:\n  contents: read\njobs:\n  test:\n    runs-on: ubuntu-latest\n    timeout-minutes: 5\n    steps:\n      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n' >"$_fx/zz-bad.yml"
    printf 'on: push\npermissions:\n  contents: read\njobs:\n  test:\n    runs-on: ubuntu-latest\n    timeout-minutes: 5\n    steps:\n      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        with:\n          persist-credentials: false\n' >"$_fx/zz-good.yml"
    if "$ZIZMOR" --offline "$_fx/zz-bad.yml" 2>/dev/null | grep -q '^warning\[artipacked\]'; then
        selftest_ok "zizmor flags a checkout with no persist-credentials: false"
    else
        selftest_fail "zizmor did not flag the artipacked fixture"
    fi
    "$ZIZMOR" --offline "$_fx/zz-good.yml" >/dev/null 2>&1 \
        && selftest_ok "zizmor accepts the corrected twin" \
        || selftest_fail "zizmor rejected input with no known-bad shape"

    rm -rf "$_fx"
    trap - EXIT
    printf '\nselftest: %s passed, %s failed\n' "$SELFTEST_PASS" "$SELFTEST_FAIL"
    [ "$SELFTEST_FAIL" -eq 0 ] || exit 1
}

# ---------------------------------------------------------------------------- the real lint

SHELLCHECK="$(install_tool shellcheck "$SHELLCHECK_VERSION")"
SHFMT="$(install_tool shfmt "$SHFMT_VERSION")"
ACTIONLINT="$(install_tool actionlint "$ACTIONLINT_VERSION")"
ZIZMOR="$(install_tool zizmor "$ZIZMOR_VERSION")"

printf 'shellcheck %s, shfmt %s, actionlint %s, zizmor %s\n' \
    "$SHELLCHECK_VERSION" "$SHFMT_VERSION" "$ACTIONLINT_VERSION" "$ZIZMOR_VERSION"

selftest

# Space-separated on purpose: shellcheck and shfmt below split this into one argument per file.
SH_FILES="grubstake.sh
hooks/commit-msg hooks/post-commit hooks/pre-commit
.githooks/commit-msg .githooks/post-commit .githooks/pre-commit
.githooks/commit-msg.d/scan-for-leaks .githooks/pre-commit.d/scan-for-leaks
test/run.sh test/gates.sh test/scan-for-leaks.sh test/lint.sh
.claude/hooks/antagonist-gate.sh .claude/hooks/antagonist-receipt.sh .claude/hooks/gate-lib.sh"

cd "$REPO"

# Every tool runs even if an earlier one fails, so one red check cannot hide another behind it.
STATUS=0

printf '\nshellcheck\n'
# shellcheck disable=SC2086
"$SHELLCHECK" -s sh $SH_FILES || STATUS=1

printf '\nshfmt -d\n'
# shellcheck disable=SC2086
"$SHFMT" -d $SH_FILES || STATUS=1

printf '\nactionlint\n'
"$ACTIONLINT" -shellcheck="$SHELLCHECK" -pyflakes= || STATUS=1

printf '\nzizmor\n'
"$ZIZMOR" --offline .github/workflows || STATUS=1

if [ "$STATUS" -eq 0 ]; then
    printf '\nlint: clean\n'
else
    printf '\nlint: failed\n'
fi
exit "$STATUS"
