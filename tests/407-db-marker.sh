#!/bin/sh
# the `requested` marker - an empty file, present iff the package
# was named on the command line at install time. Dependency installs never
# set it; reinstalling by name sets it; a satisfied dependency is skipped,
# so its marker is never touched. The recipe's `conflicts` is copied
# verbatim into the db.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- CLI name marked, pulled dependency not ---
mkpkg "$CHY_ROOT" libm 1.0 usr/bin/libm-tool
mkpkg "$CHY_ROOT" app 1.0 usr/bin/app-tool
recipe_list "$CHY_ROOT" app depends libm
run_chy install app
assert_rc 0 'app pulls libm'
assert_requested "$CHY_ROOT" app
assert_not_requested "$CHY_ROOT" libm

# --- no conflicts file in the recipe: none in the db ---
assert_absent "$CHY_ROOT/db/installed/app/conflicts"

# --- reinstalling the dependency by name sets its marker ---
run_chy install libm
assert_rc 0 'libm reinstalls by name'
assert_order 'libm'
assert_requested "$CHY_ROOT" libm

# --- a satisfied dependency is skipped entirely: the marker it earned
#     stays untouched through a later dependent install ---
run_chy install app
assert_rc 0 'app reinstall, libm satisfied'
assert_order 'app'
assert_requested "$CHY_ROOT" libm

# --- conflicts copied into the db verbatim, comments and blanks included ---
mkpkg "$CHY_ROOT" confy 1.0 usr/bin/confy-tool
printf '# rivals\n\nother-pkg\n' >"$CHY_ROOT/recipes/confy/conflicts"
run_chy install confy
assert_rc 0 'confy installs (its conflict is not installed, not needed)'
[ -f "$CHY_ROOT/db/installed/confy/conflicts" ] || fail 'conflicts not copied to db'
assert_eq "$(sha_of "$CHY_ROOT/db/installed/confy/conflicts")" \
    "$(sha_of "$CHY_ROOT/recipes/confy/conflicts")" 'conflicts copied verbatim'
assert_requested "$CHY_ROOT" confy

exit 0
