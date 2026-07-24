#!/bin/sh
# step 11 / tools are checked when first needed. With no
# ldd on PATH the install neither fails nor half-runs the scan: exactly
# `chy: <name>: warning: ldd unavailable; runtime verification skipped`
# on stderr, exit 0, the package fully placed. True even for a package
# whose ELF really does miss a soname.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# NOLDD: every host tool by symlink, minus ldd
NOLDD=$TMPD/noldd-bin
mkdir -p "$NOLDD"
for ml_d in /usr/bin /bin /usr/sbin /sbin /usr/local/bin; do
    [ -d "$ml_d" ] || continue
    ln -s "$ml_d"/* "$NOLDD/" 2>/dev/null || :
done
rm -f "$NOLDD/ldd"
if PATH=$NOLDD command -v ldd >/dev/null 2>&1; then
    fail 'ldd is still reachable under the masked PATH'
fi

# --- a plain text package: the skip warning, and a complete install ---
mkpkg "$CHY_ROOT" quiet 1.0 usr/bin/quiet-tool
run env "PATH=$NOLDD" sh "$CHY" install quiet
assert_rc 0 'no ldd: install still succeeds'
file_has_line "$OUT" 'chy: quiet: installed 1.0 1'
assert_eq "$(cat "$ERR")" \
    'chy: quiet: warning: ldd unavailable; runtime verification skipped' \
    'stderr is exactly the skip warning'
assert_installed "$CHY_ROOT" quiet 1.0 1
assert_link "$CHY_ROOT/usr/bin/quiet-tool" '../../store/quiet/usr/bin/quiet-tool'

# --- a needy ELF package: skipped means no needs line either ---
elf_template_init || { echo 'SKIP: needy half untested (no patchable dynamic ELF)'; exit 0; }
fake_s=$(elf_fake_soname s)
mk_needy_elf "$TMPD/needy-elf" "$fake_s"

rn="$TMPD/root-needy"
mkdir -p "$rn"
mkpkg "$rn" needy 1.0
{
    printf 'set -eu\n'
    printf "mkdir -p \"\$1\$CHY_ROOT/usr/bin\"\n"
    printf "install -m755 '%s' \"\$1\$CHY_ROOT/usr/bin/needy-elf\"\n" "$TMPD/needy-elf"
} >"$rn/recipes/needy/build"

run env "PATH=$NOLDD" "CHY_ROOT=$rn" sh "$CHY" install needy
assert_rc 0 'no ldd: needy install still succeeds'
file_has_line "$OUT" 'chy: needy: installed 1.0 1'
assert_eq "$(cat "$ERR")" \
    'chy: needy: warning: ldd unavailable; runtime verification skipped' \
    'the scan is skipped whole: no needs warning without ldd'
assert_installed "$rn" needy 1.0 1

# with ldd back, doctor sees what the skipped scan would have: the
# package really was needy, only the missing tool silenced step 11
run_chy_root "$rn" doctor
assert_rc 1 'ldd restored: the debt is visible'
want=$(printf 'chy: doctor: needy: needs %s\nchy: doctor: 1 problem(s)' "$fake_s")
assert_eq "$(cat "$OUT")" "$want" 'doctor reports the soname install skipped'

exit 0
