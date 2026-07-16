#!/bin/sh
# a dependency cycle is a resolution error. The line names the
# cycle containing the smallest name on any cycle, printed starting from
# that name (x -> y means "x depends on y"), first name repeated at the
# end, ASCII arrows: `chy: install: error: dependency cycle: a -> b -> a`.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- two-cycle: a <-> b ---
mkpkg "$CHY_ROOT" a 1.0 usr/bin/a-tool
mkpkg "$CHY_ROOT" b 1.0 usr/bin/b-tool
recipe_list "$CHY_ROOT" a depends b
recipe_list "$CHY_ROOT" b depends a
run_chy install a
assert_rc 1 'a two-cycle fails resolution'
assert_eq "$(cat "$ERR")" 'chy: install: error: dependency cycle: a -> b -> a' \
    'exact pinned two-cycle line'
assert_empty_file "$OUT" 'cycle error prints no order line, no pipeline'
assert_not_installed "$CHY_ROOT" a
assert_not_installed "$CHY_ROOT" b

# --- entering the cycle from the other member changes nothing: the line
#     still starts at the smallest member ---
run_chy install b
assert_rc 1
assert_eq "$(cat "$ERR")" 'chy: install: error: dependency cycle: a -> b -> a' \
    'start rule is smallest-on-cycle, not the requested name'

# --- three-cycle reached through an outside package, one edge being a
#     makedepends (edges are the union): x -> y -> z -> x ---
d2="$TMPD/tri"
mkdir -p "$d2"
mkpkg "$d2" top 1.0 usr/bin/top-tool
mkpkg "$d2" x 1.0 usr/bin/x-tool
mkpkg "$d2" y 1.0 usr/bin/y-tool
mkpkg "$d2" z 1.0 usr/bin/z-tool
recipe_list "$d2" top depends z
recipe_list "$d2" x depends y
recipe_list "$d2" y depends z
recipe_list "$d2" z makedepends x
run_chy_root "$d2" install top
assert_rc 1 'a three-cycle fails resolution'
assert_eq "$(cat "$ERR")" 'chy: install: error: dependency cycle: x -> y -> z -> x' \
    'cycle printed from its smallest member, walked along the edges'
assert_empty_file "$OUT"
assert_not_installed "$d2" top
assert_not_installed "$d2" x
assert_not_installed "$d2" y
assert_not_installed "$d2" z

exit 0
