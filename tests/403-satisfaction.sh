#!/bin/sh
# a walked dependency is satisfied (added to nothing, subtree
# not entered) when already installed or listed in db/provided. A dep
# that IS being built pulls its own makedepends like any dependency.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- installed dependency: not rebuilt, not in the order ---
mkpkg "$CHY_ROOT" libq 1.0 usr/bin/libq-tool
run_chy install libq
assert_rc 0 'libq installs first'
mkpkg "$CHY_ROOT" appq 1.0 usr/bin/appq-tool
recipe_list "$CHY_ROOT" appq depends libq
stamp_builds "$CHY_ROOT" libq "$TMPD"
run_chy install appq
assert_rc 0 'appq installs over the satisfied dep'
assert_order 'appq'
assert_eq "$(installed_seq)" 'appq' 'satisfied dep never rebuilds'
assert_absent "$TMPD/built-libq"
assert_installed "$CHY_ROOT" libq 1.0 1

# --- provided dependency: not built, needs no recipe, and no warning
#     (the host warning belongs to requested names only) ---
mkpkg "$CHY_ROOT" appv 1.0 usr/bin/appv-tool
recipe_list "$CHY_ROOT" appv depends hostlib
printf 'hostlib\n' >"$CHY_ROOT/db/provided"
run_chy install appv
assert_rc 0 'a provided dependency satisfies the walk'
assert_order 'appv'
assert_empty_file "$ERR" 'no warning for a provided dependency'
assert_installed "$CHY_ROOT" appv 1.0 1
assert_not_installed "$CHY_ROOT" hostlib

# --- a dep being built pulls its makedepends transitively ---
d2="$TMPD/mkpull"
mkdir -p "$d2"
mkpkg "$d2" app3 1.0 usr/bin/app3-tool
mkpkg "$d2" libb 1.0 usr/bin/libb-tool
mkpkg "$d2" zzmk 1.0 usr/bin/zzmk-tool
recipe_list "$d2" app3 depends libb
recipe_list "$d2" libb makedepends zzmk
run_chy_root "$d2" install app3
assert_rc 0 'dep under build pulls its makedepends'
assert_order 'zzmk libb app3'
assert_eq "$(installed_seq)" 'zzmk libb app3' 'makedepends built before its user'
assert_installed "$d2" zzmk 1.0 1
assert_installed "$d2" libb 1.0 1
assert_installed "$d2" app3 1.0 1

# --- satisfied dep: subtree not entered, so an unresolvable makedepends
#     added to its recipe after the fact never matters ---
recipe_list "$d2" libb makedepends ghost-mk
mkpkg "$d2" app4 1.0 usr/bin/app4-tool
recipe_list "$d2" app4 depends libb
run_chy_root "$d2" install app4
assert_rc 0 'satisfied dep subtree is not entered'
assert_order 'app4'
assert_not_installed "$d2" ghost-mk

exit 0
