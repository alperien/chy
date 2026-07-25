#!/bin/sh
# upgrade resumability: an interrupted soname-bump rebuild self-heals.
# Build the half-killed state directly: plain install converges libfake
# to v2 (warns the bump, never rebuilds dependents), leaving app
# NEEDing libfake.so.1 while the farm has the library at another
# version. doctor names the dangler; the next plain `chy upgrade`
# rebuilds it and the root converges. An unresolved soname with no farm
# provider at all is host drift: doctor keeps reporting it, upgrade
# leaves it alone.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

elf_template_init || { echo 'SKIP: no patchable dynamic ELF on this host'; exit 0; }

# the real file ELF_SONAME resolves to: shipped under the libfake names
# it is genuinely loadable, so a NEEDED that reaches it stays silent
# (612's technique)
real_lib=$(ldd "$ELF_TEMPLATE" 2>/dev/null |
    LC_ALL=C awk -v s="$ELF_SONAME" '$1 == s && $2 == "=>" { print $3; exit }')
[ -f "$real_lib" ] || fail "cannot locate the template library for $ELF_SONAME"
if ldd "$real_lib" 2>/dev/null | grep -q 'not found'; then
    echo 'SKIP: the template library does not resolve cleanly on this host'
    exit 0
fi
cp "$real_lib" "$TMPD/real-so"

# mk_named_elf OUT SONAME - mk_needy_elf for a chosen SONAME shorter than
# ELF_SONAME: the dynstr bytes are overwritten NUL-padded, so the entry
# just ends early. Returns 1 when the technique does not take here.
mk_named_elf() {
    python3 - "$ELF_TEMPLATE" "$1" "$ELF_SONAME" "$2" <<'PYEOF' || return 1
import sys
src, dst, old, new = sys.argv[1:5]
data = open(src, 'rb').read()
o, n = old.encode(), new.encode()
assert len(n) <= len(o), 'replacement soname too long'
assert o in data, 'template lost its NEEDED string'
open(dst, 'wb').write(data.replace(o, n.ljust(len(o), b'\0')))
PYEOF
    chmod 755 "$1"
    ldd "$1" 2>/dev/null | grep -F -- "$2" | grep -q 'not found'
}

if ! mk_named_elf "$TMPD/app-needs-1" libfake.so.1 ||
    ! mk_named_elf "$TMPD/app-needs-2" libfake.so.2; then
    echo 'SKIP: NUL-padded soname patch does not take on this host'
    exit 0
fi

# mk_libfake VERSION REAL SOLINK - libfake at VERSION ships a loadable
# usr/lib/REAL plus SOLINK -> REAL and libfake.so -> SOLINK.
mk_libfake() {
    mkpkg "$CHY_ROOT" libfake "$1"
    {
        printf 'set -eu\n'
        printf "mkdir -p \"\$1\$CHY_ROOT/usr/lib\"\n"
        printf "install -m755 '%s' \"\$1\$CHY_ROOT/usr/lib/%s\"\n" "$TMPD/real-so" "$2"
        printf "ln -s '%s' \"\$1\$CHY_ROOT/usr/lib/%s\"\n" "$2" "$3"
        printf "ln -s '%s' \"\$1\$CHY_ROOT/usr/lib/libfake.so\"\n" "$3"
    } >"$CHY_ROOT/recipes/libfake/build"
}

mk_libfake 1.0 libfake.so.1.0.0 libfake.so.1

# app relinks against whatever libfake soname the farm offers at build
# time, the way a real rebuild picks up the new library
mkpkg "$CHY_ROOT" app 1.0
{
    printf 'set -eu\n'
    printf "mkdir -p \"\$1\$CHY_ROOT/usr/bin\"\n"
    printf "if [ -e \"\$CHY_ROOT/usr/lib/libfake.so.2\" ]; then\n"
    printf "    install -m755 '%s' \"\$1\$CHY_ROOT/usr/bin/app-elf\"\n" "$TMPD/app-needs-2"
    printf "else\n"
    printf "    install -m755 '%s' \"\$1\$CHY_ROOT/usr/bin/app-elf\"\n" "$TMPD/app-needs-1"
    printf "fi\n"
} >"$CHY_ROOT/recipes/app/build"
recipe_list "$CHY_ROOT" app depends libfake
stamp_builds "$CHY_ROOT" app "$TMPD"

run_chy install app
assert_rc 0 'app pulls libfake'
assert_order_first 'libfake app'
assert_empty_file "$ERR" 'baseline: libfake.so.1 resolves through the farm'
run_chy doctor
assert_rc 0 'baseline doctor'
assert_eq "$(cat "$OUT")" 'chy: doctor: clean' 'the baseline root is clean'

# --- the interruption: libfake converges to v2 by plain install, which
# warns the bump and stops there (install never rebuilds
#     dependents); app is left dangling ---
mk_libfake 2.0 libfake.so.2.0.0 libfake.so.2
rm -f "$TMPD/built-app"
run_chy install libfake
assert_rc 0 'libfake 2.0 installs'
file_has_line "$OUT" 'chy: libfake: installed 2.0 1'
assert_eq "$(cat "$ERR")" 'chy: libfake: warning: soname bump: libfake.so.1' \
    'install warns the bump, alone on stderr'
assert_eq "$(count_matches '^chy: rebuild: ' "$OUT")" 0 'install never rebuilds dependents'
assert_absent "$TMPD/built-app"
assert_installed "$CHY_ROOT" libfake 2.0 1
assert_installed "$CHY_ROOT" app 1.0 1
assert_absent "$CHY_ROOT/usr/lib/libfake.so.1"
[ -h "$CHY_ROOT/usr/lib/libfake.so.2" ] || fail 'the farm provides the new soname'
[ -h "$CHY_ROOT/usr/lib/libfake.so" ] || fail 'the farm provides the bare .so link'

# --- doctor names the dangler precisely ---
run_chy doctor
assert_rc 1 'a dangling dependent is a problem'
want=$(printf 'chy: doctor: app: needs libfake.so.1\nchy: doctor: 1 problem(s)')
assert_eq "$(cat "$OUT")" "$want" 'exactly the dangling NEEDED, named'

# --- re-run upgrade: the library is present at a different version, so
#     the dangler rebuilds and the root converges ---
rm -f "$TMPD/built-app"
run_chy upgrade
assert_rc 0 'upgrade repairs the interruption'
file_has_line "$OUT" 'chy: app: installed 1.0 1'
[ -f "$TMPD/built-app" ] || fail 'the app build must run for the repair'
assert_eq "$(count_matches '^chy: libfake: installed ' "$OUT")" 0 'libfake is current: untouched'
assert_installed "$CHY_ROOT" app 1.0 1

run_chy doctor
assert_rc 0 'doctor after the repair'
assert_eq "$(cat "$OUT")" 'chy: doctor: clean' 'relinking resolved the need'

rm -f "$TMPD/built-app"
run_chy upgrade
assert_rc 0 'converged: a re-run has nothing to do'
assert_empty_file "$OUT" 'nothing outdated, nothing dangling: prints nothing'
assert_absent "$TMPD/built-app"

# --- control: an unresolved soname with no farm provider at all is host
#     drift: upgrade leaves it alone, doctor keeps reporting it ---
rd="$TMPD/root-drift"
mkdir -p "$rd"
fake_d=$(elf_fake_soname d)
mk_needy_elf "$TMPD/drift-elf" "$fake_d"
mkpkg "$rd" drift 1.0
{
    printf 'set -eu\n'
    printf "mkdir -p \"\$1\$CHY_ROOT/usr/bin\"\n"
    printf "install -m755 '%s' \"\$1\$CHY_ROOT/usr/bin/drift-elf\"\n" "$TMPD/drift-elf"
} >"$rd/recipes/drift/build"
stamp_builds "$rd" drift "$TMPD"

run_chy_root "$rd" install drift
assert_rc 0 'drift installs'
assert_eq "$(cat "$ERR")" "chy: drift: warning: needs $fake_d" \
    'install records the genuine drift'

rm -f "$TMPD/built-drift"
run_chy_root "$rd" upgrade
assert_rc 0 'host drift is not upgrade business'
assert_empty_file "$OUT" 'no farm provider: no rebuild, nothing prints'
assert_absent "$TMPD/built-drift"

run_chy_root "$rd" doctor
assert_rc 1 'doctor still owns the drift report'
want=$(printf 'chy: doctor: drift: needs %s\nchy: doctor: 1 problem(s)' "$fake_d")
assert_eq "$(cat "$OUT")" "$want" 'the drift stays visible'

exit 0
