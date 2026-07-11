#!/bin/sh
# Smoke: the scaffold holds. chy runs, reports its version, rejects nonsense.
set -eu
cd "$(dirname "$0")/.." || exit 2

v=$(sh chy/chy version)
if [ "$v" != "0.0.0" ]; then
    echo "expected version 0.0.0, got: $v"
    exit 1
fi

if sh chy/chy no-such-verb 2>/dev/null; then
    echo "unknown verb should exit nonzero"
    exit 1
fi

exit 0
