#!/bin/sh
# `chy version` prints its version string alone to stdout, exit 0. No
# arguments, -h and --help print usage to stdout, exit 0. Unknown verb
# and missing operand print usage to stderr, exit 2.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- version: one bare line on stdout ---
run_chy version
assert_rc 0 'chy version exits 0'
assert_empty_file "$ERR" 'version says nothing on stderr'
assert_eq "$(wc -l <"$OUT" | tr -d ' ')" '1' 'version prints exactly one line'
v=$(cat "$OUT")
[ -n "$v" ] || fail 'version string is empty'
case $v in
    'chy: '*) fail "version must be the bare string, got [$v]" ;;
esac

# --- no arguments: usage to stdout, exit 0 ---
run_chy
assert_rc 0 'bare chy exits 0'
[ -s "$OUT" ] || fail 'usage expected on stdout'
assert_empty_file "$ERR" 'usage goes to stdout, not stderr'

# --- -h and --help: same deal ---
run_chy -h
assert_rc 0 'chy -h exits 0'
[ -s "$OUT" ] || fail 'usage expected on stdout for -h'
assert_empty_file "$ERR"

run_chy --help
assert_rc 0 'chy --help exits 0'
[ -s "$OUT" ] || fail 'usage expected on stdout for --help'
assert_empty_file "$ERR"

# --- unknown verb: usage to stderr, exit 2, stdout silent ---
run_chy frobnicate
assert_rc 2 'unknown verb exits 2'
[ -s "$ERR" ] || fail 'usage expected on stderr for unknown verb'
assert_empty_file "$OUT" 'unknown verb prints nothing to stdout'

# --- missing operand: usage to stderr, exit 2 ---
run_chy install
assert_rc 2 'install without names exits 2'
[ -s "$ERR" ] || fail 'usage expected on stderr for bare install'
assert_empty_file "$OUT"

run_chy remove
assert_rc 2 'remove without names exits 2'
[ -s "$ERR" ] || fail 'usage expected on stderr for bare remove'
assert_empty_file "$OUT"

# `chy list` with no names is valid, not a missing operand
run_chy list
assert_rc 0 'bare list is a valid invocation'

exit 0
