#!/bin/sh
# step 11 self-shipped filter: a soname the package ships itself
# is only satisfied when it resolves to a real file (find -L -type f). A
# DANGLING usr/lib symlink for the needed soname must not suppress the
# warning; a resolvable one, pointing at a shipped real library, must.
# Doctor sees the dangling case twice: the needs finding and the broken
# owned farm link.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

elf_template_init || { echo 'SKIP: no patchable dynamic ELF on this host'; exit 0; }
fake_s=$(elf_fake_soname s)
mk_needy_elf "$TMPD/needy-elf" "$fake_s"

# the real file ELF_SONAME resolves to, so the control package can ship
# a genuinely loadable library under the fake name
real_lib=$(ldd "$ELF_TEMPLATE" 2>/dev/null |
    LC_ALL=C awk -v s="$ELF_SONAME" '$1 == s && $2 == "=>" { print $3; exit }')
[ -f "$real_lib" ] || fail "cannot locate the template library for $ELF_SONAME"

# --- dangler ships the needy ELF plus usr/lib/<soname> -> <absent>.
#     The dangling link satisfies nothing: the warning must survive ---
mkpkg "$CHY_ROOT" dangler 1.0
{
    printf 'set -eu\n'
    printf "mkdir -p \"\$1\$CHY_ROOT/usr/bin\" \"\$1\$CHY_ROOT/usr/lib\"\n"
    printf "install -m755 '%s' \"\$1\$CHY_ROOT/usr/bin/dangler-elf\"\n" "$TMPD/needy-elf"
    printf "ln -s '%s.9.9.9' \"\$1\$CHY_ROOT/usr/lib/%s\"\n" "$fake_s" "$fake_s"
} >"$CHY_ROOT/recipes/dangler/build"

run_chy install dangler
assert_rc 0 'dangler install'
assert_installed "$CHY_ROOT" dangler 1.0 1
assert_eq "$(cat "$ERR")" "chy: dangler: warning: needs $fake_s" \
    'a dangling self-shipped symlink must not suppress the warning'

run_chy doctor
assert_rc 1 'dangling case: doctor exits 1'
want=$(printf 'doctor: dangler: needs %s
doctor: dangler: broken link usr/lib/%s
doctor: 2 problem(s)' "$fake_s" "$fake_s")
assert_eq "$(cat "$OUT")" "$want" 'the needs finding plus the broken owned link'

# --- control: same needy ELF, but usr/lib/<soname> is a resolvable
#     symlink onto a shipped real library: self-shipped, no warning ---
rb="$TMPD/root-ok"
mkdir -p "$rb"
mkpkg "$rb" shipper 1.0
{
    printf 'set -eu\n'
    printf "mkdir -p \"\$1\$CHY_ROOT/usr/bin\" \"\$1\$CHY_ROOT/usr/lib\"\n"
    printf "install -m755 '%s' \"\$1\$CHY_ROOT/usr/bin/shipper-elf\"\n" "$TMPD/needy-elf"
    printf "install -m755 '%s' \"\$1\$CHY_ROOT/usr/lib/%s.9.9.9\"\n" "$real_lib" "$fake_s"
    printf "ln -s '%s.9.9.9' \"\$1\$CHY_ROOT/usr/lib/%s\"\n" "$fake_s" "$fake_s"
} >"$rb/recipes/shipper/build"

run_chy_root "$rb" install shipper
assert_rc 0 'shipper install'
assert_installed "$rb" shipper 1.0 1
assert_empty_file "$ERR" 'a resolvable self-shipped soname warns nothing'

run_chy_root "$rb" doctor
assert_rc 0 'control root is clean'
assert_eq "$(cat "$OUT")" 'doctor: clean' 'control: exactly the clean line'
assert_empty_file "$ERR" 'control doctor: stderr empty'

exit 0
