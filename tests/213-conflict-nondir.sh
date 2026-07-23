#!/bin/sh
# a needed directory path occupied by a real non-directory is a
# conflict, refused before anything links. 211 covers a symlink at the
# directory position, this covers a foreign real file there.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init
mkdir -p "$CHY_ROOT/usr"
printf 'foreign\n' >"$CHY_ROOT/usr/libexec"   # a real file where a dir is needed

mkpkg "$CHY_ROOT" needdir 1.0 usr/libexec/tool
run_chy install needdir
assert_rc 1 'a real file at a needed directory path is a conflict'
file_has "$ERR" 'chy: needdir: error: conflict: usr/libexec exists and is not a directory'
assert_not_installed "$CHY_ROOT" needdir
[ -f "$CHY_ROOT/usr/libexec" ] || fail 'the foreign file must be left in place'
assert_absent "$CHY_ROOT/usr/libexec/tool"
[ ! -e "$CHY_ROOT/store/needdir-1.0" ] || fail 'a refused conflict left a store entry'
exit 0
