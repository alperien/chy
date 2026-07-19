#!/bin/sh
# kind: absent means source, `binary` is just a provenance marker, same
# pipeline; anything else errors naming the kind. Launcher convention
# for binary kind: a launcher under usr/bin/ execs the real program with
# LD_LIBRARY_PATH="$CHY_ROOT/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}".
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- kind: binary installs through the normal pipeline ---
mkpkg "$CHY_ROOT" kbin '2.1 3' usr/bin/kbin-tool
printf 'binary\n' >"$CHY_ROOT/recipes/kbin/kind"

run_chy install kbin
assert_rc 0 'kind=binary is accepted'
assert_order_first 'kbin'
file_has_line "$OUT" 'chy: kbin: installed 2.1 3'
assert_empty_file "$ERR" 'script-only binary-kind install is silent on stderr'
assert_installed "$CHY_ROOT" kbin 2.1 3
assert_link "$CHY_ROOT/store/kbin" 'kbin-2.1'
assert_link "$CHY_ROOT/usr/bin/kbin-tool" '../../store/kbin/usr/bin/kbin-tool'
assert_eq "$(cat "$CHY_ROOT/usr/bin/kbin-tool")" \
    "$(pkg_content kbin usr/bin/kbin-tool)" 'binary-kind payload farms normally'
file_has_line "$CHY_ROOT/db/installed/kbin/manifest" 'usr/bin/kbin-tool'

# --- any other kind is still refused, naming the kind ---
mkpkg "$CHY_ROOT" kbad 1.0 usr/bin/kbad-tool
printf 'weird\n' >"$CHY_ROOT/recipes/kbad/kind"
snap0=$(snap "$CHY_ROOT")

run_chy install kbad
assert_rc 1 'kind=weird is rejected'
file_matches "$ERR" '^chy: kbad: error: '
file_has "$ERR" 'weird'
assert_not_installed "$CHY_ROOT" kbad
assert_no_store "$CHY_ROOT" kbad 1.0
assert_eq "$(snap "$CHY_ROOT")" "$snap0" 'a rejected kind leaves the root as it was'

# --- the launcher convention, end to end through the farm ---
# the build sees CHY_ROOT and bakes it into a launcher that execs the
# real program with the farm lib dir prepended; the "vendor program" is
# a script that echoes the LD_LIBRARY_PATH it got.
mkpkg "$CHY_ROOT" blaunch 3.0
printf 'binary\n' >"$CHY_ROOT/recipes/blaunch/kind"
cat >"$CHY_ROOT/recipes/blaunch/build" <<'EOF'
set -eu
mkdir -p "$1$CHY_ROOT/usr/bin"
cat >"$1$CHY_ROOT/usr/bin/blaunch-real" <<'REALEOF'
#!/bin/sh
printf '%s\n' "$LD_LIBRARY_PATH"
REALEOF
chmod 755 "$1$CHY_ROOT/usr/bin/blaunch-real"
cat >"$1$CHY_ROOT/usr/bin/blaunch" <<LAUNCHEOF
#!/bin/sh
LD_LIBRARY_PATH="$CHY_ROOT/usr/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}" exec sh "$CHY_ROOT/usr/bin/blaunch-real" "\$@"
LAUNCHEOF
chmod 755 "$1$CHY_ROOT/usr/bin/blaunch"
EOF

run_chy install blaunch
assert_rc 0 'binary-kind launcher package installs'
file_has_line "$OUT" 'chy: blaunch: installed 3.0 1'
assert_link "$CHY_ROOT/usr/bin/blaunch" '../../store/blaunch/usr/bin/blaunch'

# no prior LD_LIBRARY_PATH: the program sees exactly the farm lib dir
run env LD_LIBRARY_PATH= sh "$CHY_ROOT/usr/bin/blaunch"
assert_rc 0 'launcher runs via sh'
case $(head -n 1 "$OUT") in
    "$CHY_ROOT/usr/lib"*) ;;
    *) dump_streams; fail 'launched program must see LD_LIBRARY_PATH begin with the farm lib dir' ;;
esac
assert_eq "$(cat "$OUT")" "$CHY_ROOT/usr/lib" \
    'with no prior value the farm lib dir stands alone'

# a prior value survives, after the farm lib dir
run env LD_LIBRARY_PATH=/chy-test/prior sh "$CHY_ROOT/usr/bin/blaunch"
assert_rc 0 'launcher runs with a prior LD_LIBRARY_PATH'
assert_eq "$(cat "$OUT")" "$CHY_ROOT/usr/lib:/chy-test/prior" \
    'the prior value is preserved after the farm lib dir'

exit 0
