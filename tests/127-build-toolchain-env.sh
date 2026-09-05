#!/bin/sh
# the build environment carries the kiss-style toolchain defaults
# (CC/CXX/AR/NM/RANLIB, each defaulting only when unset) and DESTDIR set
# to the staging dir $1, so unmodified kiss build scripts work.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

mkpkg "$CHY_ROOT" tcenv 1.0
cat >"$CHY_ROOT/recipes/tcenv/build" <<EOF
set -eu
{
    printf 'cc=%s\n' "\$CC"
    printf 'cxx=%s\n' "\$CXX"
    printf 'ar=%s\n' "\$AR"
    printf 'nm=%s\n' "\$NM"
    printf 'ranlib=%s\n' "\$RANLIB"
    printf 'destdir=%s\n' "\$DESTDIR"
} >'$TMPD/tcdump'
mkdir -p "\$1\$CHY_ROOT/usr/bin"
printf 'x\n' >"\$1\$CHY_ROOT/usr/bin/tctool"
EOF

run_chy install tcenv
assert_rc 0 'tcenv install must succeed'

d="$TMPD/tcdump"
[ -f "$d" ] || fail 'build never ran: no toolchain dump'
val() { sed -n "s/^$1=//p" "$d"; }

assert_eq "$(val cc)" 'cc' 'CC defaults to cc'
assert_eq "$(val cxx)" 'c++' 'CXX defaults to c++'
assert_eq "$(val ar)" 'ar' 'AR defaults to ar'
assert_eq "$(val nm)" 'nm' 'NM defaults to nm'
assert_eq "$(val ranlib)" 'ranlib' 'RANLIB defaults to ranlib'
assert_eq "$(val destdir)" "$CHY_ROOT/build/dest" 'DESTDIR is the staging dir'

# --- caller values win over the defaults ---
mkpkg "$CHY_ROOT" tcover 1.0 usr/bin/tcover-tool
cat >"$CHY_ROOT/recipes/tcover/build" <<EOF
set -eu
printf 'cc=%s\nranlib=%s\n' "\$CC" "\$RANLIB" >'$TMPD/tcover-dump'
mkdir -p "\$1\$CHY_ROOT/usr/bin"
printf 'x\n' >"\$1\$CHY_ROOT/usr/bin/tcover-tool"
EOF
run env CC=clang RANLIB=myranlib CHY_ROOT="$CHY_ROOT" sh "$CHY" install tcover
assert_rc 0 'tcover install with preset CC must succeed'
d2="$TMPD/tcover-dump"
[ -f "$d2" ] || fail 'tcover build never ran'
val2() { sed -n "s/^$1=//p" "$d2"; }
assert_eq "$(val2 cc)" 'clang' 'a preset CC survives'
assert_eq "$(val2 ranlib)" 'myranlib' 'a preset RANLIB survives'

exit 0
