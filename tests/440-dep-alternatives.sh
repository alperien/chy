#!/bin/sh
# kiss-style dependency alternatives: a depends token `a|b` is satisfied
# by ANY installed or provided alternative; otherwise the FIRST
# alternative with a recipe is chosen and built; with no recipe anywhere
# the failure names every alternative. The remove guard reads a db
# `a|b` line conservatively: it blocks removing BOTH names. A version
# constraint on a depends line (`pkg >=1.2`) resolves pkg (the
# constraint is decoration; first_field drops it).
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- only b has a recipe: b gets installed for `a|b` ---
mkpkg "$CHY_ROOT" bonly 2.0 usr/bin/bonly-tool
mkpkg "$CHY_ROOT" needb 1.0 usr/bin/needb-tool
recipe_list "$CHY_ROOT" needb depends 'a|bonly'
run_chy install needb
assert_rc 0 'install with a|b where only b has a recipe'
assert_installed "$CHY_ROOT" bonly 2.0 1
assert_installed "$CHY_ROOT" needb 1.0 1
assert_order 'bonly needb'

# --- a already installed: `a|b` is satisfied, nothing new builds ---
mkpkg "$CHY_ROOT" aready 1.0 usr/bin/aready-tool
run_chy install aready
assert_rc 0 'aready installs first'
mkpkg "$CHY_ROOT" bside 1.0 usr/bin/bside-tool
mkpkg "$CHY_ROOT" needab 1.0 usr/bin/needab-tool
recipe_list "$CHY_ROOT" needab depends 'aready|bside'
run_chy install needab
assert_rc 0 'installed alternative satisfies a|b'
assert_installed "$CHY_ROOT" needab 1.0 1
assert_not_installed "$CHY_ROOT" bside
assert_absent "$CHY_ROOT/store/bside-1.0"

# --- both have recipes: the FIRST alternative is chosen ---
mkpkg "$CHY_ROOT" firstalt 1.0 usr/bin/firstalt-tool
mkpkg "$CHY_ROOT" secondalt 1.0 usr/bin/secondalt-tool
mkpkg "$CHY_ROOT" needfirst 1.0 usr/bin/needfirst-tool
recipe_list "$CHY_ROOT" needfirst depends 'firstalt|secondalt'
run_chy install needfirst
assert_rc 0 'first alternative chosen'
assert_installed "$CHY_ROOT" firstalt 1.0 1
assert_not_installed "$CHY_ROOT" secondalt

# --- provided alternative satisfies too ---
mkpkg "$CHY_ROOT" needsprov 1.0 usr/bin/needsprov-tool
recipe_list "$CHY_ROOT" needsprov depends 'ghostvm|needsprov-dep'
mkpkg "$CHY_ROOT" needsprov-dep 1.0 usr/bin/npdep-tool
mkdir -p "$CHY_ROOT/db"
printf 'ghostvm\n' >>"$CHY_ROOT/db/provided"
run_chy install needsprov
assert_rc 0 'a provided alternative satisfies a|b'
assert_not_installed "$CHY_ROOT" needsprov-dep

# --- no alternative buildable: failure names all of them ---
mkpkg "$CHY_ROOT" neednone 1.0 usr/bin/neednone-tool
recipe_list "$CHY_ROOT" neednone depends 'nope1|nope2'
snap1=$(snap "$CHY_ROOT")
run_chy install neednone
assert_rc 1 'an unsatisfiable alternative set fails'
file_has "$ERR" 'nope1|nope2'
file_has "$ERR" 'no alternative is installed, provided, or has a recipe'
assert_eq "$(snap "$CHY_ROOT")" "$snap1" 'root untouched'

# --- a malformed alternative fails like a malformed name ---
mkpkg "$CHY_ROOT" needbad 1.0 usr/bin/needbad-tool
recipe_list "$CHY_ROOT" needbad depends 'ok|bad/name'
run_chy install needbad
assert_rc 1 'a malformed alternative is an invalid dependency name'
file_has "$ERR" 'invalid dependency name: ok|bad/name'

# --- remove guard: db `a|b` blocks removing either alternative ---
mkpkg "$CHY_ROOT" g_a 1.0 usr/bin/g_a-tool
mkpkg "$CHY_ROOT" g_b 1.0 usr/bin/g_b-tool
mkpkg "$CHY_ROOT" g_user 1.0 usr/bin/g_user-tool
printf 'set -eu\nmkdir -p "$1$CHY_ROOT/usr/bin"\nprintf x >"$1$CHY_ROOT/usr/bin/g_user-tool"\n' \
    >"$CHY_ROOT/recipes/g_user/build"
run_chy install g_a g_b
assert_rc 0 'both alternatives install'
# record g_user with a db depends line `g_a|g_b` (as if installed when
# only one was available; the db keeps the raw token)
run_chy install g_user
assert_rc 0 'g_user installs'
printf 'g_a|g_b\n' >"$CHY_ROOT/db/installed/g_user/depends"
run_chy remove g_a
assert_rc 1 'removing alternative a is blocked by the a|b guard'
file_has "$ERR" 'g_a: error: required by: g_user'
run_chy remove g_b
assert_rc 1 'removing alternative b is blocked too'
# once the user is gone, both alternatives remove cleanly
run_chy remove g_user g_a g_b
assert_rc 0 'removing the user first frees both alternatives'
assert_not_installed "$CHY_ROOT" g_a
assert_not_installed "$CHY_ROOT" g_b
assert_not_installed "$CHY_ROOT" g_user

# --- version constraints: `pkg >=1.2` resolves pkg, constraint ignored ---
mkpkg "$CHY_ROOT" vchild 1.5 usr/bin/vchild-tool
mkpkg "$CHY_ROOT" vparent 1.0 usr/bin/vparent-tool
recipe_list "$CHY_ROOT" vparent depends 'vchild >=1.2'
run_chy install vparent
assert_rc 0 'a version-constrained depends resolves the named package'
assert_installed "$CHY_ROOT" vchild 1.5 1
assert_order 'vchild vparent'
# and the db guard sees the bare name through the constraint
run_chy remove vchild
assert_rc 1 'the guard sees vchild through the >= decoration'
file_has "$ERR" 'required by: vparent'

exit 0
