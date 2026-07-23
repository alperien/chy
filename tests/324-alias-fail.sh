#!/bin/sh
# if pointing the store alias fails, the commit rolls back the
# store entry it just placed and leaves the root as it was (do_install
# step 9). Uses a PATH-shim ln that fails on a sentinel destination.
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

# only meaningful if a PATH shim over ln actually intercepts here
op=$PATH
PATH="$fb:$PATH"
if sh -c 'command -v ln' >/dev/null 2>&1 && "$fb/ln" -s x "$TMPD/probe-ZFAULT" 2>/dev/null; then
    PATH=$op
    echo 'SKIP: fault ln does not intercept on this host'
    exit 0
fi
PATH=$op

# the alias path is store/<name>, so a name carrying the sentinel makes
# the step-9 alias link fail with the store entry (step 8) already placed.
mkpkg "$CHY_ROOT" aliasZFAULT 1.0 usr/bin/tool

op=$PATH
PATH="$fb:$PATH"
run_chy install aliasZFAULT
PATH=$op
assert_rc 1 'a failed alias link fails the install'
file_has "$ERR" 'chy: aliasZFAULT: error: cannot point the alias'
assert_not_installed "$CHY_ROOT" aliasZFAULT
[ ! -e "$CHY_ROOT/store/aliasZFAULT-1.0" ] || fail 'the store entry was not rolled back'
[ ! -e "$CHY_ROOT/store/aliasZFAULT" ] || fail 'a stray alias was left behind'
exit 0
