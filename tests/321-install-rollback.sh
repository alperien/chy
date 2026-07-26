#!/bin/sh
# the install links completely or not at all. When a farm link fails
# mid-commit (steps 8-10) the whole commit rolls back: new links
# removed, new store entry dropped, alias restored, the previous
# install's farm re-linked. A fresh install leaves no trace, a failed
# upgrade doesn't cost the working version. Fault injection is a PATH
# shim over ln that refuses destinations carrying a sentinel (the
# sandbox ignores permission bits, chmod tricks don't work here).
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

REAL_SH=$(command -v sh) || fail 'no sh on the host'
REAL_LN=$(command -v ln) || fail 'no ln on the host'

# The fault ln: silent exit 1 when the destination (last argument) has
# a ZFAULT basename, otherwise hand off to the real ln. Only link_farm
# ever creates a ZFAULT path, aliases and rollback re-links pass
# through untouched.
FAULT_BIN=$TMPD/faultbin
mkdir -p "$FAULT_BIN"
cat >"$FAULT_BIN/ln" <<EOF
#!/bin/sh
for fl_a in "\$@"; do :; done
case \${fl_a##*/} in *ZFAULT*) exit 1 ;; esac
exec $REAL_LN "\$@"
EOF
chmod +x "$FAULT_BIN/ln"

# The shim has to intercept and delegate on this host or the technique
# is unavailable. Probe through a child sh so the lookup uses the new
# PATH. $1 is the inner sh -c positional, the single quotes are meant.
# shellcheck disable=SC2016
if PATH="$FAULT_BIN:$PATH" "$REAL_SH" -c 'ln -s x "$1"' x \
    "$TMPD/probe-ZFAULT" 2>/dev/null; then
    echo 'SKIP: a PATH shim over ln does not intercept on this host'
    exit 0
fi
# shellcheck disable=SC2016
PATH="$FAULT_BIN:$PATH" "$REAL_SH" -c 'ln -s x "$1"' x "$TMPD/probe-ok" \
    || fail 'the fault ln broke plain destinations'

# run_chy_fault ROOT VERB... - run chy with the fault ln first in PATH.
run_chy_fault() {
    rf_root=$1
    shift
    RC=0
    CHY_ROOT="$rf_root" PATH="$FAULT_BIN:$PATH" "$REAL_SH" "$CHY" "$@" \
        >"$TMPD/run.out" 2>"$TMPD/run.err" || RC=$?
    OUT="$TMPD/run.out"
    ERR="$TMPD/run.err"
}

# --- fresh install: a mid-farm link failure leaves no trace at all.
#     usr/bin/aaa links first (LIST is sorted), then zZFAULT fails. ---
mkpkg "$CHY_ROOT" lnfresh 1.0 usr/bin/aaa usr/bin/zZFAULT
run_chy_fault "$CHY_ROOT" install lnfresh
assert_rc 1 'a failed farm link fails the install'
assert_eq "$(cat "$ERR")" \
    'chy: lnfresh: error: cannot link the farm; rolled back' \
    'exact rollback line, nothing else on stderr'
file_has_line "$OUT" '-> lnfresh link lnfresh-1.0'
assert_not_installed "$CHY_ROOT" lnfresh
assert_no_store "$CHY_ROOT" lnfresh 1.0
assert_absent "$CHY_ROOT/usr/bin/aaa"
assert_absent "$CHY_ROOT/usr/bin/zZFAULT"
if [ -d "$CHY_ROOT/usr" ]; then
    assert_eq "$(find "$CHY_ROOT/usr" -type l)" '' 'no farm links leaked'
fi
run_chy list
assert_rc 0
assert_empty_file "$OUT" 'nothing is installed after the rollback'

# --- upgrade: the failed 2.0 commit rolls back to an intact 1.0. The
#     2.0 build stages different bytes at aaa, so survival is provable. ---
up="$TMPD/up"
mkdir -p "$up"
mkpkg "$up" lnup 1.0 usr/bin/aaa usr/bin/keep
run_chy_root "$up" install lnup
assert_rc 0 'lnup 1.0 installs cleanly'

mkpkg "$up" lnup 2.0
cat >"$up/recipes/lnup/build" <<'EOF'
set -eu
mkdir -p "$1$CHY_ROOT/usr/bin"
printf 'v2\n' >"$1$CHY_ROOT/usr/bin/aaa"
printf 'v2\n' >"$1$CHY_ROOT/usr/bin/zZFAULT"
EOF
snap0=$(snap "$up")
run_chy_fault "$up" install lnup
assert_rc 1 'the 2.0 commit fails on the faulted link'
assert_eq "$(cat "$ERR")" \
    'chy: lnup: error: cannot link the farm; rolled back' \
    'exact rollback line for the upgrade'
assert_eq "$(snap "$up")" "$snap0" \
    'a failed commit never costs the working install'
assert_installed "$up" lnup 1.0 1
assert_absent "$up/store/lnup-2.0"
assert_link "$up/store/lnup" 'lnup-1.0'
assert_eq "$(cat "$up/usr/bin/aaa")" \
    "$(pkg_content lnup usr/bin/aaa)" 'aaa still serves the 1.0 payload'
assert_eq "$(cat "$up/usr/bin/keep")" \
    "$(pkg_content lnup usr/bin/keep)" 'keep still serves the 1.0 payload'
assert_absent "$up/usr/bin/zZFAULT"
run_chy_root "$up" list
assert_rc 0
assert_eq "$(cat "$OUT")" 'lnup 1.0 1' 'list shows exactly the 1.0 install'
run_chy_root "$up" doctor
assert_rc 0 'doctor finds nothing after the rollback'
file_has_line "$OUT" 'doctor: clean'

exit 0
