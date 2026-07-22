#!/bin/sh
# every name in the needed set needs a recipe, otherwise the smallest
# missing name is reported once as
# `chy: <requirer>: error: needs <name>, which has no recipe and is not
# provided`. <requirer> is `install` when the missing name was
# requested, else the smallest needed package that requires it. Exit 1,
# resolution fails before any pipeline step.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- requested name with no recipe: requirer is `install` ---
run_chy install ghost
assert_rc 1 'unknown requested name fails'
assert_eq "$(cat "$ERR")" \
    'chy: install: error: needs ghost, which has no recipe and is not provided' \
    'exact pinned line for a requested missing name'
assert_empty_file "$OUT" 'resolution failure prints nothing to stdout'

# --- missing dependency: the requiring package is named ---
mkpkg "$CHY_ROOT" appm 1.0 usr/bin/appm-tool
recipe_list "$CHY_ROOT" appm depends ghostdep
run_chy install appm
assert_rc 1 'missing dependency fails the resolution'
assert_eq "$(cat "$ERR")" \
    'chy: appm: error: needs ghostdep, which has no recipe and is not provided' \
    'exact pinned line naming the requirer'
assert_empty_file "$OUT"
assert_not_installed "$CHY_ROOT" appm
assert_no_store "$CHY_ROOT" appm 1.0

# --- two requirers: the smallest needed package that requires it wins ---
mkpkg "$CHY_ROOT" aa 1.0 usr/bin/aa-tool
mkpkg "$CHY_ROOT" bb 1.0 usr/bin/bb-tool
recipe_list "$CHY_ROOT" aa depends miss
recipe_list "$CHY_ROOT" bb depends miss
run_chy install bb aa
assert_rc 1
assert_eq "$(cat "$ERR")" \
    'chy: aa: error: needs miss, which has no recipe and is not provided' \
    'smallest requirer named, argument order irrelevant'
assert_not_installed "$CHY_ROOT" aa
assert_not_installed "$CHY_ROOT" bb

# --- several missing names: only the smallest is reported, once ---
mkpkg "$CHY_ROOT" multi 1.0 usr/bin/multi-tool
recipe_list "$CHY_ROOT" multi depends miss-b miss-a
run_chy install multi
assert_rc 1
assert_eq "$(cat "$ERR")" \
    'chy: multi: error: needs miss-a, which has no recipe and is not provided' \
    'smallest missing name, one line only'

# --- a missing name that is both requested and a dependency: requested
#     wins, the requirer is `install` ---
run_chy install appm ghostdep
assert_rc 1
assert_eq "$(cat "$ERR")" \
    'chy: install: error: needs ghostdep, which has no recipe and is not provided' \
    'requested-ness takes precedence in requirer selection'
assert_not_installed "$CHY_ROOT" appm

exit 0
