#!/bin/sh
# resolution-time conflicts. A needed package's recipe
# conflicts naming an installed package, an installed package's
# DB-RECORDED conflicts naming a needed package (the recipe may be long
# gone), and needed-vs-needed pairs - every violating pair prints one
# pinned line, sorted by <name> then <other>, then exit 1 before any
# pipeline step.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- needed vs installed, via the needed package's recipe ---
mkpkg "$CHY_ROOT" victim 1.0 usr/bin/victim-tool
run_chy install victim
assert_rc 0 'victim installs'
mkpkg "$CHY_ROOT" attacker 1.0 usr/bin/attacker-tool
recipe_list "$CHY_ROOT" attacker conflicts victim
stamp_builds "$CHY_ROOT" attacker "$TMPD"
snap0=$(snap "$CHY_ROOT")
run_chy install attacker
assert_rc 1 'conflict with an installed package fails resolution'
assert_eq "$(cat "$ERR")" 'chy: attacker: error: conflicts with installed victim' \
    'exact pinned needed-vs-installed line'
assert_empty_file "$OUT" 'conflicts abort before ordering and pipeline'
assert_absent "$TMPD/built-attacker"
assert_eq "$(snap "$CHY_ROOT")" "$snap0" 'root untouched by the refused install'
assert_not_installed "$CHY_ROOT" attacker

# --- installed vs needed, via THE DB COPY: recipe deleted after install ---
mkpkg "$CHY_ROOT" confpkg 1.0 usr/bin/confpkg-tool
recipe_list "$CHY_ROOT" confpkg conflicts rival
run_chy install confpkg
assert_rc 0 'conflicts naming a not-installed, not-needed name never blocks'
[ -f "$CHY_ROOT/db/installed/confpkg/conflicts" ] \
    || fail 'db copy of conflicts missing after install'
rm -rf "$CHY_ROOT/recipes/confpkg"
mkpkg "$CHY_ROOT" rival 1.0 usr/bin/rival-tool
run_chy install rival
assert_rc 1 'db-recorded conflicts fire with the recipe gone'
assert_eq "$(cat "$ERR")" 'chy: rival: error: conflicts with installed confpkg' \
    '<name> is the needed package, <other> the installed one'
assert_not_installed "$CHY_ROOT" rival
assert_installed "$CHY_ROOT" confpkg 1.0 1

# --- needed vs needed: the also-in-this-install line ---
mkpkg "$CHY_ROOT" pkg1 1.0 usr/bin/pkg1-tool
mkpkg "$CHY_ROOT" pkg2 1.0 usr/bin/pkg2-tool
recipe_list "$CHY_ROOT" pkg1 conflicts pkg2
run_chy install pkg1 pkg2
assert_rc 1 'two conflicting needed packages cannot install together'
assert_eq "$(cat "$ERR")" 'chy: pkg1: error: conflicts with pkg2, also in this install' \
    'exact pinned needed-vs-needed line'
assert_not_installed "$CHY_ROOT" pkg1
assert_not_installed "$CHY_ROOT" pkg2

# --- multiple violations: all printed, pairs sorted by <name> then <other> ---
d2="$TMPD/multi"
mkdir -p "$d2"
mkpkg "$d2" inst1 1.0 usr/bin/inst1-tool
recipe_list "$d2" inst1 conflicts nc
mkpkg "$d2" inst2 1.0 usr/bin/inst2-tool
run_chy_root "$d2" install inst1 inst2
assert_rc 0 'the installed pair goes in clean'
mkpkg "$d2" na 1.0 usr/bin/na-tool
recipe_list "$d2" na conflicts inst2 inst1
mkpkg "$d2" nb 1.0 usr/bin/nb-tool
recipe_list "$d2" nb conflicts nc
mkpkg "$d2" nc 1.0 usr/bin/nc-tool
run_chy_root "$d2" install na nb nc
assert_rc 1 'every violating pair reported'
assert_eq "$(cat "$ERR")" "$(printf '%s\n%s\n%s\n%s' \
    'chy: na: error: conflicts with installed inst1' \
    'chy: na: error: conflicts with installed inst2' \
    'chy: nb: error: conflicts with nc, also in this install' \
    'chy: nc: error: conflicts with installed inst1')" \
    'all violations, sorted by name then other'
assert_not_installed "$d2" na
assert_not_installed "$d2" nb
assert_not_installed "$d2" nc
assert_installed "$d2" inst1 1.0 1
assert_installed "$d2" inst2 1.0 1

exit 0
