#!/bin/sh
# the order line `-> order <names>` always prints (even for a single
# package) before any pipeline step. Empty needed set (everything
# requested is provided): no order line, install exits 0. Under
# --no-deps the line carries the remaining names in first-occurrence
# order, duplicates collapsed.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- single package still gets its order line, first on stdout ---
mkpkg "$CHY_ROOT" solo 1.0 usr/bin/solo-tool
run_chy install solo
assert_rc 0 'solo install'
assert_order_first 'solo'
file_has_line "$OUT" '+ solo 1.0_1'

# --- everything requested is provided: no order line, no stdout, exit 0 ---
printf 'hosta\nhostb\n' >"$CHY_ROOT/db/provided"
run_chy install hosta hostb
assert_rc 0 'an all-provided request succeeds doing nothing'
assert_no_order
assert_empty_file "$OUT" 'empty needed set prints nothing to stdout'
file_has_line "$ERR" 'chy: hosta: warning: provided by the host'
file_has_line "$ERR" 'chy: hostb: warning: provided by the host'
assert_not_installed "$CHY_ROOT" hosta
assert_not_installed "$CHY_ROOT" hostb

# --- --no-deps: duplicates collapse, first-occurrence order, resolution
#     skipped entirely (the unresolvable depends line never matters) ---
mkpkg "$CHY_ROOT" ndy 1.0 usr/bin/ndy-tool
mkpkg "$CHY_ROOT" ndx 1.0 usr/bin/ndx-tool
recipe_list "$CHY_ROOT" ndx depends ghost-dep
run_chy install --no-deps ndy ndx ndy
assert_rc 0 '--no-deps installs without resolving'
assert_order_first 'ndy ndx'
assert_eq "$(installed_seq)" 'ndy ndx' 'first-occurrence order, collapsed'
assert_installed "$CHY_ROOT" ndy 1.0 1
assert_installed "$CHY_ROOT" ndx 1.0 1
assert_not_installed "$CHY_ROOT" ghost-dep
# the db entry is identical to a resolved install's: depends still copied
[ -f "$CHY_ROOT/db/installed/ndx/depends" ] \
    || fail '--no-deps must still copy depends into the db'
file_has_line "$CHY_ROOT/db/installed/ndx/depends" 'ghost-dep'

# --- --no-deps still applies step 1: provided names skipped with warning ---
run_chy install --no-deps hosta ndy
assert_rc 0 'provided name skipped under --no-deps'
assert_order 'ndy'
file_has_line "$ERR" 'chy: hosta: warning: provided by the host'
assert_not_installed "$CHY_ROOT" hosta

exit 0
