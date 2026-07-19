#!/bin/sh
# doctor, ordering: packages report in name order (byte order,
# per the global collation rule); within a package the three checks emit
# in order - needs findings (check 1) before the manifest walks - and
# checks 2 and 3 walk the manifest in its stored byte-sorted order, at
# most one finding per path. Fixture note: the lone broken-link path here
# byte-sorts before every missing/foreign path, so the expected block is
# the same whether an implementation finishes check 2 before check 3 or
# walks the manifest once; the missing/foreign/missing run pins check 3
# to manifest order, never grouped by finding type.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

have_elf=0
if elf_template_init; then
    have_elf=1
    fake_a=$(elf_fake_soname a)
    mk_needy_elf "$TMPD/ord-elf" "$fake_a"
else
    echo 'SKIP: needs-before-checks-2/3 untested (no patchable dynamic ELF)'
fi

# amess: every finding type in one package
mkpkg "$CHY_ROOT" amess 1.0 \
    usr/bin/aa-broke usr/bin/bb-gone usr/bin/cc-alien usr/bin/dd-gone
if [ "$have_elf" = 1 ]; then
    {
        printf "mkdir -p \"\$1\$CHY_ROOT/usr/lib\"\n"
        printf "install -m755 '%s' \"\$1\$CHY_ROOT/usr/lib/amess-elf\"\n" \
            "$TMPD/ord-elf"
    } >>"$CHY_ROOT/recipes/amess/build"
fi
# mmid: installed, clean, and silent - sits between the two by name
mkpkg "$CHY_ROOT" mmid 1.0 usr/bin/mm-tool
# zmess: one problem, reported after everything amess has to say
mkpkg "$CHY_ROOT" zmess 1.0 usr/bin/zz-gone

run_chy install amess mmid zmess
assert_rc 0 'fixture packages install'
assert_installed "$CHY_ROOT" amess 1.0 1
assert_installed "$CHY_ROOT" mmid 1.0 1
assert_installed "$CHY_ROOT" zmess 1.0 1

# break amess: broken link, then missing, foreign, missing in manifest order
rm "$CHY_ROOT/store/amess-1.0/usr/bin/aa-broke"
rm "$CHY_ROOT/usr/bin/bb-gone"
rm "$CHY_ROOT/usr/bin/cc-alien"
printf 'alien\n' >"$CHY_ROOT/usr/bin/cc-alien"
rm "$CHY_ROOT/usr/bin/dd-gone"
# break zmess: one missing path
rm "$CHY_ROOT/usr/bin/zz-gone"

run_chy doctor
assert_rc 1 'problems: doctor exits 1'
{
    if [ "$have_elf" = 1 ]; then
        printf 'chy: doctor: amess: needs %s\n' "$fake_a"
    fi
    printf 'chy: doctor: amess: broken link usr/bin/aa-broke\n'
    printf 'chy: doctor: amess: missing usr/bin/bb-gone\n'
    printf 'chy: doctor: amess: foreign usr/bin/cc-alien\n'
    printf 'chy: doctor: amess: missing usr/bin/dd-gone\n'
    printf 'chy: doctor: zmess: missing usr/bin/zz-gone\n'
    printf 'chy: doctor: %s problem(s)\n' "$((4 + have_elf + 1))"
} >"$TMPD/want"
assert_eq "$(cat "$OUT")" "$(cat "$TMPD/want")" \
    'exact report: name-ordered blocks, needs first, manifest-order walks'

exit 0
