#!/bin/sh
# doctor: db manifests are filesystem state, hand edits can lose the
# final newline; an unterminated last line is still a manifest line.
# Both manifest walks (check 2 broken links, check 3 drift) have to
# audit that last line, not drop it at EOF.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# chop_nl ROOT NAME: rewrite the manifest with no final newline
chop_nl() {
    cn_m=$1/db/installed/$2/manifest
    printf '%s' "$(cat "$cn_m")" >"$cn_m.chopped" # $() drops the final newline
    mv "$cn_m.chopped" "$cn_m"
    [ "$(( $(tail -c 1 "$cn_m" | wc -l) ))" -eq 0 ] ||
        fail "manifest for $2 still ends in a newline"
}

two_file_pkg() { # two_file_pkg ROOT: install twofile, truncate its manifest
    mkpkg "$1" twofile 1.0 usr/bin/aa-tool usr/bin/zz-tool
    run_chy_root "$1" install twofile
    assert_rc 0 'twofile install'
    assert_eq "$(cat "$1/db/installed/twofile/manifest")" \
        "$(printf 'usr/bin/aa-tool\nusr/bin/zz-tool')" 'zz-tool is the last line'
    chop_nl "$1" twofile
}

# --- the unterminated last line, farm link gone: still audited ---
two_file_pkg "$CHY_ROOT"
rm "$CHY_ROOT/usr/bin/zz-tool"
run_chy doctor
assert_rc 1 'truncated manifest: missing path still found'
want=$(printf 'doctor: twofile: missing usr/bin/zz-tool\ndoctor: 1 problem(s)')
assert_eq "$(cat "$OUT")" "$want" 'check 3 walks the final unterminated line'

# --- the unterminated last line, store file gone: broken link found ---
rb="$TMPD/root-blink"
mkdir -p "$rb"
two_file_pkg "$rb"
rm "$rb/store/twofile-1.0/usr/bin/zz-tool"
run_chy_root "$rb" doctor
assert_rc 1 'truncated manifest: broken link still found'
want=$(printf 'doctor: twofile: broken link usr/bin/zz-tool\ndoctor: 1 problem(s)')
assert_eq "$(cat "$OUT")" "$want" 'check 2 walks the final unterminated line too'

exit 0
