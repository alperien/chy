#!/bin/sh
# doctor with no ldd on PATH: check 1 skips with exactly
# `chy: doctor: warning: ldd unavailable; runtime verification skipped`
# on stderr; the verdict is checks 2 and 3 alone. A clean root still
# says clean, exit 0; manifest drift is still found; a root whose only
# fault is an unresolvable soname reads clean without ldd.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

skipwarn='chy: doctor: warning: ldd unavailable; runtime verification skipped'

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

# --- clean root: the warning on stderr, the clean verdict on stdout ---
mkpkg "$CHY_ROOT" okpkg 1.0 usr/bin/ok-tool
run_chy install okpkg
assert_rc 0 'okpkg install'

run env "PATH=$NOLDD" sh "$CHY" doctor
assert_rc 0 'no ldd, clean root: doctor exits 0'
assert_eq "$(cat "$OUT")" 'chy: doctor: clean' 'stdout is exactly the clean line'
assert_eq "$(cat "$ERR")" "$skipwarn" 'stderr is exactly the skip warning'

# --- checks 2 and 3 still run without ldd ---
rm "$CHY_ROOT/usr/bin/ok-tool"
run env "PATH=$NOLDD" sh "$CHY" doctor
assert_rc 1 'no ldd: manifest drift still found'
want=$(printf 'chy: doctor: okpkg: missing usr/bin/ok-tool\nchy: doctor: 1 problem(s)')
assert_eq "$(cat "$OUT")" "$want" 'the missing finding survives the skip'
assert_eq "$(cat "$ERR")" "$skipwarn" 'still exactly the skip warning'

# --- a needy root: one problem with ldd, clean without ---
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
run_chy_root "$rn" install needy
assert_rc 0 'needy install'

run_chy_root "$rn" doctor
assert_rc 1 'with ldd the soname is a problem'
want=$(printf 'chy: doctor: needy: needs %s\nchy: doctor: 1 problem(s)' "$fake_s")
assert_eq "$(cat "$OUT")" "$want" 'sanity: check 1 fires when ldd exists'

run env "PATH=$NOLDD" "CHY_ROOT=$rn" sh "$CHY" doctor
assert_rc 0 'no ldd: check 1 gone, the root reads clean'
assert_eq "$(cat "$OUT")" 'chy: doctor: clean' 'skip means no needs findings at all'
assert_eq "$(cat "$ERR")" "$skipwarn" 'and exactly the skip warning'

exit 0
