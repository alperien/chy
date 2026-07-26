#!/bin/sh
# steps 11/12: the db entry is written once the farm links are placed
# (step 11), BEFORE the advisory runtime verification (step 12). So an
# install whose store ELF needs an unresolvable soname warns on stderr,
# exits 0, and is a complete normal installed package: whole db entry
# (version, sorted manifest, requested marker), listed, why-visible,
# and doctor reports the same needs finding instead of nothing (no db
# entry would make it a crash stray, which doctor ignores).
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

elf_template_init || { echo 'SKIP: no patchable dynamic ELF on this host'; exit 0; }
fake_w=$(elf_fake_soname w)
mk_needy_elf "$TMPD/needy-elf" "$fake_w"

mkpkg "$CHY_ROOT" warned 1.0
{
    printf 'set -eu\n'
    printf "mkdir -p \"\$1\$CHY_ROOT/usr/bin\"\n"
    printf "printf x >\"\$1\$CHY_ROOT/usr/bin/warned-note.txt\"\n"
    printf "install -m755 '%s' \"\$1\$CHY_ROOT/usr/bin/warned-elf\"\n" "$TMPD/needy-elf"
} >"$CHY_ROOT/recipes/warned/build"

# --- the warning install: exit 0, warning on stderr, completion on stdout ---
run_chy install warned
assert_rc 0 'runtime warnings never affect exit status'
assert_eq "$(cat "$ERR")" "chy: warned: warning: needs $fake_w" \
    'stderr is exactly the one needs warning'
assert_order_first 'warned'
file_has_line "$OUT" '+ warned 1.0_1'

# --- the db entry is whole: version, manifest, marker, placement ---
assert_installed "$CHY_ROOT" warned 1.0 1
assert_eq "$(cat "$CHY_ROOT/db/installed/warned/manifest")" \
    "$(printf 'usr/bin/warned-elf\nusr/bin/warned-note.txt')" \
    'complete sorted manifest despite the warning'
assert_requested "$CHY_ROOT" warned
assert_link "$CHY_ROOT/store/warned" 'warned-1.0'
assert_link "$CHY_ROOT/usr/bin/warned-elf" '../../store/warned/usr/bin/warned-elf'

# --- installed means installed: list sees it ---
run_chy list warned
assert_rc 0 'list warned'
assert_eq "$(cat "$OUT")" 'warned 1.0 1' 'listed like any package'

# --- doctor audits it as a normal installed package: the same needs
#     finding, not silence (crash strays are outside doctor's scope) ---
run_chy doctor
assert_rc 1 'the unresolved soname is a doctor problem'
assert_eq "$(cat "$OUT")" \
    "$(printf 'doctor: warned: needs %s\ndoctor: 1 problem(s)' "$fake_w")" \
    'doctor reads the db entry the warning install wrote'

# --- and why reads its marker ---
run_chy why warned
assert_rc 0 'why warned'
assert_eq "$(cat "$OUT")" 'warned: requested' 'marker recorded and surfaced'

exit 0
