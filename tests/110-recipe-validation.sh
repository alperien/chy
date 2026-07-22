#!/bin/sh
# invalid recipes fail the install (exit 1) before any fetching. Each
# bad recipe here carries a reachable file:// URL with a real payload:
# if chy fetched before validating, the file would land in cache/ and
# we'd see it.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init
traps="$TMPD/traps"
mkdir -p "$traps"
r="$CHY_ROOT/recipes"

# trap payloads: real files a premature fetch could download
for t in trap-nobuild trap-nover trap-mm1 trap-mm2 trap-kind trap-badver; do
    printf 'trap payload %s\n' "$t" >"$traps/$t.txt"
done

# --- recipe: missing required build ---
mkdir -p "$r/nobuild"
printf '1.0\n' >"$r/nobuild/version"
printf 'file://%s/trap-nobuild.txt\n' "$traps" >"$r/nobuild/sources"
sha_of "$traps/trap-nobuild.txt" >"$r/nobuild/checksums"

# --- recipe: missing required version ---
mkdir -p "$r/nover"
printf 'file://%s/trap-nover.txt\n' "$traps" >"$r/nover/sources"
sha_of "$traps/trap-nover.txt" >"$r/nover/checksums"
printf 'set -eu\n' >"$r/nover/build"

# --- recipe: missing required sources ---
mkdir -p "$r/nosrc"
printf '1.0\n' >"$r/nosrc/version"
sha_of "$traps/trap-nobuild.txt" >"$r/nosrc/checksums"
printf 'set -eu\n' >"$r/nosrc/build"

# --- recipe: missing required checksums ---
mkdir -p "$r/nosum"
printf '1.0\n' >"$r/nosum/version"
printf 'file://%s/trap-nobuild.txt\n' "$traps" >"$r/nosum/sources"
printf 'set -eu\n' >"$r/nosum/build"

# --- recipe: sources/checksums line-count mismatch (2 sources, 1 digest) ---
mkdir -p "$r/mismatch"
printf '1.0\n' >"$r/mismatch/version"
{
    printf 'file://%s/trap-mm1.txt\n' "$traps"
    printf 'file://%s/trap-mm2.txt\n' "$traps"
} >"$r/mismatch/sources"
sha_of "$traps/trap-mm1.txt" >"$r/mismatch/checksums"
printf 'set -eu\n' >"$r/mismatch/build"

# --- recipe: two source lines with colliding basenames ---
mkdir -p "$traps/t1" "$traps/t2"
printf 'dup one\n' >"$traps/t1/dup.txt"
printf 'dup two\n' >"$traps/t2/dup.txt"
mkdir -p "$r/dupbase"
printf '1.0\n' >"$r/dupbase/version"
{
    printf 'file://%s/t1/dup.txt\n' "$traps"
    printf 'file://%s/t2/dup.txt\n' "$traps"
} >"$r/dupbase/sources"
{
    sha_of "$traps/t1/dup.txt"
    sha_of "$traps/t2/dup.txt"
} >"$r/dupbase/checksums"
printf 'set -eu\n' >"$r/dupbase/build"

# --- recipe: kind other than source/binary is rejected, naming the kind
#     (tests/600 covers the accepted `binary` kind) ---
mkdir -p "$r/kindbad"
printf '1.0\n' >"$r/kindbad/version"
printf 'file://%s/trap-kind.txt\n' "$traps" >"$r/kindbad/sources"
sha_of "$traps/trap-kind.txt" >"$r/kindbad/checksums"
printf 'set -eu\n' >"$r/kindbad/build"
printf 'wobbly\n' >"$r/kindbad/kind"

# --- recipe: version with a hyphen violates the version grammar ---
mkdir -p "$r/badver"
printf '1.0-rc1\n' >"$r/badver/version"
printf 'file://%s/trap-badver.txt\n' "$traps" >"$r/badver/sources"
sha_of "$traps/trap-badver.txt" >"$r/badver/checksums"
printf 'set -eu\n' >"$r/badver/build"

snap0=$(snap "$CHY_ROOT")

check_invalid() { # name label
    run_chy install "$1"
    assert_rc 1 "$2"
    file_matches "$ERR" "^chy: $1: error: "
    assert_not_installed "$CHY_ROOT" "$1"
    assert_no_store "$CHY_ROOT" "$1" 1.0
}

check_invalid nobuild 'missing build file'
assert_absent "$CHY_ROOT/cache/trap-nobuild.txt"

check_invalid nover 'missing version file'
assert_absent "$CHY_ROOT/cache/trap-nover.txt"

check_invalid nosrc 'missing sources file'

check_invalid nosum 'missing checksums file'
assert_absent "$CHY_ROOT/cache/trap-nobuild.txt"

check_invalid mismatch 'sources/checksums count mismatch'
assert_absent "$CHY_ROOT/cache/trap-mm1.txt"
assert_absent "$CHY_ROOT/cache/trap-mm2.txt"

check_invalid dupbase 'colliding source basenames'
assert_absent "$CHY_ROOT/cache/dup.txt"

check_invalid kindbad 'kind=wobbly is rejected'
file_has "$ERR" 'wobbly'
assert_absent "$CHY_ROOT/cache/trap-kind.txt"

check_invalid badver 'hyphenated version is invalid'
assert_absent "$CHY_ROOT/cache/trap-badver.txt"

# --- unknown package: no recipe directory at all, revision 2 made this
# the resolver's missing-recipe error with requirer `install` ---
run_chy install nosuchpkg
assert_rc 1 'unknown package'
file_has_line "$ERR" \
    'chy: install: error: needs nosuchpkg, which has no recipe and is not provided'

# --- an argument that is not a legal package name fails with exit 1 ---
run_chy install .badname
assert_rc 1 'uppercase is not a legal package name'
file_matches "$ERR" '^chy: .badname: error: '

# nothing above may have touched the root
assert_eq "$(snap "$CHY_ROOT")" "$snap0" 'invalid recipes leave the root as it was'

# --- positive control: comments and blank lines are ignored in list-valued
#     files, kind=source is accepted, and this recipe installs fine ---
mkdir -p "$r/cmt"
printf '3.3 4\n' >"$r/cmt/version"
printf 'comment seed\n' >"$TMPD/cmt-src.txt"
mkdir -p "$CHY_ROOT/cache"
cp "$TMPD/cmt-src.txt" "$CHY_ROOT/cache/cmt-src.txt"
{
    printf '# the primary source\n'
    printf '\n'
    printf 'http://127.0.0.1:9/cmt-src.txt\n'
} >"$r/cmt/sources"
{
    printf '\n'
    printf '# sha256 of cmt-src.txt\n'
    sha_of "$TMPD/cmt-src.txt"
} >"$r/cmt/checksums"
printf 'source\n' >"$r/cmt/kind"
cat >"$r/cmt/build" <<'EOF'
set -eu
mkdir -p "$1$CHY_ROOT/usr/bin"
printf 'c' >"$1$CHY_ROOT/usr/bin/cmt-tool"
EOF

run_chy install cmt
assert_rc 0 'comments/blanks ignored; kind=source accepted'
assert_installed "$CHY_ROOT" cmt 3.3 4

exit 0
