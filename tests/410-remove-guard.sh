#!/bin/sh
# remove: the reverse-dependency guard. Removing a package that
# any other installed package's DB-RECORDED depends names fails with
# `chy: <name>: error: required by: <dependents, sorted, space-separated>`
# and stops. The guard reads the db, not recipes; makedepends never guard;
# a reinstall of a depended-on package is never guarded; the check happens
# at the moment each name is processed.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

mkpkg "$CHY_ROOT" liba 1.0 usr/bin/liba-tool
mkpkg "$CHY_ROOT" appx 1.0 usr/bin/appx-tool
mkpkg "$CHY_ROOT" appy 1.0 usr/bin/appy-tool
recipe_list "$CHY_ROOT" appx depends liba
recipe_list "$CHY_ROOT" appy depends liba
run_chy install appx appy
assert_rc 0 'appx and appy pull liba'
assert_order 'liba appx appy'

# --- guarded: pinned line, dependents sorted and space-separated ---
run_chy remove liba
assert_rc 1 'a depended-on package cannot be removed'
assert_eq "$(cat "$ERR")" 'chy: liba: error: required by: appx appy' \
    'exact pinned required-by line'
assert_installed "$CHY_ROOT" liba 1.0 1
assert_eq "$(cat "$CHY_ROOT/usr/bin/liba-tool")" \
    "$(pkg_content liba usr/bin/liba-tool)" 'liba untouched by the refusal'

# --- the failing name stops the run: later names are not processed ---
run_chy remove liba appx
assert_rc 1 'guard failure stops the run'
assert_eq "$(cat "$ERR")" 'chy: liba: error: required by: appx appy'
assert_installed "$CHY_ROOT" appx 1.0 1

# --- the guard reads db depends: dependents' recipes deleted, still fires ---
rm -rf "$CHY_ROOT/recipes/appx" "$CHY_ROOT/recipes/appy"
run_chy remove liba
assert_rc 1 'guard works from the db copy alone'
assert_eq "$(cat "$ERR")" 'chy: liba: error: required by: appx appy'

# --- reinstalling a depended-on package is NOT guarded ---
run_chy install liba
assert_rc 0 'reinstall replaces the old installation unguarded'
assert_installed "$CHY_ROOT" liba 1.0 1
assert_eq "$(cat "$CHY_ROOT/usr/bin/appx-tool")" \
    "$(pkg_content appx usr/bin/appx-tool)" 'dependents ride through the reinstall'

# --- checked at that moment: dependents first, then the dep, one run ---
run_chy remove appx appy liba
assert_rc 0 'once the dependents are gone the guard is silent'
assert_eq "$(removed_seq)" 'appx appy liba' 'plain remove keeps argument order'
assert_not_installed "$CHY_ROOT" liba
assert_not_installed "$CHY_ROOT" appx
assert_not_installed "$CHY_ROOT" appy

# --- makedepends never guard ---
mkpkg "$CHY_ROOT" mklib 1.0 usr/bin/mklib-tool
mkpkg "$CHY_ROOT" mkuser 1.0 usr/bin/mkuser-tool
recipe_list "$CHY_ROOT" mkuser makedepends mklib
run_chy install mkuser
assert_rc 0 'mkuser pulls its build tool'
assert_order 'mklib mkuser'
run_chy remove mklib
assert_rc 0 'a build-only dependency is removable'
file_has_line "$OUT" 'chy: mklib: removed 1.0 1'
assert_not_installed "$CHY_ROOT" mklib
assert_installed "$CHY_ROOT" mkuser 1.0 1

exit 0
