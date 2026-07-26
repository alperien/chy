#!/bin/sh
# downloads use curl or wget, whichever exists, in that order. A host
# with neither fails at the moment of need, plain message naming the
# missing tool. A verified cache hit needs no downloader at all,
# however many URLs the line carries. Hermetic: chy runs on a private
# PATH built from host tools minus the downloaders, and the wget branch
# goes through a stub that serves only file:// URLs and takes only the
# documented invocation.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# every tool an install needs, minus curl, wget, and ldd (its absence is
# only the pinned runtime-verification warning, never a failure)
bin="$TMPD/bin"
mkdir -p "$bin"
for t in sh awk cat cp find grep head ln mkdir mv readlink rm rmdir \
    sed sha256sum sort tr uniq wc; do
    p=$(command -v "$t") || { echo "SKIP: host lacks $t"; exit 0; }
    ln -s "$p" "$bin/$t"
done

run_min() { # run chy on the minimal PATH
    run env "PATH=$bin" sh "$CHY" "$@"
}

# --- (a) cache miss with neither curl nor wget: the pinned error ---
mkpkg "$CHY_ROOT" nofetch 1.0 usr/bin/nofetch-tool
rm -f "$CHY_ROOT/cache/seed-nofetch.txt"   # force the download path
run_min install nofetch
assert_rc 1 'no downloader fails the install'
file_has_line "$ERR" 'chy: nofetch: error: missing tool: curl or wget'
assert_not_installed "$CHY_ROOT" nofetch
assert_no_store "$CHY_ROOT" nofetch 1.0

# --- (b) wget fallback: no curl, so chy must reach for wget. The first
#     URL is dead, the file:// mirror rescues. The stub rejects anything
#     but `wget -O <out> -- <url>` and logs each URL it was handed. ---
mkdir -p "$TMPD/web"
printf 'wf payload\n' >"$TMPD/web/wf-src.txt"
cat >"$bin/wget" <<EOF
#!/bin/sh
[ "\$#" -eq 4 ] || exit 2
[ "\$1" = -O ] || exit 2
[ "\$3" = -- ] || exit 2
printf '%s\n' "\$4" >>"$TMPD/wget.log"
case \$4 in
    file://*) exec cp "\${4#file://}" "\$2" ;;
    *) exit 4 ;;
esac
EOF
chmod +x "$bin/wget"

r="$CHY_ROOT/recipes/wf"
mkdir -p "$r"
printf '1.0\n' >"$r/version"
printf 'http://127.0.0.1:9/wf-src.txt file://%s/web/wf-src.txt\n' \
    "$TMPD" >"$r/sources"
sha_of "$TMPD/web/wf-src.txt" >"$r/checksums"
cat >"$r/build" <<'EOF'
set -eu
[ "$(cat wf-src.txt)" = 'wf payload' ] || { echo 'wf: bad content' >&2; exit 9; }
mkdir -p "$1$CHY_ROOT/usr/bin"
printf 'w\n' >"$1$CHY_ROOT/usr/bin/wf-tool"
EOF

run_min install wf
assert_rc 0 'wget branch: dead primary, file:// mirror rescues'
file_has_line "$OUT" '+ wf 1.0_1'
assert_installed "$CHY_ROOT" wf 1.0 1
assert_eq "$(sha_of "$CHY_ROOT/cache/wf-src.txt")" \
    "$(sha_of "$TMPD/web/wf-src.txt")" 'cache keyed by the first URL basename'
assert_eq "$(cat "$TMPD/wget.log")" \
    "$(printf 'http://127.0.0.1:9/wf-src.txt\nfile://%s/web/wf-src.txt' "$TMPD")" \
    'URLs walked in order, both through wget'

# --- (c) verified cache hit on a multi-URL line: every URL is dead and
#     the stub serves no http, so success can only come from the cache;
#     an untouched log proves no downloader was consulted at all ---
r="$CHY_ROOT/recipes/ch"
mkdir -p "$r" "$CHY_ROOT/cache"
printf '2.0\n' >"$r/version"
printf 'cache hit payload\n' >"$TMPD/ch-src.txt"
cp "$TMPD/ch-src.txt" "$CHY_ROOT/cache/ch-src.txt"
printf 'http://127.0.0.1:9/ch-src.txt http://127.0.0.1:9/mirror/ch-src.txt\n' \
    >"$r/sources"
sha_of "$TMPD/ch-src.txt" >"$r/checksums"
cat >"$r/build" <<'EOF'
set -eu
[ "$(cat ch-src.txt)" = 'cache hit payload' ] || { echo 'ch: bad content' >&2; exit 9; }
mkdir -p "$1$CHY_ROOT/usr/bin"
printf 'c\n' >"$1$CHY_ROOT/usr/bin/ch-tool"
EOF
log0=$(cat "$TMPD/wget.log")

run_min install ch
assert_rc 0 'a verified cache hit satisfies a line of dead URLs'
file_has_line "$OUT" '+ ch 2.0_1'
assert_installed "$CHY_ROOT" ch 2.0 1
assert_eq "$(sha_of "$CHY_ROOT/cache/ch-src.txt")" \
    "$(sha_of "$TMPD/ch-src.txt")" 'cache file kept'
assert_eq "$(cat "$TMPD/wget.log")" "$log0" 'no download attempted on a hit'

exit 0
