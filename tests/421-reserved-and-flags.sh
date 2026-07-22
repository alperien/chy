#!/bin/sh
# the names `install` and `order` are reserved (they collide with
# reserved output scopes) and get rejected like any illegal name:
# exit 1. An unknown flag is a usage error, usage on stderr, exit 2,
# and each verb owns only its own flag.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- reserved names are rejected even when a plausible recipe exists ---
mkpkg "$CHY_ROOT" order 1.0 usr/bin/order-tool
run_chy install order
assert_rc 1 'the name order is reserved'
[ -s "$ERR" ] || fail 'rejection must say something on stderr'
assert_empty_file "$OUT" 'a rejected name produces no stdout'
assert_not_installed "$CHY_ROOT" order
assert_no_store "$CHY_ROOT" order 1.0

mkpkg "$CHY_ROOT" install 1.0 usr/bin/install-tool
run_chy install install
assert_rc 1 'the name install is reserved'
[ -s "$ERR" ] || fail 'rejection must say something on stderr'
assert_empty_file "$OUT"
assert_not_installed "$CHY_ROOT" install
assert_no_store "$CHY_ROOT" install 1.0

# --- unknown flags: usage on stderr, exit 2, nothing happens ---
mkpkg "$CHY_ROOT" plain 1.0 usr/bin/plain-tool
run_chy install --frobnicate plain
assert_rc 2 'unknown install flag is a usage error'
[ -s "$ERR" ] || fail 'usage expected on stderr'
assert_empty_file "$OUT" 'usage errors are silent on stdout'
assert_not_installed "$CHY_ROOT" plain

run_chy remove --frobnicate plain
assert_rc 2 'unknown remove flag is a usage error'
[ -s "$ERR" ] || fail 'usage expected on stderr'
assert_empty_file "$OUT"

# --- flags belong to their own verb: -r is not install's, --no-deps is
#     not remove's ---
run_chy install -r plain
assert_rc 2 '-r is unknown to install'
[ -s "$ERR" ] || fail 'usage expected on stderr'
assert_empty_file "$OUT"
assert_not_installed "$CHY_ROOT" plain

run_chy remove --no-deps plain
assert_rc 2 '--no-deps is unknown to remove'
[ -s "$ERR" ] || fail 'usage expected on stderr'
assert_empty_file "$OUT"

exit 0
