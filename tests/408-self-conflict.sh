#!/bin/sh
# A recipe whose conflicts file names itself installs fine, a package
# never conflicts with itself. (was already correct but untested, the
# guard is a deliberate self-name skip in resolve_conflicts.)
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

mkpkg "$CHY_ROOT" pkg 1.0 usr/bin/tool
recipe_list "$CHY_ROOT" pkg conflicts pkg

run_chy install pkg
assert_rc 0 'a self-named conflict does not block the package'
assert_installed "$CHY_ROOT" pkg 1.0 1

exit 0
