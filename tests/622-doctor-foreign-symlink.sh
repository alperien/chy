#!/bin/sh
# doctor check 3, symlink flavor: a manifest path that IS a symlink but
# not the package's own is foreign, whether it points outside any
# store/ (dangling counts, lstat-present is present) or into another
# package's store entry. Unowned links skip check 2, so each path gets
# exactly one finding and the count matches.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

mkpkg "$CHY_ROOT" forn 1.0 usr/bin/fa-tool usr/bin/fb-tool
mkpkg "$CHY_ROOT" other 1.0 usr/lib/other-tool
run_chy install forn other
assert_rc 0 'fixture installs'
assert_installed "$CHY_ROOT" forn 1.0 1
assert_installed "$CHY_ROOT" other 1.0 1

# fa-tool: a symlink pointing outside any store/, target absent; still
# present by lstat, so this is foreign, not missing and not broken
rm "$CHY_ROOT/usr/bin/fa-tool"
ln -s "$TMPD/alien-target" "$CHY_ROOT/usr/bin/fa-tool"
# fb-tool: a resolvable symlink owned by another package
rm "$CHY_ROOT/usr/bin/fb-tool"
ln -s ../../store/other/usr/lib/other-tool "$CHY_ROOT/usr/bin/fb-tool"

run_chy doctor
assert_rc 1 'foreign symlinks: doctor exits 1'
want=$(printf '%s\n%s\n%s' \
    'doctor: forn: foreign usr/bin/fa-tool' \
    'doctor: forn: foreign usr/bin/fb-tool' \
    'doctor: 2 problem(s)')
assert_eq "$(cat "$OUT")" "$want" \
    'one foreign finding per symlink, other stays clean, count is 2'
assert_empty_file "$ERR" 'doctor says nothing on stderr'

exit 0
