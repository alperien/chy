#!/bin/sh
# list. No names: every installed package as
# "<name> <version> <revision>", sorted by name, exit 0, empty output
# for an empty root. With names: processed in the order given, a
# missing name puts "chy: <name>: error: not installed" on stderr and
# forces exit 1, the installed ones still print.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- empty root: exit 0, byte-empty output ---
run_chy list
assert_rc 0 'empty root lists cleanly'
assert_empty_file "$OUT" 'no packages, no stdout'
assert_empty_file "$ERR" 'no packages, no stderr'

# install out of alphabetical order to catch insertion-order listings
mkpkg "$CHY_ROOT" bbb '2.0 5' usr/bin/bbb-tool
run_chy install bbb
assert_rc 0 'bbb install'
mkpkg "$CHY_ROOT" aaa 1.0 usr/bin/aaa-tool
run_chy install aaa
assert_rc 0 'aaa install'

# --- no names: sorted by name, exact lines ---
run_chy list
assert_rc 0
assert_eq "$(cat "$OUT")" "$(printf 'aaa 1.0 1\nbbb 2.0 5')" \
    'exact sorted listing'
assert_empty_file "$ERR"

# --- names: processed in the order given ---
run_chy list bbb aaa
assert_rc 0
assert_eq "$(cat "$OUT")" "$(printf 'bbb 2.0 5\naaa 1.0 1')" \
    'named listing preserves argument order'

# --- a missing name: exact stderr line, exit 1, others still printed ---
run_chy list aaa ghost bbb
assert_rc 1 'any missing name forces exit 1'
assert_eq "$(cat "$OUT")" "$(printf 'aaa 1.0 1\nbbb 2.0 5')" \
    'installed names still print around the missing one'
assert_eq "$(cat "$ERR")" 'chy: ghost: error: not installed' \
    'exact not-installed error'

# --- all names missing: every error reported, in order ---
run_chy list ghost1 ghost2
assert_rc 1
assert_empty_file "$OUT" 'nothing installed to print'
assert_eq "$(cat "$ERR")" \
    "$(printf 'chy: ghost1: error: not installed\nchy: ghost2: error: not installed')" \
    'all missing names reported in order'

exit 0
