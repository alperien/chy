# shellcheck shell=sh
# tests/lib.sh - shared helpers for the suite.
#
# Sourced by every test after `cd` to the repo root. POSIX sh, no local.
# Everything here works from chy's promised behavior; tests never look at
# chy's internals. Hermetic: source files are pre-seeded into
# "$CHY_ROOT/cache" so a verified cache hit never downloads,
# and URLs that must fail use the unreachable http://127.0.0.1:9/.

CHY="$PWD/chy/chy"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# t_init - fresh scratch dir, cleanup trap, one valid root exported.
t_init() {
    TMPD=$(mktemp -d) || fail 'mktemp -d failed'
    trap 'rm -rf "$TMPD"' EXIT
    CHY_ROOT="$TMPD/root"
    mkdir -p "$CHY_ROOT"
    export CHY_ROOT
}

sha_of() {
    sha256sum "$1" | cut -d ' ' -f 1
}

# run CMD... - capture exit code in RC, stdout file in OUT, stderr in ERR.
run() {
    RC=0
    "$@" >"$TMPD/run.out" 2>"$TMPD/run.err" || RC=$?
    OUT="$TMPD/run.out"
    ERR="$TMPD/run.err"
}

run_chy() {
    run sh "$CHY" "$@"
}

# run_chy_root ROOT VERB... - like run_chy but against an explicit root.
run_chy_root() {
    rg_root=$1
    shift
    RC=0
    CHY_ROOT="$rg_root" sh "$CHY" "$@" >"$TMPD/run.out" 2>"$TMPD/run.err" || RC=$?
    OUT="$TMPD/run.out"
    ERR="$TMPD/run.err"
}

dump_streams() {
    printf -- '--- stdout ---\n' >&2
    cat "$OUT" >&2
    printf -- '--- stderr ---\n' >&2
    cat "$ERR" >&2
}

assert_rc() {
    if [ "$RC" -ne "$1" ]; then
        dump_streams
        fail "expected exit $1, got $RC${2:+ - $2}"
    fi
}

assert_eq() { # actual expected label
    if [ "$1" != "$2" ]; then
        fail "${3:-values differ}: got [$1], want [$2]"
    fi
}

file_has() { # file fixed-string
    grep -F -q -- "$2" "$1" || { cat "$1" >&2; fail "missing string [$2] in $1"; }
}

file_has_line() { # file exact-line
    grep -F -x -q -- "$2" "$1" || { cat "$1" >&2; fail "missing exact line [$2] in $1"; }
}

file_matches() { # file regex
    grep -q -- "$2" "$1" || { cat "$1" >&2; fail "no line matches [$2] in $1"; }
}

assert_empty_file() {
    if [ -s "$1" ]; then
        cat "$1" >&2
        fail "${2:-expected no output}: $1 has content"
    fi
}

assert_absent() {
    if [ -e "$1" ] || [ -h "$1" ]; then
        fail "unexpectedly exists: $1"
    fi
}

assert_link() { # linkpath exact-target
    [ -h "$1" ] || fail "not a symlink: $1"
    al_got=$(readlink "$1") || fail "readlink failed on $1"
    assert_eq "$al_got" "$2" "wrong target for $1"
}

assert_installed() { # root name version revision
    [ -d "$1/db/installed/$2" ] || fail "db/installed/$2 missing under $1"
    assert_eq "$(cat "$1/db/installed/$2/version")" "$3 $4" "db version for $2"
}

assert_not_installed() { # root name
    assert_absent "$1/db/installed/$2"
}

assert_no_store() { # root name version
    assert_absent "$1/store/$2-$3"
    assert_absent "$1/store/$2"
}

count_matches() { # regex file - prints the count, never fails
    grep -c -- "$1" "$2" || true
}

# snap ROOT - stable fingerprint of a root: paths, file digests, link
# targets. Excludes build/ and cache/
# Roots never contain whitespace, so
# line-based processing is safe.
snap() {
    (
        cd "$1" || exit 1
        find . \( -path ./build -o -path ./cache \) -prune -o -print \
            | LC_ALL=C sort
        find . \( -path ./build -o -path ./cache \) -prune -o -type f -print \
            | LC_ALL=C sort | while read -r sn_f; do sha256sum "$sn_f"; done
        find . \( -path ./build -o -path ./cache \) -prune -o -type l -print \
            | LC_ALL=C sort | while read -r sn_l; do
                printf '%s -> %s\n' "$sn_l" "$(readlink "$sn_l")"
            done
    )
}

# add_source ROOT NAME FILE [EXTRA-URL...] - register FILE as one source
# line of NAME's recipe: seed cache/<basename> with it, append an
# unreachable primary URL (basename preserved) plus any EXTRA-URLs to
# sources, append the matching digest to checksums.
add_source() {
    as_root=$1 as_name=$2 as_file=$3
    shift 3
    as_base=${as_file##*/}
    mkdir -p "$as_root/cache" "$as_root/recipes/$as_name"
    cp "$as_file" "$as_root/cache/$as_base"
    as_line="http://127.0.0.1:9/$as_base"
    for as_url in "$@"; do
        as_line="$as_line $as_url"
    done
    printf '%s\n' "$as_line" >>"$as_root/recipes/$as_name/sources"
    sha_of "$as_file" >>"$as_root/recipes/$as_name/checksums"
}

# pkg_content NAME RELPATH - the content mkpkg-built packages install.
pkg_content() {
    printf '%s:%s' "$1" "$2"
}

# mkpkg ROOT NAME VERSION-LINE [RELPATH...] - a complete script-only
# recipe. Its build creates each RELPATH under "$1$CHY_ROOT/" containing
# "NAME:RELPATH". With no RELPATHs the build stages nothing (callers
# usually overwrite it). The single source is a seed file already in
# cache; its URL is unreachable, so any fetch attempt fails loudly.
mkpkg() {
    mk_root=$1 mk_name=$2 mk_ver=$3
    shift 3
    mk_dir="$mk_root/recipes/$mk_name"
    rm -rf "$mk_dir"
    mkdir -p "$mk_dir"
    printf '%s\n' "$mk_ver" >"$mk_dir/version"
    printf 'seed for %s\n' "$mk_name" >"$TMPD/seed-$mk_name.txt"
    add_source "$mk_root" "$mk_name" "$TMPD/seed-$mk_name.txt"
    printf 'set -eu\n' >"$mk_dir/build"
    for mk_p in "$@"; do
        mk_d=${mk_p%/*}
        if [ "$mk_d" != "$mk_p" ]; then
            printf "mkdir -p \"\$1\$CHY_ROOT/%s\"\n" "$mk_d" >>"$mk_dir/build"
        fi
        printf "printf '%%s\\\\n' '%s' >\"\$1\$CHY_ROOT/%s\"\n" \
            "$(pkg_content "$mk_name" "$mk_p")" "$mk_p" >>"$mk_dir/build"
    done
}

# recipe_list ROOT NAME FILE ENTRY... - (over)write a list-valued recipe
# file (depends, makedepends, conflicts), one entry per line.
recipe_list() {
    rl_path="$1/recipes/$2/$3"
    shift 3
    : >"$rl_path"
    for rl_e in "$@"; do
        printf '%s\n' "$rl_e" >>"$rl_path"
    done
}

# stamp_builds ROOT NAME DIR - make NAME's build touch DIR/built-<NAME>,
# so a test can tell whether the build ran at all.
stamp_builds() {
    printf 'touch "%s/built-%s"\n' "$3" "$2" >>"$1/recipes/$2/build"
}

# installed_seq - names from the "installed" completion lines of $OUT, in
# order, space-joined. The build sequence of the last install invocation.
installed_seq() {
    sed -n 's/^chy: \(.*\): installed .*$/\1/p' "$OUT" | tr '\n' ' ' | sed 's/ $//'
}

# removed_seq - same for "removed" completion lines.
removed_seq() {
    sed -n 's/^chy: \(.*\): removed .*$/\1/p' "$OUT" | tr '\n' ' ' | sed 's/ $//'
}

# assert_order 'names...' - exactly one order line on stdout, pinned.
assert_order() {
    ao_n=$(count_matches '^chy: order: ' "$OUT")
    if [ "$ao_n" != 1 ]; then
        dump_streams
        fail "expected exactly one order line, found $ao_n"
    fi
    file_has_line "$OUT" "chy: order: $1"
}

# assert_order_first 'names...' - the order line, and it precedes every
# pipeline line (printed before any pipeline step; chy's stdout is
# only the pinned lines, and the builds these tests run are silent).
assert_order_first() {
    assert_order "$1"
    aof_first=$(head -n 1 "$OUT")
    assert_eq "$aof_first" "chy: order: $1" 'order line must come first on stdout'
}

# assert_no_order - no order line printed at all.
assert_no_order() {
    if grep -q '^chy: order: ' "$OUT"; then
        dump_streams
        fail 'an order line printed where none belongs'
    fi
}

assert_requested() { # root name - marker present (and an empty file)
    [ -f "$1/db/installed/$2/requested" ] || fail "requested marker missing for $2"
    [ ! -s "$1/db/installed/$2/requested" ] || fail "requested marker for $2 is not empty"
}

assert_not_requested() { # root name
    assert_absent "$1/db/installed/$2/requested"
}

# --- hermetic ELF fixtures (for verify, and doctor check 1) ---
#
# No compiler is assumed. To get an ELF with an unresolvable NEEDED entry,
# copy a dynamically linked host binary and byte-patch ONE of its NEEDED
# sonames to an equal-length name that exists nowhere; plain ldd then
# reports `<fake> => not found`, which is the condition step 11 and
# doctor's check 1 must surface. Fixtures are built at test runtime (never
# committed) and verified with ldd before use; a host offering no usable
# template makes the caller SKIP, never fail.

# elf_template_init - find a host ELF with a patchable NEEDED soname.
# Sets ELF_TEMPLATE (the binary) and ELF_SONAME (the NEEDED entry to
# patch: 12+ chars so generated fakes fit, never libc or the loader).
# Returns 1 when the host offers none.
elf_template_init() {
    ELF_TEMPLATE='' ELF_SONAME=''
    command -v ldd >/dev/null 2>&1 || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    for et_cand in /usr/bin/awk /usr/bin/xz /usr/bin/tar /usr/bin/curl \
        /usr/bin/wget /bin/bash /usr/bin/python3 /bin/ls /usr/bin/find \
        /usr/bin/sort /usr/bin/env /bin/cat; do
        [ -f "$et_cand" ] || continue
        et_so=$(ldd "$et_cand" 2>/dev/null | awk '
            $2 == "=>" && $3 ~ /^\// && length($1) >= 12 &&
            $1 !~ /^libc\./ && $1 !~ /^ld-/ { print $1; exit }')
        if [ -n "$et_so" ]; then
            ELF_TEMPLATE=$et_cand ELF_SONAME=$et_so
            return 0
        fi
    done
    return 1
}

# elf_fake_soname TAG - print a fake soname exactly as long as
# ELF_SONAME: "libchy<TAG>", padded with x, ending ".so". Distinct TAGs
# order the fakes byte-wise (a < b < ...).
elf_fake_soname() {
    efs_base="libchy$1"
    efs_want=$((${#ELF_SONAME} - 3))
    while [ ${#efs_base} -lt "$efs_want" ]; do
        efs_base="${efs_base}x"
    done
    printf '%s.so' "$efs_base"
}

# mk_needy_elf OUT FAKE - copy ELF_TEMPLATE to OUT with ELF_SONAME
# byte-patched to FAKE (equal length), mode 755, then verify with plain
# ldd that FAKE is reported not found. Once a template was chosen the
# technique must work, so any mismatch fails the test.
mk_needy_elf() {
    python3 - "$ELF_TEMPLATE" "$1" "$ELF_SONAME" "$2" <<'PYEOF' || fail "byte-patching $1 failed"
import sys
src, dst, old, new = sys.argv[1:5]
data = open(src, 'rb').read()
o, n = old.encode(), new.encode()
assert len(o) == len(n), 'fake soname length mismatch'
assert o in data, 'template lost its NEEDED string'
open(dst, 'wb').write(data.replace(o, n))
PYEOF
    chmod 755 "$1"
    ldd "$1" 2>/dev/null | grep -F -- "$2" | grep -q 'not found' \
        || fail "host ldd does not report $2 as not found in $1"
}

# mktgz OUT DIR ENTRY... - a real gzipped tarball of DIR's ENTRYs.
mktgz() {
    mt_out=$1 mt_dir=$2
    shift 2
    tar -czf "$mt_out" -C "$mt_dir" "$@" || fail "tar -czf $mt_out failed"
}

# mktarxz OUT DIR ENTRY... - OUT must end in .tar.xz.
mktarxz() {
    mx_out=$1 mx_dir=$2
    shift 2
    mx_tar=${mx_out%.xz}
    tar -cf "$mx_tar" -C "$mx_dir" "$@" || fail "tar -cf $mx_tar failed"
    xz -f "$mx_tar" || fail "xz $mx_tar failed"
}
