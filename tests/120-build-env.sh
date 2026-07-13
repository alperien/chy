#!/bin/sh
# the build runs as `sh build <destdir> <version>` with cwd = the
# prepared build directory, $1 an absolute staging dir, $2 the version, and
# the documented environment exported (CHY_ROOT, CHY_PREFIX, PATH, CPPFLAGS,
# LDFLAGS, PKG_CONFIG_PATH - appended/prepended to any existing values).
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

mkpkg "$CHY_ROOT" envpkg 3.14
# The build dumps its world to a side file, then stages one real file.
# $TMPD is baked in at generation time, everything else expands at
# build time (escaped). The seed file shows cwd is the prepared build
# dir and that a non-archive first source is copied in verbatim.
cat >"$CHY_ROOT/recipes/envpkg/build" <<EOF
set -eu
{
    printf 'root=%s\n' "\$CHY_ROOT"
    printf 'prefix=%s\n' "\$CHY_PREFIX"
    printf 'path=%s\n' "\$PATH"
    printf 'cpp=%s\n' "\$CPPFLAGS"
    printf 'ld=%s\n' "\$LDFLAGS"
    printf 'pc=%s\n' "\$PKG_CONFIG_PATH"
    printf 'dest=%s\n' "\$1"
    printf 'ver=%s\n' "\$2"
    if [ -f seed-envpkg.txt ]; then
        printf 'cwd_has_seed=yes\n'
    else
        printf 'cwd_has_seed=no\n'
    fi
    if [ "\$(cat seed-envpkg.txt 2>/dev/null)" = 'seed for envpkg' ]; then
        printf 'seed_verbatim=yes\n'
    else
        printf 'seed_verbatim=no\n'
    fi
} >'$TMPD/envdump'
mkdir -p "\$1\$CHY_ROOT/usr/bin"
printf 'x\n' >"\$1\$CHY_ROOT/usr/bin/envtool"
EOF

# Preset values so append/prepend semantics are observable.
run env CPPFLAGS='-DCHYTEST=1' LDFLAGS='-Lchypreset' \
    PKG_CONFIG_PATH='/chypreset/pc' CHY_ROOT="$CHY_ROOT" \
    sh "$CHY" install envpkg
assert_rc 0 'envpkg install must succeed'

d="$TMPD/envdump"
[ -f "$d" ] || fail 'build never ran: no env dump'

val() {
    sed -n "s/^$1=//p" "$d"
}

assert_eq "$(val root)" "$CHY_ROOT" 'CHY_ROOT exported to the build'
assert_eq "$(val prefix)" "$CHY_ROOT/usr" 'CHY_PREFIX is the farm prefix'

case $(val path) in
    "$CHY_ROOT/usr/bin:"*) ;;
    *) fail "PATH does not start with the farm bin: $(val path)" ;;
esac

cpp=$(val cpp)
case $cpp in
    *"-DCHYTEST=1"*"-I$CHY_ROOT/usr/include"*) ;;
    *) fail "CPPFLAGS must keep the preset and append -I farm include: [$cpp]" ;;
esac

ld=$(val ld)
case $ld in
    *"-Lchypreset"*"-L$CHY_ROOT/usr/lib"*) ;;
    *) fail "LDFLAGS must keep the preset and append -L farm lib: [$ld]" ;;
esac
case $ld in
    *"-Wl,-rpath,$CHY_ROOT/usr/lib"*) ;;
    *) fail "LDFLAGS must carry the farm rpath: [$ld]" ;;
esac

pc=$(val pc)
case $pc in
    "$CHY_ROOT/usr/lib/pkgconfig"*) ;;
    *) fail "PKG_CONFIG_PATH must start with the farm pkgconfig: [$pc]" ;;
esac
case $pc in
    *"/chypreset/pc"*) ;;
    *) fail "PKG_CONFIG_PATH must keep the preset value: [$pc]" ;;
esac

dest=$(val dest)
case $dest in
    /*) ;;
    *) fail "\$1 must be an absolute staging dir, got [$dest]" ;;
esac

assert_eq "$(val ver)" '3.14' 'build arg 2 is the version string'
assert_eq "$(val cwd_has_seed)" 'yes' 'cwd is the prepared build directory'
assert_eq "$(val seed_verbatim)" 'yes' 'non-archive first source copied verbatim'

# The staged file must have made it through the pipeline.
assert_link "$CHY_ROOT/usr/bin/envtool" '../../store/envpkg/usr/bin/envtool'
assert_eq "$(cat "$CHY_ROOT/usr/bin/envtool")" 'x' 'staged file reachable via farm'

exit 0
