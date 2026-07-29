#!/bin/sh
# soname bump detection when the real ELF sits AT the soname name with
# only a bare dev link beside it, the modern layout (OpenSSL 3 ships
# libssl.so.3 as the real file, libssl.so -> libssl.so.3, no middle
# link). The runtime soname is libssl.so.3, so a bump replacing it has
# to be caught. Treating the bare dev link as superseding its target
# would drop the real soname from the set and miss the bump.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# mk_libssl VERSION SOVER - real usr/lib/libssl.so.SOVER plus the bare dev
# link libssl.so -> it. No intermediate versioned link.
mk_libssl() {
    mkpkg "$CHY_ROOT" libssl "$1"
    {
        printf 'set -eu\n'
        printf "mkdir -p \"\$1\$CHY_ROOT/usr/lib\"\n"
        printf "printf '%%s\\\\n' 'libssl %s' >\"\$1\$CHY_ROOT/usr/lib/libssl.so.%s\"\n" "$1" "$2"
        printf "ln -s 'libssl.so.%s' \"\$1\$CHY_ROOT/usr/lib/libssl.so\"\n" "$2"
    } >"$CHY_ROOT/recipes/libssl/build"
}

mk_libssl 1.0 1
mkpkg "$CHY_ROOT" app 1.0 usr/bin/app-tool
recipe_list "$CHY_ROOT" app depends libssl
stamp_builds "$CHY_ROOT" app "$TMPD"

run_chy install app
assert_rc 0 'app pulls libssl'
assert_empty_file "$ERR" 'first install: no bump'
[ -h "$CHY_ROOT/usr/lib/libssl.so.1" ] || fail 'the real soname is linked into the farm'

# bump: libssl.so.1 -> libssl.so.2 (the bare libssl.so stays). The real
# soname dependents NEED vanishes, so this is a bump and app rebuilds.
mk_libssl 2.0 2
rm -f "$TMPD/built-app"
run_chy upgrade
assert_rc 0 'soname-realfile bump upgrade'
file_has_line "$OUT" '+ libssl 2.0_1'
assert_eq "$(cat "$ERR")" 'chy: libssl: warning: soname bump: libssl.so.1' \
    'the vanished real-file soname is detected'
assert_eq "$(count_matches '^-> rebuild ' "$OUT")" 1 'the dependent is rebuilt'
[ -f "$TMPD/built-app" ] || fail 'app must rebuild after the soname bump'
assert_absent "$CHY_ROOT/usr/lib/libssl.so.1"
[ -h "$CHY_ROOT/usr/lib/libssl.so.2" ] || fail 'the new real soname is linked'

run_chy doctor
assert_rc 0 'doctor after the bump'
assert_eq "$(cat "$OUT")" 'doctor: clean'

exit 0
