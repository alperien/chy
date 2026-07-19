#!/bin/sh
# doctor: the truth report over installed packages.
# Findings go to stdout, paths $CHY_ROOT-relative; then exactly
# `chy: doctor: clean` (exit 0) or `chy: doctor: <n> problem(s)` (exit 1),
# n being the number of finding lines. Read-only: creates no directories,
# treats absent ones as empty. Check 1 finds unresolvable NEEDED sonames
# in store ELFs, check 2 broken owned farm links, check 3 manifest drift
# (missing / foreign).
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- healthy root: exactly the clean line, nothing else anywhere ---
mkpkg "$CHY_ROOT" okpkg 1.0 usr/bin/ok-tool
run_chy install okpkg
assert_rc 0 'okpkg install'

run_chy doctor
assert_rc 0 'healthy root: doctor exits 0'
assert_eq "$(cat "$OUT")" 'chy: doctor: clean' \
    'healthy root: stdout is exactly the clean line'
assert_empty_file "$ERR" 'healthy root: doctor says nothing on stderr'

# --- read-only: a fresh root with NO db/ at all is clean and stays bare ---
rb="$TMPD/bare-root"
mkdir "$rb"
run_chy_root "$rb" doctor
assert_rc 0 'bare root: doctor exits 0'
assert_eq "$(cat "$OUT")" 'chy: doctor: clean' 'bare root: clean line only'
assert_empty_file "$ERR" 'bare root: stderr empty'
for d in db usr store cache build recipes; do
    assert_absent "$rb/$d"
done
[ -z "$(ls -A "$rb")" ] || { ls -A "$rb" >&2; fail 'doctor created something in a bare root'; }

# --- broken link: store file deleted behind an owned farm link ---
rc="$TMPD/root-brok"
mkdir -p "$rc"
mkpkg "$rc" brok 1.0 usr/bin/brok-tool
run_chy_root "$rc" install brok
assert_rc 0 'brok install'
rm "$rc/store/brok-1.0/usr/bin/brok-tool"

run_chy_root "$rc" doctor
assert_rc 1 'a finding makes doctor exit 1'
want=$(printf 'chy: doctor: brok: broken link usr/bin/brok-tool\nchy: doctor: 1 problem(s)')
assert_eq "$(cat "$OUT")" "$want" 'broken link finding, then the summary'

# --- missing: a manifest-listed farm link removed ---
rd="$TMPD/root-miss"
mkdir -p "$rd"
mkpkg "$rd" miss 1.0 usr/bin/miss-tool
run_chy_root "$rd" install miss
assert_rc 0 'miss install'
rm "$rd/usr/bin/miss-tool"

run_chy_root "$rd" doctor
assert_rc 1 'missing path: exit 1'
want=$(printf 'chy: doctor: miss: missing usr/bin/miss-tool\nchy: doctor: 1 problem(s)')
assert_eq "$(cat "$OUT")" "$want" 'missing finding, then the summary'

# --- foreign: the manifest path replaced with a regular file ---
re="$TMPD/root-forn"
mkdir -p "$re"
mkpkg "$re" forn 1.0 usr/bin/forn-tool
run_chy_root "$re" install forn
assert_rc 0 'forn install'
rm "$re/usr/bin/forn-tool"
printf 'intruder\n' >"$re/usr/bin/forn-tool"

run_chy_root "$re" doctor
assert_rc 1 'foreign path: exit 1'
want=$(printf 'chy: doctor: forn: foreign usr/bin/forn-tool\nchy: doctor: 1 problem(s)')
assert_eq "$(cat "$OUT")" "$want" 'foreign finding, then the summary'

# --- combined root: one finding per package, n counts finding lines ---
rf="$TMPD/root-combo"
mkdir -p "$rf"
mkpkg "$rf" okpkg 1.0 usr/bin/ok-tool
mkpkg "$rf" brok 1.0 usr/bin/brok-tool
mkpkg "$rf" forn 1.0 usr/bin/forn-tool
mkpkg "$rf" miss 1.0 usr/bin/miss-tool
run_chy_root "$rf" install okpkg brok forn miss
assert_rc 0 'combo installs'
rm "$rf/store/brok-1.0/usr/bin/brok-tool"
rm "$rf/usr/bin/miss-tool"
rm "$rf/usr/bin/forn-tool"
printf 'intruder\n' >"$rf/usr/bin/forn-tool"

run_chy_root "$rf" doctor
assert_rc 1 'combined problems: exit 1'
want=$(printf '%s\n%s\n%s\n%s' \
    'chy: doctor: brok: broken link usr/bin/brok-tool' \
    'chy: doctor: forn: foreign usr/bin/forn-tool' \
    'chy: doctor: miss: missing usr/bin/miss-tool' \
    'chy: doctor: 3 problem(s)')
assert_eq "$(cat "$OUT")" "$want" \
    'exact multi-problem report: n = finding-line count, clean okpkg silent'

# --- check 1: a store ELF with an unresolvable NEEDED soname ---
elf_template_init || { echo 'SKIP: no patchable dynamic ELF on this host'; exit 0; }
fake_m=$(elf_fake_soname m)
mk_needy_elf "$TMPD/doc-elf" "$fake_m"

rg="$TMPD/root-needy"
mkdir -p "$rg"
mkpkg "$rg" needy 1.0
{
    printf 'set -eu\n'
    printf "mkdir -p \"\$1\$CHY_ROOT/usr/bin\"\n"
    printf "install -m755 '%s' \"\$1\$CHY_ROOT/usr/bin/needy-elf\"\n" "$TMPD/doc-elf"
} >"$rg/recipes/needy/build"
run_chy_root "$rg" install needy
assert_rc 0 'needy install'

run_chy_root "$rg" doctor
assert_rc 1 'unresolved soname: exit 1'
want=$(printf 'chy: doctor: needy: needs %s\nchy: doctor: 1 problem(s)' "$fake_m")
assert_eq "$(cat "$OUT")" "$want" 'bare needs finding when no map exists'

# the shlibs.map hint reaches doctor too
printf '%s helperpkg\n' "$fake_m" >"$rg/shlibs.map"
run_chy_root "$rg" doctor
assert_rc 1 'mapped soname still a problem'
want=$(printf 'chy: doctor: needy: needs %s (package: helperpkg)\nchy: doctor: 1 problem(s)' "$fake_m")
assert_eq "$(cat "$OUT")" "$want" 'doctor findings carry the map hint'

exit 0
