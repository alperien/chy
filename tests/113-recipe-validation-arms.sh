#!/bin/sh
# checksums have to be lowercase sha256 hex, and every sources line
# needs a usable filename (basename of its first URL). Both fail the
# install (exit 1) before any fetching, so the digest-length decoy
# carries a reachable file:// payload that must never land in cache/.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init
traps="$TMPD/traps"
mkdir -p "$traps"
r="$CHY_ROOT/recipes"

printf 'trap payload zsum\n' >"$traps/trap-zsum.txt"

# --- checksums line of digest length but not lowercase hex (64 z's) ---
z64=$(printf '%064d' 0 | tr '0' 'z')
mkdir -p "$r/zsum"
printf '1.0\n' >"$r/zsum/version"
printf 'file://%s/trap-zsum.txt\n' "$traps" >"$r/zsum/sources"
printf '%s\n' "$z64" >"$r/zsum/checksums"
printf 'set -eu\n' >"$r/zsum/build"

# --- sources line whose URL ends in '/': no basename to key cache by.
#     Its digest is valid, so only the filename check can trip. ---
mkdir -p "$r/nobase"
printf '1.0\n' >"$r/nobase/version"
printf 'http://127.0.0.1:9/pkgdir/\n' >"$r/nobase/sources"
sha_of "$traps/trap-zsum.txt" >"$r/nobase/checksums"
printf 'set -eu\n' >"$r/nobase/build"

snap0=$(snap "$CHY_ROOT")

run_chy install zsum
assert_rc 1 'non-hex digest fails the install'
file_has_line "$ERR" \
    'chy: zsum: error: checksums must be lowercase sha256 hex digests'
assert_absent "$CHY_ROOT/cache/trap-zsum.txt"
assert_not_installed "$CHY_ROOT" zsum
assert_no_store "$CHY_ROOT" zsum 1.0

run_chy install nobase
assert_rc 1 'a sources line without a filename fails the install'
file_has_line "$ERR" \
    'chy: nobase: error: a sources line has no usable filename'
assert_not_installed "$CHY_ROOT" nobase
assert_no_store "$CHY_ROOT" nobase 1.0

# validation failed before fetching: no cache/ appeared, root untouched
assert_absent "$CHY_ROOT/cache"
assert_eq "$(snap "$CHY_ROOT")" "$snap0" 'invalid recipes leave the root as it was'

exit 0
