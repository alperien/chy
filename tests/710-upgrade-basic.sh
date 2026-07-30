#!/bin/sh
# upgrade: no names means every outdated package reinstalls to its
# recipe version, resolved and ordered like install (deps first), each
# printing the normal completion line. Upgraded packages keep their
# `requested` marker; `why` reads the result. The named form validates
# every name before any work; a named current package skips silently;
# an empty target set prints nothing, exit 0.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

mkpkg "$CHY_ROOT" lib 1.0 usr/bin/lib-tool
mkpkg "$CHY_ROOT" app 1.0 usr/bin/app-tool
recipe_list "$CHY_ROOT" app depends lib
stamp_builds "$CHY_ROOT" lib "$TMPD"
stamp_builds "$CHY_ROOT" app "$TMPD"

run_chy install app
assert_rc 0 'app pulls lib'
assert_order_first 'lib app'
assert_requested "$CHY_ROOT" app
assert_not_requested "$CHY_ROOT" lib

# --- nothing outdated: no output, exit 0, no build runs ---
rm -f "$TMPD/built-lib" "$TMPD/built-app"
run_chy upgrade
assert_rc 0 'nothing to do is success'
assert_empty_file "$OUT" 'an empty target set prints nothing'
assert_empty_file "$ERR"
assert_absent "$TMPD/built-lib"
assert_absent "$TMPD/built-app"

# --- only the dependency bumped: lib reinstalls, app is untouched ---
printf '1.1\n' >"$CHY_ROOT/recipes/lib/version"
rm -f "$TMPD/built-lib" "$TMPD/built-app"
run_chy upgrade
assert_rc 0 'upgrade converges lib'
assert_order_first 'lib'
file_has_line "$OUT" '+ lib 1.1_1'
assert_eq "$(count_matches '^+ app ' "$OUT")" 0 'app is current: not rebuilt'
assert_empty_file "$ERR"
[ -f "$TMPD/built-lib" ] || fail 'the lib build must run'
assert_absent "$TMPD/built-app"
assert_installed "$CHY_ROOT" lib 1.1 1
assert_installed "$CHY_ROOT" app 1.0 1
assert_requested "$CHY_ROOT" app
assert_not_requested "$CHY_ROOT" lib

run_chy outdated
assert_rc 0 'outdated after upgrade exits 0'
assert_empty_file "$OUT" 'the root matches the default repo again'
run_chy doctor
assert_rc 0 'doctor after upgrade'
assert_eq "$(cat "$OUT")" 'doctor: clean' 'the root is clean'

# --- both outdated: dependency order, markers preserved, why agrees ---
printf '1.2\n' >"$CHY_ROOT/recipes/lib/version"
printf '2.0\n' >"$CHY_ROOT/recipes/app/version"
run_chy upgrade
assert_rc 0 'both converge'
assert_order_first 'lib app'
assert_eq "$(installed_seq)" 'lib app' 'the dependency rebuilds before its dependent'
file_has_line "$OUT" '+ lib 1.2_1'
file_has_line "$OUT" '+ app 2.0_1'
assert_installed "$CHY_ROOT" lib 1.2 1
assert_installed "$CHY_ROOT" app 2.0 1
assert_requested "$CHY_ROOT" app
assert_not_requested "$CHY_ROOT" lib

run_chy why app
assert_rc 0 'why app'
assert_eq "$(cat "$OUT")" 'app: requested' 'app keeps its marker through upgrade'
run_chy why lib
assert_rc 0 'why lib'
assert_eq "$(cat "$OUT")" 'lib: required by: app' 'lib is still only a dependency'

run_chy outdated
assert_rc 0
assert_empty_file "$OUT" 'nothing outdated after the double upgrade'
run_chy doctor
assert_rc 0 'doctor stays clean'

# --- named form: a name that is not installed is the pinned error ---
run_chy upgrade nosuch
assert_rc 1 'unknown name fails'
assert_eq "$(cat "$ERR")" 'chy: nosuch: error: not installed' 'the pinned error, alone'
assert_empty_file "$OUT"

# --- every name is validated before any work begins ---
printf '1.3\n' >"$CHY_ROOT/recipes/lib/version"
rm -f "$TMPD/built-lib" "$TMPD/built-app"
run_chy upgrade lib nosuch
assert_rc 1 'one bad name fails the whole invocation'
assert_eq "$(cat "$ERR")" 'chy: nosuch: error: not installed' 'only the bad name errors'
assert_empty_file "$OUT" 'nothing is touched, not even the order line'
assert_absent "$TMPD/built-lib"
assert_installed "$CHY_ROOT" lib 1.2 1

run_chy upgrade aaa-none zzz-none
assert_rc 1 'a bad name aborts the invocation before any work'
file_has_line "$ERR" 'chy: aaa-none: error: not installed'
assert_empty_file "$OUT"

# --- named form: only the named package upgrades ---
rm -f "$TMPD/built-lib" "$TMPD/built-app"
run_chy upgrade lib
assert_rc 0 'named upgrade'
assert_order_first 'lib'
file_has_line "$OUT" '+ lib 1.3_1'
assert_eq "$(count_matches '^+ app ' "$OUT")" 0 'app was not named'
assert_absent "$TMPD/built-app"
assert_installed "$CHY_ROOT" lib 1.3 1

# --- a named package that is current is skipped silently ---
run_chy upgrade lib
assert_rc 0 'current named package: exit 0'
assert_empty_file "$OUT" 'skipped silently: no order line, no pipeline'
assert_empty_file "$ERR"

# --- and the no-argument form agrees ---
run_chy upgrade
assert_rc 0
assert_empty_file "$OUT"
assert_empty_file "$ERR"

exit 0
