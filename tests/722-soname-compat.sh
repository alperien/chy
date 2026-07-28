#!/bin/sh
# soname bump detection with a compat soname link. Some libraries ship
# a second, shorter-versioned soname link beside the main one: bzip2
# keeps libbz2.so.1.0 next to libbz2.so.1 so binaries linked against
# either resolve. Both are names a dependent NEEDs, so either vanishing
# on a reinstall is a bump. A name-only "drop the longer sibling" rule
# can't see this (it reads libbz.so.1.0 as backing libbz.so.1 and hides
# it), so the soname set comes from the tree: a symlink is a soname,
# the real file it backs isn't. Pins that a vanished compat link is
# caught and the dependent rebuilt, and that a patch bump under this
# layout isn't mistaken for one. Plain files stand in for ELFs.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# mk_libbz VERSION REAL [COMPAT] - the libbz recipe at VERSION, staging a
# real file usr/lib/REAL, the main soname libbz.so.1 -> REAL, the bare
# libbz.so -> libbz.so.1, and (when COMPAT is given) a second soname link
# COMPAT -> REAL, the bzip2 shape.
mk_libbz() {
    mkpkg "$CHY_ROOT" libbz "$1"
    {
        printf 'set -eu\n'
        printf "mkdir -p \"\$1\$CHY_ROOT/usr/lib\"\n"
        printf "printf '%%s\\\\n' 'libbz %s' >\"\$1\$CHY_ROOT/usr/lib/%s\"\n" "$1" "$2"
        printf "ln -s '%s' \"\$1\$CHY_ROOT/usr/lib/libbz.so.1\"\n" "$2"
        printf "ln -s libbz.so.1 \"\$1\$CHY_ROOT/usr/lib/libbz.so\"\n"
        [ -z "${3:-}" ] || printf "ln -s '%s' \"\$1\$CHY_ROOT/usr/lib/%s\"\n" "$2" "$3"
    } >"$CHY_ROOT/recipes/libbz/build"
}

# v1 ships the compat link libbz.so.1.0 beside libbz.so.1
mk_libbz 1.0 libbz.so.1.0.6 libbz.so.1.0
mkpkg "$CHY_ROOT" app 1.0 usr/bin/app-tool
recipe_list "$CHY_ROOT" app depends libbz
stamp_builds "$CHY_ROOT" app "$TMPD"

run_chy install app
assert_rc 0 'app pulls libbz'
assert_order_first 'libbz app'
assert_empty_file "$ERR" 'a first install has no old tree, no bump'
[ -h "$CHY_ROOT/usr/lib/libbz.so.1.0" ] || fail 'the compat soname link is in the farm'

# --- (a) patch bump keeping both soname links: the real file moves, both
#     links stay, the set is unchanged, so no bump and no rebuild ---
mk_libbz 1.1 libbz.so.1.0.7 libbz.so.1.0
rm -f "$TMPD/built-app"
run_chy upgrade
assert_rc 0 'patch bump upgrade'
file_has_line "$OUT" '+ libbz 1.1_1'
assert_empty_file "$ERR" 'both soname links kept: no bump warning'
assert_eq "$(count_matches '^-> rebuild ' "$OUT")" 0 'no rebuild on a patch bump'
assert_absent "$TMPD/built-app"

# --- (b) the compat link is dropped while libbz.so.1 stays. A name-only
#     rule reports nothing here (the bug); the tree-based set sees the
#     vanished compat soname and rebuilds the dependent ---
mk_libbz 2.0 libbz.so.1.0.7
rm -f "$TMPD/built-app"
run_chy upgrade
assert_rc 0 'compat-drop upgrade'
file_has_line "$OUT" '+ libbz 2.0_1'
assert_eq "$(cat "$ERR")" 'chy: libbz: warning: soname bump: libbz.so.1.0' \
    'the vanished compat soname is detected, alone on stderr'
assert_eq "$(count_matches '^-> rebuild ' "$OUT")" 1 'the dependent is announced'
[ -f "$TMPD/built-app" ] || fail 'app must rebuild after the compat-soname drop'
assert_absent "$CHY_ROOT/usr/lib/libbz.so.1.0"
[ -h "$CHY_ROOT/usr/lib/libbz.so.1" ] || fail 'the main soname link survives'

run_chy doctor
assert_rc 0 'doctor after the compat drop'
assert_eq "$(cat "$OUT")" 'doctor: clean'

exit 0
