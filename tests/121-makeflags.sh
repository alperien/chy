#!/bin/sh
# the build environment exports MAKEFLAGS: the caller's value wins, else
# one job per CPU (kiss exports MAKEFLAGS too; without it make styles
# build serially).  Ninja styles ignore the variable, so the default is
# safe to set unconditionally.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

mkpkg "$CHY_ROOT" mfpkg 1.0
cat >"$CHY_ROOT/recipes/mfpkg/build" <<EOF
set -eu
printf 'makeflags=%s\n' "\$MAKEFLAGS" >'$TMPD/mfdump'
mkdir -p "\$1\$CHY_ROOT/usr/bin"
printf 'x\n' >"\$1\$CHY_ROOT/usr/bin/mftool"
EOF

run_chy install mfpkg
assert_rc 0 'mfpkg install must succeed'

d="$TMPD/mfdump"
[ -f "$d" ] || fail 'build never ran: no makeflags dump'

mf=$(sed -n 's/^makeflags=//p' "$d")
case $mf in
    -j[0-9]*) ;;
    *) fail "MAKEFLAGS default must be -j<N>, got [$mf]" ;;
esac

# --- the caller's MAKEFLAGS wins verbatim ---
rm -rf "$CHY_ROOT/store" "$CHY_ROOT/db" "$CHY_ROOT/log"
run env MAKEFLAGS='-j2' sh "$CHY" install mfpkg
assert_rc 0 'reinstall with preset MAKEFLAGS must succeed'

mf=$(sed -n 's/^makeflags=//p' "$d")
assert_eq "$mf" '-j2' 'caller MAKEFLAGS must reach the build verbatim'
