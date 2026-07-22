#!/bin/sh
# duplicate command-line names collapse (first occurrence wins). A
# requested name listed in db/provided is skipped with the pinned
# warning, builds nothing, run exits 0. No other requested name is ever
# treated as satisfied: an installed name given on the command line
# rebuilds, its installed deps don't.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- duplicates collapse: one order entry, one build ---
mkpkg "$CHY_ROOT" dup 1.0 usr/bin/dup-tool
run_chy install dup dup dup
assert_rc 0 'duplicate names install once'
assert_order 'dup'
assert_eq "$(installed_seq)" 'dup' 'exactly one build for three mentions'
assert_installed "$CHY_ROOT" dup 1.0 1

# --- requested name in db/provided: pinned warning, nothing built ---
mkpkg "$CHY_ROOT" hosty 1.0 usr/bin/hosty-tool
stamp_builds "$CHY_ROOT" hosty "$TMPD"
printf 'hosty\n' >"$CHY_ROOT/db/provided"
run_chy install hosty
assert_rc 0 'a provided requested name is the host business, exit 0'
assert_eq "$(cat "$ERR")" 'chy: hosty: warning: provided by the host' \
    'exact warning, alone on stderr'
assert_empty_file "$OUT" 'skipped name joins nothing: no order, no pipeline'
assert_not_installed "$CHY_ROOT" hosty
assert_no_store "$CHY_ROOT" hosty 1.0
assert_absent "$TMPD/built-hosty"

# --- mixed with a buildable name: warning plus a normal install ---
mkpkg "$CHY_ROOT" realp 1.0 usr/bin/realp-tool
run_chy install hosty realp
assert_rc 0 'the rest of the request proceeds'
assert_order 'realp'
file_has_line "$ERR" 'chy: hosty: warning: provided by the host'
assert_installed "$CHY_ROOT" realp 1.0 1
assert_not_installed "$CHY_ROOT" hosty

# --- requested installed name IS rebuilt; its installed dep is not ---
mkpkg "$CHY_ROOT" libd 1.0 usr/bin/libd-tool
mkpkg "$CHY_ROOT" appd 1.0 usr/bin/appd-tool
recipe_list "$CHY_ROOT" appd depends libd
run_chy install appd
assert_rc 0 'appd pulls libd'
assert_order 'libd appd'
assert_installed "$CHY_ROOT" libd 1.0 1

stamp_builds "$CHY_ROOT" appd "$TMPD"
stamp_builds "$CHY_ROOT" libd "$TMPD"
run_chy install appd
assert_rc 0 'reinstall by name'
assert_order 'appd'
assert_eq "$(installed_seq)" 'appd' 'only the requested name rebuilds'
[ -f "$TMPD/built-appd" ] || fail 'appd build must run again on reinstall'
assert_absent "$TMPD/built-libd"
assert_installed "$CHY_ROOT" appd 1.0 1
assert_installed "$CHY_ROOT" libd 1.0 1

exit 0
