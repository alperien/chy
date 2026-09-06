#!/bin/sh
# a build-less binary recipe installs the verified archive directly: the
# single checksummed source IS the package image (kiss installs tarballs
# the same way -- the digest in the recipe is the whole trust surface).
# Refusals: more than one source, a non-archive, mirrors or a dest field
# on the source line.  A binary recipe WITH a build file keeps the
# normal pipeline (tests/600 covers that shape).
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- the image: a tar.gz staging usr/bin/bintool, no top-level dir ---
mkdir -p "$TMPD/image/usr/bin"
printf 'payload\n' >"$TMPD/image/usr/bin/bintool"
tar -C "$TMPD/image" -czf "$TMPD/binsample.tar.gz" usr
bin_sum=$(sha_of "$TMPD/binsample.tar.gz")

# --- happy path: kind binary, no build, one bare archive source ---
mkdir -p "$CHY_ROOT/recipes/bfast"
printf '1.0\n' >"$CHY_ROOT/recipes/bfast/version"
printf 'file://%s/binsample.tar.gz\n' "$TMPD" >"$CHY_ROOT/recipes/bfast/sources"
printf '%s\n' "$bin_sum" >"$CHY_ROOT/recipes/bfast/checksums"
printf 'binary\n' >"$CHY_ROOT/recipes/bfast/kind"

run_chy install bfast
assert_rc 0 'build-less binary install must succeed'
assert_order_first 'bfast'
file_has_line "$OUT" '+ bfast 1.0_1'
assert_installed "$CHY_ROOT" bfast 1.0 1
assert_link "$CHY_ROOT/store/bfast" 'bfast-1.0'
assert_link "$CHY_ROOT/usr/bin/bintool" '../../store/bfast/usr/bin/bintool'
assert_eq "$(cat "$CHY_ROOT/usr/bin/bintool")" 'payload' 'archive payload farms intact'
file_has_line "$CHY_ROOT/db/installed/bfast/manifest" 'usr/bin/bintool'

# --- a nested tarball root installs verbatim: no hoist magic, the
# --- archive is the layout (a gate-built image always carries usr/ at
# --- the root; a nested one is visible in the manifest, not silently
# --- flattened)
rm -rf "$CHY_ROOT/store" "$CHY_ROOT/db" "${CHY_ROOT:?}/usr" "$CHY_ROOT/log"
mkdir -p "$TMPD/nest/binsample-1.0/usr/bin"
printf 'nested\n' >"$TMPD/nest/binsample-1.0/usr/bin/bintool"
tar -C "$TMPD/nest" -czf "$TMPD/binsample.tar.gz" binsample-1.0
bin_sum=$(sha_of "$TMPD/binsample.tar.gz")
printf '%s\n' "$bin_sum" >"$CHY_ROOT/recipes/bfast/checksums"

run_chy install bfast
assert_rc 0 'nested binary install must succeed'
assert_eq "$(cat "$CHY_ROOT/store/bfast-1.0/binsample-1.0/usr/bin/bintool")" \
    'nested' 'nested layout lands verbatim under the store entry'
assert_absent "$CHY_ROOT/usr/bin/bintool"

# --- refusals: wrong shape in every direction ---
rm -rf "$CHY_ROOT/store" "$CHY_ROOT/db" "${CHY_ROOT:?}/usr" "$CHY_ROOT/log" \
    "$CHY_ROOT/binsample-1.0"
printf 'plain file, not an archive\n' >"$TMPD/plain.txt"
plain_sum=$(sha_of "$TMPD/plain.txt")

printf 'file://%s/binsample.tar.gz\n' "$TMPD" >"$CHY_ROOT/recipes/bfast/sources"
printf 'file://%s/plain.txt\n' "$TMPD" >>"$CHY_ROOT/recipes/bfast/sources"
printf '%s\n%s\n' "$bin_sum" "$plain_sum" >"$CHY_ROOT/recipes/bfast/checksums"
run_chy install bfast
assert_rc 1 'two sources are refused'
assert_not_installed "$CHY_ROOT" bfast
file_matches "$ERR" "takes exactly one source"

printf 'file://%s/binsample.tar.gz http://mirror.invalid/binsample.tar.gz\n' \
    "$TMPD" >"$CHY_ROOT/recipes/bfast/sources"
printf '%s\n' "$bin_sum" >"$CHY_ROOT/recipes/bfast/checksums"
run_chy install bfast
assert_rc 1 'a mirror on the source line is refused'
assert_not_installed "$CHY_ROOT" bfast
file_matches "$ERR" "takes no mirrors"

printf 'file://%s/plain.txt\n' "$TMPD" >"$CHY_ROOT/recipes/bfast/sources"
printf '%s\n' "$plain_sum" >"$CHY_ROOT/recipes/bfast/checksums"
run_chy install bfast
assert_rc 1 'a non-archive source is refused'
assert_not_installed "$CHY_ROOT" bfast
file_matches "$ERR" "not an archive"

# --- kind binary WITH a build file still runs the build (tests/600 shape) ---
rm -rf "$CHY_ROOT/store" "$CHY_ROOT/db" "${CHY_ROOT:?}/usr" "$CHY_ROOT/log"
mkpkg "$CHY_ROOT" bscript 1.0 usr/bin/bscript
printf 'binary\n' >"$CHY_ROOT/recipes/bscript/kind"
run_chy install bscript
assert_rc 0 'binary kind with a build keeps the normal pipeline'
assert_installed "$CHY_ROOT" bscript 1.0 1
