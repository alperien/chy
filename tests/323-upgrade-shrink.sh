#!/bin/sh
# a successful upgrade retires the previous version: farm links the new
# manifest no longer carries get pruned, the old store dir goes.
# Exercises retire_prev on a shrinking manifest.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init
mkpkg "$CHY_ROOT" up 1.0 usr/bin/aaa usr/bin/extra
run_chy install up
assert_rc 0 'v1 installs'
assert_link "$CHY_ROOT/usr/bin/extra" '../../store/up/usr/bin/extra'

mkpkg "$CHY_ROOT" up 2.0 usr/bin/aaa          # v2 drops usr/bin/extra
run_chy install up
assert_rc 0 'v2 upgrade installs'
file_has_line "$OUT" 'chy: up: installed 2.0 1'
assert_installed "$CHY_ROOT" up 2.0 1
assert_link "$CHY_ROOT/usr/bin/aaa" '../../store/up/usr/bin/aaa'
assert_absent "$CHY_ROOT/usr/bin/extra"       # stale link pruned by retire_prev
[ ! -e "$CHY_ROOT/store/up-1.0" ] || fail 'the old store dir was not retired'
run_chy doctor
assert_rc 0 'doctor clean after upgrade'
file_has_line "$OUT" 'chy: doctor: clean'
exit 0
