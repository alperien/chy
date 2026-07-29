#!/bin/sh
# The reverse-dependency guard matches whole names, not substrings. A
# package "ab" must be removable when the only depends entry that contains
# the text "ab" is another package's dependency on "abc": "abc" is not "ab".
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

mkpkg "$CHY_ROOT" ab 1.0 usr/bin/ab-tool
mkpkg "$CHY_ROOT" abc 1.0 usr/bin/abc-tool
mkpkg "$CHY_ROOT" user 1.0 usr/bin/user-tool
recipe_list "$CHY_ROOT" user depends abc

run_chy install user ab
assert_rc 0 'user pulls abc; ab is requested'
assert_installed "$CHY_ROOT" ab 1.0 1
assert_installed "$CHY_ROOT" abc 1.0 1

# nothing depends on "ab" (user depends on "abc"), so ab is removable
run_chy remove ab
assert_rc 0 'ab is removable: the guard matches abc exactly, not as a substring'
assert_not_installed "$CHY_ROOT" ab
assert_installed "$CHY_ROOT" abc 1.0 1

# and abc is still guarded by user
run_chy remove abc
assert_rc 1 'abc is still required by user'
file_has "$ERR" 'required by: user'

exit 0
