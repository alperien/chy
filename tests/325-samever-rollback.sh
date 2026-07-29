#!/bin/sh
# Reinstalling the version that's already installed must not destroy
# the working install when the commit fails. Old and new store entry
# share a name, so a naive commit would rm -rf the live payload before
# it had a fallback, and a failed farm-link would then leave the db
# saying installed with the store gone and every link dangling. chy
# stages the new tree under a temp name and swaps it in only once the
# commit succeeds, so a failed same-version reinstall keeps the
# previous install. Uses a PATH-shim ln that fails on a sentinel farm
# path (do_install step 10).
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init
real_ln=$(command -v ln)
fb="$TMPD/faultbin"
mkdir -p "$fb"
cat >"$fb/ln" <<EOF
#!/bin/sh
for fa in "\$@"; do fd=\$fa; done
case \${fd##*/} in *ZFAULT*) exit 1 ;; esac
exec $real_ln "\$@"
EOF
chmod +x "$fb/ln"

op=$PATH
PATH="$fb:$PATH"
if sh -c 'command -v ln' >/dev/null 2>&1 && "$fb/ln" -s x "$TMPD/probe-ZFAULT" 2>/dev/null; then
    PATH=$op
    echo 'SKIP: fault ln does not intercept on this host'
    exit 0
fi
PATH=$op

# libz 1.0 ships a keeper library and a sentinel tool. The sentinel
# sorts before the keeper (usr/bin < usr/lib), so the reinstall's
# farm-link fails on it, the keeper's payload is what has to survive.
mkpkg "$CHY_ROOT" libz 1.0 usr/lib/keep.so.1 usr/bin/ZFAULT-tool

run_chy install libz
assert_rc 0 'first install of libz succeeds'
assert_installed "$CHY_ROOT" libz 1.0 1
[ -e "$CHY_ROOT/usr/lib/keep.so.1" ] || fail 'the keeper link resolves after install'

# reinstall the SAME version with the farm-link fault armed
op=$PATH
PATH="$fb:$PATH"
run_chy install libz
PATH=$op
assert_rc 1 'the failed same-version reinstall reports failure'
file_has "$ERR" 'rolled back'

# the previous install must be intact: db, store payload, and the keeper link
assert_installed "$CHY_ROOT" libz 1.0 1
[ -d "$CHY_ROOT/store/libz-1.0" ] || fail 'the live store entry was destroyed'
[ -e "$CHY_ROOT/store/libz-1.0/usr/lib/keep.so.1" ] || fail 'the store payload is gone'
[ -e "$CHY_ROOT/usr/lib/keep.so.1" ] || fail 'the keeper farm link no longer resolves'
run_chy list
assert_rc 0 'list works after the rolled-back reinstall'
file_has_line "$OUT" 'libz 1.0 1'

# no temp staging entry is left behind in the store
[ ! -e "$CHY_ROOT/store/.libz-1.0.new" ] || fail 'a temp staging entry leaked'

exit 0
