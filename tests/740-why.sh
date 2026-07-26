#!/bin/sh
# why: explain why each named package is installed, stdout, db only
# (never recipes). A `requested` marker prints `<name>: requested`;
# installed dependents print
# `<name>: required by: <names, byte-sorted, space-separated>`,
# byte-for-byte the list the remove guard refuses with; both hold, both
# lines print, requested first; neither means the orphan line. Names
# process like list: all of them, in the order given; an invalid or
# not-installed name errors on stderr, exit 1, the rest still print.
# Zero names or an unknown flag is usage, exit 2.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# app and tool are requested; both depend on lib, which arrives unmarked
mkpkg "$CHY_ROOT" lib 1.0 usr/bin/lib-tool
mkpkg "$CHY_ROOT" app 1.0 usr/bin/app-tool
mkpkg "$CHY_ROOT" tool 1.0 usr/bin/tool-tool
recipe_list "$CHY_ROOT" app depends lib
recipe_list "$CHY_ROOT" tool depends lib
run_chy install app tool
assert_rc 0 'app and tool pull lib'
assert_order 'lib app tool'
assert_not_requested "$CHY_ROOT" lib

# --- requested only: exactly the one line ---
run_chy why app
assert_rc 0 'why app'
assert_eq "$(cat "$OUT")" 'app: requested' 'exact requested line'
assert_empty_file "$ERR" 'why says nothing on stderr for installed names'

# --- required only: dependents byte-sorted, space-separated ---
run_chy why lib
assert_rc 0 'why lib'
assert_eq "$(cat "$OUT")" 'lib: required by: app tool' \
    'exact required-by line, dependents byte-sorted'
assert_empty_file "$ERR"

# --- byte-for-byte the list the remove guard refuses with ---
run_chy remove lib
assert_rc 1 'lib is guarded'
assert_eq "$(cat "$ERR")" 'chy: lib: error: required by: app tool' \
    'why and the guard share one list'
assert_installed "$CHY_ROOT" lib 1.0 1

# --- names processed in the order given ---
run_chy why tool app
assert_rc 0 'why tool app'
assert_eq "$(cat "$OUT")" "$(printf 'tool: requested\napp: requested')" \
    'argument order preserved'

# --- a failing name sets exit 1; the rest still print ---
run_chy why app nosuch lib
assert_rc 1 'any bad name forces exit 1'
assert_eq "$(cat "$OUT")" \
    "$(printf 'app: requested\nlib: required by: app tool')" \
    'installed names still print around the missing one'
assert_eq "$(cat "$ERR")" 'chy: nosuch: error: not installed' \
    'exact not-installed error'

# --- an illegal name: pinned error, exit 1 ---
run_chy why 'bad!name'
assert_rc 1 'an illegal name fails'
assert_empty_file "$OUT" 'nothing to explain'
assert_eq "$(cat "$ERR")" 'chy: bad!name: error: invalid package name' \
    'exact invalid-name error'

# --- both requested and required: both lines, requested first ---
run_chy install lib
assert_rc 0 'reinstalling lib by name marks it'
run_chy why lib
assert_rc 0 'why lib, now marked'
assert_eq "$(cat "$OUT")" \
    "$(printf 'lib: requested\nlib: required by: app tool')" \
    'both lines, requested first'

# --- orphan: unmarked, nothing requires it ---
mkpkg "$CHY_ROOT" loner 1.0 usr/bin/loner-tool
mkpkg "$CHY_ROOT" parent 1.0 usr/bin/parent-tool
recipe_list "$CHY_ROOT" parent depends loner
run_chy install parent
assert_rc 0 'parent pulls loner'
run_chy remove parent
assert_rc 0 'parent removed, loner left behind'
run_chy why loner
assert_rc 0 'why loner'
assert_eq "$(cat "$OUT")" \
    'loner: orphan (not requested, nothing requires it)' \
    'exact orphan line'
assert_empty_file "$ERR"

# --- reads the db only: recipes gone, why still answers ---
rm -rf "$CHY_ROOT/recipes"
run_chy why lib
assert_rc 0 'why works without recipes'
assert_eq "$(cat "$OUT")" \
    "$(printf 'lib: requested\nlib: required by: app tool')" \
    'db-only answer unchanged'

# --- zero names / unknown flag: usage to stderr, exit 2 ---
run_chy why
assert_rc 2 'why without names is a usage error'
[ -s "$ERR" ] || fail 'usage expected on stderr for bare why'
assert_empty_file "$OUT"

run_chy why -x
assert_rc 2 'unknown flag is a usage error'
[ -s "$ERR" ] || fail 'usage expected on stderr for why -x'
assert_empty_file "$OUT"

exit 0
