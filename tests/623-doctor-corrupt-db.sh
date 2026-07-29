#!/bin/sh
# doctor must not call a damaged root clean. A db entry with an empty version
# file, or with its manifest gone, is corrupt; doctor names it and exits 1
# rather than skipping the entry and reporting clean over the damage it
# exists to find.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

mkpkg "$CHY_ROOT" pkg 1.0 usr/bin/tool
run_chy install pkg
assert_rc 0 'pkg installs'
run_chy doctor
assert_rc 0 'a healthy root is clean'
assert_eq "$(cat "$OUT")" 'doctor: clean'

# --- empty version file ---
: >"$CHY_ROOT/db/installed/pkg/version"
run_chy doctor
assert_rc 1 'an empty version file is a problem'
file_has "$OUT" 'pkg: corrupt db entry'

# --- missing manifest (reinstall to restore, then remove it) ---
run_chy install pkg
assert_rc 0 'reinstall restores the entry'
rm -f "$CHY_ROOT/db/installed/pkg/manifest"
run_chy doctor
assert_rc 1 'a missing manifest is a problem'
file_has "$OUT" 'pkg: corrupt db entry'

exit 0
