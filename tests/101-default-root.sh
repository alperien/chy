#!/bin/sh
# unset or empty $CHY_ROOT means $HOME/.chy; no other location is
# ever consulted; two roots at different paths are fully independent.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- unset CHY_ROOT falls back to $HOME/.chy (never the real HOME) ---
home="$TMPD/home"
defroot="$home/.chy"
mkdir -p "$home"
mkpkg "$defroot" homer 1.0 usr/bin/homer-tool

run env -u CHY_ROOT HOME="$home" sh "$CHY" install homer
assert_rc 0 'install with CHY_ROOT unset uses HOME/.chy'
[ -f "$defroot/store/homer-1.0/usr/bin/homer-tool" ] \
    || fail 'store entry not under HOME/.chy'
assert_link "$defroot/usr/bin/homer-tool" '../../store/homer/usr/bin/homer-tool'
assert_installed "$defroot" homer 1.0 1

# --- empty CHY_ROOT falls back to the same default ---
run env CHY_ROOT='' HOME="$home" sh "$CHY" list
assert_rc 0 'empty CHY_ROOT means the default root'
assert_eq "$(cat "$OUT")" 'homer 1.0 1' 'empty CHY_ROOT sees HOME/.chy state'

# --- with CHY_ROOT set, HOME is never consulted ---
fakehome="$TMPD/fakehome"
mkdir -p "$fakehome"
mkpkg "$CHY_ROOT" iso 1.0 usr/bin/iso-tool
run env HOME="$fakehome" CHY_ROOT="$CHY_ROOT" sh "$CHY" install iso
assert_rc 0 'install into the explicit root'
assert_absent "$fakehome/.chy"
assert_installed "$CHY_ROOT" iso 1.0 1

# --- two roots at different paths are fully independent ---
rootb="$TMPD/rootb"
mkdir -p "$rootb"
snap_a=$(snap "$CHY_ROOT")

run_chy_root "$rootb" list
assert_rc 0 'a fresh root lists cleanly'
assert_empty_file "$OUT" 'a fresh root has nothing installed'

run_chy_root "$rootb" list iso
assert_rc 1 'root B does not know root A packages'
file_has_line "$ERR" 'chy: iso: error: not installed'

mkpkg "$rootb" bee 2.0 usr/bin/bee-tool
run_chy_root "$rootb" install bee
assert_rc 0 'install into root B'
assert_installed "$rootb" bee 2.0 1
assert_absent "$rootb/usr/bin/iso-tool"

assert_eq "$(snap "$CHY_ROOT")" "$snap_a" 'root A untouched by root B activity'
assert_absent "$CHY_ROOT/usr/bin/bee-tool"
run_chy_root "$rootb" list
assert_eq "$(cat "$OUT")" 'bee 2.0 1' 'root B sees only its own package'

exit 0
