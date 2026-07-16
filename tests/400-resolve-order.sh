#!/bin/sh
# /the needed set is ordered as the unique smallest valid
# sequence over the union of depends and makedepends edges - repeatedly
# emit the smallest name whose kept dependencies have all been emitted.
# Argument order is irrelevant; the order line is printed to stdout before
# any pipeline step and the builds run in exactly that sequence.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- an order no argument order can produce: a depends z, b standalone.
#     `install a b` must interleave the pulled dependency: b z a. ---
mkpkg "$CHY_ROOT" a 1.0 usr/bin/a-tool
mkpkg "$CHY_ROOT" b 1.0 usr/bin/b-tool
mkpkg "$CHY_ROOT" z 1.0 usr/bin/z-tool
recipe_list "$CHY_ROOT" a depends z

run_chy install a b
assert_rc 0 'a and b install with the pulled dependency z'
assert_order_first 'b z a'
assert_eq "$(installed_seq)" 'b z a' 'builds run in the printed order'
assert_installed "$CHY_ROOT" a 1.0 1
assert_installed "$CHY_ROOT" b 1.0 1
assert_installed "$CHY_ROOT" z 1.0 1

# --- diamond: dtop -> {left,right} -> base, requested by the top alone ---
d2="$TMPD/diamond"
mkdir -p "$d2"
mkpkg "$d2" dtop 1.0 usr/bin/dtop-tool
mkpkg "$d2" left 1.0 usr/bin/left-tool
mkpkg "$d2" right 1.0 usr/bin/right-tool
mkpkg "$d2" base 1.0 usr/bin/base-tool
recipe_list "$d2" dtop depends left right
recipe_list "$d2" left depends base
recipe_list "$d2" right depends base

run_chy_root "$d2" install dtop
assert_rc 0 'diamond resolves'
assert_order_first 'base left right dtop'
assert_eq "$(installed_seq)" 'base left right dtop' 'diamond builds in order'
assert_installed "$d2" base 1.0 1
assert_installed "$d2" left 1.0 1
assert_installed "$d2" right 1.0 1
assert_installed "$d2" dtop 1.0 1

# --- makedepends-only edges order builds too: byte order alone would put
#     aa-app first; the edge forces its build tool ahead of it ---
d3="$TMPD/mkedge"
mkdir -p "$d3"
mkpkg "$d3" aa-app 1.0 usr/bin/aa-app-tool
mkpkg "$d3" zz-tool 1.0 usr/bin/zz-tool-tool
recipe_list "$d3" aa-app makedepends zz-tool

run_chy_root "$d3" install aa-app
assert_rc 0 'makedepends pulled and ordered'
assert_order_first 'zz-tool aa-app'
assert_eq "$(installed_seq)" 'zz-tool aa-app' 'the makedepends edge builds the tool first'
assert_installed "$d3" zz-tool 1.0 1
assert_installed "$d3" aa-app 1.0 1

exit 0
