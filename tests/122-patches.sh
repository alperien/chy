#!/bin/sh
# all patches/*.patch and *.diff, one merged list in byte order of
# filename, apply from the build dir root at -p1, or at the level the
# optional patchlevel file names per patch. A patch that doesn't apply
# aborts the build.
#
# Needs patch(1), CI has it. Absent, this test skips.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

if ! command -v patch >/dev/null 2>&1; then
    echo 'SKIP: patch(1) unavailable'
    exit 0
fi

t_init

# The tarball carries data.txt reading "line-one". 05-first.diff makes
# it "line-two", 10-second.patch makes that "line-three". Only the
# merged byte-ordered sequence (.diff before .patch here) applies
# cleanly, so the final content shows both the merge and the order.
mkdir -p "$TMPD/t-patched/patched-2.2"
printf 'line-one\n' >"$TMPD/t-patched/patched-2.2/data.txt"
mktgz "$TMPD/patched-src.tar.gz" "$TMPD/t-patched" patched-2.2

r="$CHY_ROOT/recipes/patched"
mkdir -p "$r/patches"
printf '2.2\n' >"$r/version"
add_source "$CHY_ROOT" patched "$TMPD/patched-src.tar.gz"
cat >"$r/patches/05-first.diff" <<'EOF'
--- a/data.txt
+++ b/data.txt
@@ -1 +1 @@
-line-one
+line-two
EOF
cat >"$r/patches/10-second.patch" <<'EOF'
--- a/data.txt
+++ b/data.txt
@@ -1 +1 @@
-line-two
+line-three
EOF
cat >"$r/build" <<'EOF'
set -eu
mkdir -p "$1$CHY_ROOT/usr/share/patched"
cp data.txt "$1$CHY_ROOT/usr/share/patched/data.txt"
EOF

run_chy install patched
assert_rc 0 'both patches apply in byte order of filename'
file_has_line "$OUT" '+ patched 2.2_1'
assert_eq "$(cat "$CHY_ROOT/usr/share/patched/data.txt")" 'line-three' \
    'patched content visible through the farm'

# --- a patch that does not apply aborts the build; root left as it was ---
mkdir -p "$TMPD/t-pfail/pfail-1.0"
printf 'real-line\n' >"$TMPD/t-pfail/pfail-1.0/data.txt"
mktgz "$TMPD/pfail-src.tar.gz" "$TMPD/t-pfail" pfail-1.0

rf="$CHY_ROOT/recipes/pfail"
mkdir -p "$rf/patches"
printf '1.0\n' >"$rf/version"
add_source "$CHY_ROOT" pfail "$TMPD/pfail-src.tar.gz"
cat >"$rf/patches/00-bad.patch" <<'EOF'
--- a/data.txt
+++ b/data.txt
@@ -1 +1 @@
-no-such-line
+never
EOF
cat >"$rf/build" <<'EOF'
set -eu
mkdir -p "$1$CHY_ROOT/usr/share/pfail"
cp data.txt "$1$CHY_ROOT/usr/share/pfail/data.txt"
EOF

snap0=$(snap "$CHY_ROOT")
run_chy install pfail
assert_rc 1 'a patch that fails to apply aborts the install'
assert_eq "$(snap "$CHY_ROOT")" "$snap0" 'failed patch leaves the root as it was'
assert_not_installed "$CHY_ROOT" pfail
assert_no_store "$CHY_ROOT" pfail 1.0

# --- a bare-header patch applies at the level the optional patchlevel
#     file names; unlisted patches stay at -p1 ---
mkdir -p "$TMPD/t-plevel/plevel-1.0"
printf 'alpha\n' >"$TMPD/t-plevel/plevel-1.0/base.txt"
mktgz "$TMPD/plevel-src.tar.gz" "$TMPD/t-plevel" plevel-1.0

r0="$CHY_ROOT/recipes/plevel"
mkdir -p "$r0/patches"
printf '1.0\n' >"$r0/version"
add_source "$CHY_ROOT" plevel "$TMPD/plevel-src.tar.gz"
cat >"$r0/patches/00-zero.patch" <<'EOF'
--- base.txt
+++ base.txt
@@ -1 +1 @@
-alpha
+beta
EOF
cat >"$r0/patches/10-one.patch" <<'EOF'
--- a/base.txt
+++ b/base.txt
@@ -1 +1 @@
-beta
+gamma
EOF
printf '0 00-zero.patch\n' >"$r0/patchlevel"
cat >"$r0/build" <<'EOF'
set -eu
mkdir -p "$1$CHY_ROOT/usr/share/plevel"
cp base.txt "$1$CHY_ROOT/usr/share/plevel/base.txt"
EOF

run_chy install plevel
assert_rc 0 'mixed strip levels via the patchlevel file'
assert_eq "$(cat "$CHY_ROOT/usr/share/plevel/base.txt")" 'gamma' \
    'both levels applied in order'

# a malformed patchlevel entry fails loudly, before patch runs
run_chy remove plevel
printf 'x 00-zero.patch\n' >"$r0/patchlevel"
run_chy install plevel
assert_rc 1 'a malformed patchlevel entry aborts'
file_has "$ERR" 'bad patchlevel line'

# a DOS-edited entry (trailing CR) still names its level, every other
# recipe file already tolerates CRs
printf '0 00-zero.patch\r\n' >"$r0/patchlevel"
run_chy install plevel
assert_rc 0 'a CR-terminated patchlevel entry still applies'
assert_eq "$(cat "$CHY_ROOT/usr/share/plevel/base.txt")" 'gamma' \
    'levels honored under CRLF'

# an entry naming no patch is a recipe defect, not a silent -p1
run_chy remove plevel
printf '0 no-such.patch\n' >"$r0/patchlevel"
run_chy install plevel
assert_rc 1 'a patchlevel entry naming no patch aborts'
file_has "$ERR" 'bad patchlevel line'

exit 0
