#!/bin/sh
# Smoke: the scaffold holds. chy runs, reports its version, rejects nonsense.
set -eu
cd "$(dirname "$0")/.." || exit 2

# Only pin that some version prints, not the value, chy may be past
# the 0.1.0 it started at.
v=$(sh chy/chy version)
if [ -z "$v" ]; then
    echo "chy version printed nothing"
    exit 1
fi
case $v in
    'chy: '*|usage*)
        echo "expected a bare version string, got: $v"
        exit 1
        ;;
esac

if sh chy/chy no-such-verb 2>/dev/null; then
    echo "unknown verb should exit nonzero"
    exit 1
fi

exit 0
