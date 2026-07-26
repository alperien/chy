#!/bin/sh
# remove: a manifest path that's still a symlink but not owned by the
# package (ownership is the component right after store/, string
# equality) gets a warning and stays put, exit stays 0 and the rest of
# the package goes. Both foreign shapes warn: a target with no store/
# at all, and one owned by another package.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- one link kept owned, two replaced by foreign links ---
mkpkg "$CHY_ROOT" owl 1.0 usr/bin/owl-a usr/bin/owl-b usr/bin/owl-c
run_chy install owl
assert_rc 0 'owl install'
rm "$CHY_ROOT/usr/bin/owl-b"
ln -s /nowhere/else "$CHY_ROOT/usr/bin/owl-b"       # no store/ in the target
rm "$CHY_ROOT/usr/bin/owl-c"
ln -s ../../store/thief/usr/bin/owl-c "$CHY_ROOT/usr/bin/owl-c" # another owner

run_chy remove owl
assert_rc 0 'unowned paths never affect the exit status'
file_has_line "$OUT" '- owl 1.0_1'
assert_eq "$(cat "$ERR")" \
    "$(printf 'chy: owl: warning: usr/bin/owl-b is not owned by owl; left in place\nchy: owl: warning: usr/bin/owl-c is not owned by owl; left in place')" \
    'exact not-owned warnings, manifest order'
assert_absent "$CHY_ROOT/usr/bin/owl-a"
assert_link "$CHY_ROOT/usr/bin/owl-b" '/nowhere/else'
assert_link "$CHY_ROOT/usr/bin/owl-c" '../../store/thief/usr/bin/owl-c'
[ -d "$CHY_ROOT/usr/bin" ] || fail 'usr/bin still holds the foreign links'
assert_no_store "$CHY_ROOT" owl 1.0
assert_not_installed "$CHY_ROOT" owl
run_chy list owl
assert_rc 1 'owl is gone from the db'

exit 0
