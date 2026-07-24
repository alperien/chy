#!/bin/sh
# the smallest missing name is blamed on its smallest needed requirer,
# compared as bytes. z needs the recipe-less 1e2, the unrelated b needs
# the existing 100. Numerically 1e2 equals 100, so a strnum edge match
# used to blame b. The line has to name z.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

mkpkg "$CHY_ROOT" z 1.0 usr/bin/z-tool
mkpkg "$CHY_ROOT" b 1.0 usr/bin/b-tool
mkpkg "$CHY_ROOT" 100 1.0 usr/bin/tool-100
recipe_list "$CHY_ROOT" z depends 1e2
recipe_list "$CHY_ROOT" b depends 100

run_chy install z b
assert_rc 1 'a missing dependency fails the resolution'
assert_eq "$(cat "$ERR")" \
    'chy: z: error: needs 1e2, which has no recipe and is not provided' \
    'the real requirer z is blamed, not b (100 is not 1e2)'
assert_empty_file "$OUT" 'resolution failure prints nothing to stdout'
assert_not_installed "$CHY_ROOT" z
assert_not_installed "$CHY_ROOT" b
assert_not_installed "$CHY_ROOT" 100
assert_no_store "$CHY_ROOT" z 1.0
assert_no_store "$CHY_ROOT" b 1.0

exit 0
