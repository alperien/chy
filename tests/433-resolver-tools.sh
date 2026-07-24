#!/bin/sh
# chy checks for a tool at the moment it needs it and fails with a
# plain message naming it. Resolution leans on sort and awk, with
# either missing the install has to fail loudly (`missing tool: sort` /
# `missing tool: awk`) before ordering: no order line, nothing
# installed, root untouched. The failure mode to catch is a silent
# wrong order.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

REAL_SH=$(command -v sh) || fail 'no sh on the host'

# mk_tools DIR TOOL... - a PATH dir of symlinks to the host tools that
# resolve to real binaries (shell builtins need no entry).
mk_tools() {
    mt_dir=$1
    shift
    mkdir -p "$mt_dir"
    for mt_t in "$@"; do
        mt_p=$(command -v "$mt_t" 2>/dev/null) || continue
        case $mt_p in /*) ln -s "$mt_p" "$mt_dir/$mt_t" ;; esac
    done
}

# has_tool DIR TOOL - whether a child sh restricted to DIR finds TOOL.
has_tool() {
    PATH=$1 "$REAL_SH" -c "command -v $2" >/dev/null 2>&1
}

# run_chy_tools DIR VERB... - run chy with PATH restricted to DIR.
run_chy_tools() {
    rt_dir=$1
    shift
    RC=0
    PATH="$rt_dir" "$REAL_SH" "$CHY" "$@" \
        >"$TMPD/run.out" 2>"$TMPD/run.err" || RC=$?
    OUT="$TMPD/run.out"
    ERR="$TMPD/run.err"
}

TOOLS='sh rm mkdir rmdir tr head cat sed grep find readlink ln cp mv wc
    uniq sha256sum ls env touch'

# app depends dep: the resolution has an edge to order.
mkpkg "$CHY_ROOT" app 1.0 usr/bin/app-tool
mkpkg "$CHY_ROOT" dep 1.0 usr/bin/dep-tool
recipe_list "$CHY_ROOT" app depends dep
snap0=$(snap "$CHY_ROOT")

# --- everything but sort ---
NOSORT=$TMPD/nosort
# shellcheck disable=SC2086
mk_tools "$NOSORT" $TOOLS awk
if has_tool "$NOSORT" sort; then
    echo 'SKIP: cannot construct a PATH without sort on this host'
else
    has_tool "$NOSORT" awk || fail 'the restricted PATH lost awk'
    run_chy_tools "$NOSORT" install app
    assert_rc 1 'resolution without sort fails'
    file_has_line "$ERR" 'chy: install: error: missing tool: sort'
    assert_empty_file "$OUT" 'no order line printed, no pipeline ran'
    assert_eq "$(snap "$CHY_ROOT")" "$snap0" 'root untouched without sort'
    assert_not_installed "$CHY_ROOT" app
    assert_not_installed "$CHY_ROOT" dep
fi

# --- everything but awk ---
NOAWK=$TMPD/noawk
# shellcheck disable=SC2086
mk_tools "$NOAWK" $TOOLS sort
if has_tool "$NOAWK" awk; then
    echo 'SKIP: cannot construct a PATH without awk on this host'
else
    has_tool "$NOAWK" sort || fail 'the restricted PATH lost sort'
    run_chy_tools "$NOAWK" install app
    assert_rc 1 'resolution without awk fails'
    assert_eq "$(cat "$ERR")" 'chy: install: error: missing tool: awk' \
        'exact missing-tool line, nothing else on stderr'
    assert_empty_file "$OUT" 'no order line printed, no pipeline ran'
    assert_eq "$(snap "$CHY_ROOT")" "$snap0" 'root untouched without awk'
    assert_not_installed "$CHY_ROOT" app
    assert_not_installed "$CHY_ROOT" dep
fi

exit 0
