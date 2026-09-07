#!/bin/sh
# $CHY_PATH: colon-separated extra repositories, searched in order
# between the overlay and the default repo (kiss's KISS_PATH).  First
# match wins: an earlier repo shadows a later one per package, install
# resolves through the path, search lists each name once from its
# winning repo, and empty segments are skipped.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# repos: default has dual@1; extra has dual@2 and only@extra
mkpkg "$CHY_ROOT" dual 1.0 usr/bin/dual
mkpkg "$CHY_ROOT" extra 1.0 usr/bin/extra-tool
printf 'seed for only\n' >"$TMPD/seed-only.txt"
mkdir -p "$TMPD/extra_repo/dual" "$TMPD/extra_repo/only"
printf '2.0\n' >"$TMPD/extra_repo/dual/version"
printf 'file://%s/seed-dual.txt\n' "$TMPD" >"$TMPD/extra_repo/dual/sources"
sha_of "$TMPD/seed-dual.txt" >"$TMPD/extra_repo/dual/checksums"
printf 'set -eu\nmkdir -p "$1$CHY_ROOT/usr/bin"\nprintf extra >"$1$CHY_ROOT/usr/bin/dual"\n' \
    >"$TMPD/extra_repo/dual/build"
printf '3.0\n' >"$TMPD/extra_repo/only/version"
printf 'file://%s/seed-only.txt\n' "$TMPD" >"$TMPD/extra_repo/only/sources"
sha_of "$TMPD/seed-only.txt" >"$TMPD/extra_repo/only/checksums"
printf 'set -eu\nmkdir -p "$1$CHY_ROOT/usr/bin"\nprintf x >"$1$CHY_ROOT/usr/bin/onlytool"\n' \
    >"$TMPD/extra_repo/only/build"

# --- an extra-repo package installs, resolving through the path ---
CHY_PATH="$TMPD/extra_repo" run_chy install only
assert_rc 0 'install from a CHY_PATH repo must succeed'
assert_installed "$CHY_ROOT" only 3.0 1
assert_link "$CHY_ROOT/usr/bin/onlytool" '../../store/only/usr/bin/onlytool'

# --- earlier path entries shadow the default repo ---
rm -rf "$CHY_ROOT/store" "$CHY_ROOT/db" "$CHY_ROOT/usr" "$CHY_ROOT/log"
CHY_PATH="$TMPD/extra_repo" run_chy install dual
assert_rc 0 'shadowing install must succeed'
assert_installed "$CHY_ROOT" dual 2.0 1
assert_eq "$(cat "$CHY_ROOT/usr/bin/dual")" 'extra' \
    'the CHY_PATH repo won over the default repo'

# --- reversed order hands the win back to the default repo ---
rm -rf "$CHY_ROOT/store" "$CHY_ROOT/db" "$CHY_ROOT/usr" "$CHY_ROOT/log"
CHY_PATH="" run_chy install dual
assert_rc 0 'default-repo install must succeed'
assert_installed "$CHY_ROOT" dual 1.0 1

# --- empty segments are skipped, unset behaves as before ---
CHY_PATH="::$TMPD/extra_repo:" run_chy install only
assert_rc 0 'empty CHY_PATH segments are skipped'

# --- search: each name once, from its winning repo ---
CHY_PATH="$TMPD/extra_repo" run_chy search dual
assert_rc 0 'search exits 0'
assert_eq "$(cat "$OUT")" 'dual 2.0 1' 'search shows the shadowing repo version'

# --- outdated reports drift against the winning recipe ---
CHY_PATH="$TMPD/extra_repo" run_chy outdated
assert_rc 0 'outdated exits 0'
file_has_line "$OUT" 'dual 1.0 1 -> 2.0 1'

# --- an empty pattern is a usage error (searches match everything) ---
CHY_PATH="$TMPD/extra_repo" run_chy search ''
assert_rc 2 'search needs a pattern'
