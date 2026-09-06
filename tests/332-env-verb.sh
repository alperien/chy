#!/bin/sh
# `chy env` prints self-contained export lines for eval in a profile.
# Silent (exit 0) on a root that has no bin dir yet; exactly three lines
# once something is installed; extra arguments are a usage error.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- empty root: nothing on stdout, exit 0 (a profile must not print) ---
run_chy env
assert_rc 0 'env on an empty root exits 0'
assert_empty_file "$OUT" 'env on an empty root prints nothing'
assert_empty_file "$ERR" 'env on an empty root is silent on stderr'

# --- with an installed package: three self-contained lines ---
mkpkg "$CHY_ROOT" envpkg 1.0 usr/bin/envtool
run_chy install envpkg
assert_rc 0 'envpkg install must succeed'

run_chy env
assert_rc 0 'env exits 0 with a populated root'
assert_empty_file "$ERR" 'env is silent on stderr'
assert_eq "$(wc -l <"$OUT" | tr -d ' ')" '3' 'env prints exactly three lines'

# shellcheck disable=SC2016
file_has_line "$OUT" 'export PATH="$CHY_ROOT/usr/bin${PATH:+:$PATH}"'
# shellcheck disable=SC2016
file_has_line "$OUT" 'export XDG_DATA_DIRS="$CHY_ROOT/usr/share${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"'
# shellcheck disable=SC2016
file_has_line "$OUT" 'export MANPATH="$CHY_ROOT/usr/share/man${MANPATH:+:$MANPATH}"'

# --- the lines actually work when evaluated ---
chmod 755 "$CHY_ROOT/usr/bin/envtool"   # mkpkg payloads are data; a real
                                        # binary is executable, which is
                                        # what command -v requires
got=$(CHY_ROOT="$CHY_ROOT" CHY="$CHY" sh -c 'eval "$(sh "$CHY" env)"; command -v envtool')
assert_eq "$got" "$CHY_ROOT/usr/bin/envtool" 'eval of env output must put the farm on PATH'

# --- arguments are refused ---
run_chy env extra
assert_rc 2 'env with an argument exits 2'
[ -s "$ERR" ] || fail 'usage expected on stderr for env with an argument'
