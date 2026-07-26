#!/bin/sh
# ownership at the shallowest depth: a file staged at the top of the
# prefix gets a farm link with no ../ in the target at all,
# `topfile -> store/top/topfile`. Ownership parsing has to take that
# store/-anchored shape, not just the */store/* one deeper links carry:
# doctor's checks, reinstall's conflict scan and remove's unlink all
# read it. Normalize accepts the top-level file, so this hits the plain
# `store/*` branch directly.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- install: exact link shape, manifest entry, payload resolves ---
mkpkg "$CHY_ROOT" top 1.0
cat >"$CHY_ROOT/recipes/top/build" <<'EOF'
set -eu
mkdir -p "$1$CHY_ROOT"
printf 'top:topfile\n' >"$1$CHY_ROOT/topfile"
EOF
run_chy install top
assert_rc 0 'a top-level file installs'
file_has_line "$OUT" '+ top 1.0_1'
assert_link "$CHY_ROOT/topfile" 'store/top/topfile'
assert_eq "$(cat "$CHY_ROOT/topfile")" 'top:topfile' \
    'payload resolves through the link'
file_has_line "$CHY_ROOT/db/installed/top/manifest" 'topfile'

# --- doctor: the store/-anchored target parses as ours, all clean ---
run_chy doctor
assert_rc 0 'doctor is clean'
file_has_line "$OUT" 'doctor: clean'

# --- reinstall: the existing link is recognized as our own, replaced ---
run_chy install top
assert_rc 0 'same-version reinstall over the top-level link'
assert_link "$CHY_ROOT/topfile" 'store/top/topfile'

# --- remove: the owned link goes cleanly, nothing above it to prune ---
run_chy remove top
assert_rc 0 'remove'
file_has_line "$OUT" '- top 1.0_1'
assert_empty_file "$ERR" 'clean removal warns about nothing'
assert_absent "$CHY_ROOT/topfile"
assert_no_store "$CHY_ROOT" top 1.0
assert_not_installed "$CHY_ROOT" top

exit 0
