# chy

chy is a byte-sized, portable, source-based package manager written in
POSIX shell. 1.5k lines of pretty shell with no dependencies.

Packages are recipe based and easily readable and tweakable

Everything is at $CHY_ROOT, ~/.chy by default. Packages get built into
store/ and get linked into a usr/ symlink farm. chy lives in userland and won't write outside its
root, so deleting the folder is equal to a full uninstall. Running chy with no arguments prints
the list of all options.

    git clone https://github.com/alperien/chy && cd chy
    export CHY_ROOT=$HOME/.chy PATH="$HOME/.chy/usr/bin:$PATH"
    mkdir -p "$CHY_ROOT" && ln -s "$PWD/recipes" "$CHY_ROOT/recipes"
    sh chy/chy install freetype

A recipe is a folder containing text files: version, sources, checksums,
depends, makedepends, a build script, and patches/. A recipe repo is a
directory of recipes, chy builds from whichever one $CHY_ROOT/recipes
points at: the symlink above picks the default repo, but making your
own is encouraged. For quick tweaks there's also
$CHY_ROOT/overlay/<name>, which chy reads before the repo.

The default repo is converted from Void Linux's xbps by the chytrans tool. All fixes go in the
translator, and PRs that edit recipes/ get closed.

MIT.
