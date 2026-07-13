#!/bin/sh
# /a build exiting nonzero aborts the install and the root is
# left exactly as it was - even when the build had already staged files.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# a bystander package that must survive untouched
mkpkg "$CHY_ROOT" keeper 1.0 usr/bin/keeper-tool
run_chy install keeper
assert_rc 0 'keeper install'

# the failing build stages a file first, then dies
mkpkg "$CHY_ROOT" boom 1.0
cat >"$CHY_ROOT/recipes/boom/build" <<'EOF'
set -eu
mkdir -p "$1$CHY_ROOT/usr/bin"
printf 'half\n' >"$1$CHY_ROOT/usr/bin/halfway"
exit 3
EOF

snap0=$(snap "$CHY_ROOT")
run_chy install boom
assert_rc 1 'nonzero build exit aborts the install'
assert_eq "$(snap "$CHY_ROOT")" "$snap0" 'root exactly as it was after build failure'
assert_not_installed "$CHY_ROOT" boom
assert_no_store "$CHY_ROOT" boom 1.0
assert_absent "$CHY_ROOT/usr/bin/halfway"

run_chy list
assert_rc 0
assert_eq "$(cat "$OUT")" 'keeper 1.0 1' 'only keeper remains installed'
assert_eq "$(cat "$CHY_ROOT/usr/bin/keeper-tool")" \
    "$(pkg_content keeper usr/bin/keeper-tool)" 'keeper still resolves'

exit 0
