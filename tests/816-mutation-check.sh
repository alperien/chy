#!/bin/sh
# 816: the mutation check (ci/mutation-check.sh).
#
# The probe's suite is stubbed (the real one would recurse). The honest
# stub goes red exactly when chy/chy carries the pinned mutation; the
# dishonest stub always passes. Checks: the probe passes an honest
# suite, fails loudly on a dishonest one, restores chy/chy
# byte-identical both ways, and refuses to run when the pinned mutation
# no longer applies.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

orig_sum=$(sha256sum chy/chy)

# an honest suite: red exactly when the mutation is present
cat >"$TMPD/honest" <<'EOF'
#!/bin/sh
! grep -q '"\$2" != "\$R_VER"' chy/chy
EOF
chmod 755 "$TMPD/honest"

run sh ci/mutation-check.sh --suite "$TMPD/honest"
assert_rc 0 'the probe passes an honest suite'
file_has "$OUT" 'red when broken, green when pristine'
assert_eq "$(sha256sum chy/chy)" "$orig_sum" 'chy restored byte-identical'

# a dishonest suite: always green
cat >"$TMPD/dishonest" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 755 "$TMPD/dishonest"

run sh ci/mutation-check.sh --suite "$TMPD/dishonest"
assert_rc 1 'the probe fails a dishonest suite'
file_has "$OUT" 'PASSED AGAINST BROKEN CODE'
assert_eq "$(sha256sum chy/chy)" "$orig_sum" 'chy restored after the miss'

# a plain broken suite: red even on pristine code
cat >"$TMPD/broken" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod 755 "$TMPD/broken"

run sh ci/mutation-check.sh --suite "$TMPD/broken"
assert_rc 1 'the probe fails a suite that cannot go green'
file_has "$OUT" 'FAILED ON PRISTINE CODE'
assert_eq "$(sha256sum chy/chy)" "$orig_sum" 'chy restored again'

exit 0
