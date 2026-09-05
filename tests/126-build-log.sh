#!/bin/sh
# a failed build's whole session lands in $CHY_ROOT/log/<name>-<version>-
# <utc>.log, the failure message names the log path, and a successful
# build is logged too. The log dir is per-run output, not root state.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- failing build: log exists, carries the build's stderr, message names it ---
mkpkg "$CHY_ROOT" boom 1.0
cat >"$CHY_ROOT/recipes/boom/build" <<'EOF'
set -eu
mkdir -p "$1$CHY_ROOT/usr/bin"
printf 'half\n' >"$1$CHY_ROOT/usr/bin/halfway"
echo 'boom: the compiler exploded' >&2
exit 3
EOF

run_chy install boom
assert_rc 1 'nonzero build exit aborts the install'
assert_not_installed "$CHY_ROOT" boom

logs=$(find "$CHY_ROOT/log" -type f 2>/dev/null | LC_ALL=C sort)
n=$(printf '%s\n' "$logs" | grep -c . || true)
assert_eq "$n" '1' 'exactly one log file for the failed build'
case $logs in
    "$CHY_ROOT/log/boom-1.0-"*".log") ;;
    *) fail "log path must be log/boom-1.0-<ts>.log, got [$logs]" ;;
esac
file_has "$logs" 'boom: the compiler exploded'
file_has "$ERR" "error: build failed (log: $logs)"
assert_absent "$CHY_ROOT/usr/bin/halfway"

# --- successful build: also logged, stdout and stderr both captured ---
mkpkg "$CHY_ROOT" okpkg 2.5 usr/bin/okpkg-tool
printf 'echo "okpkg: built fine"\n' >>"$CHY_ROOT/recipes/okpkg/build"
run_chy install okpkg
# shellcheck disable=SC2086,SC2125
set -- "$CHY_ROOT/log/okpkg-2.5-"*.log
if [ "$#" -eq 1 ] && [ -f "$1" ]; then :; else
    fail 'exactly one okpkg log expected'
fi
file_has "$1" 'okpkg: built fine'
# second granularity in the timestamp: wait so the names differ
sleep 1
# --- a second failing run appends a second log (timestamped, not clobbered) ---
run_chy install boom
assert_rc 1 'boom fails again'
n=$(find "$CHY_ROOT/log" -name 'boom-*' -type f | grep -c . || true)
[ "$n" -ge 2 ] || fail 'the second failed build must leave its own log'

exit 0
