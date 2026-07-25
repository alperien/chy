#!/bin/sh
# upgrade ABI safety: a manifest's soname set is
# filename-based: usr/lib/<base> (exactly one component) matching *.so or
# *.so.*, the fully-versioned real file dropped in favour of the soname
# link that backs it; symlinks count like files. A reinstall whose old
# set lost a member warns `chy: <name>: warning: soname bump: <soname>`
# (stderr, byte-sorted); under upgrade a non-empty vanished set rebuilds
# the installed dependents, announced once as `chy: rebuild: <names>`
# after the target set finishes, markers preserved. A patch bump keeps
# the set: no warning, no rebuild. Plain files stand in for the .so
# payloads; nothing here is an ELF, so verification stays silent.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# mk_libfake VERSION REAL SOLINK - the libfake recipe at VERSION, staging
# a plain file usr/lib/REAL plus SOLINK -> REAL and libfake.so -> SOLINK.
mk_libfake() {
    mkpkg "$CHY_ROOT" libfake "$1"
    {
        printf 'set -eu\n'
        printf "mkdir -p \"\$1\$CHY_ROOT/usr/lib\"\n"
        printf "printf '%%s\\\\n' 'libfake %s' >\"\$1\$CHY_ROOT/usr/lib/%s\"\n" "$1" "$2"
        printf "ln -s '%s' \"\$1\$CHY_ROOT/usr/lib/%s\"\n" "$2" "$3"
        printf "ln -s '%s' \"\$1\$CHY_ROOT/usr/lib/libfake.so\"\n" "$3"
    } >"$CHY_ROOT/recipes/libfake/build"
}

# line_no FILE EXACT-LINE - 1-based line number of the unique match.
line_no() {
    ln_c=$(grep -c -F -x -- "$2" "$1" || true)
    if [ "$ln_c" != 1 ]; then
        dump_streams
        fail "expected exactly one [$2] line in $1, found $ln_c"
    fi
    grep -n -F -x -- "$2" "$1" | cut -d: -f1
}

mk_libfake 1.0 libfake.so.1.0.0 libfake.so.1
mkpkg "$CHY_ROOT" app 1.0 usr/bin/app-tool
recipe_list "$CHY_ROOT" app depends libfake
stamp_builds "$CHY_ROOT" app "$TMPD"

run_chy install app
assert_rc 0 'app pulls libfake'
assert_order_first 'libfake app'
assert_requested "$CHY_ROOT" app
assert_not_requested "$CHY_ROOT" libfake
assert_link "$CHY_ROOT/usr/lib/libfake.so.1" '../../store/libfake/usr/lib/libfake.so.1'

# --- (a) patch bump: the real file moves, the soname links stay, so the
#     vanished set is empty: no warning, no rebuild line, app untouched ---
mk_libfake 1.0.1 libfake.so.1.0.1 libfake.so.1
rm -f "$TMPD/built-app"
run_chy upgrade
assert_rc 0 'patch bump upgrade'
assert_order_first 'libfake'
file_has_line "$OUT" 'chy: libfake: installed 1.0.1 1'
assert_empty_file "$ERR" 'same soname set: no soname bump warning'
assert_eq "$(count_matches '^chy: rebuild: ' "$OUT")" 0 'no rebuild line'
assert_eq "$(count_matches '^chy: app: installed ' "$OUT")" 0 'app not reinstalled'
assert_absent "$TMPD/built-app"
assert_installed "$CHY_ROOT" libfake 1.0.1 1
assert_installed "$CHY_ROOT" app 1.0 1
[ -h "$CHY_ROOT/usr/lib/libfake.so.1" ] || fail 'the soname link survives the patch bump'
[ -h "$CHY_ROOT/usr/lib/libfake.so.1.0.1" ] || fail 'the new real file is linked'
assert_absent "$CHY_ROOT/usr/lib/libfake.so.1.0.0"

run_chy doctor
assert_rc 0 'doctor after the patch bump'
assert_eq "$(cat "$OUT")" 'chy: doctor: clean'

# --- (b) soname bump: libfake.so.1 vanishes (libfake.so survives, so the
#     drop rule is what keeps it out of the warning); exactly one bump
#     warning, the dependent announced and rebuilt after the target set ---
mk_libfake 2.0 libfake.so.2.0.0 libfake.so.2
rm -f "$TMPD/built-app"
run_chy upgrade
assert_rc 0 'soname bump upgrade'
assert_order_first 'libfake'
assert_eq "$(cat "$ERR")" 'chy: libfake: warning: soname bump: libfake.so.1' \
    'exactly one bump warning, alone on stderr'
assert_eq "$(count_matches '^chy: rebuild: ' "$OUT")" 1 'the rebuild set is announced once'
lf_done=$(line_no "$OUT" 'chy: libfake: installed 2.0 1')
reb_line=$(line_no "$OUT" 'chy: rebuild: app')
app_done=$(line_no "$OUT" 'chy: app: installed 1.0 1')
[ "$lf_done" -lt "$reb_line" ] || fail 'the rebuild line must follow the finished target set'
[ "$reb_line" -lt "$app_done" ] || fail 'the rebuild line must precede the rebuild pipeline'
assert_eq "$(installed_seq)" 'libfake app' 'app completes after libfake'
[ -f "$TMPD/built-app" ] || fail 'the app build must run for the rebuild'
assert_installed "$CHY_ROOT" libfake 2.0 1
assert_installed "$CHY_ROOT" app 1.0 1
assert_requested "$CHY_ROOT" app
assert_not_requested "$CHY_ROOT" libfake
assert_absent "$CHY_ROOT/usr/lib/libfake.so.1"
[ -h "$CHY_ROOT/usr/lib/libfake.so.2" ] || fail 'the new soname link is in the farm'
[ -h "$CHY_ROOT/usr/lib/libfake.so" ] || fail 'the bare .so link is in the farm'

run_chy outdated
assert_rc 0
assert_empty_file "$OUT" 'everything converged to the corpus'
run_chy doctor
assert_rc 0 'doctor after the soname bump'
assert_eq "$(cat "$OUT")" 'chy: doctor: clean' 'the root stays coherent'

exit 0
