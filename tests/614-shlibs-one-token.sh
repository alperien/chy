#!/bin/sh
# step 11 shlibs.map parsing: a mapping needs two tokens. A
# malformed line carrying only the soname is no mapping at all: it must
# not shadow a valid later line for the same soname, and alone it must
# not invent a hint.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

elf_template_init || { echo 'SKIP: no patchable dynamic ELF on this host'; exit 0; }
fake_s=$(elf_fake_soname s)
mk_needy_elf "$TMPD/needy-elf" "$fake_s"

# needy_pkg NAME: a recipe staging the one patched ELF
needy_pkg() {
    np_name=$1
    mkpkg "$CHY_ROOT" "$np_name" 1.0
    {
        printf 'set -eu\n'
        printf "mkdir -p \"\$1\$CHY_ROOT/usr/bin\"\n"
        printf "install -m755 '%s' \"\$1\$CHY_ROOT/usr/bin/%s-elf\"\n" \
            "$TMPD/needy-elf" "$np_name"
    } >"$CHY_ROOT/recipes/$np_name/build"
}

# --- one-token first line, valid second line: the hint must come from
#     the second line, not vanish behind the malformed first ---
printf '%s\n%s realpkg\n' "$fake_s" "$fake_s" >"$CHY_ROOT/shlibs.map"
needy_pkg mapfirst
run_chy install mapfirst
assert_rc 0 'mapfirst install'
assert_eq "$(cat "$ERR")" \
    "chy: mapfirst: warning: needs $fake_s (package: realpkg)" \
    'a one-token line must not shadow the valid mapping below it'

# --- the malformed line alone: a bare warning, no empty hint ---
printf '%s\n' "$fake_s" >"$CHY_ROOT/shlibs.map"
needy_pkg maponly
run_chy install maponly
assert_rc 0 'maponly install'
assert_eq "$(cat "$ERR")" "chy: maponly: warning: needs $fake_s" \
    'a one-token line alone yields the bare warning'

exit 0
