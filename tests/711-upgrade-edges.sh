#!/bin/sh
# upgrade edges: an all-current root upgrades to silence; a named
# current package skips silently, no order line; a provided outdated
# package is the host's business; a named recipe-gone package errors
# `no recipe` before any work, bare upgrade just warns and converges
# the rest; the `requested` marker survives both ways; a bumped
# recipe's new depends line gets pulled in and installed unmarked.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- (a) everything current: no output at all, exit 0 ---
mkpkg "$CHY_ROOT" cur 1.0 usr/bin/cur-tool
run_chy install cur
assert_rc 0 'cur installs'
stamp_builds "$CHY_ROOT" cur "$TMPD"
run_chy upgrade
assert_rc 0 'nothing outdated, exit 0'
assert_empty_file "$OUT" 'an empty target set prints nothing'
assert_empty_file "$ERR"
assert_absent "$TMPD/built-cur"

# --- (b) named but current: skipped silently, no order line ---
run_chy upgrade cur
assert_rc 0 'a current named package is already converged'
assert_no_order
assert_empty_file "$OUT" 'skipped silently'
assert_empty_file "$ERR"
assert_absent "$TMPD/built-cur"
assert_installed "$CHY_ROOT" cur 1.0 1

# --- (c) provided, installed, outdated: host warning, no rebuild ---
rb="$TMPD/root-prov"
mkdir -p "$rb"
mkpkg "$rb" hostlib 1.0 usr/bin/hostlib-tool
run_chy_root "$rb" install hostlib
assert_rc 0 'hostlib installs'
mkpkg "$rb" hostlib 2.0 usr/bin/hostlib-tool
stamp_builds "$rb" hostlib "$TMPD"
printf 'hostlib\n' >"$rb/db/provided"
run_chy_root "$rb" upgrade
assert_rc 0 'the host business never fails the run'
assert_eq "$(cat "$ERR")" 'chy: hostlib: warning: provided by the host' \
    'exact host warning, alone on stderr'
assert_empty_file "$OUT" 'a provided name joins nothing: no order, no build'
assert_absent "$TMPD/built-hostlib"
assert_installed "$rb" hostlib 1.0 1

# --- (d) recipe gone: named errors before any work, bare warns ---
rc="$TMPD/root-gone"
mkdir -p "$rc"
mkpkg "$rc" gone 1.0 usr/bin/gone-tool
mkpkg "$rc" okpkg 1.0 usr/bin/okpkg-tool
run_chy_root "$rc" install gone okpkg
assert_rc 0 'gone and okpkg install'
mkpkg "$rc" okpkg 2.0 usr/bin/okpkg-tool
stamp_builds "$rc" okpkg "$TMPD"
rm -rf "$rc/recipes/gone"

run_chy_root "$rc" upgrade gone
assert_rc 1 'a named recipe-gone package is an error'
assert_eq "$(cat "$ERR")" 'chy: gone: error: no recipe' 'exact no-recipe error'
assert_empty_file "$OUT"
assert_installed "$rc" gone 1.0 1

# names are validated before any work: the outdated companion is untouched
run_chy_root "$rc" upgrade okpkg gone
assert_rc 1 'one bad name and nothing is touched'
assert_eq "$(cat "$ERR")" 'chy: gone: error: no recipe'
assert_empty_file "$OUT" 'no order line: no work began'
assert_absent "$TMPD/built-okpkg"
assert_installed "$rc" okpkg 1.0 1

# bare upgrade: the same package only warns, the rest converge
run_chy_root "$rc" upgrade
assert_rc 0 'bare upgrade skips the recipe-gone package'
assert_eq "$(cat "$ERR")" 'chy: gone: warning: no recipe' 'exact warning'
assert_order_first 'okpkg'
file_has_line "$OUT" '+ okpkg 2.0_1'
assert_installed "$rc" okpkg 2.0 1
[ -f "$TMPD/built-okpkg" ] || fail 'okpkg must rebuild on bare upgrade'
assert_installed "$rc" gone 1.0 1

# --- (e) markers: a NAMED upgrade of a dependency never marks it ---
rd="$TMPD/root-mark"
mkdir -p "$rd"
mkpkg "$rd" libp 1.0 usr/bin/libp-tool
mkpkg "$rd" appq 1.0 usr/bin/appq-tool
recipe_list "$rd" appq depends libp
run_chy_root "$rd" install appq
assert_rc 0 'appq pulls libp'
assert_requested "$rd" appq
assert_not_requested "$rd" libp

mkpkg "$rd" libp 2.0 usr/bin/libp-tool
run_chy_root "$rd" upgrade libp
assert_rc 0 'named upgrade of the dependency'
assert_order 'libp'
file_has_line "$OUT" '+ libp 2.0_1'
assert_installed "$rd" libp 2.0 1
assert_not_requested "$rd" libp
run_chy_root "$rd" why libp
assert_rc 0 'why libp'
assert_eq "$(cat "$OUT")" 'libp: required by: appq' \
    'an upgraded dependency shows no requested line'

# --- (e)+(f) requested survives; a new depends line is pulled in ---
mkpkg "$rd" appq 2.0 usr/bin/appq-tool
recipe_list "$rd" appq depends libp newdep
mkpkg "$rd" newdep 1.0 usr/bin/newdep-tool
run_chy_root "$rd" upgrade
assert_rc 0 'upgrade converges appq and pulls its new dependency'
assert_order_first 'newdep appq'
assert_eq "$(installed_seq)" 'newdep appq' 'libp is current and satisfied'
assert_empty_file "$ERR"
assert_installed "$rd" appq 2.0 1
assert_installed "$rd" newdep 1.0 1
assert_requested "$rd" appq
assert_not_requested "$rd" newdep
assert_not_requested "$rd" libp
run_chy_root "$rd" why appq
assert_rc 0 'why appq'
assert_eq "$(cat "$OUT")" 'appq: requested' \
    'an upgraded requested package stays requested'
run_chy_root "$rd" why newdep
assert_rc 0 'why newdep'
assert_eq "$(cat "$OUT")" 'newdep: required by: appq' \
    'the pulled-in dependency arrives unmarked'

exit 0
