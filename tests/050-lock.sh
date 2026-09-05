#!/bin/sh
# mutating verbs (install/upgrade/remove) take an exclusive lock over the
# root: a second live chy is refused by name and pid; a lock left behind by
# a dead process is stolen and the run proceeds; read-only verbs ignore the
# lock entirely; the lock is released on exit, including on failure.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

mkpkg "$CHY_ROOT" lpkg 1.0 usr/bin/lpkg-tool

# --- live holder: install refuses ---
sleep 60 &
holder=$!
mkdir -p "$CHY_ROOT/.lock"
printf '%s\n' "$holder" >"$CHY_ROOT/.lock/pid"

run_chy install lpkg
assert_rc 1 'install refuses while another chy holds the lock'
file_has_line "$ERR" "chy: error: another chy is running (pid $holder)"
assert_not_installed "$CHY_ROOT" lpkg

run_chy remove lpkg
assert_rc 1 'remove refuses while locked'
file_has "$ERR" "another chy is running"

run_chy upgrade
assert_rc 1 'upgrade refuses while locked'
file_has "$ERR" "another chy is running"

# --- read-only verbs must NOT lock ---
run_chy list
assert_rc 0 'list succeeds while locked'
run_chy outdated
assert_rc 0 'outdated succeeds while locked'
run_chy provided
assert_rc 0 'provided succeeds while locked'
run_chy version
assert_rc 0 'version succeeds while locked'
run_chy why lpkg
assert_rc 1 'why runs (uninstalled) while locked'
file_has "$ERR" 'not installed'
run_chy doctor
assert_rc 0 'doctor succeeds while locked'
assert_eq "$(cat "$CHY_ROOT/.lock/pid")" "$holder" 'read verbs leave the lock alone'

# --- dead holder: install steals and proceeds ---
kill "$holder" 2>/dev/null || :
wait "$holder" 2>/dev/null || :
run_chy install lpkg
assert_rc 0 'install steals a dead holder lock'
assert_installed "$CHY_ROOT" lpkg 1.0 1

# --- release: the lock is gone after a successful run ---
assert_absent "$CHY_ROOT/.lock"

# --- release on failure too ---
mkpkg "$CHY_ROOT" lbad 1.0
rm -rf "$CHY_ROOT/recipes/lbad/version"
run_chy install lbad
assert_rc 1 'a failing install still releases the lock'
assert_absent "$CHY_ROOT/.lock"

# --- a lock dir with no/unreadable pid file is stealable ---
mkdir -p "$CHY_ROOT/.lock"
run_chy install lpkg
assert_rc 0 'a pid-less lock is stealable'
assert_absent "$CHY_ROOT/.lock"

exit 0
