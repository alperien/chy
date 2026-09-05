#!/bin/sh
# plain .tar, .tar.zst/.tzst, and .zip sources extract into the build
# dir (with the first-source hoist), and archives carrying absolute or
# parent-traversing members are refused before extraction. Fixtures are
# built at test runtime; a host without the matching tools SKIPs that
# format instead of failing.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# mkarch_recipe ROOT NAME ARCHIVE - recipe whose single source is the
# cache-seeded ARCHIVE; the build asserts the hoisted payload landed in
# cwd and stages one tool.
mkarch_recipe() {
    ma_root=$1 ma_name=$2 ma_arch=$3
    ma_dir="$ma_root/recipes/$ma_name"
    mkdir -p "$ma_dir" "$ma_root/cache"
    printf '1.0\n' >"$ma_dir/version"
    cp "$ma_arch" "$ma_root/cache/${ma_arch##*/}"
    printf 'http://127.0.0.1:9/%s\n' "${ma_arch##*/}" >"$ma_dir/sources"
    sha_of "$ma_root/cache/${ma_arch##*/}" >"$ma_dir/checksums"
    cat >"$ma_dir/build" <<EOF
set -eu
[ -f a.txt ] || { echo '$ma_name: hoisted payload missing' >&2; exit 8; }
mkdir -p "\$1\$CHY_ROOT/usr/bin"
printf 'tool\n' >"\$1\$CHY_ROOT/usr/bin/$ma_name-tool"
EOF
}

# a payload dir: z/a.txt
mkdir -p "$TMPD/z"
printf 'payload\n' >"$TMPD/z/a.txt"

# --- plain .tar ---
command -v tar >/dev/null 2>&1 || { echo 'SKIP: tar unavailable'; exit 0; }
(cd "$TMPD" && tar cf plain.tar z)
mkarch_recipe "$CHY_ROOT" tartest "$TMPD/plain.tar"
run_chy install tartest
assert_rc 0 'plain .tar source installs'
assert_installed "$CHY_ROOT" tartest 1.0 1
assert_eq "$(cat "$CHY_ROOT/usr/bin/tartest-tool")" 'tool'

# --- .tar.zst (needs a zstd-capable tar or unzstd) ---
zst=''
if tar --zstd -cf "$TMPD/probe.tar.zst" -C "$TMPD" z 2>/dev/null; then
    zst=gnu
elif command -v zstd >/dev/null 2>&1; then
    zst=pipe
fi
if [ -n "$zst" ]; then
    case $zst in
        gnu)  (cd "$TMPD" && tar --zstd -cf p.tar.zst z) ;;
        pipe) (cd "$TMPD" && tar cf - z | zstd -q -o p.tar.zst) ;;
    esac
    mkarch_recipe "$CHY_ROOT" zsttest "$TMPD/p.tar.zst"
    run_chy install zsttest
    assert_rc 0 '.tar.zst source installs'
    assert_installed "$CHY_ROOT" zsttest 1.0 1
    # .tzst is the same format under the short suffix
    cp "$TMPD/p.tar.zst" "$TMPD/short.tzst"
    mkarch_recipe "$CHY_ROOT" tzsttest "$TMPD/short.tzst"
    run_chy install tzsttest
    assert_rc 0 '.tzst source installs'
else
    echo 'SKIP: no zstd-capable tar and no zstd CLI'
fi

# --- .zip ---
if command -v zip >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
    (cd "$TMPD" && zip -q -r pkg.zip z)
    mkarch_recipe "$CHY_ROOT" ziptest "$TMPD/pkg.zip"
    run_chy install ziptest
    assert_rc 0 '.zip source installs'
    assert_installed "$CHY_ROOT" ziptest 1.0 1
else
    echo 'SKIP: zip or unzip unavailable'
fi

# --- unsafe members refused: tar with a ../ member ---
mkdir -p "$TMPD/sub"
printf 'evil\n' >"$TMPD/evil.txt"
(cd "$TMPD/sub" && tar -cPf "$TMPD/esc.tar" ../evil.txt)
tar -tf "$TMPD/esc.tar" | grep -q '^\.\./' ||
    fail 'fixture: tar stripped the traversal member anyway'
mkarch_recipe "$CHY_ROOT" escpkg "$TMPD/esc.tar"
snap0=$(snap "$CHY_ROOT")
run_chy install escpkg
assert_rc 1 'a ../ tar member is refused'
file_has "$ERR" 'unsafe path in archive esc.tar; refusing to extract'
assert_eq "$(snap "$CHY_ROOT")" "$snap0" 'refused archive touches nothing'

# --- unsafe members refused: zip with a ../ entry (python builds it;
#     the zip CLI normalizes traversal away) ---
if command -v unzip >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    python3 - "$TMPD/esc.zip" <<'PYEOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("../evil.txt", "evil\n")
PYEOF
    unzip -Z1 "$TMPD/esc.zip" | grep -q '^\.\./' ||
        fail 'fixture: python zip lost the traversal entry'
    mkarch_recipe "$CHY_ROOT" esczip "$TMPD/esc.zip"
    snap1=$(snap "$CHY_ROOT")
    run_chy install esczip
    assert_rc 1 'a ../ zip entry is refused'
    file_has "$ERR" 'unsafe path in archive esc.zip; refusing to extract'
    assert_eq "$(snap "$CHY_ROOT")" "$snap1" 'refused zip touches nothing'
else
    echo 'SKIP: unzip or python3 unavailable for the hostile-zip fixture'
fi

exit 0
