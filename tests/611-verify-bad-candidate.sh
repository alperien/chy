#!/bin/sh
# step 11 / doctor check 1: a search-path candidate that exists
# but is not a loadable ELF (a one-line text file at usr/lib/<soname>)
# makes the loader abort the whole trace with "error while loading
# shared libraries: ...: file too short" instead of printing
# "=> not found". The scan must recover the soname from the abort
# message, never swallow it and report nothing. The junk file sits in
# the root, not in the package: a shipped real file would be the
# self-shipped case (612) and is deliberately silent.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

elf_template_init || { echo 'SKIP: no patchable dynamic ELF on this host'; exit 0; }
fake_a=$(elf_fake_soname a)
fake_b=$(elf_fake_soname b)
mk_needy_elf "$TMPD/needy-elf-a" "$fake_a"
mk_needy_elf "$TMPD/needy-elf-b" "$fake_b"

# the junk candidate: found via the LD_LIBRARY_PATH convention, unloadable
mkdir -p "$CHY_ROOT/usr/lib"
printf 'not a library\n' >"$CHY_ROOT/usr/lib/$fake_a"

# classify this host's loader: glibc hard-aborts on the junk candidate; a
# loader that skips it degenerates to a plain "not found", which yields
# the same report. Anything else gets only the weaker assertions below.
strict=1
probe=$(LD_LIBRARY_PATH="$CHY_ROOT/usr/lib" ldd "$TMPD/needy-elf-a" 2>&1) || :
case $probe in
    *'error while loading shared libraries'*) ;;
    *"$fake_a => not found"*) ;;
    *) strict=0
       printf 'note: unrecognized loader report, weak assertions only:\n%s\n' "$probe" ;;
esac

# badcand ships two ELFs: one hits the junk candidate for fake_a, one
# misses fake_b outright. Both sonames must surface.
mkpkg "$CHY_ROOT" badcand 1.0
{
    printf 'set -eu\n'
    printf "mkdir -p \"\$1\$CHY_ROOT/usr/bin\"\n"
    printf "install -m755 '%s' \"\$1\$CHY_ROOT/usr/bin/badcand-a\"\n" "$TMPD/needy-elf-a"
    printf "install -m755 '%s' \"\$1\$CHY_ROOT/usr/bin/badcand-b\"\n" "$TMPD/needy-elf-b"
} >"$CHY_ROOT/recipes/badcand/build"

run_chy install badcand
assert_rc 0 'warnings never affect exit status'
file_has_line "$OUT" '+ badcand 1.0_1'
assert_installed "$CHY_ROOT" badcand 1.0 1
if [ "$strict" -eq 1 ]; then
    want=$(printf 'chy: badcand: warning: needs %s\nchy: badcand: warning: needs %s' \
        "$fake_a" "$fake_b")
    assert_eq "$(cat "$ERR")" "$want" \
        'the aborted trace still yields its soname, sorted with the plain miss'
else
    file_has "$ERR" 'chy: badcand: warning: needs '
fi

run_chy doctor
assert_rc 1 'a junk candidate is never a clean root'
if [ "$strict" -eq 1 ]; then
    want=$(printf 'doctor: badcand: needs %s
doctor: badcand: needs %s
doctor: 2 problem(s)' "$fake_a" "$fake_b")
    assert_eq "$(cat "$OUT")" "$want" 'doctor recovers both sonames'
else
    if grep -Fxq 'doctor: clean' "$OUT"; then
        dump_streams
        fail 'doctor said clean over a loader-aborting root'
    fi
    file_has "$OUT" ' problem(s)'
fi

exit 0
