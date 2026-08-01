#!/bin/sh
# ci/mutation-check.sh - check the suite still catches a real bug.
#
# The check: the suite has to go red on broken code. Apply one pinned
# mutation to chy/chy (retire_prev's version guard inverted, the
# current store tree gets deleted instead of the old one, real and
# damaging), make sure the file actually changed (sed rot is a probe
# defect, not a suite defect), run the suite expecting failure,
# restore, run expecting success. Either expectation missing is a
# nonzero exit, the output says which one.
#
#   mutation-check.sh [--suite CMD]
#
# --suite defaults to "sh ./test". The offline test stubs it, running
# the real suite from inside the suite would recurse.
set -eu

say() { printf 'mutation-check: %s\n' "$1"; }
die() { printf 'mutation-check: error: %s\n' "$1" >&2; exit 1; }

suite='sh ./test'
while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || die "$1 needs a value"
    case $1 in
        --suite) suite=$2 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift 2
done
[ -f chy/chy ] || die 'run from the repo root'

work=$(mktemp -d) || die 'mktemp -d failed'
trap 'cp "$work/chy.orig" chy/chy 2>/dev/null || :; rm -rf "$work"' \
    EXIT INT TERM
cp chy/chy "$work/chy.orig"

sed 's/\[ "\$2" = "\$R_VER" \]/[ "$2" != "$R_VER" ]/' \
    "$work/chy.orig" >chy/chy
if cmp -s "$work/chy.orig" chy/chy; then
    die 'the pinned mutation no longer applies; re-pin it against chy/chy'
fi
say 'mutation applied (retire_prev inverted); expecting the suite red'
if sh -c "$suite" >"$work/red.log" 2>&1; then
    say 'THE SUITE PASSED AGAINST BROKEN CODE; something is wrong'
    exit 1
fi
say 'red as expected; restoring'
cp "$work/chy.orig" chy/chy
say 'expecting the suite green on pristine code'
if ! sh -c "$suite" >"$work/green.log" 2>&1; then
    say 'THE SUITE FAILED ON PRISTINE CODE; the probe or the tree is broken'
    tail -n 20 "$work/green.log" >&2
    exit 1
fi
say 'red when broken, green when pristine'
exit 0
