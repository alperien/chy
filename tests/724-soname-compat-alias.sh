#!/bin/sh
# soname bump detection when a versioned COMPAT alias points at a
# real-file soname of a different version: real libx.so.2 (the
# library's own soname) plus a compat alias libx.so.1 -> libx.so.2 for
# old-ABI binaries. The name dependents NEED (libx.so.2) is a real
# file, and a bump replacing it has to be caught even though the alias
# also names it. A link only supersedes a target it extends (libx.so.1
# doesn't extend to libx.so.2), so libx.so.2 stays in the set.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# mk_libx VERSION SOVER ALIAS - real usr/lib/libx.so.SOVER, a bare dev link
# libx.so -> it, and a versioned compat alias ALIAS -> it.
mk_libx() {
    mkpkg "$CHY_ROOT" libx "$1"
    {
        printf 'set -eu\n'
        printf "mkdir -p \"\$1\$CHY_ROOT/usr/lib\"\n"
        printf "printf '%%s\\\\n' 'libx %s' >\"\$1\$CHY_ROOT/usr/lib/libx.so.%s\"\n" "$1" "$2"
        printf "ln -s 'libx.so.%s' \"\$1\$CHY_ROOT/usr/lib/libx.so\"\n" "$2"
        printf "ln -s 'libx.so.%s' \"\$1\$CHY_ROOT/usr/lib/%s\"\n" "$2" "$3"
    } >"$CHY_ROOT/recipes/libx/build"
}

# v1: real libx.so.2, compat alias libx.so.1 -> libx.so.2
mk_libx 1.0 2 libx.so.1
mkpkg "$CHY_ROOT" app 1.0 usr/bin/app-tool
recipe_list "$CHY_ROOT" app depends libx
stamp_builds "$CHY_ROOT" app "$TMPD"

run_chy install app
assert_rc 0 'app pulls libx'
assert_empty_file "$ERR" 'first install: no bump'
[ -h "$CHY_ROOT/usr/lib/libx.so.2" ] || fail 'the real soname is linked'
[ -h "$CHY_ROOT/usr/lib/libx.so.1" ] || fail 'the compat alias is linked'

# v2: real libx.so.3, alias retargeted to libx.so.3; libx.so.2 vanishes
mk_libx 2.0 3 libx.so.1
rm -f "$TMPD/built-app"
run_chy upgrade
assert_rc 0 'compat-alias bump upgrade'
file_has_line "$OUT" '+ libx 2.0_1'
assert_eq "$(cat "$ERR")" 'chy: libx: warning: soname bump: libx.so.2' \
    'the vanished real soname is detected, not hidden by the compat alias'
assert_eq "$(count_matches '^-> rebuild ' "$OUT")" 1 'the dependent is rebuilt'
[ -f "$TMPD/built-app" ] || fail 'app must rebuild after the bump'
assert_absent "$CHY_ROOT/usr/lib/libx.so.2"
[ -h "$CHY_ROOT/usr/lib/libx.so.3" ] || fail 'the new real soname is linked'

exit 0
