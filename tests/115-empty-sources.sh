#!/bin/sh
# A recipe whose sources and checksums have no significant lines is
# refused: nothing to fetch, verify, or build. (behaviour was already
# right, just untested.)
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

mkpkg "$CHY_ROOT" pkg 1.0 usr/bin/tool
: >"$CHY_ROOT/recipes/pkg/sources"
: >"$CHY_ROOT/recipes/pkg/checksums"

run_chy install pkg
assert_rc 1 'a recipe with no sources is refused'
file_has "$ERR" 'sources lists no sources'
assert_not_installed "$CHY_ROOT" pkg

exit 0
