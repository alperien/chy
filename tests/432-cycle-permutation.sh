#!/bin/sh
# the cycle line is a function of the graph, not of recipe file layout.
# The equal-length cycles a -> b -> x -> a and a -> b -> y -> a share
# the prefix a -> b, and which branch the printed path takes must not
# depend on the order b's depends file lists x and y. The resolver
# byte-sorts the edge list, so both permutations print the byte-smaller
# branch x, identically.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

mkpkg "$CHY_ROOT" a 1.0 usr/bin/a-tool
mkpkg "$CHY_ROOT" b 1.0 usr/bin/b-tool
mkpkg "$CHY_ROOT" x 1.0 usr/bin/x-tool
mkpkg "$CHY_ROOT" y 1.0 usr/bin/y-tool
recipe_list "$CHY_ROOT" a depends b
recipe_list "$CHY_ROOT" x depends a
recipe_list "$CHY_ROOT" y depends a

want='chy: install: error: dependency cycle: a -> b -> x -> a'

# --- x listed before y ---
recipe_list "$CHY_ROOT" b depends x y
run_chy install a
assert_rc 1 'the cycle fails resolution (x listed first)'
line1=$(cat "$ERR")
assert_eq "$line1" "$want" 'the path walks the byte-smaller branch x'
assert_empty_file "$OUT" 'cycle error prints no order line, no pipeline'

# --- y listed before x: same graph, same line ---
recipe_list "$CHY_ROOT" b depends y x
run_chy install a
assert_rc 1 'the cycle fails resolution (y listed first)'
line2=$(cat "$ERR")
assert_eq "$line2" "$want" 'permuted depends order changes nothing'
assert_eq "$line2" "$line1" 'both runs print identical bytes'
assert_empty_file "$OUT"
assert_not_installed "$CHY_ROOT" a
assert_not_installed "$CHY_ROOT" b
assert_not_installed "$CHY_ROOT" x
assert_not_installed "$CHY_ROOT" y

exit 0
