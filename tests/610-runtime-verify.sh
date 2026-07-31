#!/bin/sh
# install step 12: after linking, every store regular file with the ELF
# magic gets ldd under the launcher LD_LIBRARY_PATH convention; an
# unresolvable NEEDED soname is exactly
# `chy: <name>: warning: needs <soname>` on stderr, one line per
# distinct missing soname, sorted, ` (package: <pkg>)` appended when
# $CHY_ROOT/shlibs.map knows it (significant lines, first two tokens,
# first match wins). Warnings don't touch exit status and don't undo
# the install.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# elf_install_pkg NAME ELF...: recipe whose build stages each pre-built
# ELF fixture as usr/bin/<basename>, plus one text file.
elf_install_pkg() {
    eip_name=$1
    shift
    mkpkg "$CHY_ROOT" "$eip_name" 1.0
    {
        printf 'set -eu\n'
        printf "mkdir -p \"\$1\$CHY_ROOT/usr/bin\"\n"
        printf "printf x >\"\$1\$CHY_ROOT/usr/bin/%s-note.txt\"\n" "$eip_name"
        for eip_e in "$@"; do
            # prefix with the package name: sub-cases share one root, and
            # identical staged paths would (correctly) conflict
            printf "install -m755 '%s' \"\$1\$CHY_ROOT/usr/bin/%s-%s\"\n" \
                "$eip_e" "$eip_name" "${eip_e##*/}"
        done
    } >"$CHY_ROOT/recipes/$eip_name/build"
}

# --- a clean text-only package: step 12 has nothing to say ---
mkpkg "$CHY_ROOT" quiet 1.0 usr/bin/quiet-tool
run_chy install quiet
assert_rc 0 'text-only install'
assert_empty_file "$ERR" 'no ELFs staged, no needs warnings'

elf_template_init || { echo 'SKIP: no patchable dynamic ELF on this host'; exit 0; }
fake_a=$(elf_fake_soname a)
fake_b=$(elf_fake_soname b)
mk_needy_elf "$TMPD/needy-elf-a" "$fake_a"
mk_needy_elf "$TMPD/needy-elf-b" "$fake_b"

# --- one patched ELF, no shlibs.map: exactly one bare warning line;
#     the install still succeeds and is fully placed ---
elf_install_pkg needy "$TMPD/needy-elf-a"
run_chy install needy
assert_rc 0 'needs warnings never affect exit status'
file_has_line "$OUT" '+ needy 1.0_1'
assert_eq "$(cat "$ERR")" "chy: needy: warning: needs $fake_a" \
    'stderr is exactly the one bare needs line (map absent)'
assert_installed "$CHY_ROOT" needy 1.0 1
assert_link "$CHY_ROOT/store/needy" 'needy-1.0'
assert_link "$CHY_ROOT/usr/bin/needy-needy-elf-a" \
    '../../store/needy/usr/bin/needy-needy-elf-a'
file_has_line "$CHY_ROOT/db/installed/needy/manifest" 'usr/bin/needy-needy-elf-a'

# --- shlibs.map knows the soname: the (package: <pkg>) suffix ---
printf '%s somepkg\n' "$fake_a" >"$CHY_ROOT/shlibs.map"
elf_install_pkg mapped "$TMPD/needy-elf-a"
run_chy install mapped
assert_rc 0 'mapped install'
assert_eq "$(cat "$ERR")" \
    "chy: mapped: warning: needs $fake_a (package: somepkg)" \
    'map hit appends the package hint'

# --- map parsing: comments and blanks ignored, first two tokens used,
#     extra tokens ignored, first matching line wins ---
{
    printf '# default repo artifact from the translator\n'
    printf '\n'
    printf 'libunrelated.so.99 otherpkg\n'
    printf '%s\tmappkg\textra tokens here are ignored\n' "$fake_a"
    printf '%s loser\n' "$fake_a"
} >"$CHY_ROOT/shlibs.map"
elf_install_pkg mapfmt "$TMPD/needy-elf-a"
run_chy install mapfmt
assert_rc 0 'mapfmt install'
assert_eq "$(cat "$ERR")" \
    "chy: mapfmt: warning: needs $fake_a (package: mappkg)" \
    'first matching significant line wins; extra tokens are ignored'
rm "$CHY_ROOT/shlibs.map"

# --- two ELFs missing the same soname: ONE warning line ---
cp "$TMPD/needy-elf-a" "$TMPD/needy-elf-a2"
elf_install_pkg twins "$TMPD/needy-elf-a" "$TMPD/needy-elf-a2"
run_chy install twins
assert_rc 0 'twins install'
assert_eq "$(cat "$ERR")" "chy: twins: warning: needs $fake_a" \
    'one line per distinct missing soname, not per file'

# --- two distinct missing sonames: one line each, sorted ---
elf_install_pkg pair "$TMPD/needy-elf-b" "$TMPD/needy-elf-a"
run_chy install pair
assert_rc 0 'pair install'
want=$(printf 'chy: pair: warning: needs %s\nchy: pair: warning: needs %s' \
    "$fake_a" "$fake_b")
assert_eq "$(cat "$ERR")" "$want" 'distinct sonames warn once each, sorted'

exit 0
