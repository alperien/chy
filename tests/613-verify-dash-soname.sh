#!/bin/sh
# step 11: a NEEDED soname is data, never an option. An ELF
# needing a dash-leading soname must produce the ordinary pinned warning
# and nothing else on stderr; the scan's internal grep over self-shipped
# names must not parse the soname as a flag and leak "grep: ..." noise.
# Doctor shares the scan, so its finding and its stderr are pinned too.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

elf_template_init || { echo 'SKIP: no patchable dynamic ELF on this host'; exit 0; }

# like elf_fake_soname, but the name begins with a dash
dash_soname() {
    dsn_base='-fdashy'
    dsn_want=$((${#ELF_SONAME} - 3))
    while [ ${#dsn_base} -lt "$dsn_want" ]; do
        dsn_base="${dsn_base}x"
    done
    printf '%s.so' "$dsn_base"
}

fake_d=$(dash_soname)
mk_needy_elf "$TMPD/needy-elf" "$fake_d"

mkpkg "$CHY_ROOT" dashy 1.0
{
    printf 'set -eu\n'
    printf "mkdir -p \"\$1\$CHY_ROOT/usr/bin\"\n"
    printf "install -m755 '%s' \"\$1\$CHY_ROOT/usr/bin/dashy-elf\"\n" "$TMPD/needy-elf"
} >"$CHY_ROOT/recipes/dashy/build"

run_chy install dashy
assert_rc 0 'dashy install'
assert_installed "$CHY_ROOT" dashy 1.0 1
assert_eq "$(cat "$ERR")" "chy: dashy: warning: needs $fake_d" \
    'stderr is exactly the pinned warning: no grep option error leaked'

run_chy doctor
assert_rc 1 'dash soname: doctor exits 1'
want=$(printf 'doctor: dashy: needs %s\ndoctor: 1 problem(s)' "$fake_d")
assert_eq "$(cat "$OUT")" "$want" 'the doctor finding carries the dash soname'
assert_empty_file "$ERR" 'doctor stderr clean: no grep option error leaked'

exit 0
