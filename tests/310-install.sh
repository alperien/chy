#!/bin/sh
# install: names processed strictly in order, first failure aborts
# the run but completed installs stay; stdout is only "chy: <name>: ..."
# progress plus the exact completion line. Reinstalls follow the full
# pipeline: a failed rebuild never costs the working install; a successful
# one replaces store entry, alias, farm links and db entry.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- quiet solo install: stdout grammar and exact completion line ---
mkpkg "$CHY_ROOT" solo 1.0 usr/bin/solo-tool
run_chy install solo
assert_rc 0 'solo install'
file_has_line "$OUT" 'chy: solo: installed 1.0 1'
if grep -q -v '^chy: solo: ' "$OUT"; then
    cat "$OUT" >&2
    fail 'stdout carries a line outside the chy: solo: grammar'
fi
assert_empty_file "$ERR" 'clean install is silent on stderr'

# --- order given, abort on first failure, earlier installs kept ---
mkpkg "$CHY_ROOT" ok1 1.0 usr/bin/ok1-tool
mkpkg "$CHY_ROOT" bad 1.0 usr/bin/bad-tool
rm "$CHY_ROOT/recipes/bad/build"
mkpkg "$CHY_ROOT" ok2 1.0 usr/bin/ok2-tool

run_chy install ok1 bad ok2
assert_rc 1 'first failure aborts the run'
file_has_line "$OUT" 'chy: ok1: installed 1.0 1'
file_matches "$ERR" '^chy: bad: error: '
assert_installed "$CHY_ROOT" ok1 1.0 1
assert_eq "$(cat "$CHY_ROOT/usr/bin/ok1-tool")" \
    "$(pkg_content ok1 usr/bin/ok1-tool)" 'ok1 stays installed'
assert_not_installed "$CHY_ROOT" ok2
assert_no_store "$CHY_ROOT" ok2 1.0
assert_absent "$CHY_ROOT/usr/bin/ok2-tool"
if grep -q '^chy: ok2: installed' "$OUT"; then
    fail 'ok2 must never be reached after the bad package'
fi

# --- failed rebuild: the previous version survives completely ---
mkpkg "$CHY_ROOT" re 1.0 usr/bin/re-tool
run_chy install re
assert_rc 0 're 1.0 install'

mkpkg "$CHY_ROOT" re 2.0 usr/bin/re-tool
cat >"$CHY_ROOT/recipes/re/build" <<'EOF'
set -eu
exit 1
EOF
snap0=$(snap "$CHY_ROOT")
run_chy install re
assert_rc 1 'the 2.0 rebuild fails'
assert_eq "$(snap "$CHY_ROOT")" "$snap0" \
    'a failed rebuild never costs the working install'
assert_installed "$CHY_ROOT" re 1.0 1
run_chy list re
assert_rc 0
assert_eq "$(cat "$OUT")" 're 1.0 1' 'still listed at 1.0'
assert_link "$CHY_ROOT/store/re" 're-1.0'
assert_eq "$(cat "$CHY_ROOT/usr/bin/re-tool")" \
    "$(pkg_content re usr/bin/re-tool)" 'old payload still linked'

# --- successful upgrade: old installation replaced wholesale ---
mkpkg "$CHY_ROOT" re 2.0
cat >"$CHY_ROOT/recipes/re/build" <<'EOF'
set -eu
mkdir -p "$1$CHY_ROOT/usr/bin"
printf 're2\n' >"$1$CHY_ROOT/usr/bin/re-tool"
EOF
run_chy install re
assert_rc 0 'upgrade to 2.0'
file_has_line "$OUT" 'chy: re: installed 2.0 1'
assert_installed "$CHY_ROOT" re 2.0 1
assert_link "$CHY_ROOT/store/re" 're-2.0'
assert_absent "$CHY_ROOT/store/re-1.0"
assert_link "$CHY_ROOT/usr/bin/re-tool" '../../store/re/usr/bin/re-tool'
assert_eq "$(cat "$CHY_ROOT/usr/bin/re-tool")" 're2' 'farm serves the new payload'
run_chy list
assert_rc 0
file_has_line "$OUT" 're 2.0 1'
if grep -q '^re 1.0' "$OUT"; then
    fail 'old version still listed after upgrade'
fi

# --- reinstalling the same version is allowed ---
run_chy install re
assert_rc 0 'same-version reinstall'
run_chy list re
assert_eq "$(cat "$OUT")" 're 2.0 1' 'exactly one entry after reinstall'

exit 0
